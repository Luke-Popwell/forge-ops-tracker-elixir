defmodule ForgeOpsTracker.ClientTest do
  use ExUnit.Case, async: true

  alias ForgeOpsTracker.{Client, Configuration, TestHttpServer}

  defp new_configuration(dsn) do
    %Configuration{dsn: dsn, timeout: 2_000}
  end

  test "delivers successfully on a 2xx response and sends the authorization header" do
    {port, requests} = TestHttpServer.start(202)
    config = new_configuration("http://the-api-key@localhost:#{port}/api/v1/events")

    assert Client.deliver(config, %{"message" => "boom"})

    [request] = wait_for_requests(requests, 1)
    assert request.headers["authorization"] == "Bearer the-api-key"
    assert request.body == "{\"message\":\"boom\"}"
  end

  test "returns false on a non-2xx response" do
    {port, _requests} = TestHttpServer.start(500)
    config = new_configuration("http://key@localhost:#{port}/events")

    refute Client.deliver(config, %{"message" => "boom"})
  end

  test "returns false when there is no dsn" do
    config = new_configuration(nil)
    refute Client.deliver(config, %{"message" => "boom"})
  end

  test "returns false rather than raising when nothing is listening" do
    {:ok, probe} = :gen_tcp.listen(0, [:binary])
    {:ok, closed_port} = :inet.port(probe)
    :gen_tcp.close(probe)

    config = %Configuration{dsn: "http://key@localhost:#{closed_port}/events", timeout: 500}

    refute Client.deliver(config, %{"message" => "boom"})
  end

  test "the attempt functions tell a rejection from a failure worth retrying" do
    expected = %{
      202 => :delivered,
      400 => :rejected,
      401 => :rejected,
      403 => :rejected,
      413 => :rejected,
      422 => :rejected,
      408 => :failed,
      429 => :failed,
      500 => :failed,
      503 => :failed
    }

    for {code, status} <- expected do
      {port, _requests} = TestHttpServer.start(code)
      config = new_configuration("http://key@localhost:#{port}/api/v1/events")

      assert {code, Client.attempt_metrics(config, [%{metric_name: "signup", value: 1}])} ==
               {code, status}

      assert {code, Client.deliver_metrics(config, [%{metric_name: "signup", value: 1}])} ==
               {code, status == :delivered}
    end
  end

  test "an attempt is failed for now when nothing is listening or there is no dsn" do
    {:ok, probe} = :gen_tcp.listen(0, [:binary])
    {:ok, closed_port} = :inet.port(probe)
    :gen_tcp.close(probe)

    config = %Configuration{
      dsn: "http://key@localhost:#{closed_port}/api/v1/events",
      timeout: 500
    }

    assert Client.attempt_performance_samples(config, []) == :failed
    assert Client.attempt_infrastructure_metrics(new_configuration(nil), []) == :failed
  end

  test "says why a delivery was not accepted" do
    test_pid = self()
    {port, _requests} = TestHttpServer.start(422)

    config = %{
      new_configuration("http://key@localhost:#{port}/api/v1/events")
      | logger: fn message -> send(test_pid, {:logged, message}) end
    }

    refute Client.deliver(config, %{"message" => "boom"})

    assert_received {:logged,
                     "[forge_ops_tracker] delivery rejected: HTTP 422, the server will not accept a retry"}
  end

  test "deliver_performance_samples posts to the /performance_samples sibling path" do
    {port, requests} = TestHttpServer.start(202)
    config = new_configuration("http://the-api-key@localhost:#{port}/api/v1/events")

    assert Client.deliver_performance_samples(config, [%{"transaction_name" => "GET /users"}])

    [request] = wait_for_requests(requests, 1)
    assert request.request_line == "POST /api/v1/performance_samples HTTP/1.1"
    assert request.headers["authorization"] == "Bearer the-api-key"
    assert request.body == "{\"samples\":[{\"transaction_name\":\"GET /users\"}]}"
  end

  test "deliver_performance_samples returns false on a non-2xx response" do
    {port, _requests} = TestHttpServer.start(500)
    config = new_configuration("http://key@localhost:#{port}/api/v1/events")

    refute Client.deliver_performance_samples(config, [%{"transaction_name" => "GET /users"}])
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
