defmodule ForgeOpsTracker.MetricBuffer do
  @moduledoc """
  Collects individual `ForgeOpsTracker.capture_metric/2` / `capture_infrastructure_metric/3` calls
  and periodically flushes them as one batch, rather than one network call per capture. Unlike
  `ForgeOpsTracker.PerformanceFlusher` this keeps a *list* of individually meaningful entries
  instead of summing them into buckets: a customer's own signup or payment is exactly the kind of
  thing they will want a genuinely accurate count/sum of later, so the server stores one row per
  entry as-is. Ported from `gems/forge_ops_tracker`'s `metric_buffer.rb` and
  `infrastructure_metric_buffer.rb`, which are the same class twice; here it is one `GenServer`
  started twice under `ForgeOpsTracker.Application` (`:custom` and `:infrastructure`), each
  registered under its own name.

  Same shape as `PerformanceFlusher`: a supervised `GenServer`, a periodic `Process.send_after`
  flush, and a flush in `terminate/2` on a normal supervised shutdown (the BEAM equivalent of the
  Ruby gem's `at_exit`, which is what lets a short-lived cron script that captures a few readings
  and ends still deliver them, given `Process.flag(:trap_exit, true)`). Delivery runs synchronously
  inside the server, so a `record` cast that arrives mid-delivery just waits in the mailbox and is
  handled right after: nothing recorded during a delivery can be lost, and a delivery that failed
  for now leaves the entries in place for the next flush. A batch the server rejected, or one that
  failed `ForgeOpsTracker.DeliveryStatus.max_failed_flushes/0` flushes in a row, is dropped.

  Differences from the Ruby buffers: the buffer is capped at `max_entries/0` and drops further
  entries once full (an unreachable server fails every flush, and an uncapped buffer would keep
  growing until the batch is given up on), and a non-numeric value is dropped at record time
  (the BEAM has no NaN or infinity to worry about, but a string would still be an invalid metric).
  """

  use GenServer

  alias ForgeOpsTracker.{Client, Configuration, DeliveryStatus}

  @max_entries 1000

  @type kind :: :custom | :infrastructure

  @doc "The most entries one buffer holds; once full, further entries are dropped until a flush lets go of them."
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @doc false
  def start_link(kind) when kind in [:custom, :infrastructure] do
    GenServer.start_link(__MODULE__, kind, name: name(kind))
  end

  @doc false
  def child_spec(kind) do
    %{id: {__MODULE__, kind}, start: {__MODULE__, :start_link, [kind]}}
  end

  @doc "The registered name of the buffer for `kind`."
  @spec name(kind()) :: atom()
  def name(:custom), do: ForgeOpsTracker.MetricBuffer.Custom
  def name(:infrastructure), do: ForgeOpsTracker.MetricBuffer.Infrastructure

  @doc """
  Adds one entry (everything but `recorded_at`, which is stamped here). Returns `:ok` immediately;
  a non-numeric value is dropped, and so is anything past `max_entries/0`.
  """
  @spec record(kind(), map()) :: :ok
  def record(kind, entry), do: GenServer.cast(name(kind), {:record, entry})

  @doc "Delivers whatever is buffered right now, without waiting for the next interval."
  @spec flush(kind()) :: :ok
  def flush(kind), do: GenServer.call(name(kind), :flush, 10_000)

  @doc false
  @spec entries(kind()) :: [map()]
  def entries(kind), do: GenServer.call(name(kind), :entries)

  @doc false
  @spec clear(kind()) :: :ok
  def clear(kind), do: GenServer.call(name(kind), :clear)

  @impl true
  def init(kind) do
    Process.flag(:trap_exit, true)
    schedule_flush(kind)
    {:ok, %{kind: kind, entries: [], count: 0, failed_flushes: 0}}
  end

  @impl true
  def handle_cast({:record, entry}, %{entries: entries, count: count} = state) do
    config = Configuration.get()

    cond do
      not is_number(entry[:value]) ->
        Configuration.log(config, "[forge_ops_tracker] dropped a metric with a non-numeric value")
        {:noreply, state}

      count >= @max_entries ->
        Configuration.log(config, "[forge_ops_tracker] metric buffer full, dropping a metric")
        {:noreply, state}

      true ->
        stamped = Map.put(entry, :recorded_at, timestamp())
        {:noreply, %{state | entries: [stamped | entries], count: count + 1}}
    end
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, do_flush(state)}
  def handle_call(:entries, _from, state), do: {:reply, Enum.reverse(state.entries), state}

  def handle_call(:clear, _from, state),
    do: {:reply, :ok, %{state | entries: [], count: 0, failed_flushes: 0}}

  @impl true
  def handle_info(:flush, %{kind: kind} = state) do
    new_state = do_flush(state)
    schedule_flush(kind)
    {:noreply, new_state}
  end

  @impl true
  def terminate(_reason, state) do
    do_flush(state)
    :ok
  end

  # `failed_flushes` counts flushes in a row that failed for now; nothing left to send ends the streak.
  defp do_flush(%{entries: []} = state), do: %{state | failed_flushes: 0}

  defp do_flush(%{kind: kind, entries: entries, count: count} = state) do
    config = Configuration.get()
    status = deliver(config, kind, Enum.reverse(entries))

    case DeliveryStatus.settle(status, state.failed_flushes) do
      {:keep, failed_flushes} ->
        %{state | failed_flushes: failed_flushes}

      {:release, why} ->
        if why do
          Configuration.log(
            config,
            "[forge_ops_tracker] dropping #{count} buffered metrics: #{why}"
          )
        end

        %{state | entries: [], count: 0, failed_flushes: 0}
    end
  end

  defp deliver(config, :custom, entries),
    do: safely(config, fn -> Client.attempt_metrics(config, entries) end)

  defp deliver(config, :infrastructure, entries),
    do: safely(config, fn -> Client.attempt_infrastructure_metrics(config, entries) end)

  defp safely(config, fun) do
    fun.()
  rescue
    e ->
      Configuration.log(
        config,
        "[forge_ops_tracker] metric flush error: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      :failed
  end

  defp schedule_flush(kind) do
    config = Configuration.get()

    interval =
      case kind do
        :custom -> config.metric_flush_interval
        :infrastructure -> config.infrastructure_metric_flush_interval
      end

    Process.send_after(self(), :flush, interval)
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
