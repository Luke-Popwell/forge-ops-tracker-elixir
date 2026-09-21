defmodule ForgeOpsTracker.HistogramBucketerTest do
  use ExUnit.Case, async: true

  alias ForgeOpsTracker.HistogramBucketer

  test "returns the smallest boundary a duration fits under, as a string" do
    assert HistogramBucketer.bucket_for(10) == "50"
    assert HistogramBucketer.bucket_for(50) == "50"
    assert HistogramBucketer.bucket_for(50.5) == "100"
    assert HistogramBucketer.bucket_for(4999) == "5000"
  end

  test "returns inf for anything larger than the largest boundary" do
    assert HistogramBucketer.bucket_for(10_001) == "inf"
    assert HistogramBucketer.bucket_for(1_000_000) == "inf"
  end

  test "puts a duration exactly on a boundary into that boundary's own bucket" do
    for boundary <- HistogramBucketer.boundaries_ms() do
      assert HistogramBucketer.bucket_for(boundary) == Integer.to_string(boundary)
    end
  end

  test "boundaries match the server's HistogramPercentile" do
    # app/services/histogram_percentile.rb and every other SDK must agree on this exact list.
    assert HistogramBucketer.boundaries_ms() == [50, 100, 250, 500, 1000, 2500, 5000, 10_000]
  end
end
