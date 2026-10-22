defmodule ForgeOpsTracker.StrictPrivacyTest do
  # async: false: the span tests deliver through the shared, process-wide DeliveryQueue, which
  # reads the shared Configuration singleton (same reasoning as TracingTest).
  use ExUnit.Case, async: false

  alias ForgeOpsTracker.{Configuration, EventBuilder, PiiScrubber, StrictPrivacy, TestHttpServer}

  # test/fixtures/strict_privacy_vectors.json, a byte-identical copy of this repo's
  # sdks/strict_privacy_vectors.json, generated from the server's own implementation.
  @vectors Path.expand("../fixtures/strict_privacy_vectors.json", __DIR__)
           |> File.read!()
           |> JSON.decode!()

  defmodule PatientError do
    defexception message: "Couldn't find Invoice with id=8821 for jane@example.com",
                 statement: "SELECT * FROM invoices WHERE id = 8821"
  end

  setup do
    on_exit(fn ->
      Configuration.update(fn _ -> %Configuration{} end)
      ForgeOpsTracker.reset_for_testing()
    end)

    :ok
  end

  defp strict_configuration(overrides \\ %{}) do
    struct(
      %Configuration{
        environment: "production",
        app_module_prefix: "ForgeOpsTracker",
        capture_sql_statement: true,
        strict_privacy: true,
        privacy_allowed_fields: ["error_code", "feature", "nested"]
      },
      overrides
    )
  end

  defp raise_and_rescue do
    raise PatientError
  rescue
    e -> {e, __STACKTRACE__}
  end

  defp build(config) do
    {error, stacktrace} = raise_and_rescue()
    context = %{"error_code" => "E42", feature: 7, nested: %{a: 1}, patient: "Jane Doe"}
    user = %{id: 42, email: "jane@example.com", username: "jane"}

    crumbs = [
      %{
        "category" => "custom",
        "message" => "opened Jane's chart",
        "level" => "info",
        "timestamp" => "t",
        "data" => %{}
      }
    ]

    request = %{
      "transaction_name" => "GET /patients/:id",
      "endpoint" => "GET /patients/:id",
      "trace_id" => "abc"
    }

    {error, EventBuilder.build(config, error, stacktrace, context, user, crumbs, request)}
  end

  test "every fingerprint vector normalizes and hashes exactly" do
    for vector <- @vectors["fingerprint"] do
      assert StrictPrivacy.normalize_message(vector["message"]) == vector["normalized"]
      assert StrictPrivacy.message_fingerprint(vector["message"]) == vector["fingerprint"]
    end

    assert @vectors["fingerprint"] != []
  end

  test "every span_name vector" do
    for vector <- @vectors["span_name"] do
      assert StrictPrivacy.span_name(vector["name"]) == vector["strict"], inspect(vector)
    end
  end

  test "every path vector" do
    for vector <- @vectors["path"] do
      assert StrictPrivacy.strict_path(vector["path"]) == vector["strict"], inspect(vector)
    end
  end

  test "transaction names keep only a raw path's first segment and keep routes" do
    for {name, want} <- [
          {"GET /patients/42/notes", "GET /patients/:path"},
          {"GET /patients/jane-doe", "GET /patients/:path"},
          {"GET /users/:id", "GET /users/:id"},
          {"OrdersController#create", "OrdersController#create"},
          {"/patients/jane-doe-1961", "/patients/:path"},
          {"MyApp.Workers.Sync", "MyApp.Workers.Sync"},
          {"", ""},
          {nil, nil}
        ] do
      assert StrictPrivacy.transaction_name(name) == want, inspect(name)
    end
  end

  test "an error event's raw path transaction name keeps only its first segment" do
    {error, stacktrace} = raise_and_rescue()
    request = %{"transaction_name" => "GET /patients/42"}

    assert EventBuilder.build(strict_configuration(), error, stacktrace, %{}, nil, [], request)[
             "transaction_name"
           ] == "GET /patients/:path"

    assert EventBuilder.build(
             strict_configuration(%{strict_privacy: false}),
             error,
             stacktrace,
             %{},
             nil,
             [],
             request
           )[
             "transaction_name"
           ] == "GET /patients/42"
  end

  test "performance samples reduce a raw path transaction name" do
    for strict <- [true, false] do
      {drain_port, _} = TestHttpServer.start(202)
      configure(drain_port, strict)
      ForgeOpsTracker.PerformanceFlusher.flush()

      {port, requests} = TestHttpServer.start(202)
      configure(port, strict)
      ForgeOpsTracker.record_performance("GET /patients/42/notes", "controller", 10.0)
      ForgeOpsTracker.record_performance("GET /users/:id", "controller", 10.0)
      assert ForgeOpsTracker.PerformanceFlusher.flush() == :ok

      [request] = Agent.get(requests, & &1)

      names =
        request.body
        |> JSON.decode!()
        |> Map.fetch!("samples")
        |> Enum.map(& &1["transaction_name"])

      raw = if strict, do: "GET /patients/:path", else: "GET /patients/42/notes"
      assert Enum.sort(names) == Enum.sort([raw, "GET /users/:id"])
    end
  end

  test "the options come from the environment" do
    assert StrictPrivacy.from_environment(%{
             "FORGE_OPS_STRICT_PRIVACY" => "true",
             "FORGE_OPS_PRIVACY_ALLOWED_FIELDS" => "error_code, feature,,"
           }) == {true, ["error_code", "feature"]}

    assert StrictPrivacy.from_environment(%{}) == {false, []}
    assert %Configuration{}.strict_privacy == false
    assert %Configuration{}.privacy_allowed_fields == []
  end

  test "a strict event carries no free text" do
    {error, payload} = build(strict_configuration())

    assert payload["message"] == ""

    # Of the message as it would otherwise have been sent: after PII scrubbing.
    assert payload["message_fingerprint"] ==
             StrictPrivacy.message_fingerprint(PiiScrubber.scrub_string(Exception.message(error)))

    assert payload["message_fingerprint"] =~ ~r/\A[0-9a-f]{32}\z/

    for key <- ["breadcrumbs", "endpoint", "sql_statement", "tags"] do
      refute Map.has_key?(payload, key), key
    end

    assert payload["context"] == %{"error_code" => "E42", "feature" => 7}
    assert payload["user"] == %{"id" => "42"}
    assert payload["sql_objects"] != nil
    assert payload["transaction_name"] == "GET /patients/:id"
    assert payload["trace_id"] == "abc"
    assert payload["exception_class"] == "ForgeOpsTracker.StrictPrivacyTest.PatientError"
    assert Enum.any?(payload["backtrace"], & &1["in_app"])

    for frame <- payload["backtrace"] do
      refute Map.has_key?(frame, "context_line")
      refute Map.has_key?(frame, "pre_context")
      refute Map.has_key?(frame, "post_context")
    end
  end

  test "context, tags and user are left out when nothing is left" do
    {_error, payload} = build(strict_configuration(%{privacy_allowed_fields: []}))
    refute Map.has_key?(payload, "context")
    refute Map.has_key?(payload, "tags")

    assert StrictPrivacy.event(%{"message" => "boom", "user" => %{email: "jane@example.com"}}, [])
           |> Map.has_key?("user") == false
  end

  test "source context is never read under strict privacy" do
    frame = %{"file" => __ENV__.file, "line" => 1, "method" => "m", "in_app" => true}
    assert EventBuilder.attach_source_context(strict_configuration(), frame) == frame

    assert Map.has_key?(
             EventBuilder.attach_source_context(
               strict_configuration(%{strict_privacy: false}),
               frame
             ),
             "context_line"
           )
  end

  test "strict privacy off leaves events as before" do
    {error, payload} = build(strict_configuration(%{strict_privacy: false}))

    assert payload["message"] == PiiScrubber.scrub_string(Exception.message(error))
    refute Map.has_key?(payload, "message_fingerprint")
    assert payload["endpoint"] == "GET /patients/:id"
    assert payload["sql_statement"] == "SELECT * FROM invoices WHERE id = ?"
    assert payload["tags"] == %{}
    assert Map.has_key?(payload["context"], :patient)
    assert payload["user"] == %{id: 42, email: "jane@example.com", username: "jane"}
    assert length(payload["breadcrumbs"]) == 1
    assert Enum.any?(payload["backtrace"], &Map.has_key?(&1, "context_line"))
  end

  test "no breadcrumbs are recorded under strict privacy" do
    Configuration.update(&%{&1 | strict_privacy: true})
    ForgeOpsTracker.clear_breadcrumbs()
    ForgeOpsTracker.add_breadcrumb("opened Jane's chart")
    assert ForgeOpsTracker.current_breadcrumbs() == []
  end

  defp configure(port, strict_privacy) do
    Configuration.update(fn config ->
      %{
        config
        | dsn: "http://key@localhost:#{port}/api/v1/events",
          environment: "production",
          trace_capture_threshold: 10,
          strict_privacy: strict_privacy
      }
    end)
  end

  defp delivered_trace(requests) do
    deadline = System.monotonic_time(:millisecond) + 3_000

    wait = fn wait ->
      case Agent.get(requests, & &1) do
        [request | _] ->
          JSON.decode!(request.body)

        [] ->
          if System.monotonic_time(:millisecond) > deadline, do: flunk("no trace delivered")
          Process.sleep(10)
          wait.(wait)
      end
    end

    wait.(wait)
  end

  defp record_spans do
    ForgeOpsTracker.start_trace()

    ForgeOpsTracker.record_span(
      "GET https://api.example.com/patients/42?x=1",
      "http",
      DateTime.utc_now(),
      1,
      %{"status" => 200, "url" => "https://api.example.com/patients/42"}
    )

    ForgeOpsTracker.record_span("load patient", "database", DateTime.utc_now(), 1, %{"rows" => 1},
      statement: "SELECT * FROM patients WHERE name = 'Jane'",
      db_system: "postgresql"
    )

    ForgeOpsTracker.finish_trace("GET /patients/42/notes", "controller", DateTime.utc_now(), 250)
  end

  test "strict spans keep only method, host and statement data" do
    {port, requests} = TestHttpServer.start(202)
    configure(port, true)
    record_spans()

    by_name = Map.new(delivered_trace(requests)["spans"], &{&1["name"], &1})
    refute Map.has_key?(by_name["GET api.example.com"], "data")
    refute Map.has_key?(by_name["GET /patients/:path"], "data")

    assert by_name["load patient"]["data"] == %{
             "db.statement" => "SELECT * FROM patients WHERE name = ?",
             "db.system" => "postgresql"
           }
  end

  test "spans are unchanged with strict privacy off" do
    {port, requests} = TestHttpServer.start(202)
    configure(port, false)
    record_spans()

    by_name = Map.new(delivered_trace(requests)["spans"], &{&1["name"], &1})
    assert by_name["GET https://api.example.com/patients/42?x=1"]["data"]["url"] =~ "patients/42"
    assert by_name["GET /patients/42/notes"]["data"] == %{}
    assert by_name["load patient"]["data"]["rows"] == 1
  end
end
