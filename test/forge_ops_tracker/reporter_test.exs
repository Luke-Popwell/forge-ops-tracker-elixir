defmodule ForgeOpsTracker.ReporterTest do
  # async: false: Reporter reads the shared Configuration/DeliveryQueue singletons internally.
  use ExUnit.Case, async: false

  alias ForgeOpsTracker.{Configuration, Reporter, TestHttpServer}

  setup do
    on_exit(fn -> Configuration.update(fn _ -> %Configuration{} end) end)
    :ok
  end

  defp raise_and_rescue do
    raise "boom"
  rescue
    e -> {e, __STACKTRACE__}
  end

  defp point_configuration_at(port, overrides) do
    Configuration.update(fn config ->
      struct(%{config | dsn: "http://key@localhost:#{port}/events"}, overrides)
    end)
  end

  test "report does nothing when disabled" do
    {port, requests} = TestHttpServer.start(202)
    point_configuration_at(port, %{environment: "development"})
    {error, stacktrace} = raise_and_rescue()

    Reporter.report(error, stacktrace)
    Process.sleep(100)

    assert Agent.get(requests, & &1) == []
  end

  test "report delivers when enabled" do
    {port, requests} = TestHttpServer.start(202)
    point_configuration_at(port, %{environment: "production"})
    {error, stacktrace} = raise_and_rescue()

    Reporter.report(error, stacktrace)

    wait_until(fn -> Agent.get(requests, & &1) != [] end)
    assert length(Agent.get(requests, & &1)) == 1
  end

  test "report includes the given user in the delivered payload" do
    {port, requests} = TestHttpServer.start(202)
    point_configuration_at(port, %{environment: "production"})
    {error, stacktrace} = raise_and_rescue()

    Reporter.report(error, stacktrace, %{}, %{"id" => 42, "email" => "alice@example.com"})

    wait_until(fn -> Agent.get(requests, & &1) != [] end)
    [request] = Agent.get(requests, & &1)
    body = JSON.decode!(request.body)
    assert body["user"] == %{"id" => 42, "email" => "alice@example.com"}
  end

  test "report includes the given breadcrumbs in the delivered payload" do
    {port, requests} = TestHttpServer.start(202)
    point_configuration_at(port, %{environment: "production"})
    {error, stacktrace} = raise_and_rescue()

    crumb = %{
      "category" => "controller",
      "message" => "GET /orders/42",
      "level" => "info",
      "timestamp" => "2024-01-15T10:29:58Z",
      "data" => %{}
    }

    Reporter.report(error, stacktrace, %{}, nil, [crumb])

    wait_until(fn -> Agent.get(requests, & &1) != [] end)
    [request] = Agent.get(requests, & &1)
    body = JSON.decode!(request.body)
    assert body["breadcrumbs"] == [crumb]
  end

  test "report never raises even when delivery fails" do
    point_configuration_at(1, %{environment: "production", timeout: 300})
    {error, stacktrace} = raise_and_rescue()

    # Must not raise: an error reporter that can crash the caller while reporting is the worst
    # possible failure mode.
    assert Reporter.report(error, stacktrace) == :ok
  end

  defp wait_until(predicate, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    cond do
      predicate.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        wait_until(predicate, deadline)
    end
  end
end
