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
