defmodule ForgeOpsTracker.ChangesTest do
  # async: false: shares the Configuration/DeliveryQueue singletons and the once-per-VM snapshot
  # flag with ForgeOpsTrackerTest.
  use ExUnit.Case, async: false

  alias ForgeOpsTracker.{Changes, Configuration, TestHttpServer}

  setup do
    on_exit(fn ->
      ForgeOpsTracker.reset_for_testing()
      Changes.set_snapshot_sent_for_testing(true)
    end)

    :ok
  end

  defp init_against(status, opts \\ []) do
    {port, requests} = TestHttpServer.start(status)

    ForgeOpsTracker.init(
      [dsn: "http://the-key@localhost:#{port}/api/v1/events", environment: "production"] ++ opts
    )

    requests
  end

  describe "record_change/3" do
    test "posts the change to /api/v1/changes with the configured environment" do
      requests = init_against(202)

      assert :ok =
               ForgeOpsTracker.record_change(:feature_flag, "Enabled new checkout",
                 details: %{flag: "new_checkout"},
                 actor: "alice@example.com",
                 url: "https://example.com/flags/1",
                 id: "flag-1",
                 service: "web"
               )

      [request] = wait_for_requests(requests, 1)
      assert request.request_line == "POST /api/v1/changes HTTP/1.1"
      assert request.headers["authorization"] == "Bearer the-key"

      body = JSON.decode!(request.body)
      assert body["kind"] == "feature_flag"
      assert body["title"] == "Enabled new checkout"
      assert body["details"] == %{"flag" => "new_checkout"}
      assert body["environment"] == "production"
      assert body["service"] == "web"
      assert body["actor"] == "alice@example.com"
      assert body["url"] == "https://example.com/flags/1"
      assert body["id"] == "flag-1"
      assert {:ok, _at, 0} = DateTime.from_iso8601(body["occurred_at"])
    end

    test "leaves out options that weren't given" do
      config = %Configuration{environment: "staging"}
      change = Changes.build_change(config, "config", "Raised pool size", [])

      assert Map.keys(change) |> Enum.sort() ==
               ~w(environment kind occurred_at title)

      assert change["environment"] == "staging"
    end

    test "an explicit environment and occurred_at win" do
      at = ~U[2026-09-25 12:00:00Z]

      change =
        Changes.build_change(%Configuration{}, :migration, "Add index",
          environment: "canary",
          occurred_at: at
        )

      assert change["environment"] == "canary"
      assert change["occurred_at"] == "2026-09-25T12:00:00Z"
    end

    test "accepts the six kinds as atoms or strings and defaults anything else to other" do
      for kind <- Changes.kinds() do
        assert Changes.normalize_kind(kind) == kind
        assert Changes.normalize_kind(String.to_atom(kind)) == kind
      end

      assert Changes.normalize_kind("deploy") == "other"
      assert Changes.normalize_kind(:rollback) == "other"
      assert Changes.normalize_kind(nil) == "other"
      assert Changes.normalize_kind(42) == "other"
    end

    test "cuts the title to 200 characters" do
      change = Changes.build_change(%Configuration{}, :other, String.duplicate("a", 300), [])
      assert String.length(change["title"]) == 200
    end

    test "is a no-op when the client isn't enabled" do
      {port, requests} = TestHttpServer.start(202)

      ForgeOpsTracker.init(
        dsn: "http://key@localhost:#{port}/api/v1/events",
        environment: "development"
      )

      assert :ok = ForgeOpsTracker.record_change(:config, "Not sent in development")
      Process.sleep(100)
      assert Agent.get(requests, & &1) == []
    end

    test "never raises on a 403, a 500, or an unreachable server" do
      for status <- [403, 500] do
        requests = init_against(status)
        assert :ok = ForgeOpsTracker.record_change(:config, "Rejected")
        wait_for_requests(requests, 1)
      end

      {:ok, probe} = :gen_tcp.listen(0, [:binary])
      {:ok, closed_port} = :inet.port(probe)
      :gen_tcp.close(probe)

      ForgeOpsTracker.init(
        dsn: "http://key@localhost:#{closed_port}/api/v1/events",
        environment: "production",
        timeout: 500
      )

      assert :ok = ForgeOpsTracker.record_change(:config, "Nobody listening")
    end

    test "never raises on a title that can't become a string" do
      init_against(202)
      assert :ok = ForgeOpsTracker.record_change(:config, %{not: "a string"})
    end
  end

  describe "startup change snapshot" do
    test "init/1 posts one snapshot with runtime and dependencies, and only once" do
      Changes.set_snapshot_sent_for_testing(false)
      requests = init_against(202)

      [request] = wait_for_requests(requests, 1)
      assert request.request_line == "POST /api/v1/change_snapshots HTTP/1.1"
      assert request.headers["authorization"] == "Bearer the-key"

      body = JSON.decode!(request.body)
      assert body["environment"] == "production"
      refute Map.has_key?(body, "service")

      state = body["state"]
      assert state["runtime"] == "elixir #{System.version()} / otp #{System.otp_release()}"
      assert state["dependencies"]["elixir"] == System.version()
      assert is_binary(state["dependencies"]["forge_ops_tracker"])
      refute Map.has_key?(state, "env_var_names")
      refute Map.has_key?(state, "schema_version")

      ForgeOpsTracker.init(environment: "production")
      Process.sleep(100)
      assert length(Agent.get(requests, & &1)) == 1
    end

    test "detect_changes: false sends nothing" do
      Changes.set_snapshot_sent_for_testing(false)
      requests = init_against(202, detect_changes: false)

      Process.sleep(100)
      assert Agent.get(requests, & &1) == []
    end

    test "a 403 from a plan without change tracking is silent" do
      Changes.set_snapshot_sent_for_testing(false)
      requests = init_against(403)
      wait_for_requests(requests, 1)
    end

    test "env var names are sent only when opted in, with the denylist applied" do
      env = %{
        "DATABASE_URL" => "postgres://secret",
        "SECRET_KEY_BASE" => "shh",
        "HOSTNAME" => "web-1",
        "PATH" => "/usr/bin",
        "LC_ALL" => "C",
        "SYSTEMD_EXEC_PID" => "1",
        "KUBERNETES_SERVICE_HOST" => "10.0.0.1",
        "REDIS_SERVICE_HOST" => "10.0.0.2",
        "REDIS_SERVICE_PORT_HTTP" => "6379",
        "REDIS_PORT_6379_TCP_ADDR" => "10.0.0.2",
        "FORGE_OPS_DSN" => "https://key@example.com/api/v1/events",
        "_" => "/usr/bin/mix"
      }

      off = Changes.build_snapshot(%Configuration{}, env)
      refute Map.has_key?(off["state"], "env_var_names")

      on = Changes.build_snapshot(%Configuration{track_env_var_names: true}, env)
      assert on["state"]["env_var_names"] == ["DATABASE_URL", "SECRET_KEY_BASE"]
      refute JSON.encode!(on) =~ "postgres://secret"
    end

    test "track_env_var_names reaches the wire through init/1" do
      Changes.set_snapshot_sent_for_testing(false)
      System.put_env("FORGE_OPS_CHANGES_TEST_ONLY", "x")
      System.put_env("CHANGES_TEST_VISIBLE_NAME", "hidden value")

      on_exit(fn ->
        System.delete_env("FORGE_OPS_CHANGES_TEST_ONLY")
        System.delete_env("CHANGES_TEST_VISIBLE_NAME")
      end)

      requests = init_against(202, track_env_var_names: true)
      [request] = wait_for_requests(requests, 1)

      names = JSON.decode!(request.body)["state"]["env_var_names"]
      assert "CHANGES_TEST_VISIBLE_NAME" in names
      refute "FORGE_OPS_CHANGES_TEST_ONLY" in names
      refute request.body =~ "hidden value"
    end

    test "dependencies are capped at 3000 and truncated" do
      loaded =
        for i <- 1..3100 do
          {String.to_atom("app_#{String.pad_leading(to_string(i), 4, "0")}"), ~c"desc", ~c"1.0.0"}
        end

      long =
        {String.to_atom(String.duplicate("a", 250)), ~c"desc", ~c"#{String.duplicate("9", 150)}"}

      deps = Changes.dependencies([long | loaded])

      assert map_size(deps) == 3000
      {name, version} = Enum.find(deps, fn {name, _} -> String.starts_with?(name, "aaa") end)
      assert String.length(name) == 200
      assert String.length(version) == 100
    end
  end

  defp wait_for_requests(requests, count, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    list = Agent.get(requests, & &1)

    cond do
      length(list) >= count ->
        list

      System.monotonic_time(:millisecond) > deadline ->
        flunk("timed out waiting for #{count} request(s), got #{length(list)}")

      true ->
        Process.sleep(10)
        wait_for_requests(requests, count, deadline)
    end
  end
end
