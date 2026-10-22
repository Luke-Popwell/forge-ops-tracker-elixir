defmodule ForgeOpsTracker.DeliveryQueueTest do
  # async: false: DeliveryQueue is a single named GenServer, shared process-wide, and it reads
  # the *shared* Configuration singleton internally (not one passed to it directly): concurrent
  # tests would both race the queue itself and stomp on each other's Configuration.
  use ExUnit.Case, async: false

  alias ForgeOpsTracker.{Configuration, DeliveryQueue, TestHttpServer}

  setup do
    on_exit(fn -> Configuration.update(fn _ -> %Configuration{} end) end)
    :ok
  end

  defp point_configuration_at(port, overrides \\ %{}) do
    Configuration.update(fn config ->
      struct(%{config | dsn: "http://key@localhost:#{port}/events"}, overrides)
    end)
  end

  test "push delivers in the background" do
    {port, requests} = TestHttpServer.start(202)
    point_configuration_at(port)

    DeliveryQueue.push(%{"n" => 1})
    DeliveryQueue.push(%{"n" => 2})

    wait_until(fn -> length(Agent.get(requests, & &1)) >= 2 end)
    assert length(Agent.get(requests, & &1)) == 2
  end

  test "drops when full" do
    # hold_for: self(): the server holds each response until this test explicitly releases it
    # (see TestHttpServer's own doc), so the worker stays reliably busy delivering the first
    # payload for as long as this test needs, no real-time sleep-and-hope required. Every held
    # connection (not just the first) has to be released before this test returns: DeliveryQueue
    # is a single process-wide GenServer shared across this whole test suite, so a delivery left
    # dangling here would still occupy its "one at a time" slot and delay every later test's own
    # pushes behind it.
    {port, _requests} = TestHttpServer.start(202, self())
    point_configuration_at(port, %{queue_size: 1, timeout: 5_000})

    DeliveryQueue.push(%{"n" => 1})
    assert_receive {:held, first_connection}, 2_000

    assert :sys.get_state(DeliveryQueue).length == 0,
           "the first item should already be out of the queue and in flight"

    DeliveryQueue.push(%{"n" => 2})

    assert :sys.get_state(DeliveryQueue).length == 1,
           "second push should have filled the size-1 queue"

    DeliveryQueue.push(%{"n" => 3})

    assert :sys.get_state(DeliveryQueue).length == 1,
           "third push should have been dropped: queue was full"

    send(first_connection, :release)
    assert_receive {:held, second_connection}, 2_000
    send(second_connection, :release)

    wait_until(fn ->
      match?(%{length: 0, delivering?: false}, :sys.get_state(DeliveryQueue))
    end)
  end

  test "flush returns once everything queued has been delivered" do
    {port, requests} = TestHttpServer.start(202)
    point_configuration_at(port)

    for n <- 1..3, do: DeliveryQueue.push(%{"n" => n})

    assert DeliveryQueue.flush(2_000) == :ok
    assert length(Agent.get(requests, & &1)) == 3
  end

  test "flush gives up at its timeout rather than waiting on a stuck delivery" do
    {port, _requests} = TestHttpServer.start(202, self())
    point_configuration_at(port, %{timeout: 5_000})

    DeliveryQueue.push(%{"n" => 1})
    assert_receive {:held, connection}, 2_000

    started = System.monotonic_time(:millisecond)
    assert ForgeOpsTracker.flush(200) == {:error, :timeout}
    assert System.monotonic_time(:millisecond) - started < 1_000

    send(connection, :release)
    assert DeliveryQueue.flush(2_000) == :ok
  end

  test "flush returns straight away when nothing is queued" do
    started = System.monotonic_time(:millisecond)
    assert DeliveryQueue.flush() == :ok
    assert System.monotonic_time(:millisecond) - started < 100
  end

  test "the shutdown drain delivers what is still queued" do
    {port, requests} = TestHttpServer.start(202)
    point_configuration_at(port)
    state = %{queue: :queue.from_list([%{"n" => 1}, %{"n" => 2}]), task: nil}

    assert DeliveryQueue.drain(state, 2_000) == :ok
    assert length(Agent.get(requests, & &1)) == 2
  end

  test "the shutdown drain gives up at its timeout" do
    {port, _requests} = TestHttpServer.start(202, self())
    point_configuration_at(port, %{timeout: 5_000})
    state = %{queue: :queue.from_list([%{"n" => 1}]), task: nil}

    started = System.monotonic_time(:millisecond)
    assert DeliveryQueue.drain(state, 200) == :ok
    assert System.monotonic_time(:millisecond) - started < 1_000
    assert_receive {:held, connection}, 1_000
    send(connection, :release)
  end

  test "the shutdown drain waits for the delivery already under way" do
    test_pid = self()
    {pid, ref} = spawn_monitor(fn -> receive do: (:finish -> send(test_pid, :finished)) end)
    Process.send_after(pid, :finish, 100)

    assert DeliveryQueue.drain(%{queue: :queue.new(), task: {pid, ref}}, 2_000) == :ok
    assert_received :finished
  end

  test "allows the supervisor long enough to drain at shutdown" do
    assert DeliveryQueue.child_spec([]).shutdown > DeliveryQueue.drain_timeout()
  end

  describe "in a separate VM" do
    # A real `elixir` process using this compiled client, the way a `mix run` script, an `elixir`
    # script or an escript does: it reports an error and ends straight away.
    defp run_script(script) do
      paths =
        Mix.Project.build_path()
        |> Path.join("lib/*/ebin")
        |> Path.wildcard()
        |> Enum.flat_map(&["-pa", &1])

      System.cmd("elixir", paths ++ ["-e", script], stderr_to_stdout: true)
    end

    defp report_script(port, ending) do
      """
      {:ok, _} = Application.ensure_all_started(:forge_ops_tracker)
      ForgeOpsTracker.init(
        dsn: "http://key@localhost:#{port}/api/v1/events",
        environment: "production",
        detect_changes: false
      )
      ForgeOpsTracker.Reporter.report(%RuntimeError{message: "reported just before exit"}, [])
      #{ending}
      """
    end

    test "a script that reports an error and ends still delivers it" do
      {port, requests} = TestHttpServer.start(202)

      {output, status} = run_script(report_script(port, ""))

      assert status == 0, output
      assert [%{body: body}] = Agent.get(requests, & &1), output
      assert body =~ "reported just before exit"
    end

    test "a VM stopped normally drains the queue in terminate/2" do
      {port, requests} = TestHttpServer.start(202, self())

      # System.stop/0 stops every application, so the at_exit callback never runs here.
      child =
        Task.async(fn ->
          run_script(report_script(port, "System.stop()\nProcess.sleep(:infinity)"))
        end)

      assert_receive {:held, connection}, 5_000
      Process.sleep(200)
      send(connection, :release)

      {output, status} = Task.await(child, 10_000)
      assert status == 0, output
      assert [%{body: body}] = Agent.get(requests, & &1)
      assert body =~ "reported just before exit"
    end
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
