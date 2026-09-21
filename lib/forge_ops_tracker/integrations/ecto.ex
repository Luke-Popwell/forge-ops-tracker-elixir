defmodule ForgeOpsTracker.Integrations.Ecto do
  @moduledoc """
  Times every query a given `Ecto.Repo` runs, `kind: "query"`. Call once at startup, passing the
  repo module itself:

      ForgeOpsTracker.Integrations.Ecto.attach(MyApp.Repo)

  Unlike `ForgeOpsTracker.Integrations.Phoenix`/`Oban`, this needs the repo handed over explicitly
  rather than attaching to one fixed global event name: confirmed directly against the installed
  `ecto`/`ecto_sql` source, `Ecto.Adapters.SQL`'s own query logging emits `telemetry_prefix ++
  [:query]`, where `telemetry_prefix` defaults to the repo module's own name, underscored
  (`MyApp.Repo` -> `[:my_app, :repo]`), but is stored on the repo's own runtime config
  (`repo.config()[:telemetry_prefix]`, which also respects a host app that set a custom prefix
  explicitly), not a name this module could otherwise guess. Call once per repo if the host app
  has more than one.

  `measurements.total_time` is already `query_time + decode_time + queue_time` summed (Ecto's own
  `Ecto.Adapters.SQL` computes this exact total for its own query logging), native time units.
  `metadata.source` is the table name directly for any query built from `Ecto.Query` (the common
  case), `nil` for a raw SQL call; see `ForgeOpsTracker.QueryNaming` for how each is turned into a
  low-cardinality `transaction_name`.

  Also records an automatic `"query"` breadcrumb (message is just `transaction_name`, data holds
  `duration_ms`), gated independently on `track_breadcrumbs` the same way performance recording is
  independently gated on `track_performance`.

  Also records a `"database"` span per query into whatever trace the calling process has open (the
  Phoenix or Oban integration opens one), named like the transaction, never the SQL text.
  """

  alias ForgeOpsTracker.QueryNaming

  @doc "Registers the telemetry handler for `repo`. Safe to call more than once for the same repo."
  @spec attach(module()) :: :ok
  def attach(repo) do
    event_name = repo.config()[:telemetry_prefix] ++ [:query]

    case :telemetry.attach(
           "forge-ops-tracker-ecto-#{inspect(repo)}",
           event_name,
           &__MODULE__.handle_event/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_event(_event_name, measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.total_time, :native, :millisecond)
    transaction_name = QueryNaming.transaction_name(metadata.query, metadata.source)

    ForgeOpsTracker.record_performance(transaction_name, "query", duration_ms)
    ForgeOpsTracker.add_breadcrumb(transaction_name, "query", "info", %{duration_ms: duration_ms})

    micros = System.convert_time_unit(measurements.total_time, :native, :microsecond)

    ForgeOpsTracker.record_span(
      transaction_name,
      "database",
      DateTime.add(DateTime.utc_now(), -micros, :microsecond),
      micros / 1000
    )
  end
end
