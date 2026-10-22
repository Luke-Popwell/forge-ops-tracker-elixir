defmodule ForgeOpsTracker.Changes do
  @moduledoc """
  Builds the two "what changed" payloads: one explicit change (`ForgeOpsTracker.record_change/3`,
  POSTed to `/api/v1/changes`) and the startup change snapshot (POSTed to
  `/api/v1/change_snapshots`), which describes what this node sees when it boots: the runtime,
  every loaded OTP application with its version, and, only when `track_env_var_names` is on, the
  names (never the values) of its environment variables. ForgeOps diffs each snapshot against the
  last one for the same project and environment and records what changed, so this module keeps no
  state between boots.

  Both go through `ForgeOpsTracker.DeliveryQueue`, so neither blocks the caller, and a failed
  delivery (including the 403 a plan without change tracking gets) is dropped silently.
  """

  alias ForgeOpsTracker.{Configuration, DeliveryQueue}

  @kinds ~w(feature_flag config migration dependency infrastructure other)
  @max_title 200
  @max_dependencies 3000
  @max_dependency_name 200
  @max_dependency_version 100
  @snapshot_sent_key {__MODULE__, :snapshot_sent}

  # Exact names that differ from host to host (or shell to shell) without meaning anything about
  # the deployment, so a fleet of identical nodes doesn't look like it's changing on every boot.
  @denied_names ~w(HOSTNAME HOST HOME PATH PWD OLDPWD SHLVL _ TERM USER LOGNAME SHELL LANG TMPDIR TZ
                   PORT DYNO INVOCATION_ID JOURNAL_STREAM)
  @denied_prefixes ~w(LC_ SYSTEMD_ MEMORY_PRESSURE_ KUBERNETES_ FORGE_OPS_)
  # Service discovery variables injected per pod/container: *_SERVICE_HOST, *_SERVICE_PORT*, and
  # *_PORT_*_TCP*.
  @denied_patterns [~r/_SERVICE_HOST\z/, ~r/_SERVICE_PORT/, ~r/_PORT_.*_TCP/]

  @doc "The change kinds ForgeOps accepts; anything else is sent as `\"other\"`."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  Queues one explicit change for delivery. A no-op when the client isn't enabled, and never
  raises: see `ForgeOpsTracker.record_change/3` for the options.
  """
  @spec record(term(), term(), keyword()) :: :ok
  def record(kind, title, opts \\ []) do
    config = Configuration.get()

    if Configuration.enabled?(config) do
      DeliveryQueue.push_change(build_change(config, kind, title, opts))
    end

    :ok
  rescue
    e ->
      log_failure("record_change failed", e, __STACKTRACE__)
      :ok
  end

  @doc false
  # The /api/v1/changes body. Keys with no value are left out so the server applies its own
  # defaults (occurred_at always has one here: now, in UTC).
  @spec build_change(Configuration.t(), term(), term(), keyword()) :: map()
  def build_change(%Configuration{} = config, kind, title, opts) do
    %{
      "kind" => normalize_kind(kind),
      "title" => title |> to_string() |> String.slice(0, @max_title),
      "details" => details(Keyword.get(opts, :details)),
      "environment" => Keyword.get(opts, :environment) || config.environment,
      "service" => Keyword.get(opts, :service),
      "actor" => Keyword.get(opts, :actor),
      "url" => Keyword.get(opts, :url),
      "id" => Keyword.get(opts, :id),
      "occurred_at" => occurred_at(Keyword.get(opts, :occurred_at))
    }
    |> reject_nil_values()
  end

  @doc false
  @spec normalize_kind(term()) :: String.t()
  def normalize_kind(kind) when is_atom(kind) and not is_nil(kind),
    do: normalize_kind(Atom.to_string(kind))

  def normalize_kind(kind) when kind in @kinds, do: kind
  def normalize_kind(_kind), do: "other"

  defp details(details) when is_map(details) and map_size(details) > 0, do: details
  defp details(_details), do: nil

  defp occurred_at(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp occurred_at(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp occurred_at(at) when is_binary(at), do: at
  defp occurred_at(_at), do: occurred_at(nil)

  @doc """
  Sends the startup snapshot at most once per VM, from a separate unlinked `Task` so the caller
  (usually `init/1` in an application's `start/2`) is never delayed and can never crash because of
  it. Does nothing while the client isn't enabled or `detect_changes` is off, and a later call
  once one was queued does nothing either.
  """
  @spec maybe_send_snapshot() :: :ok
  def maybe_send_snapshot do
    config = Configuration.get()

    # A plain check then set rather than an atomic claim: two init/1 calls racing on different
    # processes could at worst send the same snapshot twice, which ForgeOps records as no change.
    if config.detect_changes and Configuration.enabled?(config) and
         not :persistent_term.get(@snapshot_sent_key, false) do
      :persistent_term.put(@snapshot_sent_key, true)

      Task.start(fn ->
        try do
          DeliveryQueue.push_change_snapshot(build_snapshot(config))
        rescue
          e -> log_failure("change snapshot failed", e, __STACKTRACE__)
        end
      end)
    end

    :ok
  rescue
    e ->
      log_failure("change snapshot failed", e, __STACKTRACE__)
      :ok
  end

  @doc false
  # Not part of the public API: test_helper.exs marks the snapshot as already sent so tests that
  # count requests never see one, and the snapshot tests clear it to send one again.
  def set_snapshot_sent_for_testing(sent?) do
    :persistent_term.put(@snapshot_sent_key, sent?)
    :ok
  end

  @doc false
  # The /api/v1/change_snapshots body. No schema_version: nothing in a plain Elixir app gives one
  # reliably. env_var_names is only present when track_env_var_names is on, since an omitted key
  # means "unknown" to the server, never "every variable was removed".
  @spec build_snapshot(Configuration.t(), map()) :: map()
  def build_snapshot(%Configuration{} = config, env \\ System.get_env()) do
    state = %{"runtime" => runtime(), "dependencies" => dependencies()}

    state =
      if config.track_env_var_names,
        do: Map.put(state, "env_var_names", env_var_names(env)),
        else: state

    %{"environment" => config.environment, "state" => state}
  end

  @doc false
  @spec runtime() :: String.t()
  def runtime, do: "elixir #{System.version()} / otp #{System.otp_release()}"

  @doc false
  # Every OTP application currently loaded (the host app, its Hex dependencies, and the parts of
  # OTP itself it uses), name => version. Sorted before capping so the same set always keeps the
  # same entries.
  @spec dependencies([{atom(), charlist(), charlist()}]) :: %{String.t() => String.t()}
  def dependencies(loaded \\ Application.loaded_applications()) do
    loaded
    |> Enum.map(fn {name, _description, version} ->
      {name |> Atom.to_string() |> String.slice(0, @max_dependency_name),
       version |> to_string() |> String.slice(0, @max_dependency_version)}
    end)
    |> Enum.sort()
    |> Enum.take(@max_dependencies)
    |> Map.new()
  end

  @doc false
  # Names only, sorted, with the host-specific noise listed above dropped.
  @spec env_var_names(map()) :: [String.t()]
  def env_var_names(env) do
    env
    |> Map.keys()
    |> Enum.reject(&denied_env_var_name?/1)
    |> Enum.sort()
  end

  @doc false
  @spec denied_env_var_name?(String.t()) :: boolean()
  def denied_env_var_name?(name) do
    name in @denied_names or String.starts_with?(name, @denied_prefixes) or
      Enum.any?(@denied_patterns, &Regex.match?(&1, name))
  end

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp log_failure(what, e, stacktrace) do
    Configuration.log(
      Configuration.get(),
      "[forge_ops_tracker] #{what}: #{Exception.format(:error, e, stacktrace)}"
    )
  rescue
    _ -> :ok
  end
end
