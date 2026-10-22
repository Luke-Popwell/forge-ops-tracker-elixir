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
  pushes the whole time a delivery is in flight, while the `:DOWN` monitor message below
  still enforces the same one-delivery-at-a-time ordering every other client's own queue has.

  Bounded via `Configuration.queue_size` (`:queue` has no size limit of its own, so this tracks
  the length itself): a burst of exceptions must never apply backpressure to the host app by
  growing this queue without limit.

  Nothing reported just before the VM stops is lost, mirroring the Ruby gem's `DeliveryQueue#drain`.
  On a normal supervised shutdown (`Application.stop/1`, `System.stop/0`, a release stopping),
  `terminate/2` delivers whatever is still queued and waits for the delivery already under way,
  within `drain_timeout/0`; this needs `Process.flag(:trap_exit, true)`, like `MetricBuffer` and
  `PerformanceFlusher`, and a shutdown timeout longer than the drain. A `mix run` script, an
  `elixir` script or an escript usually ends by halting the VM without stopping applications, so the
  first push also registers a `System.at_exit/1` callback (once per VM) that calls `flush/1`.
  A VM that never reports anything never waits.
  """

  # The shutdown timeout leaves a second on top of the drain, so the supervisor never kills the
  # queue while terminate/2 is still sending.
  use GenServer, shutdown: 6_000

  alias ForgeOpsTracker.{Client, Configuration}

  @drain_timeout 5_000

  @doc "The longest a drain at shutdown, or `flush/0` with no argument, waits, in milliseconds."
  @spec drain_timeout() :: pos_integer()
  def drain_timeout, do: @drain_timeout

  @doc false
  def start_link(_opts) do
    GenServer.start_link(
      __MODULE__,
      %{queue: :queue.new(), length: 0, delivering?: false, task: nil, waiters: []},
      name: __MODULE__
    )
  end

  @doc """
  Waits until everything queued so far has been delivered (or given up on), for at most `timeout`
  milliseconds. Returns `:ok`, or `{:error, :timeout}` if something was still waiting when the time
  ran out. Returns `:ok` straight away when nothing is queued, or when the client isn't running.
  """
  @spec flush(timeout()) :: :ok | {:error, :timeout}
  def flush(timeout \\ @drain_timeout) do
    GenServer.call(__MODULE__, :flush, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _not_running -> :ok
  end

  @doc "Enqueues payload for delivery. Always returns :ok: a full queue drops the payload
  (logged via Configuration.logger) rather than raising or blocking the caller."
  @spec push(map()) :: :ok
  def push(payload), do: cast_push(payload)

  @doc "Enqueues a finished trace, delivered to the spans endpoint; shares this queue's bound."
  @spec push_trace(map()) :: :ok
  def push_trace(trace), do: cast_push({:spans, trace})

  @doc "Enqueues one explicit change, delivered to the changes endpoint; shares this queue's bound."
  @spec push_change(map()) :: :ok
  def push_change(change), do: cast_push({:change, change})

  @doc "Enqueues the startup change snapshot, delivered to the change snapshots endpoint."
  @spec push_change_snapshot(map()) :: :ok
  def push_change_snapshot(snapshot),
    do: cast_push({:change_snapshot, snapshot})

  @doc "Enqueues one masked EXPLAIN plan, delivered to the query plans endpoint."
  @spec push_query_plan(map()) :: :ok
  def push_query_plan(plan), do: cast_push({:query_plan, plan})

  # The exit hook is registered here, in the caller, not when the server handles the cast: a script
  # can finish before the server gets to the cast, and System.at_exit/1 callbacks added after that
  # never run.
  defp cast_push(payload) do
    register_exit_hook()
    GenServer.cast(__MODULE__, {:push, payload})
  end

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

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
  def handle_call(:flush, _from, %{length: 0, delivering?: false} = state),
    do: {:reply, :ok, state}

  def handle_call(:flush, from, %{waiters: waiters} = state),
    do: {:noreply, %{state | waiters: [from | waiters]}}

  # The delivery Task is monitored rather than reporting back itself, so one that crashes still
  # frees the "one at a time" slot.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: {_task_pid, ref}} = state) do
    new_state =
      %{state | delivering?: false, task: nil}
      |> maybe_start_next_delivery()
      |> reply_to_waiters()

    {:noreply, new_state}
  end

  # trap_exit turns exits of linked processes into messages; nothing here needs them.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # A normal supervised shutdown: deliver what's still queued and wait for the delivery under way,
  # within drain_timeout/0, the BEAM equivalent of the Ruby gem's at_exit drain.
  @impl true
  def terminate(_reason, state) do
    drain(state, @drain_timeout)
  end

  @doc false
  # Delivers every queued payload from a Task of its own while the in-flight delivery (if any)
  # finishes, giving up on both once timeout milliseconds have passed. Public only for tests.
  def drain(%{queue: queue, task: task}, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    config = Configuration.get()

    drainer =
      case :queue.to_list(queue) do
        [] -> nil
        payloads -> Task.async(fn -> Enum.each(payloads, &deliver_safely(config, &1)) end)
      end

    with {_pid, ref} <- task do
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        remaining(deadline) -> :ok
      end
    end

    if drainer do
      Task.yield(drainer, remaining(deadline)) || Task.shutdown(drainer, :brutal_kill)
    end

    :ok
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp reply_to_waiters(%{length: 0, delivering?: false, waiters: [_ | _] = waiters} = state) do
    Enum.each(waiters, &GenServer.reply(&1, :ok))
    %{state | waiters: []}
  end

  defp reply_to_waiters(state), do: state

  # Once per VM, and only once something has been pushed, so a VM that never reports anything
  # never waits at exit. System.at_exit/1 callbacks run when a `mix run` or `elixir` script, or an
  # escript, finishes, before the VM halts without stopping applications (so terminate/2 above
  # never runs there).
  defp register_exit_hook do
    unless :persistent_term.get({__MODULE__, :exit_hook}, false) do
      :persistent_term.put({__MODULE__, :exit_hook}, true)
      System.at_exit(fn _status -> flush(@drain_timeout) end)
    end
  end

  defp maybe_start_next_delivery(%{delivering?: true} = state), do: state

  defp maybe_start_next_delivery(%{queue: queue, length: length} = state) do
    case :queue.out(queue) do
      {{:value, payload}, remaining_queue} ->
        task = start_delivery(payload)
        %{state | queue: remaining_queue, length: length - 1, delivering?: true, task: task}

      {:empty, _queue} ->
        state
    end
  end

  defp start_delivery(payload) do
    config = Configuration.get()
    {:ok, pid} = Task.start(fn -> deliver_safely(config, payload) end)
    {pid, Process.monitor(pid)}
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

  defp deliver_safely(config, {:change, change}) do
    Client.deliver_change(config, change)
  rescue
    e ->
      Configuration.log(
        config,
        "[forge_ops_tracker] change delivery error: #{Exception.format(:error, e, __STACKTRACE__)}"
      )
  end

  defp deliver_safely(config, {:change_snapshot, snapshot}) do
    Client.deliver_change_snapshot(config, snapshot)
  rescue
    e ->
      Configuration.log(
        config,
        "[forge_ops_tracker] change snapshot delivery error: #{Exception.format(:error, e, __STACKTRACE__)}"
      )
  end

  defp deliver_safely(config, {:query_plan, plan}) do
    Client.deliver_query_plan(config, plan)
  rescue
    e ->
      Configuration.log(
        config,
        "[forge_ops_tracker] query plan delivery error: #{Exception.format(:error, e, __STACKTRACE__)}"
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
