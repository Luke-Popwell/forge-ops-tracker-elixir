defmodule ForgeOpsTracker.Configuration do
  @moduledoc """
  Holds a single ForgeOps DSN plus everything else the client needs to build and deliver events.
  Mirrors `gems/forge_ops_tracker`'s `Configuration`: a single DSN string carries
  both the ingestion URL and the project's api_key: `https://<api_key>@host/api/v1/events`.

  Backed by a `GenServer` (started under `ForgeOpsTracker.Application`'s supervision tree, the
  same "shared mutable state" role every other SDK in this repo's own `Configuration` class
  plays) rather than a plain struct a caller has to thread through every call: Elixir has no
  language-level singleton the way Ruby's module-level state or a Kotlin `object` gives other
  clients in this repo for free, so a supervised process is the idiomatic BEAM equivalent.
  """

  use GenServer

  require Logger

  @warned_key {__MODULE__, :disabled_environment_warned}

  defstruct dsn: nil,
            # See resolve_environment/3 for where the running app's value comes from.
            environment: "production",
            release: nil,
            server_name: nil,
            app_module_prefix: nil,
            enabled_environments: MapSet.new(["production", "staging"]),
            queue_size: 1000,
            timeout: 2_000,
            scrub_pii: true,
            track_performance: true,
            # Milliseconds, not seconds: unlike the Ruby gem's own performance_flush_interval
            # (seconds, since it's handed straight to Ruby's Kernel#sleep), this is fed directly
            # to Process.send_after/2 by ForgeOpsTracker.PerformanceFlusher, which already takes
            # milliseconds, the same unit this struct's own `timeout` field above already uses.
            performance_flush_interval: 60_000,
            # Whether EventBuilder reads a few lines of source off disk around each in_app
            # frame's culprit line (see EventBuilder's own moduledoc for the attach-context
            # logic). Defaults to true so a snippet shows up with no extra setup, but this flag
            # by itself isn't the real protection against sending proprietary source code
            # somewhere it shouldn't go: ForgeOps' own per-project setting is the durable,
            # server-enforced off switch, since it applies no matter what this flag happens to be
            # set to on any given deployment, and can't quietly drift back on the way a local
            # config value could. Set this to false too if this host app should never even
            # attempt that disk read in the first place.
            capture_source_context: true,
            # When an error comes from a database call (Postgrex.Error, MyXQL.Error, and anything
            # else exposing the failing statement on the exception), send the names of the stored
            # procedure, table and view its SQL touched, so an issue says where to start looking.
            # Names are identifiers, never values, which is why this defaults on.
            # capture_sql_statement is the separate, opt-in step of also sending the statement
            # itself, with every string and number replaced by "?"; off by default because even a
            # masked statement describes your schema, and ForgeOps' own per-project setting is
            # what durably governs whether the server stores it. See ForgeOpsTracker.SqlStatement.
            capture_sql_objects: true,
            capture_sql_statement: false,
            # Whether ForgeOpsTracker.add_breadcrumb/4 actually records anything, and whether
            # capture_exception/4 attaches the calling process's own trail to a report at all:
            # add_breadcrumb/4 itself never raises when this is false, it just becomes a no-op,
            # the same "the call site never has to check first" posture track_performance already
            # has. On by default.
            track_breadcrumbs: true,
            # The most recent entries a single process's trail keeps; the oldest is dropped once
            # full. Matches gems/forge_ops_tracker's own default exactly.
            max_breadcrumbs: 30,
            # Milliseconds between flushes of the buffered capture_metric/3 and
            # capture_infrastructure_metric/3 entries (see ForgeOpsTracker.MetricBuffer). No
            # track_metrics flag the way track_performance has one: these are explicit calls the host
            # app's own code makes, not automatic instrumentation, so there is nothing to turn off
            # that simply not calling them doesn't already do.
            metric_flush_interval: 60_000,
            infrastructure_metric_flush_interval: 60_000,
            # Whether the Phoenix/Ecto/Oban integrations record spans per request/job and report
            # them (when slow, or when the request errored) to /spans. ForgeOpsTracker.span/4 and
            # record_span/5 only record inside a trace, so this gates span reporting. A request
            # still gets a trace id with this off (see propagate_traces below). On by default.
            track_tracing: true,
            # Milliseconds, like every other duration in this struct: a trace is only sent when
            # its root span took at least this long, or the request errored.
            trace_capture_threshold: 1_000,
            # Whether ForgeOpsTracker.http_span/4 hands its function a W3C `traceparent` header
            # (https://www.w3.org/TR/trace-context/) for the outgoing request, so the service being
            # called can continue this request's trace instead of starting its own. On by default,
            # and independent of track_tracing: the header also carries the trace id that links an
            # error here to an error there, which is useful with or without spans.
            propagate_traces: true,
            # Which hosts get that header: nil (the default) means every host. Otherwise a list
            # where each entry is either a host string, matching that host and its subdomains on a
            # dot boundary, ignoring case and a leading dot ("example.com" matches
            # "api.example.com" but not "badexample.com"), or a Regex matched against the host.
            # Useful for third-party APIs that reject unknown headers, or that shouldn't learn this
            # app's trace ids at all.
            trace_propagation_targets: nil,
            # Whether init/1 sends one change snapshot per VM (runtime and loaded application
            # versions, see ForgeOpsTracker.Changes) so ForgeOps can record what changed between
            # deploys. On by default; record_change/3 works either way.
            detect_changes: true,
            # Whether that snapshot also lists environment variable names (never values), minus
            # host-specific noise like HOSTNAME or PATH. Off by default.
            track_env_var_names: false,
            # Opt-in EXPLAIN for slow PostgreSQL reads (see ForgeOpsTracker.QueryPlanner). When on,
            # a plain SELECT the Ecto integration timed at explain_threshold_ms or more gets an
            # EXPLAIN (FORMAT JSON), never EXPLAIN ANALYZE, from a background Task on its own pooled
            # connection, inside a READ ONLY transaction with a 2 second statement_timeout that is
            # always rolled back. The masked statement and masked plan are sent; params never leave
            # the VM. Rate limited to one EXPLAIN per distinct statement per 10 minutes and 10 per
            # minute. Off by default because it does run extra (cheap, read-only) statements
            # against your database.
            explain_slow_queries: false,
            # Milliseconds a query has to take before explain_slow_queries considers it.
            explain_threshold_ms: 500,
            # Send only structured facts about an error, never free text that could hold personal
            # or health data: no message (a fingerprint of it instead, so errors still group), no
            # breadcrumbs (none are recorded), endpoint, SQL statement or source context, only the
            # user's id, and only the context and tag keys named in privacy_allowed_fields. Spans
            # are named by method and host for outbound calls, raw paths cut to their first
            # segment, and keep no data beyond the masked statement and database system. Off by
            # default; FORGE_OPS_STRICT_PRIVACY=true or
            # `config :forge_ops_tracker, strict_privacy: true` turns it on. See
            # ForgeOpsTracker.StrictPrivacy.
            strict_privacy: false,
            # The context and tag keys strict privacy still sends, when their value is a string,
            # number or boolean (your own error codes, say). Empty by default;
            # FORGE_OPS_PRIVACY_ALLOWED_FIELDS=error_code,feature sets it.
            privacy_allowed_fields: [],
            logger: nil

  @type t :: %__MODULE__{
          dsn: String.t() | nil,
          environment: String.t(),
          release: String.t() | nil,
          server_name: String.t() | nil,
          app_module_prefix: String.t() | nil,
          enabled_environments: MapSet.t(String.t()),
          queue_size: pos_integer(),
          timeout: pos_integer(),
          scrub_pii: boolean(),
          track_performance: boolean(),
          performance_flush_interval: pos_integer(),
          capture_source_context: boolean(),
          capture_sql_objects: boolean(),
          capture_sql_statement: boolean(),
          track_breadcrumbs: boolean(),
          max_breadcrumbs: pos_integer(),
          metric_flush_interval: pos_integer(),
          infrastructure_metric_flush_interval: pos_integer(),
          track_tracing: boolean(),
          trace_capture_threshold: non_neg_integer(),
          propagate_traces: boolean(),
          trace_propagation_targets: [String.t() | Regex.t()] | nil,
          detect_changes: boolean(),
          track_env_var_names: boolean(),
          explain_slow_queries: boolean(),
          explain_threshold_ms: non_neg_integer(),
          strict_privacy: boolean(),
          privacy_allowed_fields: [String.t()],
          logger: (String.t() -> any()) | nil
        }

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, initial_state(), name: __MODULE__)
  end

  defp initial_state do
    {strict_privacy, privacy_allowed_fields} =
      ForgeOpsTracker.StrictPrivacy.from_environment(System.get_env())

    %__MODULE__{
      dsn: env_or_nil("FORGE_OPS_DSN") || Application.get_env(:forge_ops_tracker, :dsn),
      environment:
        resolve_environment(
          System.get_env(),
          Application.get_env(:forge_ops_tracker, :environment),
          running_mix_env()
        ),
      release:
        env_or_nil("FORGE_OPS_RELEASE") || Application.get_env(:forge_ops_tracker, :release),
      server_name: safe_hostname(),
      # The app's own config wins over the environment, as anything set in code does.
      strict_privacy: Application.get_env(:forge_ops_tracker, :strict_privacy, strict_privacy),
      privacy_allowed_fields:
        Application.get_env(:forge_ops_tracker, :privacy_allowed_fields, privacy_allowed_fields)
    }
  end

  @doc """
  The environment the client starts with, given the OS environment variables (`System.get_env/0`),
  the app's `config :forge_ops_tracker, environment:` value, and `Mix.env/0` when this VM is running
  under Mix (`nil` otherwise), in this order:

    1. `FORGE_OPS_ENVIRONMENT`
    2. `config :forge_ops_tracker, environment: ...`
    3. `MIX_ENV`, with `prod` read as `"production"`, `dev` as `"development"` and `test` as
       `"test"` (any other value as written)
    4. `Mix.env/0`, mapped the same way: `mix` doesn't put its default `:dev` into `MIX_ENV`, so
       this is what keeps `iex -S mix` or `mix phx.server` on a developer's machine from reporting
       as production
    5. `"production"`: a Mix release, an escript or an `elixir` script, where Mix isn't running and
       nothing above is set, so an app deployed with nothing but a DSN still sends its errors.

  An empty value counts as unset.
  """
  @spec resolve_environment(%{optional(String.t()) => String.t()}, term(), atom() | nil) ::
          String.t()
  def resolve_environment(os_env, app_environment, mix_env) do
    present(Map.get(os_env, "FORGE_OPS_ENVIRONMENT")) ||
      present(app_environment) ||
      mix_environment(present(Map.get(os_env, "MIX_ENV"))) ||
      mix_environment(present(mix_env)) ||
      "production"
  end

  # Mix.env/0 only when Mix is actually running (mix run, iex -S mix, mix test, mix phx.server).
  # Being loadable isn't enough: a plain `elixir` script can load the Mix module, but Mix.env/0
  # raises there, since Mix's state only exists once the :mix application has started.
  defp running_mix_env do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and
         List.keymember?(Application.started_applications(), :mix, 0) do
      Mix.env()
    end
  rescue
    _ -> nil
  end

  defp present(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: present(Atom.to_string(value))

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp mix_environment(nil), do: nil
  defp mix_environment("prod"), do: "production"
  defp mix_environment("dev"), do: "development"
  defp mix_environment(other), do: other

  @doc """
  The one-line warning `ForgeOpsTracker.init/1` logs when a DSN is configured but the environment
  isn't one of `enabled_environments`, so nothing would be sent; `nil` when there's nothing to warn
  about (no DSN, or the environment is enabled).
  """
  @spec disabled_environment_warning(t()) :: String.t() | nil
  def disabled_environment_warning(%__MODULE__{} = config) do
    if config.dsn in [nil, ""] or is_nil(api_key(config)) or
         MapSet.member?(config.enabled_environments, config.environment) do
      nil
    else
      enabled = Enum.join(config.enabled_environments, ", ")
      verb = if MapSet.size(config.enabled_environments) == 1, do: "is", else: "are"

      "[ForgeOps] Not sending: this environment is #{inspect(config.environment)}, and only " <>
        "#{enabled} #{verb} enabled. Set FORGE_OPS_ENVIRONMENT=production (or add " <>
        "#{inspect(config.environment)} to the enabled environments) to send from here."
    end
  end

  @doc false
  # Called by ForgeOpsTracker.init/1, and by Reporter.report when it drops an error: logs
  # disabled_environment_warning/1 through Logger, at most once per VM, since a DSN with an
  # environment that isn't enabled otherwise sends nothing, silently. No DSN, no warning: that's a
  # deliberate "off".
  @spec warn_if_not_sending(t()) :: :ok
  def warn_if_not_sending(%__MODULE__{} = config) do
    case disabled_environment_warning(config) do
      nil ->
        :ok

      warning ->
        unless :persistent_term.get(@warned_key, false) do
          :persistent_term.put(@warned_key, true)
          Logger.warning(warning)
        end

        :ok
    end
  end

  @doc false
  def reset_warning_for_testing do
    :persistent_term.erase(@warned_key)
    :ok
  end

  defp env_or_nil(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp safe_hostname do
    case :inet.gethostname() do
      {:ok, hostname} -> to_string(hostname)
      _ -> nil
    end
  end

  @doc "The current configuration."
  @spec get() :: t()
  def get, do: GenServer.call(__MODULE__, :get)

  @doc """
  Updates the configuration via a function that receives the current struct and returns the new
  one (`ForgeOpsTracker.Configuration.update(&%{&1 | dsn: "..."})`) the closest Elixir
  equivalent to every other SDK's own mutable `Configuration` object, without actually mutating
  anything (this replaces the `GenServer`'s state, doesn't mutate a shared struct in place).

  If `fun` raises, that's re-raised here, in the *calling* process, with its original stacktrace:
  not left to crash this shared, process-wide `GenServer` (which every other part of a host
  app calling `ForgeOpsTracker` also depends on) over what's usually just a caller bug, like an
  unknown configuration key.
  """
  @spec update((t() -> t())) :: t()
  def update(fun) when is_function(fun, 1) do
    case GenServer.call(__MODULE__, {:update, fun}) do
      {:ok, new_state} -> new_state
      {:error, exception, stacktrace} -> reraise exception, stacktrace
    end
  end

  @doc "The DSN's userinfo component, percent-decoded: nil if the DSN is unset or malformed."
  @spec api_key(t()) :: String.t() | nil
  def api_key(%__MODULE__{} = config) do
    case parsed_dsn(config.dsn) do
      {_scheme, "", _host_and_path} -> nil
      {_scheme, userinfo, _host_and_path} -> URI.decode(userinfo)
      nil -> nil
    end
  end

  @doc """
  The ingestion URL with credentials stripped out (they travel as the Authorization header
  instead).
  """
  @spec ingestion_uri(t()) :: String.t() | nil
  def ingestion_uri(%__MODULE__{} = config) do
    case parsed_dsn(config.dsn) do
      {scheme, _userinfo, host_and_path} -> "#{scheme}://#{host_and_path}"
      nil -> nil
    end
  end

  @doc """
  Same host and api_key as `ingestion_uri/1`, a sibling path under the same DSN rather than a
  second DSN to configure: the DSN's own path is always `/api/v1/events` (what ForgeOps issues to
  every project), so the performance-samples endpoint is derived by substitution, the same
  approach `gems/forge_ops_tracker`'s own `Configuration#performance_samples_uri` already takes.
  """
  @spec performance_samples_uri(t()) :: String.t() | nil
  def performance_samples_uri(%__MODULE__{} = config) do
    case ingestion_uri(config) do
      nil -> nil
      uri -> Regex.replace(~r{/events\z}, uri, "/performance_samples")
    end
  end

  @doc "Same derivation as `performance_samples_uri/1`, swapping the trailing `/events` for `/custom_metrics`."
  @spec custom_metrics_uri(t()) :: String.t() | nil
  def custom_metrics_uri(%__MODULE__{} = config),
    do: swap_events_suffix(config, "/custom_metrics")

  @doc "Same derivation again, swapping the trailing `/events` for `/infrastructure_metrics`."
  @spec infrastructure_metrics_uri(t()) :: String.t() | nil
  def infrastructure_metrics_uri(%__MODULE__{} = config),
    do: swap_events_suffix(config, "/infrastructure_metrics")

  defp swap_events_suffix(config, replacement) do
    case ingestion_uri(config) do
      nil -> nil
      uri -> Regex.replace(~r{/events\z}, uri, replacement)
    end
  end

  @doc "Same derivation as `performance_samples_uri/1`, swapping the trailing `/events` for `/spans`."
  @spec spans_uri(t()) :: String.t() | nil
  def spans_uri(%__MODULE__{} = config) do
    case ingestion_uri(config) do
      nil -> nil
      uri -> Regex.replace(~r{/events\z}, uri, "/spans")
    end
  end

  @doc "Same derivation again, swapping the trailing `/events` for `/changes`."
  @spec changes_uri(t()) :: String.t() | nil
  def changes_uri(%__MODULE__{} = config), do: swap_events_suffix(config, "/changes")

  @doc "Same derivation again, swapping the trailing `/events` for `/change_snapshots`."
  @spec change_snapshots_uri(t()) :: String.t() | nil
  def change_snapshots_uri(%__MODULE__{} = config),
    do: swap_events_suffix(config, "/change_snapshots")

  @doc "Same derivation again, swapping the trailing `/events` for `/query_plans`."
  @spec query_plans_uri(t()) :: String.t() | nil
  def query_plans_uri(%__MODULE__{} = config), do: swap_events_suffix(config, "/query_plans")

  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{} = config) do
    not is_nil(config.dsn) and config.dsn != "" and not is_nil(api_key(config)) and
      MapSet.member?(config.enabled_environments, config.environment)
  end

  @doc """
  Whether an outgoing request to `host` should carry a `traceparent` header; see
  `propagate_traces`/`trace_propagation_targets` above. Case-insensitive, since hostnames are.
  """
  @spec propagate_trace?(t(), String.t() | nil) :: boolean()
  def propagate_trace?(%__MODULE__{propagate_traces: false}, _host), do: false
  def propagate_trace?(%__MODULE__{trace_propagation_targets: nil}, _host), do: true
  def propagate_trace?(%__MODULE__{}, host) when host in [nil, ""], do: false

  def propagate_trace?(%__MODULE__{trace_propagation_targets: targets}, host) do
    host = String.downcase(host)
    Enum.any?(List.wrap(targets), &target_matches?(&1, host))
  end

  defp target_matches?(%Regex{} = target, host), do: Regex.match?(target, host)

  defp target_matches?(target, host) when is_binary(target) do
    target = target |> String.downcase() |> String.trim_leading(".")
    target != "" and (host == target or String.ends_with?(host, "." <> target))
  end

  defp target_matches?(_target, _host), do: false

  @spec log(t(), String.t()) :: :ok
  def log(%__MODULE__{logger: logger}, message) when is_function(logger, 1) do
    logger.(message)
    :ok
  end

  def log(%__MODULE__{}, _message), do: :ok

  # Hand-parses a DSN of the form "scheme://api_key@host[:port]/path[?query]" rather than pulling
  # in a URI-parsing dependency for it: Elixir's own URI module can parse the *shape* fine, but
  # its userinfo field is only populated when RFC 3986-valid, and a bare API key (no ":password"
  # part) is exactly the kind of userinfo real-world URI parsers are inconsistent about; a small
  # dependency-free parser sidesteps that rather than fighting it, the same spirit as the
  # Rust/Go/C clients' own dependency-free DSN parsing.
  defp parsed_dsn(nil), do: nil
  defp parsed_dsn(""), do: nil

  defp parsed_dsn(dsn) do
    case String.split(dsn, "://", parts: 2) do
      [scheme, rest] when scheme != "" ->
        case String.split(rest, "@", parts: 2) do
          [userinfo, host_and_path] when host_and_path != "" -> {scheme, userinfo, host_and_path}
          [host_and_path] when host_and_path != "" -> {scheme, "", host_and_path}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  @impl true
  def handle_call({:update, fun}, _from, state) do
    # fun is caller-supplied (ultimately from ForgeOpsTracker.init/1's own caller): if it
    # raises, that must become a normal raised exception back in the *caller's* process (see
    # update/1's own doc), not a crash of this shared, process-wide GenServer taking
    # Configuration down for the entire host app over what's usually just a typo in a config key.
    try do
      new_state = fun.(state)
      {:reply, {:ok, new_state}, new_state}
    rescue
      e -> {:reply, {:error, e, __STACKTRACE__}, state}
    end
  end
end
