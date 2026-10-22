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
  Phoenix or Oban integration opens one), named like the transaction. Its data carries
  `"db.statement"`, the SQL with every string and number replaced by `?`, and `"db.system"`, from
  the repo's adapter (`Ecto.Adapters.Postgres` is `"postgresql"`). Query params are never sent.

  With `explain_slow_queries` on, a slow plain SELECT on a PostgreSQL repo is also handed to
  `ForgeOpsTracker.QueryPlanner`, which EXPLAINs it later through `explain_with_repo/3`.
  """

  alias ForgeOpsTracker.{Configuration, QueryNaming, QueryPlanner, QueryPlans}

  @doc "Registers the telemetry handler for `repo`. Safe to call more than once for the same repo."
  @spec attach(module()) :: :ok
  def attach(repo) do
    event_name = repo.config()[:telemetry_prefix] ++ [:query]

    case :telemetry.attach(
           "forge-ops-tracker-ecto-#{inspect(repo)}",
           event_name,
           &__MODULE__.handle_event/4,
           %{repo: repo}
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_event(event_name, measurements, metadata, config) do
    unless QueryPlanner.explaining?() do
      record(event_name, measurements, metadata, config)
    end

    :ok
  end

  defp record(_event_name, measurements, metadata, config) do
    duration_ms = System.convert_time_unit(measurements.total_time, :native, :millisecond)
    transaction_name = QueryNaming.transaction_name(metadata.query, metadata.source)

    ForgeOpsTracker.record_performance(transaction_name, "query", duration_ms)
    ForgeOpsTracker.add_breadcrumb(transaction_name, "query", "info", %{duration_ms: duration_ms})

    micros = System.convert_time_unit(measurements.total_time, :native, :microsecond)
    started_at = DateTime.add(DateTime.utc_now(), -micros, :microsecond)

    # The span carries the masked statement and db.system; the raw SQL and params are only
    # captured by the explain function, held in the planner until its Task runs it. Guarded, since
    # :telemetry detaches a handler that raises.
    try do
      repo = Map.get(metadata, :repo) || (is_map(config) && Map.get(config, :repo)) || nil
      db_system = QueryPlans.repo_db_system(repo)
      statement = metadata.query
      params = Map.get(metadata, :params, [])

      explain =
        if db_system == "postgresql",
          do: fn -> explain_with_repo(repo, statement, params) end

      ForgeOpsTracker.record_database_query(
        transaction_name,
        started_at,
        micros / 1000,
        statement,
        db_system,
        explain
      )
    rescue
      e ->
        Configuration.log(
          Configuration.get(),
          "[forge_ops_tracker] Ecto span failed: #{Exception.message(e)}"
        )
    end
  end

  @doc """
  Runs EXPLAIN (FORMAT JSON), never EXPLAIN ANALYZE, for `sql` with its original `params`, and
  returns the plan. Called only from `ForgeOpsTracker.QueryPlanner`'s own `Task`, never the
  process that ran the query, so `repo.transaction/2` checks out a separate connection from the
  pool (the app's connection and transaction are never touched). The transaction is made READ
  ONLY with a 2 second `statement_timeout` and always rolled back. Raises on any failure, which
  the planner logs and drops.
  """
  @spec explain_with_repo(module(), String.t(), list()) :: term()
  def explain_with_repo(repo, sql, params) do
    result =
      repo.transaction(fn ->
        repo.query!("SET TRANSACTION READ ONLY", [], log: false)

        repo.query!(
          "SET LOCAL statement_timeout = '#{QueryPlans.statement_timeout()}'",
          [],
          log: false
        )

        %{rows: [[plan] | _]} = repo.query!("EXPLAIN (FORMAT JSON) " <> sql, params, log: false)
        repo.rollback({:forge_ops_tracker_plan, plan})
      end)

    case result do
      {:error, {:forge_ops_tracker_plan, plan}} -> plan
      other -> raise "EXPLAIN transaction ended unexpectedly: #{inspect(other)}"
    end
  end
end
