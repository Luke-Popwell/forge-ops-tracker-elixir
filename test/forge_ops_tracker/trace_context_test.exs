defmodule ForgeOpsTracker.TraceContextTest do
  # async: false: events and traces are delivered through the shared, process-wide DeliveryQueue,
  # which reads the shared Configuration singleton (same reasoning as TracingTest).
  use ExUnit.Case, async: false

  alias ForgeOpsTracker.{Configuration, EventBuilder, TestHttpServer, TraceParent, Tracing}
  alias ForgeOpsTracker.Integrations.Oban
  alias ForgeOpsTracker.Integrations.Phoenix, as: PhoenixIntegration

  @trace_id "4bf92f3577b34da6a3ce929d0e0e4736"
  @parent_id "00f067aa0ba902b7"
  @header "00-#{@trace_id}-#{@parent_id}-01"

  # Raises from inside a Phoenix-shaped request: the router's :start and :exception telemetry
  # events run in this process exactly as Phoenix.Router emits them around a controller that
  # raises, then the process crashes, so the crash report reaches ForgeOpsTracker.LoggerHandler
  # only after the request's trace has been finished.
  defmodule CrashingRequest do
    @moduledoc false
    use GenServer
    def start_link(conn), do: GenServer.start_link(__MODULE__, conn)
    def init(conn), do: {:ok, conn}

    def handle_call(:request, _from, conn) do
      metadata = %{route: "/checkout/:cart", conn: conn}
      PhoenixIntegration.handle_event([:phoenix, :router_dispatch, :start], %{}, metadata, nil)
      error = RuntimeError.exception("checkout exploded")

      PhoenixIntegration.handle_event(
        [:phoenix, :router_dispatch, :exception],
        %{duration: System.convert_time_unit(2, :millisecond, :native)},
        Map.merge(metadata, %{kind: :error, reason: error, stacktrace: []}),
        nil
      )

      raise error
    end
  end

  setup do
    on_exit(fn ->
      Configuration.update(fn _ -> %Configuration{} end)
      ForgeOpsTracker.reset_for_testing()
    end)

    :ok
  end

  defp configure(port \\ 1, overrides \\ %{}) do
    Configuration.update(fn config ->
      struct(
        %{
          config
          | dsn: "http://key@localhost:#{port}/api/v1/events",
            environment: "production",
            release: "abc123"
        },
        overrides
      )
    end)
  end

  defp conn(method, headers),
    do: %{method: method, status: 200, request_path: "/x", req_headers: headers}

  defp delivered(requests, count) do
    wait_until(fn -> length(Agent.get(requests, & &1)) >= count end)
    # Give anything unexpected a moment to arrive too, so a count assertion means something.
    Process.sleep(50)

    Agent.get(requests, & &1)
    |> Enum.map(fn request ->
      kind = if request.request_line =~ "/spans", do: :trace, else: :event
      {kind, JSON.decode!(request.body)}
    end)
  end

  defp of_kind(delivered, kind), do: for({^kind, body} <- delivered, do: body)

  describe "TraceParent" do
    test "parses a valid header, trimming whitespace" do
      assert TraceParent.parse(@header) == %{trace_id: @trace_id, parent_span_id: @parent_id}
      assert TraceParent.parse(" #{@header}\n").trace_id == @trace_id
    end

    test "accepts a future version with extra fields" do
      assert TraceParent.parse("01-#{@trace_id}-#{@parent_id}-01-extra").trace_id == @trace_id
    end

    test "rejects invalid headers" do
      for value <- [
            nil,
            42,
            "",
            "not-a-traceparent",
            "00-#{String.upcase(@trace_id)}-#{@parent_id}-01",
            "ff-#{@trace_id}-#{@parent_id}-01",
            "00-#{String.duplicate("0", 32)}-#{@parent_id}-01",
            "00-#{@trace_id}-#{String.duplicate("0", 16)}-01",
            "00-#{String.slice(@trace_id, 1..-1//1)}-#{@parent_id}-01",
            "#{@header}-extra",
            "00-#{@trace_id}-#{@parent_id}"
          ] do
        assert TraceParent.parse(value) == nil, "expected #{inspect(value)} to be rejected"
      end
    end

    test "builds and generates W3C ids" do
      assert TraceParent.build(@trace_id, @parent_id) == @header
      assert TraceParent.generate_trace_id() =~ ~r/\A[0-9a-f]{32}\z/
      assert TraceParent.generate_span_id() =~ ~r/\A[0-9a-f]{16}\z/
    end
  end

  describe "propagation targets" do
    test "every host by default, none with propagate_traces off" do
      config = %Configuration{}
      assert config.propagate_traces == true
      assert config.trace_propagation_targets == nil
      assert Configuration.propagate_trace?(config, "anything.example")

      refute Configuration.propagate_trace?(
               %{config | propagate_traces: false},
               "anything.example"
             )
    end

    test "hosts match on a dot boundary, ignoring case and a leading dot; Regexes match the host" do
      config = %Configuration{trace_propagation_targets: [".Example.com", ~r/\A10\.0\./]}

      assert Configuration.propagate_trace?(config, "example.com")
      assert Configuration.propagate_trace?(config, "API.example.com")
      refute Configuration.propagate_trace?(config, "badexample.com")
      refute Configuration.propagate_trace?(config, "example.com.evil.test")
      assert Configuration.propagate_trace?(config, "10.0.3.4")
      refute Configuration.propagate_trace?(config, "110.0.3.4")
      refute Configuration.propagate_trace?(config, nil)

      refute Configuration.propagate_trace?(
               %{config | trace_propagation_targets: []},
               "example.com"
             )
    end
  end

  test "error fields are top level, left out when unknown, and never scrubbed" do
    fields = %{"trace_id" => @trace_id, "endpoint" => "GET /users/:a@b.co"}

    payload =
      EventBuilder.build(
        %Configuration{},
        RuntimeError.exception("boom"),
        [],
        %{},
        nil,
        [],
        fields
      )

    assert payload["trace_id"] == @trace_id
    assert payload["endpoint"] == "GET /users/:a@b.co"
    refute Map.has_key?(payload, "transaction_name")

    refute Map.has_key?(
             EventBuilder.build(%Configuration{}, RuntimeError.exception("boom"), []),
             "trace_id"
           )
  end

  test "a continued request's trace id, name and endpoint reach a captured error, and its fast trace is sent" do
    {port, requests} = TestHttpServer.start(202)
    configure(port)
    metadata = %{route: "/orders/:id", conn: conn("GET", [{"traceparent", @header}])}

    PhoenixIntegration.handle_event([:phoenix, :router_dispatch, :start], %{}, metadata, nil)
    assert ForgeOpsTracker.current_trace_id() == @trace_id
    ForgeOpsTracker.capture_exception(RuntimeError.exception("handled"), [])

    PhoenixIntegration.handle_event(
      [:phoenix, :router_dispatch, :stop],
      %{duration: System.convert_time_unit(2, :millisecond, :native)},
      metadata,
      nil
    )

    delivered = delivered(requests, 2)
    [event] = of_kind(delivered, :event)
    [trace] = of_kind(delivered, :trace)

    assert event["trace_id"] == @trace_id
    assert event["transaction_name"] == "GET /orders/:id"
    assert event["endpoint"] == "GET /orders/:id"
    assert trace["trace_id"] == @trace_id
    [root] = trace["spans"]
    assert root["parent_span_id"] == @parent_id
    assert ForgeOpsTracker.current_trace_id() == nil
  end

  test "a request that raises is reported by the crash handler with its context, and its trace is sent" do
    {port, requests} = TestHttpServer.start(202)

    ForgeOpsTracker.init(
      dsn: "http://key@localhost:#{port}/api/v1/events",
      environment: "production"
    )

    ForgeOpsTracker.install_handlers()

    {:ok, pid} = CrashingRequest.start_link(conn("POST", [{"traceparent", @header}]))
    Process.unlink(pid)
    ref = Process.monitor(pid)
    catch_exit(GenServer.call(pid, :request))
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000

    delivered = delivered(requests, 2)
    [event] = of_kind(delivered, :event)
    [trace] = of_kind(delivered, :trace)

    assert event["message"] =~ "checkout exploded"
    assert event["trace_id"] == @trace_id
    assert event["transaction_name"] == "POST /checkout/:cart"
    assert event["endpoint"] == "POST /checkout/:cart"
    assert trace["trace_id"] == @trace_id
  end

  test "a remembered escaped error only applies to that same error" do
    configure()
    ForgeOpsTracker.start_trace(@header)
    error = RuntimeError.exception("escaped")
    Tracing.snapshot_escaped(error)
    ForgeOpsTracker.finish_trace("GET /x", DateTime.utc_now(), 1)

    assert Tracing.error_fields(error) == %{"trace_id" => @trace_id}
    assert Tracing.error_fields(RuntimeError.exception("another")) == %{}

    assert Tracing.error_fields(%{__struct__: Plug.Conn.WrapperError, reason: error}) == %{
             "trace_id" => @trace_id
           }

    ForgeOpsTracker.start_trace()
    ForgeOpsTracker.finish_trace("GET /y", DateTime.utc_now(), 1)
    assert Tracing.error_fields(error) == %{}
  end

  test "a malformed header starts a fresh trace with no remote parent" do
    {port, requests} = TestHttpServer.start(202)
    configure(port, %{trace_capture_threshold: 0})

    ForgeOpsTracker.start_trace("00-#{String.upcase(@trace_id)}-#{@parent_id}-01")
    fresh = ForgeOpsTracker.current_trace_id()
    ForgeOpsTracker.finish_trace("GET /x", DateTime.utc_now(), 1)

    [trace] = delivered(requests, 1) |> of_kind(:trace)
    assert fresh =~ ~r/\A[0-9a-f]{32}\z/
    assert fresh != @trace_id
    assert trace["trace_id"] == fresh
    assert hd(trace["spans"])["parent_span_id"] == nil
  end

  test "with tracing off a request still gets a trace id, but no trace is sent" do
    {port, requests} = TestHttpServer.start(202)
    configure(port, %{track_tracing: false})

    ForgeOpsTracker.start_trace(@header)
    ForgeOpsTracker.capture_exception(RuntimeError.exception("boom"), [])
    headers = ForgeOpsTracker.http_span("GET", "https://api.example.com/", & &1)
    ForgeOpsTracker.finish_trace("GET /x", DateTime.utc_now(), 5_000)

    [{:event, event}] = delivered(requests, 1)
    assert event["trace_id"] == @trace_id
    assert [{"traceparent", "00-" <> @trace_id <> _rest}] = headers
  end

  test "nothing starts when the client is not enabled, and errors outside a trace are unchanged" do
    configure(1, %{environment: "development"})
    ForgeOpsTracker.start_trace(@header)
    assert ForgeOpsTracker.current_trace_id() == nil
    assert Tracing.error_fields(RuntimeError.exception("boom")) == %{}
    assert ForgeOpsTracker.http_span("GET", "https://api.example.com/", & &1) == []
  end

  test "http_span hands over a traceparent naming its own recorded span" do
    {port, requests} = TestHttpServer.start(202)
    configure(port)
    ForgeOpsTracker.start_trace(@header)

    result =
      ForgeOpsTracker.http_span(
        :post,
        "https://Payments.Example.com:8443/charges/42?token=x",
        %{attempt: 1},
        fn headers ->
          send(self(), {:headers, headers})
          :response
        end
      )

    ForgeOpsTracker.capture_exception(RuntimeError.exception("boom"), [])
    ForgeOpsTracker.finish_trace("POST /checkout", DateTime.utc_now(), 1)

    assert result == :response
    assert_received {:headers, [{"traceparent", header}]}
    parsed = TraceParent.parse(header)
    assert parsed.trace_id == @trace_id

    [trace] = delivered(requests, 2) |> of_kind(:trace)
    [root, http] = trace["spans"]
    assert http["name"] == "POST payments.example.com"
    assert http["kind"] == "http"
    assert http["span_id"] == parsed.parent_span_id
    assert http["parent_span_id"] == root["span_id"]
    assert http["data"] == %{"attempt" => 1}
  end

  test "http_span records the span and re-raises when the call raises" do
    {port, requests} = TestHttpServer.start(202)
    configure(port, %{trace_capture_threshold: 0})
    ForgeOpsTracker.start_trace()

    assert_raise RuntimeError, "connection refused", fn ->
      ForgeOpsTracker.http_span("GET", "https://api.example.com/", fn _headers ->
        raise "connection refused"
      end)
    end

    ForgeOpsTracker.finish_trace("GET /x", DateTime.utc_now(), 1)
    [trace] = delivered(requests, 1) |> of_kind(:trace)
    assert Enum.at(trace["spans"], 1)["name"] == "GET api.example.com"
  end

  test "http_span sends no header to a host outside the targets, or with propagation off" do
    configure(1, %{trace_propagation_targets: ["internal.example"]})
    ForgeOpsTracker.start_trace()

    assert ForgeOpsTracker.http_span("GET", "https://api.thirdparty.test/x", & &1) == []

    assert [{"traceparent", _}] =
             ForgeOpsTracker.http_span("GET", "https://orders.internal.example/x", & &1)

    Configuration.update(&%{&1 | propagate_traces: false})
    assert ForgeOpsTracker.http_span("GET", "https://orders.internal.example/x", & &1) == []
  end

  test "an Oban job that fails for good reports with the job's trace id, and its trace is sent" do
    {port, requests} = TestHttpServer.start(202)
    configure(port)
    metadata = %{job: %{worker: "MyApp.Worker"}}

    Oban.handle_event([:oban, :job, :start], %{}, metadata, nil)
    trace_id = ForgeOpsTracker.current_trace_id()

    Oban.handle_event(
      [:oban, :job, :exception],
      %{duration: System.convert_time_unit(2, :millisecond, :native)},
      Map.merge(metadata, %{
        state: :discard,
        reason: RuntimeError.exception("job failed"),
        stacktrace: []
      }),
      nil
    )

    delivered = delivered(requests, 2)
    assert [%{"trace_id" => ^trace_id}] = of_kind(delivered, :event)
    assert [%{"trace_id" => ^trace_id}] = of_kind(delivered, :trace)
  end

  defp wait_until(predicate, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    cond do
      predicate.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        wait_until(predicate, deadline)
    end
  end
end
