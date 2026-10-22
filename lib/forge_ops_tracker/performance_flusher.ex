defmodule ForgeOpsTracker.PerformanceFlusher do
  @moduledoc """
  Times every request/job/query in-process, bucketed by `{transaction_name, kind}` (`kind` is
  `"controller"`/`"job"`/`"query"`, see the `ForgeOpsTracker.Integrations.*` modules, each a
  different telemetry source), and periodically flushes each distinct bucket as one small
  aggregate report, rather than one network call per event. Mirrors `gems/forge_ops_tracker`'s own
  `PerformanceFlusher` exactly in shape (the aggregation itself: count + duration sum + max over a
  period), but started once as a supervised `GenServer` (a fourth child of
  `ForgeOpsTracker.Application`, alongside `Configuration` and `DeliveryQueue`) rather than lazily
  spawning a background thread on first use: Elixir has no per-request-process fork boundary to
  dodge the way Ruby's Puma/Passenger workers do (the actual reason that gem starts lazily), and
  BEAM processes are cheap enough that there's no cost to just always running one.

  The actual HTTP delivery on each periodic flush runs synchronously inside this GenServer's own
  `handle_info(:flush, ...)`, not split into a separate `Task` the way `DeliveryQueue` does for its
  own deliveries: a deliberately simpler design here, matching the Ruby gem's own `PerformanceFlusher
  #flush`, which also delivers synchronously within its one dedicated background thread. A `record`
  cast that arrives mid-flush just queues in this process's mailbox and is processed right after,
  bounded by `Configuration.timeout` (2 seconds by default); an already-precedented trade-off, not
  a new one being invented here.
  """

  use GenServer

  alias ForgeOpsTracker.{Client, Configuration, DeliveryStatus, HistogramBucketer}

  @type bucket :: %{
          count: non_neg_integer(),
          duration_sum_ms: float(),
          max_duration_ms: float(),
          histogram: %{String.t() => pos_integer()}
        }

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Records one occurrence of `transaction_name`/`kind` taking `duration_ms`. Not called directly by
  integrations; see `ForgeOpsTracker.record_performance/3`, the guarded public entry point every
  `ForgeOpsTracker.Integrations.*` module actually calls.
  """
  @spec record(String.t(), String.t(), number()) :: :ok
  def record(transaction_name, kind, duration_ms) do
    GenServer.cast(__MODULE__, {:record, transaction_name, kind, duration_ms})
  end

  @doc """
  Delivers whatever's currently tallied, without waiting for the next scheduled flush. Exposed
  mainly for tests; the periodic timer already calls this on its own on every real run.
  """
  @spec flush() :: :ok
  def flush, do: GenServer.call(__MODULE__, :flush)

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    schedule_flush()
    {:ok, %{buckets: %{}, period_started_at: DateTime.utc_now(), failed_flushes: 0}}
  end

  @impl true
  def handle_cast({:record, transaction_name, kind, duration_ms}, state) do
    duration_ms = duration_ms * 1.0

    bucket =
      Map.get(state.buckets, {transaction_name, kind}, %{
        count: 0,
        duration_sum_ms: 0.0,
        max_duration_ms: 0.0,
        histogram: %{}
      })

    # The distribution count/sum/max can't reconstruct: see HistogramBucketer for why the server
    # approximates a percentile from these bucket counts.
    label = HistogramBucketer.bucket_for(duration_ms)

    bucket = %{
      count: bucket.count + 1,
      duration_sum_ms: bucket.duration_sum_ms + duration_ms,
      max_duration_ms: max(bucket.max_duration_ms, duration_ms),
      histogram: Map.update(bucket.histogram, label, 1, &(&1 + 1))
    }

    {:noreply, put_in(state.buckets[{transaction_name, kind}], bucket)}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, :ok, do_flush(state)}
  end

  @impl true
  def handle_info(:flush, state) do
    new_state = do_flush(state)
    schedule_flush()
    {:noreply, new_state}
  end

  @impl true
  def terminate(_reason, state) do
    # The BEAM-idiomatic equivalent of the Ruby gem's own at_exit hook: flushes whatever's left on
    # a normal supervised shutdown so the last partial window (anything shorter than a full
    # performance_flush_interval) isn't silently dropped. Requires Process.flag(:trap_exit, true)
    # in init/1 above; without it a Supervisor's ordinary shutdown never calls this callback at
    # all. The default :worker child spec's 5000ms shutdown timeout comfortably covers one
    # blocking HTTP POST bounded by the 2000ms default Configuration.timeout.
    do_flush(state)
    :ok
  end

  # Delivers the current buckets as one batch. Delivery runs synchronously, so there's no window
  # for a concurrent `record` cast to land while it's in flight (this GenServer processes one
  # message at a time, and the next :flush isn't scheduled until this returns; see the moduledoc):
  # a failed delivery therefore just leaves `state` entirely untouched rather than needing to merge
  # anything back in, and the *next* flush's window grows to cover the gap instead of losing what
  # was already tallied, the same reasoning the Ruby gem's own PerformanceFlusher#flush documents
  # (there, under a real concurrent-access mutex, "grows" is a merge; here it's simply a no-op),
  # and the same reason Api::V1::PerformanceSamplesController accepts a batch rather than a single
  # row: a failed flush shouldn't have to re-deliver by transaction one at a time.
  #
  # That only holds for a delivery that failed for now, and only DeliveryStatus.max_failed_flushes/0
  # times in a row: a batch the server rejected, or one that keeps failing, is let go of exactly the
  # way a delivered one is, since re-sending it could never succeed. `failed_flushes` counts the
  # streak, and nothing left to send ends it.
  defp do_flush(%{buckets: buckets} = state) when map_size(buckets) == 0,
    do: %{state | failed_flushes: 0}

  defp do_flush(state) do
    config = Configuration.get()
    period_ended_at = DateTime.utc_now()

    samples =
      Enum.map(state.buckets, &to_sample(&1, config, state.period_started_at, period_ended_at))

    case DeliveryStatus.settle(deliver(config, samples), state.failed_flushes) do
      {:keep, failed_flushes} ->
        %{state | failed_flushes: failed_flushes}

      {:release, why} ->
        if why do
          Configuration.log(
            config,
            "[forge_ops_tracker] dropping #{length(samples)} buffered performance samples: #{why}"
          )
        end

        %{state | buckets: %{}, period_started_at: DateTime.utc_now(), failed_flushes: 0}
    end
  end

  defp deliver(config, samples) do
    Client.attempt_performance_samples(config, samples)
  rescue
    e ->
      Configuration.log(
        config,
        "[forge_ops_tracker] performance flush error: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      :failed
  end

  defp to_sample({{transaction_name, kind}, bucket}, config, period_started_at, period_ended_at) do
    %{
      transaction_name: transaction_name,
      kind: kind,
      environment: config.environment,
      release: config.release,
      period_started_at: DateTime.to_iso8601(period_started_at),
      period_ended_at: DateTime.to_iso8601(period_ended_at),
      request_count: bucket.count,
      duration_sum_ms: bucket.duration_sum_ms,
      max_duration_ms: bucket.max_duration_ms,
      histogram: bucket.histogram
    }
  end

  defp schedule_flush do
    interval = Configuration.get().performance_flush_interval
    Process.send_after(self(), :flush, interval)
  end
end
