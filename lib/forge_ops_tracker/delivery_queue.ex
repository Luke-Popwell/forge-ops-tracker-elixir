defmodule ForgeOpsTracker.DeliveryQueue do
  @moduledoc """
  A small bounded queue, processed one event at a time, so delivery never blocks the caller that
  raised the error. The BEAM equivalent of the Ruby/Python/Java clients' own background-thread-
  backed queue: except here the "queue manager" is an ordinary supervised `GenServer` (started
  once, see `ForgeOpsTracker.Application`, not spun up lazily on first push, since BEAM processes
  are cheap enough that there's no meaningful cost to keeping one alive idle) and each actual
  delivery runs in its own short-lived `Task`, not inline in the `GenServer`'s own callback.

  That split matters, confirmed directly (not a hypothetical): a `GenServer` that calls a slow,
  blocking operation (`:httpc.request`, here) directly from inside `handle_info` cannot process
  *any* other message (including a `push` from another process, or even `:sys.get_state`)
  until that call returns, because a `GenServer` only ever handles one message at a time. Doing
  the actual HTTP call in a separate `Task` instead keeps this `GenServer` responsive to new
  pushes the whole time a delivery is in flight, while `handle_info(:delivery_done, ...)` below
  still enforces the same one-delivery-at-a-time ordering every other client's own queue has.

  Bounded via `Configuration.queue_size` (`:queue` has no size limit of its own, so this tracks
  the length itself): a burst of exceptions must never apply backpressure to the host app by
  growing this queue without limit.
  """

  use GenServer

  alias ForgeOpsTracker.{Client, Configuration}

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{queue: :queue.new(), length: 0, delivering?: false},
      name: __MODULE__
    )
  end

  @doc "Enqueues payload for delivery. Always returns :ok: a full queue drops the payload
  (logged via Configuration.logger) rather than raising or blocking the caller."
  @spec push(map()) :: :ok
  def push(payload), do: GenServer.cast(__MODULE__, {:push, payload})

  @doc "Enqueues a finished trace, delivered to the spans endpoint; shares this queue's bound."
  @spec push_trace(map()) :: :ok
  def push_trace(trace), do: GenServer.cast(__MODULE__, {:push, {:spans, trace}})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:push, payload}, %{queue: queue, length: length} = state) do
    config = Configuration.get()

    if length >= max(config.queue_size, 1) do
      Configuration.log(config, "[forge_ops_tracker] delivery queue full, dropping event")
      {:noreply, state}
    else
      new_state = %{state | queue: :queue.in(payload, queue), length: length + 1}
      new_state = maybe_start_next_delivery(new_state)
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:delivery_done, state) do
    {:noreply, maybe_start_next_delivery(%{state | delivering?: false})}
  end

  defp maybe_start_next_delivery(%{delivering?: true} = state), do: state

  defp maybe_start_next_delivery(%{queue: queue, length: length} = state) do
    case :queue.out(queue) do
      {{:value, payload}, remaining_queue} ->
        start_delivery(payload)
        %{state | queue: remaining_queue, length: length - 1, delivering?: true}

      {:empty, _queue} ->
        state
    end
  end

  defp start_delivery(payload) do
    config = Configuration.get()
    genserver = self()

    Task.start(fn ->
      deliver_safely(config, payload)
      send(genserver, :delivery_done)
    end)
  end

  # Per-item, not wrapping the whole queue: one bad delivery must not stop every event queued
  # after it. Client.deliver already turns every failure mode of its own into a plain false
  # return rather than raising; this is a second, redundant layer of safety around it, the same
  # "defensive even against our own code" stance ForgeOpsTracker.Reporter takes at the call site
  # one level up. This runs inside the spawned Task, not this GenServer itself, so even a bug
  # this rescue somehow didn't catch would only crash that one Task, never this shared queue.
  defp deliver_safely(config, {:spans, trace}) do
    Client.deliver_spans(config, trace)
  rescue
    e ->
      Configuration.log(
        config,
        "[forge_ops_tracker] span delivery error: #{Exception.format(:error, e, __STACKTRACE__)}"
      )
  end

  defp deliver_safely(config, payload) do
    Client.deliver(config, payload)
  rescue
    e ->
      Configuration.log(
        config,
        "[forge_ops_tracker] delivery worker error: #{Exception.format(:error, e, __STACKTRACE__)}"
      )
  end
end
