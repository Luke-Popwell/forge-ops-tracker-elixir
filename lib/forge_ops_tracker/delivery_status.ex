defmodule ForgeOpsTracker.DeliveryStatus do
  @moduledoc """
  What became of one delivery attempt. A bare `true`/`false` could not tell "the server will never
  take this payload" apart from "try again later", so a batch a plan or a validation rule refused
  was re-sent at every flush for as long as the node lived. Ported from `gems/forge_ops_tracker`'s
  `delivery_status.rb`.

    * `:delivered` is any 2xx.
    * `:rejected` is a 4xx other than 408 and 429: sending the same payload again can only fail
      the same way.
    * `:failed` is a network error, a timeout, a 5xx, a 408 or a 429: worth another attempt later.

  `ForgeOpsTracker.Client`'s `deliver*` functions still answer a boolean (`true` only for
  `:delivered`); its `attempt_*` functions answer the status itself.
  """

  @type t :: :delivered | :rejected | :failed

  @max_failed_flushes 5

  @doc """
  After this many flushes in a row that failed for now, a batch is dropped rather than kept for yet
  another attempt, so an outage can never pin the same data in memory for the life of the node.
  """
  @spec max_failed_flushes() :: pos_integer()
  def max_failed_flushes, do: @max_failed_flushes

  @spec for_code(integer()) :: t()
  def for_code(code) when code >= 200 and code < 300, do: :delivered
  def for_code(code) when code in [408, 429], do: :failed
  def for_code(code) when code >= 400 and code < 500, do: :rejected
  def for_code(_code), do: :failed

  @doc """
  Decides whether the batch a flush just sent is done with, given the status of the attempt and how
  many flushes in a row had failed before it. Returns `{:release, nil}` for a delivered batch,
  `{:release, why}` for one to drop (`why` is what to log), and `{:keep, failed_flushes}` for one to
  hold for the next flush, with the new count.
  """
  @spec settle(t(), non_neg_integer()) :: {:release, String.t() | nil} | {:keep, pos_integer()}
  def settle(:delivered, _failed_flushes), do: {:release, nil}

  def settle(:rejected, _failed_flushes),
    do: {:release, "the server rejected them and will not accept a retry"}

  def settle(:failed, failed_flushes) when failed_flushes + 1 >= @max_failed_flushes,
    do: {:release, "#{@max_failed_flushes} flushes in a row failed"}

  def settle(:failed, failed_flushes), do: {:keep, failed_flushes + 1}
end
