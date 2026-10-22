defmodule ForgeOpsTracker.QueryPlansTest do
  # async: false: the planner and delivery queue are shared, process-wide singletons reading the
  # shared Configuration.
  use ExUnit.Case, async: false

  alias ForgeOpsTracker.{Configuration, QueryPlanner, QueryPlans, TestHttpServer}

  @plan [
    %{
      "Plan" => %{
        "Node Type" => "Seq Scan",
        "Relation Name" => "users",
        "Filter" => "((email = 'a@b.co'::text) AND (id > 42))",
        "Total Cost" => 35.5,
        "Plan Rows" => 1
      }
    }
  ]

  setup do
    on_exit(fn -> ForgeOpsTracker.reset_for_testing() end)
    ForgeOpsTracker.reset_for_testing()
    :ok
  end

  defp configure(port \\ 1, overrides \\ %{}) do
    Configuration.update(fn config ->
      struct(
        %{
          config
          | dsn: "http://key@localhost:#{port}/api/v1/events",
            environment: "production",
            trace_capture_threshold: 0
        },
        overrides
      )
    end)
  end

  describe "explainable?/1" do
    for statement <- [
          "SELECT 1",
          "  select * from users where id = $1",
          "SELECT * FROM users;",
          "-- a leading comment\nSELECT * FROM users",
          "/* app:web */ SELECT * FROM users",
          "SELECT * FROM users WHERE note = 'delete; update'",
          "SELECT * FROM users WHERE deleted_at IS NULL"
        ] do
      test "accepts #{inspect(statement)}" do
        assert QueryPlans.explainable?(unquote(statement))
      end
    end

    for statement <- [
          nil,
          "   ",
          "INSERT INTO users (email) VALUES ($1)",
          "UPDATE users SET email = $1",
          "DELETE FROM users",
          "WITH gone AS (DELETE FROM users RETURNING id) SELECT * FROM gone",
          "WITH x AS (SELECT 1) SELECT * FROM x",
          "SELECT * FROM users FOR UPDATE",
          "SELECT * FROM users for share",
          "SELECT * FROM users FOR NO KEY UPDATE",
          "SELECT * FROM users FOR KEY SHARE",
          "SELECT 1; SELECT 2",
          "SELECT * FROM a MERGE",
          "EXPLAIN SELECT 1",
          "-- SELECT\nDELETE FROM users",
          "SELECT 1 -- it's fine\n; DELETE FROM users; --'"
        ] do
      test "rejects #{inspect(statement)}" do
        refute QueryPlans.explainable?(unquote(statement))
      end
    end
  end

  test "rate limits each statement to once per ten minutes" do
    {true, limits} = QueryPlans.allow(QueryPlans.new_limits(), "SELECT ?", 0)
    {false, limits} = QueryPlans.allow(limits, "SELECT ?", 1)
    {false, limits} = QueryPlans.allow(limits, "SELECT ?", 599_999)
    assert {true, _limits} = QueryPlans.allow(limits, "SELECT ?", 600_000)
  end

  test "rate limits to ten EXPLAINs per minute overall" do
    limits =
      Enum.reduce(0..9, QueryPlans.new_limits(), fn i, limits ->
        {true, limits} = QueryPlans.allow(limits, "SELECT #{i}", i)
        limits
      end)

    assert {false, limits} = QueryPlans.allow(limits, "SELECT 10", 100)
    assert {true, _limits} = QueryPlans.allow(limits, "SELECT 10", 60_000)
  end

  test "db_system/1 names Ecto adapters" do
    assert QueryPlans.db_system(Ecto.Adapters.Postgres) == "postgresql"
    assert QueryPlans.db_system(Ecto.Adapters.MyXQL) == "mysql"
    assert QueryPlans.db_system(Ecto.Adapters.SQLite3) == "sqlite"
    assert QueryPlans.db_system(Ecto.Adapters.Tds) == "mssql"
    assert QueryPlans.db_system("PostgreSQL") == "postgresql"
    assert QueryPlans.db_system(nil) == nil
  end

  test "mask_plan/1 masks every string and leaves numbers, keys and structure alone" do
    [%{"Plan" => node}] = masked = QueryPlans.mask_plan(@plan)

    assert node["Filter"] == "((email = ?::text) AND (id > ?))"
    assert node["Node Type"] == "Seq Scan"
    assert node["Relation Name"] == "users"
    assert node["Total Cost"] == 35.5
    assert node["Plan Rows"] == 1
    refute JSON.encode!(masked) =~ "a@b.co"
  end

  test "payload/6 decodes JSON text and carries the masked statement and plan" do
    config = %Configuration{environment: "production"}
    captured_at = ~U[2026-09-25 00:00:00.123456Z]

    payload =
      QueryPlans.payload(
        config,
        "SELECT ?",
        "postgresql",
        JSON.encode!(@plan),
        812.5,
        captured_at
      )

    assert payload.statement == "SELECT ?"
    assert payload.db_system == "postgresql"
    assert payload.duration_ms == 812.5
    assert payload.environment == "production"
    assert payload.captured_at == "2026-09-25T00:00:00.123Z"
    assert [%{"Plan" => %{"Filter" => "((email = ?::text) AND (id > ?))"}}] = payload.plan
  end

  test "payload/6 drops a plan over 64 KB, and anything that isn't a plan" do
    config = %Configuration{}
    huge = [%{"Plan" => %{"Output" => List.duplicate(String.duplicate("x", 1000), 70)}}]

    assert QueryPlans.payload(config, "SELECT ?", "postgresql", huge, 900, DateTime.utc_now()) ==
             nil

    assert QueryPlans.payload(config, "SELECT ?", "postgresql", "nope", 900, DateTime.utc_now()) ==
             nil

    assert QueryPlans.payload(config, "SELECT ?", "postgresql", nil, 900, DateTime.utc_now()) ==
             nil
  end

  test "query_plans_uri swaps the trailing /events" do
    config = %Configuration{dsn: "https://key@tracker.example.com/api/v1/events"}

    assert Configuration.query_plans_uri(config) ==
             "https://tracker.example.com/api/v1/query_plans"
  end

  describe "QueryPlanner.consider/5" do
    test "is off by default" do
      configure()
      assert %Configuration{}.explain_slow_queries == false
      assert %Configuration{}.explain_threshold_ms == 500

      refute QueryPlanner.consider("SELECT * FROM users", "postgresql", 5000, fn -> @plan end)
    end

    test "does nothing under strict privacy, even with explain_slow_queries on" do
      configure(1, %{explain_slow_queries: true, strict_privacy: true})

      refute QueryPlanner.consider("SELECT * FROM users", "postgresql", 5000, fn -> @plan end)
    end

    test "skips fast queries, other databases and anything but a plain SELECT" do
      configure(1, %{explain_slow_queries: true})
      plan = fn -> @plan end

      refute QueryPlanner.consider("SELECT * FROM users", "postgresql", 499, plan)
      refute QueryPlanner.consider("SELECT * FROM users", "mysql", 5000, plan)
      refute QueryPlanner.consider("SELECT * FROM users", nil, 5000, plan)
      refute QueryPlanner.consider("UPDATE users SET email = $1", "postgresql", 5000, plan)
      refute QueryPlanner.consider("SELECT * FROM users FOR UPDATE", "postgresql", 5000, plan)
    end

    test "is skipped when the client isn't enabled" do
      configure(1, %{explain_slow_queries: true, environment: "development"})
      refute QueryPlanner.consider("SELECT * FROM users", "postgresql", 5000, fn -> @plan end)
    end

    test "runs the EXPLAIN in the planner's own Task and delivers only masked data" do
      {port, requests} = TestHttpServer.start(202)
      configure(port, %{explain_slow_queries: true})
      test_pid = self()

      explain = fn ->
        send(test_pid, {:explained_in, self(), Process.get(:"$callers", [])})
        @plan
      end

      assert QueryPlanner.consider(
               "SELECT * FROM users WHERE email = 'a@b.co' AND id > 42",
               "postgresql",
               812.5,
               explain
             )

      assert_receive {:explained_in, pid, callers}, 2_000
      refute pid == test_pid
      refute test_pid in callers

      [request] = wait_for_requests(requests)
      assert request.request_line =~ "POST /api/v1/query_plans"
      refute request.body =~ "a@b.co"
      payload = JSON.decode!(request.body)
      assert payload["statement"] == "SELECT * FROM users WHERE email = ? AND id > ?"
      assert payload["db_system"] == "postgresql"
      assert payload["duration_ms"] == 812.5
      assert payload["environment"] == "production"
      assert [%{"Plan" => %{"Filter" => "((email = ?::text) AND (id > ?))"}}] = payload["plan"]
    end

    test "rate limits repeats of the same masked statement" do
      configure(1, %{explain_slow_queries: true})
      test_pid = self()
      explain = fn -> [send(test_pid, :explained), @plan] |> List.last() end

      assert QueryPlanner.consider("SELECT * FROM users WHERE id = 1", "postgresql", 900, explain)
      assert_receive :explained, 2_000
      # Different literal, same masked statement: handed over, but the planner won't run it.
      QueryPlanner.consider("SELECT * FROM users WHERE id = 2", "postgresql", 900, explain)
      refute_receive :explained, 200
    end

    test "a failed EXPLAIN is logged and dropped" do
      test_pid = self()

      configure(1, %{
        explain_slow_queries: true,
        logger: fn message -> send(test_pid, {:log, message}) end
      })

      QueryPlanner.consider("SELECT * FROM users", "postgresql", 900, fn ->
        raise "canceling statement due to statement timeout"
      end)

      assert_receive {:log, "[forge_ops_tracker] EXPLAIN failed: canceling statement" <> _}, 2_000
      refute QueryPlanner.explaining?()
    end

    test "an exit or throw from the EXPLAIN is swallowed too" do
      config = %Configuration{logger: fn _ -> :ok end}
      job = fn explain -> {explain, "SELECT ?", "postgresql", 900, DateTime.utc_now()} end

      refute QueryPlanner.run_job(config, job.(fn -> exit(:pool_timeout) end))
      refute QueryPlanner.run_job(config, job.(fn -> throw(:nope) end))
      refute QueryPlanner.run_job(config, job.(fn -> "not json" end))
      refute QueryPlanner.explaining?()
    end

    test "explaining?/0 is only true while the EXPLAIN runs" do
      config = %Configuration{}
      test_pid = self()

      explain = fn ->
        send(test_pid, {:explaining, QueryPlanner.explaining?()})
        @plan
      end

      assert QueryPlanner.run_job(
               config,
               {explain, "SELECT ?", "postgresql", 900, DateTime.utc_now()}
             )

      assert_receive {:explaining, true}
      refute QueryPlanner.explaining?()
    end
  end

  describe "database spans" do
    test "record_database_query/6 puts the masked statement and db.system on the span" do
      {port, requests} = TestHttpServer.start(202)
      configure(port)
      ForgeOpsTracker.start_trace()

      ForgeOpsTracker.record_database_query(
        "SELECT users",
        DateTime.utc_now(),
        3,
        "SELECT * FROM users WHERE email = 'a@b.co' AND id = 42",
        "postgresql"
      )

      ForgeOpsTracker.finish_trace("GET /", "controller", DateTime.utc_now(), 10)
      span = database_span(requests)

      assert span["data"] == %{
               "db.statement" => "SELECT * FROM users WHERE email = ? AND id = ?",
               "db.system" => "postgresql"
             }
    end

    test "the statement is capped at 4000 characters" do
      {port, requests} = TestHttpServer.start(202)
      configure(port)
      ForgeOpsTracker.start_trace()

      statement = "SELECT " <> String.duplicate("a, ", 3000) <> "b"
      ForgeOpsTracker.record_database_query("SELECT", DateTime.utc_now(), 1, statement, nil)
      ForgeOpsTracker.finish_trace("GET /", "controller", DateTime.utc_now(), 10)

      data = database_span(requests)["data"]
      assert String.length(data["db.statement"]) == 4000
      refute Map.has_key?(data, "db.system")
    end

    test "span/5 takes a statement and db_system for a database span and masks it" do
      {port, requests} = TestHttpServer.start(202)
      configure(port)
      ForgeOpsTracker.start_trace()

      result =
        ForgeOpsTracker.span(
          "Load orders",
          "database",
          %{"rows" => 3},
          [statement: "SELECT * FROM orders WHERE total > 100.50", db_system: "PostgreSQL"],
          fn -> :loaded end
        )

      assert result == :loaded
      ForgeOpsTracker.finish_trace("GET /", "controller", DateTime.utc_now(), 10)

      assert database_span(requests)["data"] == %{
               "rows" => 3,
               "db.statement" => "SELECT * FROM orders WHERE total > ?",
               "db.system" => "postgresql"
             }
    end

    test "record_span/6 takes the same options" do
      {port, requests} = TestHttpServer.start(202)
      configure(port)
      ForgeOpsTracker.start_trace()

      ForgeOpsTracker.record_span("Load orders", "database", DateTime.utc_now(), 4, %{},
        statement: "SELECT * FROM orders WHERE status = 'paid'"
      )

      ForgeOpsTracker.finish_trace("GET /", "controller", DateTime.utc_now(), 10)

      assert database_span(requests)["data"] == %{
               "db.statement" => "SELECT * FROM orders WHERE status = ?"
             }
    end
  end

  defp database_span(requests) do
    [request] = wait_for_requests(requests)

    request.body
    |> JSON.decode!()
    |> Map.fetch!("spans")
    |> Enum.find(&(&1["kind"] == "database"))
  end

  defp wait_for_requests(requests, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    case Agent.get(requests, & &1) do
      [] ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk("nothing was delivered")
        Process.sleep(10)
        wait_for_requests(requests, deadline)

      delivered ->
        delivered
    end
  end
end
