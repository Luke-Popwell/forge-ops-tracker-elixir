defmodule ForgeOpsTracker.Integrations.ObanTest do
  # async: false: handle_event/4 ultimately records into the shared, process-wide
  # PerformanceFlusher singleton, and captured exceptions flow through the shared Configuration/
  # DeliveryQueue singletons too, same reasoning as ReporterTest/PerformanceFlusherTest's own
  # async: false.
  use ExUnit.Case, async: false

  alias ForgeOpsTracker.{BreadcrumbBuffer, Configuration, TestHttpServer}
  alias ForgeOpsTracker.Integrations.Oban, as: ObanIntegration

  setup do
    on_exit(fn ->
      Configuration.update(fn _ -> %Configuration{} end)
      :sys.replace_state(ForgeOpsTracker.PerformanceFlusher, &%{&1 | buckets: %{}})
      BreadcrumbBuffer.clear()
    end)

    :ok
  end

  # Shaped exactly like the real [:oban, :job, :stop]/[:oban, :job, :exception] events, verified
  # directly against the installed oban source: measurements.duration is native time units,
  # available on both; metadata.job.worker is the worker module's own name, as a string.
  defp measurements(ms), do: %{duration: System.convert_time_unit(ms, :millisecond, :native)}
  defp job(worker), do: %{worker: worker}

  test "records a succeeded job's duration as kind: job" do
    Configuration.update(fn config ->
      %{config | dsn: "http://key@localhost:1/api/v1/events", environment: "production"}
    end)

    metadata = %{job: job("MyApp.Workers.SendWelcomeEmail"), state: :success}
    ObanIntegration.handle_event([:oban, :job, :stop], measurements(15), metadata, nil)

    bucket =
      :sys.get_state(ForgeOpsTracker.PerformanceFlusher).buckets[
        {"MyApp.Workers.SendWelcomeEmail", "job"}
      ]

    assert bucket.count == 1
    assert_in_delta bucket.max_duration_ms, 15.0, 1.0
  end

  test "records a started job breadcrumb on :start" do
    Configuration.update(fn config ->
      %{config | dsn: "http://key@localhost:1/api/v1/events", environment: "production"}
    end)

    metadata = %{job: job("MyApp.Workers.SendWelcomeEmail")}
    ObanIntegration.handle_event([:oban, :job, :start], %{}, metadata, nil)

    [crumb] = BreadcrumbBuffer.all()
    assert crumb["category"] == "job"
    assert crumb["message"] == "started job MyApp.Workers.SendWelcomeEmail"
  end

  test "a job discarded after :start includes the started-job breadcrumb in its own report" do
    {port, requests} = TestHttpServer.start(202)

    Configuration.update(fn config ->
      %{config | dsn: "http://key@localhost:#{port}/api/v1/events", environment: "production"}
    end)

    metadata = %{
      job: job("MyApp.Workers.ChargeCard"),
      state: :discard,
      reason: %RuntimeError{message: "card declined"},
      stacktrace: []
    }

    # The real sequence a job discarded on its first attempt fires: :start, then :exception, no
    # :stop in between, the exact scenario this breadcrumb exists to survive.
    ObanIntegration.handle_event([:oban, :job, :start], %{}, metadata, nil)
    ObanIntegration.handle_event([:oban, :job, :exception], measurements(4), metadata, nil)

    [request] = wait_for_requests(requests, 1)
    body = JSON.decode!(request.body)

    assert Enum.any?(
             body["breadcrumbs"],
             &(&1["message"] == "started job MyApp.Workers.ChargeCard")
           )
  end

  test "records duration but does not report an error for a failed attempt that will still retry" do
    {port, requests} = TestHttpServer.start(202)

    Configuration.update(fn config ->
      %{config | dsn: "http://key@localhost:#{port}/api/v1/events", environment: "production"}
    end)

    metadata = %{
      job: job("MyApp.Workers.ChargeCard"),
      state: :failure,
      reason: %RuntimeError{message: "card declined"},
      stacktrace: []
    }

    ObanIntegration.handle_event([:oban, :job, :exception], measurements(4), metadata, nil)

    bucket =
      :sys.get_state(ForgeOpsTracker.PerformanceFlusher).buckets[
        {"MyApp.Workers.ChargeCard", "job"}
      ]

    assert bucket.count == 1

    Process.sleep(100)
    assert Agent.get(requests, & &1) == []
  end

  test "records duration and reports the exception with job context once retries are exhausted" do
    {port, requests} = TestHttpServer.start(202)

    Configuration.update(fn config ->
      %{config | dsn: "http://key@localhost:#{port}/api/v1/events", environment: "production"}
    end)

    metadata = %{
      job: job("MyApp.Workers.ChargeCard"),
      state: :discard,
      reason: %RuntimeError{message: "card declined"},
      stacktrace: []
    }

    ObanIntegration.handle_event([:oban, :job, :exception], measurements(4), metadata, nil)

    bucket =
      :sys.get_state(ForgeOpsTracker.PerformanceFlusher).buckets[
        {"MyApp.Workers.ChargeCard", "job"}
      ]

    assert bucket.count == 1

    [request] = wait_for_requests(requests, 1)
    body = JSON.decode!(request.body)
    assert body["message"] == "card declined"
    assert body["context"]["job"] == "MyApp.Workers.ChargeCard"
  end

  defp wait_for_requests(requests, count, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    list = Agent.get(requests, & &1)

    cond do
      length(list) >= count ->
        list

      System.monotonic_time(:millisecond) > deadline ->
        flunk("timed out waiting for #{count} request(s), got #{length(list)}")

      true ->
        Process.sleep(10)
        wait_for_requests(requests, count, deadline)
    end
  end
end
