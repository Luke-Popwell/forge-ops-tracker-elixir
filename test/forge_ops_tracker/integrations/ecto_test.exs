defmodule ForgeOpsTracker.Integrations.EctoTest do
  # async: false: handle_event/4 ultimately records into the shared, process-wide
  # PerformanceFlusher singleton, same reasoning as PerformanceFlusherTest's own async: false.
  use ExUnit.Case, async: false

  alias ForgeOpsTracker.{BreadcrumbBuffer, Configuration}
  alias ForgeOpsTracker.Integrations.Ecto, as: EctoIntegration

  setup do
    # Start from empty buckets: PerformanceFlusher is shared by every test module, and the ones
    # that drive an integration for another purpose (TracingTest, TraceContextTest) leave their
    # timings in it, some under the very keys asserted on here. Which module ran last depends
    # on the seed, so cleaning up only after each test here was never enough.
    :sys.replace_state(ForgeOpsTracker.PerformanceFlusher, &%{&1 | buckets: %{}})

    on_exit(fn ->
      Configuration.update(fn _ -> %Configuration{} end)
      :sys.replace_state(ForgeOpsTracker.PerformanceFlusher, &%{&1 | buckets: %{}})
      BreadcrumbBuffer.clear()
    end)

    Configuration.update(fn config ->
      %{config | dsn: "http://key@localhost:1/api/v1/events", environment: "production"}
    end)

    :ok
  end

  # Shaped exactly like the real telemetry_prefix ++ [:query] event, verified directly against
  # the installed ecto_sql source (Ecto.Adapters.SQL's own query logging): measurements.total_time
  # is already query_time + decode_time + queue_time summed, native time units; metadata.source is
  # the table name for an Ecto.Query-built query, nil for a raw SQL call.
  defp measurements(ms), do: %{total_time: System.convert_time_unit(ms, :millisecond, :native)}

  test "uses metadata.source directly when it's an Ecto.Query-built query" do
    metadata = %{query: "SELECT u0.\"id\" FROM \"users\" AS u0", source: "users"}

    EctoIntegration.handle_event([:my_app, :repo, :query], measurements(12), metadata, nil)

    bucket = :sys.get_state(ForgeOpsTracker.PerformanceFlusher).buckets[{"SELECT users", "query"}]
    assert bucket.count == 1
    assert_in_delta bucket.max_duration_ms, 12.0, 1.0
  end

  test "falls back to QueryNaming's own regex extraction for a raw SQL call with no source" do
    metadata = %{query: "PRAGMA foreign_keys = ON", source: nil}

    EctoIntegration.handle_event([:my_app, :repo, :query], measurements(3), metadata, nil)

    bucket = :sys.get_state(ForgeOpsTracker.PerformanceFlusher).buckets[{"PRAGMA", "query"}]
    assert bucket.count == 1
  end

  test "records an automatic query breadcrumb with the same transaction_name and duration" do
    metadata = %{query: "SELECT u0.\"id\" FROM \"users\" AS u0", source: "users"}

    EctoIntegration.handle_event([:my_app, :repo, :query], measurements(12), metadata, nil)

    [crumb] = BreadcrumbBuffer.all()
    assert crumb["category"] == "query"
    assert crumb["message"] == "SELECT users"
    assert crumb["level"] == "info"
    assert_in_delta crumb["data"][:duration_ms], 12.0, 1.0
  end

  defmodule FakeRepo do
    def config, do: [telemetry_prefix: [:my_app, :repo]]
  end

  test "attach/1 computes the event name from the given repo's own telemetry_prefix" do
    assert EctoIntegration.attach(FakeRepo) == :ok
    assert EctoIntegration.attach(FakeRepo) == :ok

    :telemetry.execute([:my_app, :repo, :query], measurements(9), %{
      query: "SELECT 1",
      source: nil
    })

    bucket = :sys.get_state(ForgeOpsTracker.PerformanceFlusher).buckets[{"SELECT", "query"}]
    assert bucket.count == 1
  end

  # Masked SQL on database spans, and the opt-in EXPLAIN on PostgreSQL

  defmodule FakePostgresRepo do
    @moduledoc false
    # Stands in for an Ecto repo on Ecto.Adapters.Postgres: reports every call to the test process
    # registered under :persistent_term, with the pid it was called from.
    def config, do: [telemetry_prefix: [:my_app, :pg_repo]]
    def __adapter__, do: Ecto.Adapters.Postgres

    def transaction(fun) do
      report({:transaction, Process.get(:"$callers", [])})
      fun.()
      {:ok, :committed}
    catch
      {:fake_rollback, value} ->
        report({:rollback})
        {:error, value}
    end

    def query!(sql, params, opts) do
      report({:query, sql, params, opts})

      if :persistent_term.get({__MODULE__, :fail_on}, nil) &&
           String.contains?(sql, :persistent_term.get({__MODULE__, :fail_on})) do
        raise "permission denied for table users"
      end

      if String.starts_with?(sql, "EXPLAIN"),
        do: %{rows: [[[%{"Plan" => %{"Index Cond" => "(email = 'a@b.co'::text)"}}]]]},
        else: %{rows: []}
    end

    def rollback(value), do: throw({:fake_rollback, value})

    defp report(call) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:repo, self(), call})
    end
  end

  defp use_fake_postgres_repo(fail_on \\ nil) do
    :persistent_term.put({FakePostgresRepo, :test_pid}, self())
    :persistent_term.put({FakePostgresRepo, :fail_on}, fail_on)

    on_exit(fn ->
      :persistent_term.erase({FakePostgresRepo, :test_pid})
      :persistent_term.erase({FakePostgresRepo, :fail_on})
    end)
  end

  defp start_trace_and_capture do
    {port, requests} = ForgeOpsTracker.TestHttpServer.start(202)

    Configuration.update(fn config ->
      %{
        config
        | dsn: "http://key@localhost:#{port}/api/v1/events",
          environment: "production",
          trace_capture_threshold: 0
      }
    end)

    ForgeOpsTracker.start_trace()
    requests
  end

  defp delivered(requests, path, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    found = Enum.filter(Agent.get(requests, & &1), &(&1.request_line =~ path))

    cond do
      found != [] ->
        found

      System.monotonic_time(:millisecond) > deadline ->
        flunk("nothing was delivered to #{path}")

      true ->
        Process.sleep(10)
        delivered(requests, path, deadline)
    end
  end

  test "the database span carries the masked statement and the repo's db.system" do
    requests = start_trace_and_capture()

    EctoIntegration.handle_event(
      [:my_app, :pg_repo, :query],
      measurements(4),
      %{
        query:
          "SELECT u0.\"id\" FROM \"users\" AS u0 WHERE u0.\"email\" = 'a@b.co' AND u0.\"id\" = $1",
        source: "users",
        params: [42],
        repo: FakePostgresRepo
      },
      %{repo: FakePostgresRepo}
    )

    ForgeOpsTracker.finish_trace("GET /", "controller", DateTime.utc_now(), 10)

    [request] = delivered(requests, "/api/v1/spans")
    refute request.body =~ "a@b.co"

    span =
      request.body
      |> JSON.decode!()
      |> Map.fetch!("spans")
      |> Enum.find(&(&1["kind"] == "database"))

    assert span["data"] == %{
             "db.statement" =>
               "SELECT u0.\"id\" FROM \"users\" AS u0 WHERE u0.\"email\" = ? AND u0.\"id\" = $1",
             "db.system" => "postgresql"
           }
  end

  test "a repo whose adapter can't be told still gets the masked statement, without db.system" do
    requests = start_trace_and_capture()

    EctoIntegration.handle_event(
      [:my_app, :repo, :query],
      measurements(4),
      %{query: "SELECT 1", source: nil},
      %{repo: FakeRepo}
    )

    ForgeOpsTracker.finish_trace("GET /", "controller", DateTime.utc_now(), 10)
    [request] = delivered(requests, "/api/v1/spans")

    span =
      request.body
      |> JSON.decode!()
      |> Map.fetch!("spans")
      |> Enum.find(&(&1["kind"] == "database"))

    assert span["data"] == %{"db.statement" => "SELECT ?"}
  end

  test "a slow Postgres SELECT is explained from the planner's own process on a fresh read-only transaction" do
    use_fake_postgres_repo()
    requests = start_trace_and_capture()

    Configuration.update(fn config ->
      %{config | explain_slow_queries: true, explain_threshold_ms: 0}
    end)

    sql = "SELECT u0.\"id\" FROM \"users\" AS u0 WHERE u0.\"email\" = $1"

    EctoIntegration.handle_event(
      [:my_app, :pg_repo, :query],
      measurements(900),
      %{query: sql, source: "users", params: ["a@b.co"], repo: FakePostgresRepo},
      %{repo: FakePostgresRepo}
    )

    test_pid = self()
    assert_receive {:repo, pid, {:transaction, callers}}, 2_000
    refute pid == test_pid
    refute test_pid in callers

    assert_receive {:repo, ^pid, {:query, "SET TRANSACTION READ ONLY", [], [log: false]}}

    assert_receive {:repo, ^pid, {:query, "SET LOCAL statement_timeout = '2s'", [], [log: false]}}

    assert_receive {:repo, ^pid,
                    {:query, "EXPLAIN (FORMAT JSON) " <> ^sql, ["a@b.co"], [log: false]}}

    assert_receive {:repo, ^pid, {:rollback}}

    [request] = delivered(requests, "/api/v1/query_plans")
    refute request.body =~ "a@b.co"
    payload = JSON.decode!(request.body)
    assert payload["statement"] == sql
    assert payload["db_system"] == "postgresql"
    assert [%{"Plan" => %{"Index Cond" => "(email = ?::text)"}}] = payload["plan"]
  end

  test "writes and non-Postgres repos are never explained" do
    use_fake_postgres_repo()
    start_trace_and_capture()

    Configuration.update(fn config ->
      %{config | explain_slow_queries: true, explain_threshold_ms: 0}
    end)

    EctoIntegration.handle_event(
      [:my_app, :pg_repo, :query],
      measurements(900),
      %{
        query: "UPDATE \"users\" SET \"name\" = $1",
        source: "users",
        params: ["x"],
        repo: FakePostgresRepo
      },
      %{repo: FakePostgresRepo}
    )

    EctoIntegration.handle_event(
      [:my_app, :repo, :query],
      measurements(900),
      %{query: "SELECT 1", source: nil},
      %{repo: FakeRepo}
    )

    refute_receive {:repo, _pid, _call}, 300
  end

  test "a failing EXPLAIN still rolls back and never reaches the app" do
    use_fake_postgres_repo("EXPLAIN")
    test_pid = self()

    Configuration.update(fn config ->
      %{
        config
        | dsn: "http://key@localhost:1/api/v1/events",
          environment: "production",
          explain_slow_queries: true,
          explain_threshold_ms: 0,
          logger: fn message -> send(test_pid, {:log, message}) end
      }
    end)

    assert :ok ==
             EctoIntegration.handle_event(
               [:my_app, :pg_repo, :query],
               measurements(900),
               %{
                 query: "SELECT * FROM users",
                 source: "users",
                 params: [],
                 repo: FakePostgresRepo
               },
               %{repo: FakePostgresRepo}
             )

    assert_receive {:log, "[forge_ops_tracker] EXPLAIN failed: permission denied" <> _}, 2_000
  end

  test "explain_with_repo/3 runs the EXPLAIN inside a rolled back READ ONLY transaction" do
    use_fake_postgres_repo()

    plan = EctoIntegration.explain_with_repo(FakePostgresRepo, "SELECT 1", [])

    assert [%{"Plan" => _}] = plan
    assert_received {:repo, _, {:transaction, _}}
    assert_received {:repo, _, {:query, "SET TRANSACTION READ ONLY", [], _}}
    assert_received {:repo, _, {:query, "SET LOCAL statement_timeout = '2s'", [], _}}
    assert_received {:repo, _, {:query, "EXPLAIN (FORMAT JSON) SELECT 1", [], _}}
    assert_received {:repo, _, {:rollback}}
    refute_received {:repo, _, {:query, "EXPLAIN ANALYZE" <> _, _, _}}
  end

  test "ignores the EXPLAIN's own statements" do
    Process.put(:forge_ops_tracker_explaining, true)
    on_exit(fn -> Process.delete(:forge_ops_tracker_explaining) end)

    EctoIntegration.handle_event(
      [:my_app, :repo, :query],
      measurements(5),
      %{query: "EXPLAIN (FORMAT JSON) SELECT 1", source: nil},
      nil
    )

    Process.delete(:forge_ops_tracker_explaining)
    assert :sys.get_state(ForgeOpsTracker.PerformanceFlusher).buckets == %{}
    assert BreadcrumbBuffer.all() == []
  end
end
