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

  @spec report(term(), Exception.stacktrace(), map(), map() | nil, [map()], map()) :: :ok
  def report(
        reason,
        stacktrace,
        context \\ %{},
        user \\ nil,
        breadcrumbs \\ [],
        request_fields \\ %{}
      ) do
    config = Configuration.get()

    if Configuration.enabled?(config) do
      payload =
        EventBuilder.build(config, reason, stacktrace, context, user, breadcrumbs, request_fields)

      DeliveryQueue.push(payload)
    else
      # An error is being dropped. Say why, once per VM: an app configured through config.exs or
      # FORGE_OPS_DSN alone never calls init/1, which used to be the only place that said so.
      Configuration.warn_if_not_sending(config)
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
