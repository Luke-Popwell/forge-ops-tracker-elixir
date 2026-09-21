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
      :sys.get_state(DeliveryQueue) == %{queue: :queue.new(), length: 0, delivering?: false}
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
end
