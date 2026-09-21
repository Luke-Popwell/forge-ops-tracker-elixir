defmodule ForgeOpsTracker.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ForgeOpsTracker.Configuration,
      ForgeOpsTracker.DeliveryQueue,
      ForgeOpsTracker.PerformanceFlusher,
      {ForgeOpsTracker.MetricBuffer, :custom},
      {ForgeOpsTracker.MetricBuffer, :infrastructure}
    ]

    opts = [strategy: :one_for_one, name: ForgeOpsTracker.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
