defmodule ForgeOpsTracker.Integrations.EctoTest do
  # async: false: handle_event/4 ultimately records into the shared, process-wide
  # PerformanceFlusher singleton, same reasoning as PerformanceFlusherTest's own async: false.
  use ExUnit.Case, async: false

  alias ForgeOpsTracker.{BreadcrumbBuffer, Configuration}
  alias ForgeOpsTracker.Integrations.Ecto, as: EctoIntegration

  setup do
    on_exit(fn ->
      Configuration.update(fn _ -> %Configuration{} end)
      :sys.replace_state(ForgeOpsTracker.PerformanceFlusher, &%{&1 | buckets: %{}})
      BreadcrumbBuffer.clear()
    end)

    Configuration.update(fn config ->
      %{config | dsn: "http://key@localhost:1/api/v1/events", environment: "production"}
    end)

    :ok
  end

  # Shaped exactly like the real telemetry_prefix ++ [:query] event, verified directly against
  # the installed ecto_sql source (Ecto.Adapters.SQL's own query logging): measurements.total_time
  # is already query_time + decode_time + queue_time summed, native time units; metadata.source is
  # the table name for an Ecto.Query-built query, nil for a raw SQL call.
  defp measurements(ms), do: %{total_time: System.convert_time_unit(ms, :millisecond, :native)}

  test "uses metadata.source directly when it's an Ecto.Query-built query" do
    metadata = %{query: "SELECT u0.\"id\" FROM \"users\" AS u0", source: "users"}

    EctoIntegration.handle_event([:my_app, :repo, :query], measurements(12), metadata, nil)

    bucket = :sys.get_state(ForgeOpsTracker.PerformanceFlusher).buckets[{"SELECT users", "query"}]
    assert bucket.count == 1
    assert_in_delta bucket.max_duration_ms, 12.0, 1.0
  end

  test "falls back to QueryNaming's own regex extraction for a raw SQL call with no source" do
    metadata = %{query: "PRAGMA foreign_keys = ON", source: nil}

    EctoIntegration.handle_event([:my_app, :repo, :query], measurements(3), metadata, nil)

    bucket = :sys.get_state(ForgeOpsTracker.PerformanceFlusher).buckets[{"PRAGMA", "query"}]
    assert bucket.count == 1
  end

  test "records an automatic query breadcrumb with the same transaction_name and duration" do
    metadata = %{query: "SELECT u0.\"id\" FROM \"users\" AS u0", source: "users"}

    EctoIntegration.handle_event([:my_app, :repo, :query], measurements(12), metadata, nil)

    [crumb] = BreadcrumbBuffer.all()
    assert crumb["category"] == "query"
    assert crumb["message"] == "SELECT users"
    assert crumb["level"] == "info"
    assert_in_delta crumb["data"][:duration_ms], 12.0, 1.0
  end

  defmodule FakeRepo do
    def config, do: [telemetry_prefix: [:my_app, :repo]]
  end

  test "attach/1 computes the event name from the given repo's own telemetry_prefix" do
    assert EctoIntegration.attach(FakeRepo) == :ok
    assert EctoIntegration.attach(FakeRepo) == :ok

    :telemetry.execute([:my_app, :repo, :query], measurements(9), %{
      query: "SELECT 1",
      source: nil
    })

    bucket = :sys.get_state(ForgeOpsTracker.PerformanceFlusher).buckets[{"SELECT", "query"}]
    assert bucket.count == 1
  end
end
