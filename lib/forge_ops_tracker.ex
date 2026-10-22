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
    Changes,
    Configuration,
    DeliveryQueue,
    MetricBuffer,
    PerformanceFlusher,
    QueryPlanner,
    QueryPlans,
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

  Once the client is enabled, this also sends a change snapshot (once per VM, from its own `Task`,
  so it never delays startup): see `record_change/3` and the `detect_changes` option.
  """
  @spec init(keyword()) :: Configuration.t()
  def init(opts \\ []) do
    config =
      Configuration.update(fn config ->
        Enum.reduce(opts, config, fn {key, value}, acc ->
          if Map.has_key?(acc, key) do
            Map.put(acc, key, value)
          else
            raise ArgumentError, "Configuration has no field #{inspect(key)}"
          end
        end)
      end)

    Configuration.warn_if_not_sending(config)
    Changes.maybe_send_snapshot()
    config
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

  Inside a trace (a Phoenix request, an Oban job, or your own `start_trace/1`), the event also
  carries the trace's `trace_id`, plus the request's `transaction_name` and `endpoint` under
  Phoenix, and the trace is marked errored so it's sent however fast it was.
  """
  @spec capture_exception(term(), Exception.stacktrace(), map(), map() | nil) :: :ok
  def capture_exception(reason, stacktrace, context \\ %{}, user \\ :from_process) do
    user = if user == :from_process, do: current_user(), else: user
    Tracing.mark_errored()

    Reporter.report(
      reason,
      stacktrace,
      context,
      user,
      BreadcrumbBuffer.all(),
      Tracing.error_fields(reason)
    )
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
  `Configuration.t/0`'s own `track_breadcrumbs` is `false` or `strict_privacy` is `true`.

  Stored in the process dictionary, the same isolation boundary `set_user/1` already uses and for
  the identical reason: a Phoenix request's own connection process, a GenServer, an Oban job all
  get their own separate trail, correctly isolated from every other process's.
  """
  @spec add_breadcrumb(String.t(), String.t(), String.t(), map()) :: :ok
  def add_breadcrumb(message, category \\ "custom", level \\ "info", data \\ %{}) do
    config = Configuration.get()

    # Strict privacy never sends breadcrumbs, so none are recorded either.
    if config.track_breadcrumbs and not config.strict_privacy do
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
      # Under strict privacy a raw path keeps only its first segment before it's ever a sample's name.
      transaction_name =
        if config.strict_privacy,
          do: ForgeOpsTracker.StrictPrivacy.transaction_name(transaction_name),
          else: transaction_name

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
  Waits until every error, change and trace queued so far has been sent, for at most `timeout`
  milliseconds (default 5000). Returns `:ok`, or `{:error, :timeout}` if something was still
  waiting when the time ran out.

  A `mix run` or `elixir` script, an escript, and a VM stopped normally already do this on their
  own, so this is for anything that ends another way (`System.halt/1`, `:erlang.halt/0`), or when you
  want delivery done before moving on:

      ForgeOpsTracker.capture_exception(error, __STACKTRACE__)
      ForgeOpsTracker.flush(2_000)
  """
  @spec flush(timeout()) :: :ok | {:error, :timeout}
  def flush(timeout \\ DeliveryQueue.drain_timeout()), do: DeliveryQueue.flush(timeout)

  @doc """
  Records one change to your system (a feature flag flipped, a config edit, a migration run) so
  ForgeOps can show it next to the errors and slowdowns that followed. Queued like an error report,
  so it never blocks the caller, and never raises; a no-op when the client isn't enabled.

      ForgeOpsTracker.record_change(:feature_flag, "Enabled new checkout",
        details: %{flag: "new_checkout", rollout: 25},
        actor: "alice@example.com"
      )

  `kind` is one of `:feature_flag`, `:config`, `:migration`, `:dependency`, `:infrastructure`,
  `:other` (atom or string; anything else is sent as `"other"`). `title` is cut to 200 characters.
  Options: `:details` (a small map), `:environment` (defaults to the configured one), `:service`,
  `:actor`, `:url`, `:id` (an idempotency key), `:occurred_at` (a `DateTime` or ISO 8601 string;
  defaults to now).

  Separately, `init/1` sends a change snapshot once per VM (runtime, loaded application versions,
  and, with `track_env_var_names: true`, environment variable names but never values), and
  ForgeOps records what changed since the last one. Turn that off with `detect_changes: false`.
  """
  @spec record_change(atom() | String.t(), String.t(), keyword()) :: :ok
  def record_change(kind, title, opts \\ []), do: Changes.record(kind, title, opts)

  @doc """
  Times `fun` as a child span of whatever span is open in this process (or of the request's root),
  returning its result. Outside a trace it just runs `fun`. Recorded even if `fun` raises, and the
  error propagates unchanged. `kind` is one of `"controller"`, `"service"`, `"database"`,
  `"redis"`, `"http"`, `"job"`, `"other"` (anything else is sent as `"other"`).

      order = ForgeOpsTracker.span("charge card", "service", %{order_id: id}, fn -> charge(id) end)

  A `"database"` span can carry its SQL with `span/5`; see there.
  """
  @spec span(String.t(), String.t(), map(), (-> result)) :: result when result: var
  def span(name, kind \\ "service", data \\ %{}, fun), do: Tracing.span(name, kind, data, fun)

  @doc """
  `span/4` with options. For a `"database"` span, `:statement` (the SQL) and `:db_system` (e.g.
  `"postgresql"`) add `"db.statement"`, with every string and number replaced by `?`, and
  `"db.system"` to the span's data. The unmasked statement is never sent:

      sql = "SELECT id, total FROM orders WHERE customer_id = $1 AND status = 'paid'"

      rows =
        ForgeOpsTracker.span("Load orders", "database", %{}, [statement: sql, db_system: "postgresql"], fn ->
          Repo.query!(sql, [customer_id]).rows
        end)

  Other options, and these two on any other kind, are ignored.
  """
  @spec span(String.t(), String.t(), map(), keyword(), (-> result)) :: result when result: var
  def span(name, kind, data, opts, fun) when is_list(opts),
    do: Tracing.span(name, kind, database_data(kind, data, opts), fun)

  @doc """
  Records a span you timed yourself under the current one; a no-op outside a trace. `started_at`
  is a `DateTime`.
  """
  @spec record_span(String.t(), String.t(), DateTime.t(), number(), map()) :: :ok
  def record_span(name, kind, started_at, duration_ms, data \\ %{}),
    do: Tracing.record_span(name, kind, started_at, duration_ms, data)

  @doc "`record_span/5` with the same `:statement` and `:db_system` options as `span/5`."
  @spec record_span(String.t(), String.t(), DateTime.t(), number(), map(), keyword()) :: :ok
  def record_span(name, kind, started_at, duration_ms, data, opts) when is_list(opts),
    do: Tracing.record_span(name, kind, started_at, duration_ms, database_data(kind, data, opts))

  defp database_data("database", data, opts) do
    statement = Keyword.get(opts, :statement)
    db_system = Keyword.get(opts, :db_system)

    if statement || db_system,
      do: QueryPlans.span_data(QueryPlans.mask_for_span(statement, db_system), db_system, data),
      else: data
  end

  defp database_data(_kind, data, _opts), do: data

  @doc false
  # Called by the Ecto integration for each query it timed: records a "database" span (inside a
  # trace) carrying "db.statement", the statement with every string and number masked to "?", and
  # "db.system", then offers the query to the opt-in EXPLAIN (see ForgeOpsTracker.QueryPlanner).
  # explain, when given, is a zero-arity function that runs EXPLAIN on a separate connection; it's
  # only ever called by the planner's own Task. Never raises.
  @spec record_database_query(
          String.t(),
          DateTime.t(),
          number(),
          String.t() | nil,
          String.t() | nil,
          (-> term()) | nil
        ) :: :ok
  def record_database_query(name, started_at, duration_ms, statement, db_system, explain \\ nil) do
    masked =
      if Tracing.active?() do
        masked = QueryPlans.mask_for_span(statement, db_system)

        Tracing.record_span(
          name,
          "database",
          started_at,
          duration_ms,
          QueryPlans.span_data(masked, db_system)
        )

        masked
      end

    if explain && is_binary(statement),
      do: QueryPlanner.consider(statement, db_system, duration_ms, explain, masked)

    :ok
  rescue
    e ->
      Configuration.log(
        Configuration.get(),
        "[forge_ops_tracker] database span failed: #{Exception.message(e)}"
      )

      :ok
  end

  @doc """
  Makes one outgoing HTTP call inside the calling process's trace: records it as an `"http"` span
  named `"<METHOD> <host>"` (never the path or query) and calls `fun` with the headers to add to
  the request, a list of `{name, value}` tuples holding a W3C `traceparent` whose parent id is that
  span's own id, so the called service's root span nests under it. Returns what `fun` returns; the
  span is recorded even if `fun` raises, which propagates unchanged.

      ForgeOpsTracker.http_span("POST", url, fn headers ->
        Req.post!(url, json: order, headers: headers)
      end)

  The headers are `[]` outside a trace, when `propagate_traces` is off, or when the host isn't in
  `trace_propagation_targets`; outside a trace no span is recorded either. With `track_tracing`
  off the header is still handed over (the trace id links errors across services) but no span is
  kept.
  """
  @spec http_span(String.t() | atom(), String.t() | URI.t(), map(), (Tracing.headers() -> result)) ::
          result
        when result: var
  def http_span(method, url, data \\ %{}, fun), do: Tracing.http_span(method, url, data, fun)

  @doc """
  The calling process's current W3C trace id (32 lowercase hex characters), or `nil` outside a
  trace. Handy for your own logs: it's the id ForgeOps links errors across services with.
  """
  @spec current_trace_id() :: String.t() | nil
  def current_trace_id, do: Tracing.current_trace_id()

  @doc """
  Names the calling process's current request: `transaction_name` is the same name its
  performance sample and root span use, `endpoint` the HTTP method plus the route pattern
  (`"GET /users/:id"`), never the literal path. `ForgeOpsTracker.Integrations.Phoenix` does this
  as soon as the router has matched the route; a no-op outside a trace.
  """
  @spec set_request_route(String.t() | nil, String.t() | nil) :: :ok
  def set_request_route(transaction_name, endpoint),
    do: Tracing.set_request_route(transaction_name, endpoint)

  @doc """
  Starts a trace on the calling process. `ForgeOpsTracker.Integrations.Phoenix`/`Oban` do this
  automatically; call it yourself (with `finish_trace/4`) to trace anything else, e.g. a GenServer
  handling a message. Pass a W3C `traceparent` header value (a job carrying the header it was
  enqueued with, say) to continue that trace: same trace id, and the root span's parent is the
  caller's span; a missing or malformed value starts a new trace.

  A trace id exists whenever the client is enabled, even with `track_tracing` off, since errors
  captured inside the trace carry it and `http_span/4` propagates it; only span recording is
  gated on `track_tracing`.
  """
  @spec start_trace(String.t() | nil) :: :ok
  def start_trace(traceparent \\ nil), do: Tracing.start_trace(traceparent)

  @doc """
  Ends the calling process's trace, sending it when the root took at least
  `trace_capture_threshold` milliseconds or an error was captured inside it. `started_at` is a
  `DateTime`, `duration_ms` a number.
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
    Configuration.reset_warning_for_testing()
    Process.delete(@current_user_key)
    BreadcrumbBuffer.clear()
    Process.delete(:forge_ops_tracker_trace)
    Process.delete(:forge_ops_tracker_request)
    Process.delete(:forge_ops_tracker_escaped)
    MetricBuffer.clear(:custom)
    MetricBuffer.clear(:infrastructure)
    QueryPlanner.reset_for_testing()
    :ok
  end
end
