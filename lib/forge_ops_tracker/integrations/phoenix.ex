defmodule ForgeOpsTracker.Integrations.Phoenix do
  @moduledoc """
  Times every matched Phoenix route, `kind: "controller"`. Call once at startup, e.g.
  `application.ex`'s own `start/2`, before the rest of the supervision tree starts:

      ForgeOpsTracker.Integrations.Phoenix.attach()

  Attaches to `[:phoenix, :router_dispatch, :stop]` (confirmed directly against the installed
  `phoenix` source, not assumed from docs: `Phoenix.Router.__call__/5` emits this around every
  matched route's own plug pipeline, controller action included), a global event name, not
  per-endpoint-namespaced, so this one call covers every Phoenix endpoint in the host app. An
  unmatched route (a 404) never fires this event at all, the same "only a real match gets timed"
  behavior every other language's own controller/action instrumentation in this repo already has.

  `transaction_name` is `"<HTTP method> <route pattern>"` (e.g. `"GET /users/:id"`), not the
  literal path: `metadata.route` is Phoenix's own matched route pattern, which keeps a distinct
  user id from exploding into its own separate transaction the way the literal path would.

  Also records the same automatic `"controller"` breadcrumb every other client's own request/
  controller-lifecycle instrumentation already does (message `"METHOD route"`, level `"error"` on
  a 5xx response and `"info"` otherwise, data holding the status and path), gated independently on
  `track_breadcrumbs` the same way `ForgeOpsTracker.record_performance/3` is already independently
  gated on `track_performance`: this one telemetry event is where several genuinely independent
  mechanisms happen to be recorded from, not one mechanism triggering another.

  Also opens a trace at `[:phoenix, :router_dispatch, :start]` and finishes it at `:stop` (or
  `:exception`), the root span named like the transaction above, so a slow request's own breakdown
  reaches `/spans` (see `ForgeOpsTracker.span/4`). `ForgeOpsTracker.Integrations.Ecto` adds a
  `"database"` span per query into it. Outbound HTTP is not instrumented (each HTTP client library
  has its own telemetry events): wrap a call in `ForgeOpsTracker.http_span/4`, which also hands it
  the `traceparent` header to send.

  The trace continues the caller's when the request arrived with a usable W3C `traceparent` header
  (see `ForgeOpsTracker.TraceParent`), and its trace id exists even with `track_tracing` off, since
  every error reported during the request carries it. `:start` fires once the router has matched
  the route, before the pipeline and controller run, so the request is named there
  (`transaction_name` and `endpoint`, both `"GET /users/:id"`): an error captured from inside the
  controller already carries both.

  A request that raises emits `:exception` before its process crashes, and the crash is only
  reported afterward, by `ForgeOpsTracker.LoggerHandler`, once this has already finished (and
  cleared) the request's trace. So `:exception` first remembers the request's context for that
  exception (`ForgeOpsTracker.Tracing.snapshot_escaped/1`), which the crash report then picks up,
  and marks the request errored, so its trace is sent however fast it was.
  """

  @doc "Registers the telemetry handler. Safe to call more than once: a later call is a no-op."
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(
           "forge-ops-tracker-phoenix",
           [
             [:phoenix, :router_dispatch, :start],
             [:phoenix, :router_dispatch, :stop],
             [:phoenix, :router_dispatch, :exception]
           ],
           &__MODULE__.handle_event/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_event([:phoenix, :router_dispatch, :start], _measurements, metadata, _config) do
    ForgeOpsTracker.start_trace(traceparent(metadata.conn))
    name = "#{metadata.conn.method} #{metadata.route}"
    ForgeOpsTracker.set_request_route(name, name)
  end

  def handle_event([:phoenix, :router_dispatch, :exception], measurements, metadata, _config) do
    ForgeOpsTracker.Tracing.snapshot_escaped(Map.get(metadata, :reason))
    finish_trace(measurements, metadata)
  end

  def handle_event([:phoenix, :router_dispatch, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    transaction_name = "#{metadata.conn.method} #{metadata.route}"
    finish_trace(measurements, metadata)

    ForgeOpsTracker.record_performance(transaction_name, "controller", duration_ms)

    status = metadata.conn.status
    level = if is_integer(status) and status >= 500, do: "error", else: "info"

    ForgeOpsTracker.add_breadcrumb(transaction_name, "controller", level, %{
      status: status,
      path: metadata.conn.request_path
    })
  end

  # A plain keyword lookup rather than Plug.Conn.get_req_header/2: Plug is an optional dependency
  # of this SDK, and req_headers is a plain list of lowercase {name, value} pairs.
  defp traceparent(conn) do
    case List.keyfind(Map.get(conn, :req_headers, []), ForgeOpsTracker.TraceParent.header(), 0) do
      {_name, value} -> value
      nil -> nil
    end
  end

  defp finish_trace(measurements, metadata) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :microsecond) / 1000

    ForgeOpsTracker.finish_trace(
      "#{metadata.conn.method} #{metadata.route}",
      "controller",
      DateTime.add(DateTime.utc_now(), -round(duration_ms * 1000), :microsecond),
      duration_ms
    )
  end
end
