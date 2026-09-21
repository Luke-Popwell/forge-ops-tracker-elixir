defmodule ForgeOpsTracker.LoggerHandlerTest do
  # async: false: LoggerHandler.log/2 routes into Reporter.report/3, which reads the shared
  # Configuration singleton.
  use ExUnit.Case, async: false

  alias ForgeOpsTracker.{Configuration, LoggerHandler, TestHttpServer}

  setup do
    on_exit(fn -> Configuration.update(fn _ -> %Configuration{} end) end)
    :ok
  end

  defp point_configuration_at(port) do
    Configuration.update(fn config ->
      %{config | dsn: "http://key@localhost:#{port}/events", environment: "production"}
    end)
  end

  test "a crash_reason event is reported through to real delivery" do
    {port, requests} = TestHttpServer.start(202)
    point_configuration_at(port)

    reason = %RuntimeError{message: "boom"}
    stacktrace = [{__MODULE__, :some_function, 0, [file: ~c"test.ex", line: 1]}]
    log_event = %{level: :error, meta: %{crash_reason: {reason, stacktrace}}, msg: {:report, %{}}}

    assert LoggerHandler.log(log_event, %{}) == :ok

    wait_until(fn -> Agent.get(requests, & &1) != [] end)
    assert length(Agent.get(requests, & &1)) == 1
  end

  test "attaches whatever set_user/1 last set on this process to the crash report" do
    {port, requests} = TestHttpServer.start(202)
    point_configuration_at(port)
    ForgeOpsTracker.set_user(%{id: 42, email: "ada@example.com"})

    reason = %RuntimeError{message: "boom"}
    stacktrace = [{__MODULE__, :some_function, 0, [file: ~c"test.ex", line: 1]}]
    log_event = %{level: :error, meta: %{crash_reason: {reason, stacktrace}}, msg: {:report, %{}}}

    assert LoggerHandler.log(log_event, %{}) == :ok

    wait_until(fn -> Agent.get(requests, & &1) != [] end)
    [request] = Agent.get(requests, & &1)
    assert request.body =~ "ada@example.com"
  end

  test "an ordinary error-level log with no crash_reason is never delivered" do
    {port, requests} = TestHttpServer.start(202)
    point_configuration_at(port)

    log_event = %{level: :error, meta: %{}, msg: {:string, "just a log message"}}

    assert LoggerHandler.log(log_event, %{}) == :ok
    Process.sleep(150)

    assert Agent.get(requests, & &1) == []
  end

  test "a non-error-level event is never delivered even with a crash_reason-shaped meta" do
    {port, requests} = TestHttpServer.start(202)
    point_configuration_at(port)

    log_event = %{
      level: :warning,
      meta: %{crash_reason: {%RuntimeError{message: "boom"}, []}},
      msg: {:report, %{}}
    }

    assert LoggerHandler.log(log_event, %{}) == :ok
    Process.sleep(150)

    assert Agent.get(requests, & &1) == []
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
