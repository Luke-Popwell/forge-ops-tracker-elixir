defmodule ForgeOpsTracker.PerformanceFlusherTest do
  # async: false: PerformanceFlusher is a single named GenServer, shared process-wide (started
  # once under ForgeOpsTracker.Application's own supervision tree), and it reads the *shared*
  # Configuration singleton internally, same reasoning as DeliveryQueueTest's own async: false.
  use ExUnit.Case, async: false

  alias ForgeOpsTracker.{Configuration, PerformanceFlusher, TestHttpServer}

  setup do
    # Start from empty buckets: an earlier test's timings (an integration test whose delivery
    # failed keeps its buckets for the next flush) would otherwise land in this test's request.
    {drain_port, _} = TestHttpServer.start(202)
    point_configuration_at(drain_port)
    PerformanceFlusher.flush()

    on_exit(fn -> Configuration.update(fn _ -> %Configuration{} end) end)
    :ok
  end

  defp point_configuration_at(port) do
    Configuration.update(fn config ->
      %{config | dsn: "http://key@localhost:#{port}/api/v1/events"}
    end)
  end

  test "buckets by transaction_name and kind, delivering count/sum/max on flush" do
    {port, requests} = TestHttpServer.start(202)
    point_configuration_at(port)

    PerformanceFlusher.record("GET /users", "controller", 10.0)
    PerformanceFlusher.record("GET /users", "controller", 30.0)
    PerformanceFlusher.record("SELECT users", "query", 5.0)

    assert PerformanceFlusher.flush() == :ok

    [request] = Agent.get(requests, & &1)
    body = JSON.decode!(request.body)
    samples = Map.fetch!(body, "samples")

    controller_sample = Enum.find(samples, &(&1["kind"] == "controller"))
    query_sample = Enum.find(samples, &(&1["kind"] == "query"))

    assert controller_sample["transaction_name"] == "GET /users"
    assert controller_sample["request_count"] == 2
    assert controller_sample["duration_sum_ms"] == 40.0
    assert controller_sample["max_duration_ms"] == 30.0

    assert query_sample["transaction_name"] == "SELECT users"
    assert query_sample["request_count"] == 1
  end

  test "resets buckets after a successful flush" do
    {port, requests} = TestHttpServer.start(202)
    point_configuration_at(port)

    PerformanceFlusher.record("GET /ok", "controller", 1.0)
    assert PerformanceFlusher.flush() == :ok
    assert length(Agent.get(requests, & &1)) == 1

    # Nothing pending: a second flush with no new records in between must not deliver an empty
    # batch (see PerformanceSamplesController's own doc: an empty samples list is never useful).
    assert PerformanceFlusher.flush() == :ok
    assert length(Agent.get(requests, & &1)) == 1
  end

  test "keeps its buckets when a flush fails to deliver, rather than dropping them" do
    # PerformanceFlusher is a shared, process-wide singleton (see this module's own async: false
    # note above): clear its buckets back out once this test is done, so a bucket deliberately
    # left non-empty here can't leak into whatever test (in this file or another) runs next.
    on_exit(fn -> :sys.replace_state(PerformanceFlusher, &%{&1 | buckets: %{}}) end)

    {:ok, probe} = :gen_tcp.listen(0, [:binary])
    {:ok, closed_port} = :inet.port(probe)
    :gen_tcp.close(probe)

    Configuration.update(fn config ->
      %{config | dsn: "http://key@localhost:#{closed_port}/api/v1/events", timeout: 500}
    end)

    PerformanceFlusher.record("GET /flaky", "controller", 7.0)
    assert PerformanceFlusher.flush() == :ok

    assert :sys.get_state(PerformanceFlusher).buckets != %{}
  end

  defp request_counts(requests) do
    for request <- Agent.get(requests, & &1) do
      request.body |> JSON.decode!() |> Map.fetch!("samples") |> Enum.map(& &1["request_count"])
    end
  end

  defp dropped_messages do
    receive do
      {:logged, "[forge_ops_tracker] dropping" <> _ = message} -> [message | dropped_messages()]
      {:logged, _other} -> dropped_messages()
    after
      0 -> []
    end
  end

  defp log_to(test_pid) do
    Configuration.update(fn config ->
      %{config | logger: fn message -> send(test_pid, {:logged, message}) end}
    end)
  end

  test "drops a batch the server rejected instead of sending it again" do
    {port, requests} = TestHttpServer.start(422)
    point_configuration_at(port)
    log_to(self())

    PerformanceFlusher.record("GET /refused", "controller", 7.0)
    assert PerformanceFlusher.flush() == :ok
    assert :sys.get_state(PerformanceFlusher).buckets == %{}

    assert PerformanceFlusher.flush() == :ok
    PerformanceFlusher.record("GET /refused", "controller", 7.0)
    assert PerformanceFlusher.flush() == :ok

    # One request each time, never the first one's count carried into the second.
    assert request_counts(requests) == [[1], [1]]

    assert dropped_messages() == [
             "[forge_ops_tracker] dropping 1 buffered performance samples: the server rejected them and will not accept a retry",
             "[forge_ops_tracker] dropping 1 buffered performance samples: the server rejected them and will not accept a retry"
           ]
  end

  test "keeps a batch through four failed flushes and drops it on the fifth" do
    {port, requests} = TestHttpServer.start(503)
    point_configuration_at(port)
    log_to(self())

    PerformanceFlusher.record("GET /flaky", "controller", 7.0)
    for _ <- 1..4, do: assert(PerformanceFlusher.flush() == :ok)
    assert :sys.get_state(PerformanceFlusher).buckets != %{}
    assert dropped_messages() == []

    assert PerformanceFlusher.flush() == :ok
    assert :sys.get_state(PerformanceFlusher).buckets == %{}
    assert PerformanceFlusher.flush() == :ok

    assert request_counts(requests) == List.duplicate([1], 5)

    assert dropped_messages() == [
             "[forge_ops_tracker] dropping 1 buffered performance samples: 5 flushes in a row failed"
           ]
  end

  test "a flush that gets through starts the count of failed flushes again" do
    on_exit(fn -> :sys.replace_state(PerformanceFlusher, &%{&1 | buckets: %{}}) end)

    {failing_port, _} = TestHttpServer.start(500)
    point_configuration_at(failing_port)
    PerformanceFlusher.record("GET /flaky", "controller", 7.0)
    for _ <- 1..4, do: assert(PerformanceFlusher.flush() == :ok)

    {port, requests} = TestHttpServer.start(202)
    point_configuration_at(port)
    assert PerformanceFlusher.flush() == :ok
    assert request_counts(requests) == [[1]]

    {failing_port, _} = TestHttpServer.start(500)
    point_configuration_at(failing_port)
    PerformanceFlusher.record("GET /flaky", "controller", 7.0)
    for _ <- 1..4, do: assert(PerformanceFlusher.flush() == :ok)

    # Four failures since the flush that got through, so the bucket is still held, not dropped.
    assert :sys.get_state(PerformanceFlusher).buckets != %{}
  end

  test "flushes whatever is pending when the process terminates" do
    {port, requests} = TestHttpServer.start(202)
    point_configuration_at(port)

    PerformanceFlusher.record("GET /shutdown", "controller", 3.0)

    # GenServer.stop/1 invokes terminate/2 as part of its own normal stop protocol regardless of
    # trap_exit (that flag matters for a Supervisor-initiated exit *signal* instead, the real
    # scenario terminate/2's own doc comment is written for); this exercises terminate/2's own
    # behavior directly. ForgeOpsTracker.Application's own :one_for_one supervisor restarts this
    # permanent child right after, so it's ready again for whichever test runs next.
    assert :ok == GenServer.stop(PerformanceFlusher)

    wait_until(fn -> length(Agent.get(requests, & &1)) == 1 end)

    wait_until(fn ->
      case Process.whereis(PerformanceFlusher) do
        nil -> false
        pid -> Process.alive?(pid)
      end
    end)
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

  test "delivers a latency histogram per bucket alongside count, sum and max" do
    {port, requests} = TestHttpServer.start(202)
    point_configuration_at(port)

    for duration <- [10, 40, 120, 700, 12_000] do
      PerformanceFlusher.record("GET /posts", "controller", duration)
    end

    assert PerformanceFlusher.flush() == :ok

    [request] = Agent.get(requests, & &1)
    [sample] = JSON.decode!(request.body)["samples"]

    assert sample["histogram"] == %{"50" => 2, "250" => 1, "1000" => 1, "inf" => 1}
    assert sample["histogram"] |> Map.values() |> Enum.sum() == sample["request_count"]
  end

  test "keeps histogram counts for the next flush when delivery fails" do
    {failing_port, _} = TestHttpServer.start(500)
    point_configuration_at(failing_port)

    PerformanceFlusher.record("GET /posts", "controller", 10.0)
    assert PerformanceFlusher.flush() == :ok

    {port, requests} = TestHttpServer.start(202)
    point_configuration_at(port)

    PerformanceFlusher.record("GET /posts", "controller", 300.0)
    assert PerformanceFlusher.flush() == :ok

    [request] = Agent.get(requests, & &1)
    [sample] = JSON.decode!(request.body)["samples"]
    assert sample["histogram"] == %{"50" => 1, "500" => 1}
  end
end
