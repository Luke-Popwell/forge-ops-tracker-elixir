defmodule ForgeOpsTracker.TracingTest do
  # async: false: traces are delivered through the shared, process-wide DeliveryQueue, which reads
  # the shared Configuration singleton (same reasoning as DeliveryQueueTest).
  use ExUnit.Case, async: false

  alias ForgeOpsTracker.{Configuration, TestHttpServer}
  alias ForgeOpsTracker.Integrations.{Ecto, Oban}
  alias ForgeOpsTracker.Integrations.Phoenix, as: PhoenixIntegration

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
            release: "abc123",
            trace_capture_threshold: 10
        },
        overrides
      )
    end)
  end

  defp finish(name \\ "GET /x", duration_ms \\ 250) do
    ForgeOpsTracker.finish_trace(name, "controller", DateTime.utc_now(), duration_ms)
  end

  defp delivered_traces(requests) do
    wait_until(fn -> Agent.get(requests, & &1) != [] end)

    Agent.get(requests, & &1)
    |> Enum.map(fn request -> {request.request_line, JSON.decode!(request.body)} end)
  end

  test "delivers a slow trace with nested spans to the spans endpoint, with the wire shape" do
    {port, requests} = TestHttpServer.start(202)
    configure(port)

    ForgeOpsTracker.start_trace()

    result =
      ForgeOpsTracker.span("charge", "service", %{order: 1}, fn ->
        ForgeOpsTracker.record_span("SELECT", "database", DateTime.utc_now(), 3)
        :ok
      end)

    assert result == :ok
    finish("GET /checkout")

    [{request_line, trace}] = delivered_traces(requests)
    assert request_line =~ "POST /api/v1/spans"
    assert trace["trace_id"] =~ ~r/\A[0-9a-f]{32}\z/

    by_name = Map.new(trace["spans"], &{&1["name"], &1})
    root = by_name["GET /checkout"]
    assert root["parent_span_id"] == nil
    assert root["kind"] == "controller"
    assert by_name["charge"]["parent_span_id"] == root["span_id"]
    assert by_name["SELECT"]["parent_span_id"] == by_name["charge"]["span_id"]
    assert by_name["charge"]["span_id"] =~ ~r/\A[0-9a-f]{16}\z/
    assert by_name["charge"]["environment"] == "production"
    assert by_name["charge"]["release"] == "abc123"
    assert by_name["charge"]["data"] == %{"order" => 1}
    assert by_name["charge"]["started_at"] =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/
  end

  test "an unknown kind is sent as other, since the server would reject the whole trace" do
    {port, requests} = TestHttpServer.start(202)
    configure(port)

    ForgeOpsTracker.start_trace()
    ForgeOpsTracker.record_span("q", "db", DateTime.utc_now(), 1)
    ForgeOpsTracker.record_span("r", "database", DateTime.utc_now(), 1)
    finish()

    [{_, trace}] = delivered_traces(requests)
    by_name = Map.new(trace["spans"], &{&1["name"], &1})
    assert by_name["q"]["kind"] == "other"
    assert by_name["r"]["kind"] == "database"
  end

  test "span records and re-raises unchanged when the function raises" do
    {port, requests} = TestHttpServer.start(202)
    configure(port)

    ForgeOpsTracker.start_trace()

    assert_raise RuntimeError, "boom", fn ->
      ForgeOpsTracker.span("bad", fn -> raise "boom" end)
    end

    finish()
    [{_, trace}] = delivered_traces(requests)
    assert "bad" in Enum.map(trace["spans"], & &1["name"])
  end

  test "span just runs the function outside a trace" do
    configure()
    assert ForgeOpsTracker.span("free", fn -> 7 end) == 7
  end

  test "a sibling after a closed span parents under the root, not the closed span" do
    {port, requests} = TestHttpServer.start(202)
    configure(port)

    ForgeOpsTracker.start_trace()
    ForgeOpsTracker.span("outer", fn -> :ok end)
    ForgeOpsTracker.record_span("sibling", "database", DateTime.utc_now(), 1)
    finish()

    [{_, trace}] = delivered_traces(requests)
    by_name = Map.new(trace["spans"], &{&1["name"], &1})
    assert by_name["sibling"]["parent_span_id"] == by_name["GET /x"]["span_id"]
  end

  test "sends nothing when the root is under the threshold, and clears the trace" do
    {port, requests} = TestHttpServer.start(202)
    configure(port)

    ForgeOpsTracker.start_trace()
    finish("GET /fast", 1)

    refute ForgeOpsTracker.Tracing.active?()
    Process.sleep(150)
    assert Agent.get(requests, & &1) == []
  end

  test "track_tracing off disables the whole feature" do
    {port, requests} = TestHttpServer.start(202)
    configure(port, %{track_tracing: false})

    ForgeOpsTracker.start_trace()
    refute ForgeOpsTracker.Tracing.active?()
    ForgeOpsTracker.span("x", fn -> :ok end)
    finish("GET /x", 500)

    Process.sleep(150)
    assert Agent.get(requests, & &1) == []
  end

  test "caps a trace at 500 spans including the root" do
    {port, requests} = TestHttpServer.start(202)
    configure(port)

    ForgeOpsTracker.start_trace()
    for _ <- 1..700, do: ForgeOpsTracker.record_span("q", "database", DateTime.utc_now(), 1)
    finish()

    [{_, trace}] = delivered_traces(requests)
    assert length(trace["spans"]) == 500
  end

  test "the Phoenix integration opens a trace at start and sends it at stop" do
    {port, requests} = TestHttpServer.start(202)
    configure(port)
    conn = %{method: "GET", status: 200, request_path: "/users/42"}
    metadata = %{route: "/users/:id", conn: conn}

    PhoenixIntegration.handle_event([:phoenix, :router_dispatch, :start], %{}, metadata, nil)
    assert ForgeOpsTracker.Tracing.active?()
    ForgeOpsTracker.span("inner", fn -> :ok end)

    PhoenixIntegration.handle_event(
      [:phoenix, :router_dispatch, :stop],
      %{duration: System.convert_time_unit(250, :millisecond, :native)},
      metadata,
      nil
    )

    refute ForgeOpsTracker.Tracing.active?()
    [{_, trace}] = delivered_traces(requests)
    assert Enum.map(trace["spans"], & &1["name"]) |> Enum.sort() == ["GET /users/:id", "inner"]
  end

  test "the Phoenix integration also finishes the trace on an exception" do
    {port, requests} = TestHttpServer.start(202)
    configure(port)
    metadata = %{route: "/boom", conn: %{method: "GET", status: nil, request_path: "/boom"}}

    PhoenixIntegration.handle_event([:phoenix, :router_dispatch, :start], %{}, metadata, nil)

    PhoenixIntegration.handle_event(
      [:phoenix, :router_dispatch, :exception],
      %{duration: System.convert_time_unit(250, :millisecond, :native)},
      metadata,
      nil
    )

    refute ForgeOpsTracker.Tracing.active?()
    [{_, trace}] = delivered_traces(requests)
    assert Enum.map(trace["spans"], & &1["name"]) == ["GET /boom"]
  end

  test "the Ecto integration adds a database span named for the query, never the SQL" do
    {port, requests} = TestHttpServer.start(202)
    configure(port)

    ForgeOpsTracker.start_trace()

    Ecto.handle_event(
      [:my_app, :repo, :query],
      %{total_time: System.convert_time_unit(5, :millisecond, :native)},
      %{query: "SELECT * FROM users WHERE email = 'a@b.com'", source: "users"},
      nil
    )

    finish()
    [{_, trace}] = delivered_traces(requests)
    span = Enum.find(trace["spans"], &(&1["kind"] == "database"))
    assert span["name"] == "SELECT users"
    refute JSON.encode!(trace) =~ "a@b.com"
  end

  test "the Oban integration traces a slow job as a job root span" do
    {port, requests} = TestHttpServer.start(202)
    configure(port)
    metadata = %{job: %{worker: "MyApp.Worker"}, state: :success}

    Oban.handle_event([:oban, :job, :start], %{}, metadata, nil)
    assert ForgeOpsTracker.Tracing.active?()

    Oban.handle_event(
      [:oban, :job, :stop],
      %{duration: System.convert_time_unit(250, :millisecond, :native)},
      metadata,
      nil
    )

    [{_, trace}] = delivered_traces(requests)
    [root] = trace["spans"]
    assert root["name"] == "MyApp.Worker"
    assert root["kind"] == "job"
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
