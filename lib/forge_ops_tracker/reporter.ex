defmodule ForgeOpsTracker.Reporter do
  @moduledoc """
  Ties Configuration, EventBuilder, and DeliveryQueue together into the one thing callers actually
  need: report an exception. Mirrors every other SDK's own Reporter/ErrorSubscriber: never
  raises. An error reporter that itself raises while reporting an error is the worst possible
  failure mode, so every path here is wrapped to guarantee this never propagates back into the
  caller (or, when called from `ForgeOpsTracker.LoggerHandler`, back into the `:logger` pipeline
  itself, which would be just as bad).
  """

  alias ForgeOpsTracker.{Configuration, DeliveryQueue, EventBuilder}

  @spec report(term(), Exception.stacktrace(), map(), map() | nil, [map()]) :: :ok
  def report(reason, stacktrace, context \\ %{}, user \\ nil, breadcrumbs \\ []) do
    config = Configuration.get()

    if Configuration.enabled?(config) do
      payload = EventBuilder.build(config, reason, stacktrace, context, user, breadcrumbs)
      DeliveryQueue.push(payload)
    end

    :ok
  rescue
    e ->
      Configuration.log(
        Configuration.get(),
        "[forge_ops_tracker] report failed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      :ok
  end
end
