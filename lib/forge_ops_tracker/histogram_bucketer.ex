defmodule ForgeOpsTracker.HistogramBucketer do
  @moduledoc """
  Buckets a single duration into one of a fixed set of latency-range labels, the building block
  `ForgeOpsTracker.PerformanceFlusher` uses to accumulate an approximate distribution (not just
  count/sum/max) alongside every `{transaction_name, kind}` bucket it already tallies. The server
  merges these counts across matching samples at read time and walks cumulative counts to
  approximate a percentile, accurate to the bucket width: this SDK never stores the raw duration
  list a true percentile would need. Ported from
  `gems/forge_ops_tracker/lib/forge_ops_tracker/histogram_bucketer.rb`.

  `boundaries_ms/0` is duplicated on the server side, in `app/services/histogram_percentile.rb`.
  Change one, change the other, or a released SDK version and the server it talks to would silently
  disagree about what each bucket label means.
  """

  @boundaries_ms [50, 100, 250, 500, 1000, 2500, 5000, 10_000]

  @doc "The fixed latency-range upper bounds, in milliseconds."
  @spec boundaries_ms() :: [pos_integer()]
  def boundaries_ms, do: @boundaries_ms

  @doc """
  Returns the label (a string) of the smallest boundary `duration_ms` fits under, or `"inf"` for
  anything larger than the largest boundary. A string, not an integer: this travels as a JSON
  object key once flushed, and JSON object keys are always strings.
  """
  @spec bucket_for(number()) :: String.t()
  def bucket_for(duration_ms) do
    case Enum.find(@boundaries_ms, &(duration_ms <= &1)) do
      nil -> "inf"
      boundary -> Integer.to_string(boundary)
    end
  end
end
