defmodule ForgeOpsTracker.MetricBufferTest do
  # async: false: the two buffers are named, process-wide GenServers reading the shared Configuration.
  use ExUnit.Case, async: false

  alias ForgeOpsTracker.{Configuration, MetricBuffer, TestHttpServer}

  setup do
    on_exit(fn ->
      Configuration.update(fn _ -> %Configuration{} end)
      ForgeOpsTracker.reset_for_testing()
    end)

    MetricBuffer.clear(:custom)
    MetricBuffer.clear(:infrastructure)
    :ok
  end

  defp configure(port \\ 1, overrides \\ %{}) do
    Configuration.update(fn config ->
      struct(
        %{
          config
          | dsn: "http://key@localhost:#{port}/api/v1/events",
            environment: "production",
            release: "a1b2c3d",
            server_name: "web-1",
            metric_flush_interval: 3_600_000,
            infrastructure_metric_flush_interval: 3_600_000
        },
        overrides
      )
    end)
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

  test "delivers every entry as one batch to custom_metrics, stamped with recorded_at, end to end" do
    {port, requests} = TestHttpServer.start(202)
    configure(port)

    ForgeOpsTracker.capture_metric("signup")
    ForgeOpsTracker.capture_metric("payment", 49.5)
    ForgeOpsTracker.capture_metric("refund", -12)
    ForgeOpsTracker.flush_metrics()

    [request] = Agent.get(requests, & &1)
    assert request.request_line =~ "POST /api/v1/custom_metrics"
    assert request.headers["authorization"] == "Bearer key"
    %{"metrics" => metrics} = JSON.decode!(request.body)
    assert Enum.map(metrics, & &1["metric_name"]) == ["signup", "payment", "refund"]
    assert Enum.map(metrics, & &1["value"]) == [1.0, 49.5, -12]
    assert hd(metrics)["environment"] == "production"
    assert hd(metrics)["release"] == "a1b2c3d"
    assert hd(metrics)["recorded_at"] =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/
  end

  test "infrastructure readings go to their own endpoint with an explicit or default hostname" do
    {port, requests} = TestHttpServer.start(202)
    configure(port)

    ForgeOpsTracker.capture_infrastructure_metric("cpu", 0.42, "db-1")
    ForgeOpsTracker.capture_infrastructure_metric("memory", 0.7)
    ForgeOpsTracker.flush_metrics()

    [request] = Agent.get(requests, & &1)
    assert request.request_line =~ "POST /api/v1/infrastructure_metrics"
    %{"metrics" => [first, second]} = JSON.decode!(request.body)
    assert first["hostname"] == "db-1"
    assert second["hostname"] == "web-1"
  end

  test "a non-numeric value is dropped" do
    configure()
    ForgeOpsTracker.capture_metric("bad", "12")
    ForgeOpsTracker.capture_metric("ok", 3)
    assert Enum.map(MetricBuffer.entries(:custom), & &1.metric_name) == ["ok"]
  end

  test "a failed delivery keeps every entry for the next flush" do
    {port, requests} = TestHttpServer.start(500)
    configure(port)

    ForgeOpsTracker.capture_metric("a")
    ForgeOpsTracker.flush_metrics()
    assert length(MetricBuffer.entries(:custom)) == 1
    ForgeOpsTracker.capture_metric("b")

    assert length(MetricBuffer.entries(:custom)) == 2
    assert length(Agent.get(requests, & &1)) == 1
  end

  defp logging_to(test_pid), do: %{logger: fn message -> send(test_pid, {:logged, message}) end}

  defp dropped_messages do
    receive do
      {:logged, "[forge_ops_tracker] dropping" <> _ = message} -> [message | dropped_messages()]
      {:logged, _other} -> dropped_messages()
    after
      0 -> []
    end
  end

  defp metric_names(requests) do
    for request <- Agent.get(requests, & &1) do
      request.body |> JSON.decode!() |> Map.fetch!("metrics") |> Enum.map(& &1["metric_name"])
    end
  end

  test "a batch the server rejected is dropped and never sent again" do
    {port, requests} = TestHttpServer.start(403)
    configure(port, logging_to(self()))

    ForgeOpsTracker.capture_metric("a")
    ForgeOpsTracker.flush_metrics()
    assert MetricBuffer.entries(:custom) == []

    ForgeOpsTracker.flush_metrics()
    ForgeOpsTracker.capture_metric("b")
    ForgeOpsTracker.flush_metrics()

    assert metric_names(requests) == [["a"], ["b"]]

    assert dropped_messages() == [
             "[forge_ops_tracker] dropping 1 buffered metrics: the server rejected them and will not accept a retry",
             "[forge_ops_tracker] dropping 1 buffered metrics: the server rejected them and will not accept a retry"
           ]
  end

  test "a batch is kept through four failed flushes and dropped on the fifth" do
    {port, requests} = TestHttpServer.start(503)
    configure(port, logging_to(self()))

    ForgeOpsTracker.capture_metric("a")
    for _ <- 1..4, do: ForgeOpsTracker.flush_metrics()
    assert length(MetricBuffer.entries(:custom)) == 1
    assert dropped_messages() == []

    ForgeOpsTracker.flush_metrics()
    assert MetricBuffer.entries(:custom) == []
    ForgeOpsTracker.flush_metrics()

    assert metric_names(requests) == List.duplicate(["a"], 5)

    assert dropped_messages() == [
             "[forge_ops_tracker] dropping 1 buffered metrics: 5 flushes in a row failed"
           ]
  end

  test "a network failure counts as a failed flush like a 5xx does" do
    {:ok, probe} = :gen_tcp.listen(0, [:binary])
    {:ok, closed_port} = :inet.port(probe)
    :gen_tcp.close(probe)
    configure(closed_port, %{timeout: 500})

    ForgeOpsTracker.capture_infrastructure_metric("cpu", 0.5)
    for _ <- 1..4, do: ForgeOpsTracker.flush_metrics()
    assert length(MetricBuffer.entries(:infrastructure)) == 1

    ForgeOpsTracker.flush_metrics()
    assert MetricBuffer.entries(:infrastructure) == []
  end

  test "a flush that gets through starts the count of failed flushes again" do
    {failing_port, _} = TestHttpServer.start(500)
    configure(failing_port)
    ForgeOpsTracker.capture_metric("a")
    for _ <- 1..4, do: ForgeOpsTracker.flush_metrics()

    {port, requests} = TestHttpServer.start(202)
    configure(port)
    ForgeOpsTracker.flush_metrics()
    assert metric_names(requests) == [["a"]]

    {failing_port, _} = TestHttpServer.start(500)
    configure(failing_port)
    ForgeOpsTracker.capture_metric("b")
    for _ <- 1..4, do: ForgeOpsTracker.flush_metrics()

    # Four failures since the flush that got through, so "b" is still held, not dropped.
    assert Enum.map(MetricBuffer.entries(:custom), & &1.metric_name) == ["b"]
  end

  test "the buffer is capped and drops further entries until a flush succeeds" do
    configure()
    for _ <- 1..(MetricBuffer.max_entries() + 50), do: ForgeOpsTracker.capture_metric("m")
    assert length(MetricBuffer.entries(:custom)) == MetricBuffer.max_entries()
  end

  test "is a no-op when the client is not enabled" do
    configure(1, %{environment: "development"})
    ForgeOpsTracker.capture_metric("signup")
    ForgeOpsTracker.capture_infrastructure_metric("cpu", 1)
    assert MetricBuffer.entries(:custom) == []
    assert MetricBuffer.entries(:infrastructure) == []
  end

  test "flushes on its own interval" do
    {port, requests} = TestHttpServer.start(202)
    configure(port)

    # The running buffer reads its interval when it schedules; restart it so the short one applies.
    Supervisor.terminate_child(ForgeOpsTracker.Supervisor, {MetricBuffer, :custom})
    Configuration.update(fn c -> %{c | metric_flush_interval: 50} end)
    Supervisor.restart_child(ForgeOpsTracker.Supervisor, {MetricBuffer, :custom})

    ForgeOpsTracker.capture_metric("tick")

    wait_until(fn -> Agent.get(requests, & &1) != [] end)
    assert hd(Agent.get(requests, & &1)).body =~ "tick"
  end

  test "a normal supervised shutdown flushes whatever is left" do
    {port, requests} = TestHttpServer.start(202)
    configure(port)

    ForgeOpsTracker.capture_metric("last words")
    :ok = Supervisor.terminate_child(ForgeOpsTracker.Supervisor, {MetricBuffer, :custom})
    {:ok, _} = Supervisor.restart_child(ForgeOpsTracker.Supervisor, {MetricBuffer, :custom})

    assert hd(Agent.get(requests, & &1)).body =~ "last words"
  end

  test "the metric uris swap the trailing events segment" do
    config = %Configuration{dsn: "https://key@tracker.example.com/api/v1/events"}

    assert Configuration.custom_metrics_uri(config) ==
             "https://tracker.example.com/api/v1/custom_metrics"

    assert Configuration.infrastructure_metrics_uri(config) ==
             "https://tracker.example.com/api/v1/infrastructure_metrics"
  end
end
