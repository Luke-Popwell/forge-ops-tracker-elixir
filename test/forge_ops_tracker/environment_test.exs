defmodule ForgeOpsTracker.EnvironmentTest do
  # async: false: shares the Configuration singleton and the once-per-VM warning flag.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForgeOpsTracker.TestHttpServer

  @not_sending ~s([ForgeOps] Not sending: this environment is "development")

  setup do
    ForgeOpsTracker.reset_for_testing()
    on_exit(fn -> ForgeOpsTracker.reset_for_testing() end)
    :ok
  end

  describe "init/1's warning" do
    test "is logged once when a DSN is set but the environment isn't enabled" do
      opts = [
        dsn: "https://key@tracker.example.com/api/v1/events",
        environment: "development",
        detect_changes: false
      ]

      log =
        capture_log(fn ->
          ForgeOpsTracker.init(opts)
          ForgeOpsTracker.init(opts)
        end)

      assert occurrences(log, @not_sending) == 1, log
      assert log =~ "[warning]"
    end

    test "is never logged without a DSN, or in an enabled environment" do
      log =
        capture_log(fn ->
          ForgeOpsTracker.init(dsn: nil, environment: "development", detect_changes: false)

          ForgeOpsTracker.init(
            dsn: "https://key@tracker.example.com/api/v1/events",
            environment: "production",
            detect_changes: false
          )
        end)

      refute log =~ "Not sending"
    end
  end

  describe "in a separate VM configured only through environment variables" do
    # A real `elixir` process using this compiled client, the way a new app following the setup
    # page runs it: init/1 with no environment, and whatever environment variables are given here.
    # FORGE_OPS_ENVIRONMENT and MIX_ENV are always unset unless given.
    defp run_script(script, env) do
      paths =
        Mix.Project.build_path()
        |> Path.join("lib/*/ebin")
        |> Path.wildcard()
        |> Enum.flat_map(&["-pa", &1])

      env = Map.merge(%{"FORGE_OPS_ENVIRONMENT" => nil, "MIX_ENV" => nil}, env)

      System.cmd("elixir", paths ++ ["-e", script],
        stderr_to_stdout: true,
        env: Enum.to_list(env)
      )
    end

    @script """
    {:ok, _} = Application.ensure_all_started(:forge_ops_tracker)
    ForgeOpsTracker.init(detect_changes: false)
    ForgeOpsTracker.init(detect_changes: false)
    ForgeOpsTracker.Reporter.report(%RuntimeError{message: "the setup page's test error"}, [])
    """

    test "with Mix running in dev and only FORGE_OPS_DSN set, nothing is sent and it warns once" do
      {port, requests} = TestHttpServer.start(202)

      # What `iex -S mix` or `mix phx.server` with no MIX_ENV looks like to the client: the :mix
      # application is running, Mix.env/0 is its default :dev, and MIX_ENV is unset.
      script = "{:ok, _} = Application.ensure_all_started(:mix)\n" <> @script

      {output, status} =
        run_script(script, %{"FORGE_OPS_DSN" => "http://key@localhost:#{port}/api/v1/events"})

      assert status == 0, output
      assert Agent.get(requests, & &1) == [], output
      assert occurrences(output, @not_sending) == 1, output
    end

    test "with Mix running in dev and no init call at all, a dropped error still says why, once" do
      {port, requests} = TestHttpServer.start(202)

      script = """
      {:ok, _} = Application.ensure_all_started(:mix)
      {:ok, _} = Application.ensure_all_started(:forge_ops_tracker)
      ForgeOpsTracker.capture_exception(RuntimeError.exception("ForgeOps test error"), [])
      ForgeOpsTracker.capture_exception(RuntimeError.exception("ForgeOps test error"), [])
      ForgeOpsTracker.flush()
      """

      {output, status} =
        run_script(script, %{"FORGE_OPS_DSN" => "http://key@localhost:#{port}/api/v1/events"})

      assert status == 0, output
      assert Agent.get(requests, & &1) == [], output
      assert occurrences(output, @not_sending) == 1, output
    end

    test "without Mix running (a release, an escript), only FORGE_OPS_DSN set sends as production" do
      {port, requests} = TestHttpServer.start(202)

      {output, status} =
        run_script(@script, %{"FORGE_OPS_DSN" => "http://key@localhost:#{port}/api/v1/events"})

      assert status == 0, output
      assert [%{body: body}] = events(requests), output
      assert body =~ "the setup page's test error"
      assert body =~ ~s("environment":"production")
      refute output =~ "Not sending"
    end

    test "MIX_ENV=prod with nothing else set delivers as production" do
      {port, requests} = TestHttpServer.start(202)

      {output, status} =
        run_script(@script, %{
          "FORGE_OPS_DSN" => "http://key@localhost:#{port}/api/v1/events",
          "MIX_ENV" => "prod"
        })

      assert status == 0, output
      assert [%{body: body}] = events(requests), output
      assert body =~ ~s("environment":"production")
    end

    test "an explicit development environment sends nothing and warns exactly once" do
      {port, requests} = TestHttpServer.start(202)

      {output, status} =
        run_script(@script, %{
          "FORGE_OPS_DSN" => "http://key@localhost:#{port}/api/v1/events",
          "FORGE_OPS_ENVIRONMENT" => "development"
        })

      assert status == 0, output
      assert Agent.get(requests, & &1) == [], output
      assert occurrences(output, @not_sending) == 1, output

      assert output =~
               "only production, staging are enabled. Set FORGE_OPS_ENVIRONMENT=production"
    end
  end

  # Error reports only: a VM configured through FORGE_OPS_DSN also sends its startup change
  # snapshot when the application starts.
  defp events(requests) do
    Enum.filter(Agent.get(requests, & &1), &(&1.request_line =~ "/api/v1/events "))
  end

  defp occurrences(text, pattern), do: length(String.split(text, pattern)) - 1
end
