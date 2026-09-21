defmodule ForgeOpsTracker do
  @moduledoc """
  Elixir error reporting client for ForgeOps:

      ForgeOpsTracker.init(dsn: "https://<api_key>@getforgeops.net/api/v1/events")
      ForgeOpsTracker.install_handlers()

  See the module docs on `ForgeOpsTracker.LoggerHandler` for what `install_handlers/0` actually
  covers (every process crash anywhere in the whole BEAM VM, via `:logger`: a meaningfully
  stronger automatic-capture story than any single-thread uncaught-exception hook) and
  `capture_exception/3` for reporting one you've already rescued yourself.
  """

  alias ForgeOpsTracker.{
    BreadcrumbBuffer,
    Configuration,
    MetricBuffer,
    PerformanceFlusher,
    Reporter,
    Tracing
  }

  @handler_id :forge_ops_tracker
  @current_user_key :forge_ops_tracker_current_user

  @doc """
  Configures the client. Call once at startup: `application.ex`'s own `start/2`, before the rest
  of your supervision tree starts, is the natural place. Accepts the same keys as
  `ForgeOpsTracker.Configuration`'s struct fields:

      ForgeOpsTracker.init(dsn: "...", environment: "production")

  Fields not passed here fall back to `Application.get_env(:forge_ops_tracker, key)` /
  `FORGE_OPS_DSN`-style environment variables read when this app started: see
  `ForgeOpsTracker.Configuration`'s own module doc.
  """
  @spec init(keyword()) :: Configuration.t()
  def init(opts \\ []) do
    Configuration.update(fn config ->
      Enum.reduce(opts, config, fn {key, value}, acc ->
        if Map.has_key?(acc, key) do
          Map.put(acc, key, value)
        else
          raise ArgumentError, "Configuration has no field #{inspect(key)}"
        end
      end)
    end)
  end

  @doc """
  Installs the `:logger` handler described in `ForgeOpsTracker.LoggerHandler`'s own module doc.
  Call once, after `init/1`. Safe to call more than once: a later call is a no-op.
  """
  @spec install_handlers() :: :ok
  def install_handlers do
    case :logger.add_handler(@handler_id, ForgeOpsTracker.LoggerHandler, %{}) do
      :ok ->
        :ok

      {:error, {:already_exist, _id}} ->
        :ok

      {:error, reason} ->
        raise "failed to install ForgeOpsTracker's :logger handler: #{inspect(reason)}"
    end
  end

  @doc """
  Report an exception (or any raised/thrown term: see `ForgeOpsTracker.EventBuilder`'s own doc
  for why this doesn't require a real `Exception` struct) you've already rescued yourself:

      try do
        charge_card(order)
      rescue
        e ->
          ForgeOpsTracker.capture_exception(e, __STACKTRACE__, %{order_id: order.id})
          reraise e, __STACKTRACE__
      end

  `stacktrace` has to come from the actual rescue/catch site (`__STACKTRACE__`): unlike
  languages where an exception object carries its own trace, Elixir's stacktrace is only
  available via that special form, and only for as long as nothing else has run since the
  rescue/catch (the same reason the example above captures it before doing anything else).

  `user`, if not given, defaults to whatever `set_user/1` last set for this process (`nil` if
  nothing did); pass one explicitly to override that for this one report. The calling process's
  own breadcrumb trail (see `add_breadcrumb/4`) is always attached automatically, the same way
  `user` already is, with no separate argument for it.
  """
  @spec capture_exception(term(), Exception.stacktrace(), map(), map() | nil) :: :ok
  def capture_exception(reason, stacktrace, context \\ %{}, user \\ :from_process) do
    user = if user == :from_process, do: current_user(), else: user
    Reporter.report(reason, stacktrace, context, user, BreadcrumbBuffer.all())
  end

  @doc """
  Manually attaches an affected user to whatever gets reported for the rest of this process
  (a Phoenix request's own connection process, a GenServer, an IEx session): stored in the
  process dictionary, the same "one process per request" isolation boundary Phoenix itself
  already gives every request, and the direct Elixir analog to `Thread.current` in
  `gems/forge_ops_tracker`'s own equivalent. `id`/`email`/`username` are all independently
  optional; call with an empty map (or nothing set at all) to clear whatever was set.
  """
  @spec set_user(map()) :: :ok
  def set_user(user \\ %{}) do
    user = Map.reject(user, fn {_key, value} -> is_nil(value) end)
    Process.put(@current_user_key, if(map_size(user) > 0, do: user))
    :ok
  end

  @doc false
  # Not part of the public API: whatever set_user/1 last set for the calling process, or nil.
  # Shared between capture_exception/4 above and ForgeOpsTracker.LoggerHandler, which calls
  # Reporter.report/4 directly (bypassing capture_exception/4 entirely, since it's not reporting
  # something rescued by application code) but still needs the exact same process-dictionary
  # lookup: confirmed directly that :logger's own crash-report handler runs log/2 synchronously
  # in the crashing process itself (self() inside log/2 matches the crashed process's own pid,
  # not some separate logger process), which is exactly what makes reading this here correct
  # rather than reading a stale or unrelated process's dictionary.
  @spec current_user() :: map() | nil
  def current_user, do: Process.get(@current_user_key)

  @doc """
  Records one entry into the calling process's own breadcrumb trail: a query, an outbound call,
  or anything worth remembering right up to the moment something actually goes wrong. `category`
  defaults to `"custom"` and `level` to `"info"`. A no-op, not a raise, when
  `Configuration.t/0`'s own `track_breadcrumbs` is `false`.

  Stored in the process dictionary, the same isolation boundary `set_user/1` already uses and for
  the identical reason: a Phoenix request's own connection process, a GenServer, an Oban job all
  get their own separate trail, correctly isolated from every other process's.
  """
  @spec add_breadcrumb(String.t(), String.t(), String.t(), map()) :: :ok
  def add_breadcrumb(message, category \\ "custom", level \\ "info", data \\ %{}) do
    config = Configuration.get()

    if config.track_breadcrumbs do
      BreadcrumbBuffer.add(message, category, level, data, config.max_breadcrumbs)
    end

    :ok
  end

  @doc """
  Clears the calling process's own breadcrumb trail. Unlike Phoenix's own request lifecycle
  (which starts a genuinely fresh BEAM process per request, so nothing ever needs clearing between
  requests there), a long-lived process that handles more than one logical "unit of work" on the
  same pid, a GenServer processing several casts, a LiveView socket across several events, has to
  call this itself between units of work, or breadcrumbs from an earlier one will bleed into a
  later one's own report.
  """
  @spec clear_breadcrumbs() :: :ok
  def clear_breadcrumbs, do: BreadcrumbBuffer.clear()

  @doc false
  # Not part of the public API: ForgeOpsTracker.LoggerHandler's own counterpart to current_user/0
  # above, for the identical reason (a crash report is built outside capture_exception/4 entirely,
  # so it needs its own way to read back whatever's already accumulated on the crashing process).
  @spec current_breadcrumbs() :: [map()]
  def current_breadcrumbs, do: BreadcrumbBuffer.all()

  @doc """
  Records one occurrence of `transaction_name` (a request, a database query, a queue job) taking
  `duration_ms`, bucketed by `kind` (`"controller"`/`"job"`/`"query"`). Not something app code
  normally calls directly: `ForgeOpsTracker.Integrations.Phoenix`/`Ecto`/`Oban` all call this once
  wired up via their own `attach/0`/`attach/1`.

  Re-checks `Configuration.enabled?/1` and `track_performance` on every call, the same "guarded
  every time, not just once at attach time" posture `capture_exception/3` already has over
  `Reporter.report/3`: config can change at runtime, so a `:telemetry.attach`ed handler that
  checked this only once at startup could keep recording long after either flag turned off.
  """
  @spec record_performance(String.t(), String.t(), number()) :: :ok
  def record_performance(transaction_name, kind \\ "controller", duration_ms) do
    config = Configuration.get()

    if config.track_performance and Configuration.enabled?(config) do
      PerformanceFlusher.record(transaction_name, kind, duration_ms)
    end

    :ok
  end

  @doc """
  Records a named business metric (a signup, a payment, anything you want to name), buffered and
  flushed periodically as one batch rather than one network call per capture. `value` defaults to
  `1.0` so a bare counter-style call needs no argument; pass one for a real magnitude
  (`capture_metric("payment", 49.0)`); it may be negative (a refund). A no-op when the client isn't
  enabled (no DSN, or this environment isn't in `enabled_environments`). Nothing here is automatic,
  so there is no `track_metrics` option.
  """
  @spec capture_metric(String.t(), number()) :: :ok
  def capture_metric(name, value \\ 1.0) do
    config = Configuration.get()

    if Configuration.enabled?(config) do
      MetricBuffer.record(:custom, %{
        metric_name: name,
        value: value,
        environment: config.environment,
        release: config.release
      })
    end

    :ok
  end

  @doc """
  Records one infrastructure reading (CPU, memory, disk, anything else a script of yours reads) from
  one of your own hosts. `hostname` defaults to `Configuration.server_name`, so a script running on the
  box it reports about needs no argument. Same buffered-batch delivery and no-op-when-disabled
  contract as `capture_metric/2`. A short-lived cron script that captures a few readings and lets the
  VM stop normally has them flushed on the supervised shutdown; call `flush_metrics/0` if it might
  exit another way (`System.halt/1`).
  """
  @spec capture_infrastructure_metric(String.t(), number(), String.t() | nil) :: :ok
  def capture_infrastructure_metric(name, value, hostname \\ nil) do
    config = Configuration.get()

    if Configuration.enabled?(config) do
      MetricBuffer.record(:infrastructure, %{
        metric_name: name,
        value: value,
        hostname: hostname || config.server_name
      })
    end

    :ok
  end

  @doc "Delivers every buffered metric and infrastructure reading right now, instead of waiting for the next flush interval."
  @spec flush_metrics() :: :ok
  def flush_metrics do
    MetricBuffer.flush(:custom)
    MetricBuffer.flush(:infrastructure)
  end

  @doc """
  Times `fun` as a child span of whatever span is open in this process (or of the request's root),
  returning its result. Outside a trace it just runs `fun`. Recorded even if `fun` raises, and the
  error propagates unchanged. `kind` is one of `"controller"`, `"service"`, `"database"`,
  `"redis"`, `"http"`, `"job"`, `"other"` (anything else is sent as `"other"`).

      order = ForgeOpsTracker.span("charge card", "service", %{order_id: id}, fn -> charge(id) end)
  """
  @spec span(String.t(), String.t(), map(), (-> result)) :: result when result: var
  def span(name, kind \\ "service", data \\ %{}, fun), do: Tracing.span(name, kind, data, fun)

  @doc """
  Records a span you timed yourself under the current one; a no-op outside a trace. `started_at`
  is a `DateTime`.
  """
  @spec record_span(String.t(), String.t(), DateTime.t(), number(), map()) :: :ok
  def record_span(name, kind, started_at, duration_ms, data \\ %{}),
    do: Tracing.record_span(name, kind, started_at, duration_ms, data)

  @doc """
  Starts a trace on the calling process. `ForgeOpsTracker.Integrations.Phoenix`/`Oban` do this
  automatically; call it yourself (with `finish_trace/4`) to trace anything else, e.g. a GenServer
  handling a message.
  """
  @spec start_trace() :: :ok
  def start_trace, do: Tracing.start_trace()

  @doc """
  Ends the calling process's trace, sending it when the root took at least
  `trace_capture_threshold` milliseconds. `started_at` is a `DateTime`, `duration_ms` a number.
  """
  @spec finish_trace(String.t(), String.t(), DateTime.t(), number()) :: :ok
  def finish_trace(name, kind \\ "controller", started_at, duration_ms),
    do: Tracing.finish_trace(name, kind, started_at, duration_ms)

  @doc false
  # Not part of the public API: resets module state between test cases. Only clears the calling
  # process's own current-user entry, the same scope set_user/1 itself is limited to; a test that
  # calls set_user/1 from inside a spawned Task of its own would need to clean that process up
  # itself, the same way it would for anything else process-scoped.
  def reset_for_testing do
    :logger.remove_handler(@handler_id)
    Configuration.update(fn _config -> %Configuration{} end)
    Process.delete(@current_user_key)
    BreadcrumbBuffer.clear()
    Process.delete(:forge_ops_tracker_trace)
    MetricBuffer.clear(:custom)
    MetricBuffer.clear(:infrastructure)
    :ok
  end
end
