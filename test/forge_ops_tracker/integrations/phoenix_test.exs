defmodule ForgeOpsTracker.Integrations.PhoenixTest do
  # async: false: handle_event/4 ultimately records into the shared, process-wide
  # PerformanceFlusher singleton, same reasoning as PerformanceFlusherTest's own async: false.
  use ExUnit.Case, async: false

  alias ForgeOpsTracker.{BreadcrumbBuffer, Configuration}
  alias ForgeOpsTracker.Integrations.Phoenix, as: PhoenixIntegration

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

  # A plain map with .method/.status/.request_path fields, standing in for the real Plug.Conn
  # that would be in metadata.conn (see the integration module's own handle_event/4 for exactly
  # what it reads off it).
  defp fake_conn(method, status \\ 200, request_path \\ "/users/42"),
    do: %{method: method, status: status, request_path: request_path}

  test "records the matched route pattern and method as kind: controller" do
    # Shaped exactly like the real [:phoenix, :router_dispatch, :stop] event, verified directly
    # against the installed phoenix source (Phoenix.Router.__call__/5): measurements.duration is
    # native time units, metadata.route is the route pattern, metadata.conn.method the HTTP verb.
    measurements = %{duration: System.convert_time_unit(25, :millisecond, :native)}
    metadata = %{route: "/users/:id", conn: fake_conn("GET")}

    PhoenixIntegration.handle_event(
      [:phoenix, :router_dispatch, :stop],
      measurements,
      metadata,
      nil
    )

    bucket =
      :sys.get_state(ForgeOpsTracker.PerformanceFlusher).buckets[{"GET /users/:id", "controller"}]

    assert bucket.count == 1
    assert_in_delta bucket.max_duration_ms, 25.0, 1.0
  end

  test "records an automatic controller breadcrumb, level info on a non-5xx response" do
    measurements = %{duration: System.convert_time_unit(25, :millisecond, :native)}
    metadata = %{route: "/users/:id", conn: fake_conn("GET", 200)}

    PhoenixIntegration.handle_event(
      [:phoenix, :router_dispatch, :stop],
      measurements,
      metadata,
      nil
    )

    [crumb] = BreadcrumbBuffer.all()
    assert crumb["category"] == "controller"
    assert crumb["message"] == "GET /users/:id"
    assert crumb["level"] == "info"
    assert crumb["data"] == %{status: 200, path: "/users/42"}
  end

  test "records an automatic controller breadcrumb, level error on a 5xx response" do
    measurements = %{duration: System.convert_time_unit(25, :millisecond, :native)}
    metadata = %{route: "/users/:id", conn: fake_conn("GET", 500)}

    PhoenixIntegration.handle_event(
      [:phoenix, :router_dispatch, :stop],
      measurements,
      metadata,
      nil
    )

    [crumb] = BreadcrumbBuffer.all()
    assert crumb["level"] == "error"
  end

  test "attach/0 is safe to call more than once" do
    assert PhoenixIntegration.attach() == :ok
    assert PhoenixIntegration.attach() == :ok
  end
end
