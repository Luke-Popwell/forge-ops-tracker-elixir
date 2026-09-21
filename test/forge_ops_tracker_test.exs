defmodule ForgeOpsTrackerTest do
  # async: false: exercises the shared Configuration/DeliveryQueue singletons and the process-
  # wide :logger handler registry.
  use ExUnit.Case, async: false

  alias ForgeOpsTracker.{Configuration, TestHttpServer}

  defmodule CrashingWorker do
    @moduledoc false
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    def init(_), do: {:ok, nil}
    def handle_call(:boom, _from, _state), do: raise("boom from a real crashed process")
  end

  setup do
    on_exit(fn ->
      ForgeOpsTracker.reset_for_testing()
    end)

    :ok
  end

  test "init configures and returns the shared configuration" do
    config =
      ForgeOpsTracker.init(dsn: "https://key@tracker.example.com/events", release: "abc123")

    assert config.dsn == "https://key@tracker.example.com/events"
    assert config.release == "abc123"
    assert Configuration.get().dsn == "https://key@tracker.example.com/events"
  end

  test "init raises on an unknown configuration field" do
    assert_raise ArgumentError, fn -> ForgeOpsTracker.init(not_a_real_field: true) end
  end

  test "capture_exception delivers through the full stack" do
    {port, requests} = TestHttpServer.start(202)

    ForgeOpsTracker.init(
      dsn: "http://key@localhost:#{port}/events",
      environment: "production"
    )

    stacktrace =
      try do
        raise "boom"
      rescue
        _ -> __STACKTRACE__
      end

    ForgeOpsTracker.capture_exception(%RuntimeError{message: "boom"}, stacktrace, %{order_id: 7})

    wait_until(fn -> Agent.get(requests, & &1) != [] end)
    [request] = Agent.get(requests, & &1)
    assert request.headers["authorization"] == "Bearer key"
  end

  test "set_user attaches the user to a later capture_exception call" do
    {port, requests} = TestHttpServer.start(202)

    ForgeOpsTracker.init(dsn: "http://key@localhost:#{port}/events", environment: "production")
    ForgeOpsTracker.set_user(%{id: 42, email: "alice@example.com"})

    stacktrace =
      try do
        raise "boom"
      rescue
        _ -> __STACKTRACE__
      end

    ForgeOpsTracker.capture_exception(%RuntimeError{message: "boom"}, stacktrace)

    wait_until(fn -> Agent.get(requests, & &1) != [] end)
    [request] = Agent.get(requests, & &1)
    body = JSON.decode!(request.body)
    assert body["user"] == %{"id" => 42, "email" => "alice@example.com"}
  end

  test "an explicit user argument overrides whatever set_user last set" do
    {port, requests} = TestHttpServer.start(202)

    ForgeOpsTracker.init(dsn: "http://key@localhost:#{port}/events", environment: "production")
    ForgeOpsTracker.set_user(%{id: 42})

    stacktrace =
      try do
        raise "boom"
      rescue
        _ -> __STACKTRACE__
      end

    ForgeOpsTracker.capture_exception(%RuntimeError{message: "boom"}, stacktrace, %{}, %{id: 99})

    wait_until(fn -> Agent.get(requests, & &1) != [] end)
    [request] = Agent.get(requests, & &1)
    body = JSON.decode!(request.body)
    assert body["user"] == %{"id" => 99}
  end

  test "add_breadcrumb accumulates on this process and capture_exception attaches the trail automatically" do
    {port, requests} = TestHttpServer.start(202)

    ForgeOpsTracker.init(dsn: "http://key@localhost:#{port}/events", environment: "production")
    ForgeOpsTracker.add_breadcrumb("opened checkout")
    ForgeOpsTracker.add_breadcrumb("charged card", "custom", "info", %{order_id: 42})

    stacktrace =
      try do
        raise "boom"
      rescue
        _ -> __STACKTRACE__
      end

    ForgeOpsTracker.capture_exception(%RuntimeError{message: "boom"}, stacktrace)

    wait_until(fn -> Agent.get(requests, & &1) != [] end)
    [request] = Agent.get(requests, & &1)
    body = JSON.decode!(request.body)
    messages = Enum.map(body["breadcrumbs"], & &1["message"])
    assert messages == ["opened checkout", "charged card"]
  end

  test "clear_breadcrumbs empties the trail before the next report" do
    {port, requests} = TestHttpServer.start(202)

    ForgeOpsTracker.init(dsn: "http://key@localhost:#{port}/events", environment: "production")
    ForgeOpsTracker.add_breadcrumb("stale entry from an earlier request")
    ForgeOpsTracker.clear_breadcrumbs()

    stacktrace =
      try do
        raise "boom"
      rescue
        _ -> __STACKTRACE__
      end

    ForgeOpsTracker.capture_exception(%RuntimeError{message: "boom"}, stacktrace)

    wait_until(fn -> Agent.get(requests, & &1) != [] end)
    [request] = Agent.get(requests, & &1)
    body = JSON.decode!(request.body)
    refute Map.has_key?(body, "breadcrumbs")
  end

  test "add_breadcrumb is a no-op when track_breadcrumbs is false" do
    ForgeOpsTracker.init(
      dsn: "http://key@localhost:1/events",
      environment: "production",
      track_breadcrumbs: false
    )

    ForgeOpsTracker.add_breadcrumb("should never be recorded")

    assert ForgeOpsTracker.current_breadcrumbs() == []
  end

  test "reset_for_testing clears the current breadcrumb trail too" do
    ForgeOpsTracker.add_breadcrumb("stale entry")

    ForgeOpsTracker.reset_for_testing()

    assert ForgeOpsTracker.current_breadcrumbs() == []
  end

  test "set_user with an empty map clears whatever was set" do
    ForgeOpsTracker.set_user(%{id: 42})

    ForgeOpsTracker.set_user()

    assert Process.get(:forge_ops_tracker_current_user) == nil
  end

  test "set_user omits fields left nil" do
    ForgeOpsTracker.set_user(%{id: 42, email: nil})

    assert Process.get(:forge_ops_tracker_current_user) == %{id: 42}
  end

  test "install_handlers is idempotent" do
    assert ForgeOpsTracker.install_handlers() == :ok
    assert ForgeOpsTracker.install_handlers() == :ok
  end

  test "a real process crash is reported automatically with zero further wiring" do
    {port, requests} = TestHttpServer.start(202)

    ForgeOpsTracker.init(dsn: "http://key@localhost:#{port}/events", environment: "production")
    ForgeOpsTracker.install_handlers()

    {:ok, pid} = CrashingWorker.start_link(nil)
    Process.unlink(pid)
    ref = Process.monitor(pid)

    catch_exit(GenServer.call(pid, :boom))
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000

    wait_until(fn -> Agent.get(requests, & &1) != [] end)
    [request] = Agent.get(requests, & &1)
    assert request.headers["authorization"] == "Bearer key"
    assert request.body =~ "boom from a real crashed process"
  end

  defp wait_until(predicate, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
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
