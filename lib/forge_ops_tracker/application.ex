defmodule ForgeOpsTracker.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ForgeOpsTracker.Configuration,
      ForgeOpsTracker.DeliveryQueue,
      ForgeOpsTracker.QueryPlanner,
      ForgeOpsTracker.PerformanceFlusher,
      {ForgeOpsTracker.MetricBuffer, :custom},
      {ForgeOpsTracker.MetricBuffer, :infrastructure}
    ]

    opts = [strategy: :one_for_one, name: ForgeOpsTracker.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Configured entirely through config.exs or FORGE_OPS_DSN (no init/1 call): send the change
    # snapshot now. A no-op when disabled, and init/1 won't send a second one.
    ForgeOpsTracker.Changes.maybe_send_snapshot()

    result
  end
end
