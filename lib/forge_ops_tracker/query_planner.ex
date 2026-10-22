defmodule ForgeOpsTracker.QueryPlanner do
  @moduledoc """
  Opt-in EXPLAIN for slow PostgreSQL queries (`explain_slow_queries`, off by default).

  `consider/5` runs in the process that ran the query, right after it finished, and only decides:
  enabled, PostgreSQL, at or over `explain_threshold_ms`, and a plain SELECT
  (`ForgeOpsTracker.QueryPlans.explainable?/1`). A query that passes is cast to this supervised
  `GenServer` along with the function that will EXPLAIN it, so nothing more happens on the
  caller's path. Here it's rate limited (each distinct masked statement once per 10 minutes, 10
  per minute overall, for the whole VM), and then run in its own `Task`, one at a time.

  That `Task` is started by this `GenServer`, not by the process that ran the query, so it never
  inherits that process's connection or transaction (not even through `$callers`): the EXPLAIN
  function checks out its own connection from the repo's pool. It runs EXPLAIN (FORMAT JSON), never
  EXPLAIN ANALYZE, with the original statement and params inside a READ ONLY transaction with a 2
  second `statement_timeout`, and rolls back (see
  `ForgeOpsTracker.Integrations.Ecto.explain_with_repo/3`). Only the masked statement and the
  masked plan are sent, through `ForgeOpsTracker.DeliveryQueue`. Any failure is logged and
  dropped; nothing here ever raises into the app.
  """

  use GenServer

  alias ForgeOpsTracker.{Configuration, DeliveryQueue, QueryPlans}

  @max_pending 10
  @explaining_key :forge_ops_tracker_explaining

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  True in the process running an EXPLAIN, so the Ecto handler can ignore the EXPLAIN's own
  statements.
  """
  @spec explaining?() :: boolean()
  def explaining?, do: Process.get(@explaining_key, false)

  @doc """
  Offers one finished query for an EXPLAIN. `explain` is a zero-arity function that runs EXPLAIN
  (FORMAT JSON) on a separate connection and returns the plan; it only ever runs in this
  planner's own `Task`. `masked` is the statement as already masked for the span, when there was
  one. Returns whether it was handed to the planner. Never raises.
  """
  @spec consider(String.t(), String.t() | nil, number(), (-> term()), String.t() | nil) ::
          boolean()
  def consider(statement, db_system, duration_ms, explain, masked \\ nil)
      when is_function(explain, 0) do
    config = Configuration.get()

    # Strict privacy sends no SQL at all, masked or not (sdks/STRICT_PRIVACY.md).
    with true <- config.explain_slow_queries and not config.strict_privacy and Configuration.enabled?(config),
         true <- db_system == "postgresql" and duration_ms >= config.explain_threshold_ms,
         true <- QueryPlans.explainable?(statement),
         masked when is_binary(masked) <- masked || QueryPlans.mask_for_span(statement, db_system) do
      GenServer.cast(__MODULE__, {:consider, masked, db_system, duration_ms, explain})
      true
    else
      _ -> false
    end
  rescue
    e ->
      Configuration.log(
        Configuration.get(),
        "[forge_ops_tracker] query plan skipped: #{Exception.message(e)}"
      )

      false
  end

  @doc false
  # Test hook: resets the rate limits and drops anything pending.
  def reset_for_testing, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(:ok), do: {:ok, initial_state()}

  defp initial_state,
    do: %{pending: :queue.new(), length: 0, running?: false, limits: QueryPlans.new_limits()}

  @impl true
  def handle_cast({:consider, masked, db_system, duration_ms, explain}, state) do
    {allowed?, limits} =
      QueryPlans.allow(state.limits, masked, System.monotonic_time(:millisecond))

    state = %{state | limits: limits}

    if allowed? and state.length < @max_pending do
      job = {explain, masked, db_system, duration_ms, DateTime.utc_now()}

      state = %{state | pending: :queue.in(job, state.pending), length: state.length + 1}
      {:noreply, maybe_run_next(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:reset, _from, _state), do: {:reply, :ok, initial_state()}

  @impl true
  def handle_info(:explain_done, state),
    do: {:noreply, maybe_run_next(%{state | running?: false})}

  defp maybe_run_next(%{running?: true} = state), do: state

  defp maybe_run_next(state) do
    case :queue.out(state.pending) do
      {{:value, job}, pending} ->
        planner = self()
        config = Configuration.get()

        Task.start(fn ->
          run_job(config, job)
          send(planner, :explain_done)
        end)

        %{state | pending: pending, length: state.length - 1, running?: true}

      {:empty, _pending} ->
        state
    end
  end

  @doc false
  # Runs one EXPLAIN and queues its plan for delivery. Public only so tests can run a job in the
  # test process; returns whether a payload was queued.
  @spec run_job(Configuration.t(), tuple()) :: boolean()
  def run_job(config, {explain, masked, db_system, duration_ms, captured_at}) do
    Process.put(@explaining_key, true)

    result =
      try do
        {:ok, explain.()}
      rescue
        e -> {:error, Exception.message(e)}
      catch
        kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
      after
        Process.delete(@explaining_key)
      end

    case result do
      {:ok, plan} ->
        case QueryPlans.payload(config, masked, db_system, plan, duration_ms, captured_at) do
          nil ->
            Configuration.log(
              config,
              "[forge_ops_tracker] query plan dropped: unusable or over #{QueryPlans.max_plan_bytes()} bytes"
            )

            false

          payload ->
            DeliveryQueue.push_query_plan(payload)
            true
        end

      {:error, message} ->
        Configuration.log(config, "[forge_ops_tracker] EXPLAIN failed: #{message}")
        false
    end
  end
end
