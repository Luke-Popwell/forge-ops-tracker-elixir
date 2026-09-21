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

  defstruct dsn: nil,
            environment: "development",
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
            # Whether the Phoenix/Ecto/Oban integrations start a trace per request/job and report
            # it (when slow) to /spans. ForgeOpsTracker.span/4 and record_span/5 only record inside
            # a trace, so this gates the whole feature. On by default.
            # Milliseconds between flushes of the buffered capture_metric/3 and
            # capture_infrastructure_metric/3 entries (see ForgeOpsTracker.MetricBuffer). No
            # track_metrics flag the way track_performance has one: these are explicit calls the host
            # app's own code makes, not automatic instrumentation, so there is nothing to turn off
            # that simply not calling them doesn't already do.
            metric_flush_interval: 60_000,
            infrastructure_metric_flush_interval: 60_000,
            track_tracing: true,
            # Milliseconds, like every other duration in this struct: a trace is only sent when
            # its root span took at least this long.
            trace_capture_threshold: 1_000,
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
          logger: (String.t() -> any()) | nil
        }

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, initial_state(), name: __MODULE__)
  end

  defp initial_state do
    %__MODULE__{
      dsn: env_or_nil("FORGE_OPS_DSN") || Application.get_env(:forge_ops_tracker, :dsn),
      environment:
        env_or_nil("FORGE_OPS_ENVIRONMENT") ||
          Application.get_env(:forge_ops_tracker, :environment, "development"),
      release:
        env_or_nil("FORGE_OPS_RELEASE") || Application.get_env(:forge_ops_tracker, :release),
      server_name: safe_hostname()
    }
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

  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{} = config) do
    not is_nil(config.dsn) and config.dsn != "" and not is_nil(api_key(config)) and
      MapSet.member?(config.enabled_environments, config.environment)
  end

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
