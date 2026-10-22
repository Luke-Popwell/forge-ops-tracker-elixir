defmodule ForgeOpsTracker.Integrations.Oban do
  @moduledoc """
  Times every Oban job, `kind: "job"`, and reports a genuinely failed job (retries exhausted, or
  the worker explicitly gave up) the same way an unhandled exception anywhere else already is. Call
  once at startup:

      ForgeOpsTracker.Integrations.Oban.attach()

  Attaches to `[:oban, :job, :stop]` and `[:oban, :job, :exception]` (confirmed directly against
  the installed `oban` source, not assumed from docs), both global event names covering every Oban
  instance in the host app. `measurements.duration` is native time units, available on both events,
  and is recorded on both: a failed attempt's own duration is still useful data, the same "always
  time it regardless of outcome" choice this repo's own Ruby/Python job integrations already make.
  `metadata.job.worker` (the worker module's own name, as a string) is the transaction_name.

  On `:exception` specifically, `metadata.state` is `:failure` (this attempt failed but will
  retry) or `:discard` (no further retries, either exhausted or the worker explicitly returned
  `:discard`/`{:discard, reason}`), per Oban's own source. `capture_exception/3` is only called
  when `state == :discard`, not on every retryable `:failure`: the same "report once retries are
  exhausted, not on every retry" scope this repo's own PHP `Queue::failing` (as opposed to
  `Queue::exceptionOccurred`) integration already settled on, applied here since Oban's own
  `:discard` vs `:failure` distinction maps onto exactly that same "final vs will-retry" question.
  `metadata.reason` is always exception-shaped by the time it reaches here (Oban's own docs: a
  raised exception passes through as-is, a crash wraps in `Oban.CrashError`, a timeout in
  `Oban.TimeoutError`, everything else normalizes into `Oban.PerformError`), so no special-casing
  is needed before handing it to `capture_exception/3`.

  Also attaches to `[:oban, :job, :start]`, purely to record an automatic `"job"` breadcrumb
  (`"started job WORKER"`) right as a job begins: recorded at *start*, not alongside the duration
  above at `:stop`/`:exception`, the same design call `sdks/python`'s own Celery integration and
  `sdks/php`'s own `Queue::before` (as opposed to `Queue::after`) already made, and for the
  identical reason: a job that ultimately fails fires `:exception`, never `:stop`, so a breadcrumb
  only ever recorded at `:stop` would never make it into that same job's own failure report.

  Also opens a trace per job (root span `kind: "job"`, named for the worker), finished at `:stop`
  or `:exception`, so a slow job's own breakdown reaches `/spans`; `Ecto` queries run inside the job
  become `"database"` spans under it.
  """

  @doc "Registers the telemetry handler. Safe to call more than once: a later call is a no-op."
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(
           "forge-ops-tracker-oban",
           [[:oban, :job, :start], [:oban, :job, :stop], [:oban, :job, :exception]],
           &__MODULE__.handle_event/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_event([:oban, :job, :start], _measurements, metadata, _config) do
    ForgeOpsTracker.start_trace()
    ForgeOpsTracker.add_breadcrumb("started job #{metadata.job.worker}", "job", "info", %{})
  end

  def handle_event([:oban, :job, :stop], measurements, metadata, _config) do
    record_duration(measurements, metadata)
  end

  # Captured before the trace is finished, so the report carries the job's trace id and the
  # trace is sent however fast the job was.
  def handle_event([:oban, :job, :exception], measurements, metadata, _config) do
    if metadata.state == :discard do
      ForgeOpsTracker.capture_exception(metadata.reason, metadata.stacktrace || [], %{
        job: metadata.job.worker
      })
    end

    record_duration(measurements, metadata)
  end

  defp record_duration(measurements, metadata) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    ForgeOpsTracker.record_performance(metadata.job.worker, "job", duration_ms)

    micros = System.convert_time_unit(measurements.duration, :native, :microsecond)

    ForgeOpsTracker.finish_trace(
      metadata.job.worker,
      "job",
      DateTime.add(DateTime.utc_now(), -micros, :microsecond),
      micros / 1000
    )
  end
end
