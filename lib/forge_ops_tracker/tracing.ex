defmodule ForgeOpsTracker.Tracing do
  @moduledoc """
  One trace's worth of spans (a request's own call tree), kept in the calling process's own
  process dictionary: the same isolation boundary `ForgeOpsTracker.set_user/1` and
  `ForgeOpsTracker.add_breadcrumb/4` already use, and for the same reason (Phoenix and Oban both
  run one unit of work in one process). Not something app code normally calls directly; see
  `ForgeOpsTracker.span/4` and `ForgeOpsTracker.record_span/5`.

  Nesting comes from a stack of open span ids: a span opened while another is open becomes its
  child, and anything else parents under the root. A trace is sent only when its root span took at
  least `Configuration.trace_capture_threshold` milliseconds, or the request errored, decided here
  once the root finishes, so a fast, successful request costs nothing on the wire.

  Alongside the spans, the process dictionary holds the request's own context (trace id, the
  remote parent span id from an incoming `traceparent`, transaction name, endpoint, and whether it
  errored), kept whether or not `track_tracing` is on: the trace id is also what an error event
  carries so ForgeOps can link it to errors other services reported for the same trace.
  """

  alias ForgeOpsTracker.{Configuration, DeliveryQueue, StrictPrivacy, TraceParent}

  @typedoc "Outgoing request headers, as `{name, value}` pairs."
  @type headers :: [{String.t(), String.t()}]

  @key :forge_ops_tracker_trace
  @request_key :forge_ops_tracker_request
  @escaped_key :forge_ops_tracker_escaped
  @max_spans 500

  # The kinds the ingestion API accepts; anything else would fail validation for the whole trace,
  # so an unknown kind is sent as "other" instead.
  @kinds ~w(controller service database redis http job other)

  @doc """
  Starts a fresh trace on the calling process, discarding any earlier one. `traceparent` is the
  incoming request's own header value: a usable W3C value continues the caller's trace (same trace
  id, and the root span's parent is the caller's span), anything else (`nil`, blank, malformed)
  starts a new one. The request context is set whenever the client is enabled; spans are only
  recorded when `track_tracing` is on too. A no-op when the client isn't enabled.
  """
  @spec start_trace(String.t() | nil) :: :ok
  def start_trace(traceparent \\ nil) do
    config = Configuration.get()
    Process.delete(@key)
    Process.delete(@request_key)
    Process.delete(@escaped_key)

    if Configuration.enabled?(config) do
      incoming = TraceParent.parse(traceparent)
      trace_id = if incoming, do: incoming.trace_id, else: TraceParent.generate_trace_id()
      parent_span_id = if incoming, do: incoming.parent_span_id

      Process.put(@request_key, %{
        trace_id: trace_id,
        parent_span_id: parent_span_id,
        transaction_name: nil,
        endpoint: nil,
        errored: false
      })

      if config.track_tracing do
        Process.put(@key, %{
          trace_id: trace_id,
          remote_parent_span_id: parent_span_id,
          root_span_id: TraceParent.generate_span_id(),
          spans: [],
          count: 0,
          open: []
        })
      end
    end

    :ok
  end

  @doc "True when the calling process has an open trace."
  @spec active?() :: boolean()
  def active?, do: Process.get(@key) != nil

  @doc "The calling process's current trace id, or `nil` outside a trace."
  @spec current_trace_id() :: String.t() | nil
  def current_trace_id do
    case Process.get(@request_key) do
      %{trace_id: trace_id} -> trace_id
      nil -> nil
    end
  end

  @doc """
  Names the current request (a no-op outside one): `transaction_name` is the same name its
  performance sample and root span use, `endpoint` the HTTP method plus the route pattern.
  """
  @spec set_request_route(String.t() | nil, String.t() | nil) :: :ok
  def set_request_route(transaction_name, endpoint) do
    update_request(&%{&1 | transaction_name: transaction_name, endpoint: endpoint})
  end

  @doc "Marks the current request errored, so its trace is sent however fast it was."
  @spec mark_errored() :: :ok
  def mark_errored, do: update_request(&%{&1 | errored: true})

  @doc """
  The top-level fields an error event carries for the request it happened in:
  `"trace_id"`, `"transaction_name"`, `"endpoint"`, each left out when unknown. Falls back to
  what `snapshot_escaped/1` remembered for `reason` once the request itself is over, and to `%{}`
  outside a request.
  """
  @spec error_fields(term()) :: map()
  def error_fields(reason) do
    request =
      case {Process.get(@request_key), Process.get(@escaped_key)} do
        {%{} = request, _escaped} ->
          request

        {nil, %{reason: escaped_reason} = escaped} ->
          if same_error?(escaped_reason, reason), do: escaped

        {nil, nil} ->
          nil
      end

    case request do
      nil ->
        %{}

      request ->
        for {key, value} <- Map.take(request, [:trace_id, :transaction_name, :endpoint]),
            value != nil,
            into: %{},
            do: {Atom.to_string(key), value}
    end
  end

  @doc """
  Remembers the current request's context for `reason`, an error escaping the request, and marks
  it errored, so an error reported only after `finish_trace/4` has cleared the request (as a
  Phoenix request's crash is, by the `:logger` handler, once the router has already emitted
  `:exception`) still carries it. The calling process's user and breadcrumbs are untouched by
  `finish_trace/4`, so only the request context needs remembering. Cleared by the next
  `start_trace/1` on the same process.
  """
  @spec snapshot_escaped(term()) :: :ok
  def snapshot_escaped(reason) do
    case Process.get(@request_key) do
      nil ->
        :ok

      request ->
        request = %{request | errored: true}
        Process.put(@request_key, request)
        Process.put(@escaped_key, Map.put(request, :reason, reason))
        :ok
    end
  end

  # A crash report's reason is the exception Phoenix re-raised, sometimes still inside
  # Plug.Conn.WrapperError (which carries the original as :reason).
  defp same_error?(reason, reason), do: true

  defp same_error?(escaped, %{__struct__: Plug.Conn.WrapperError, reason: reason}),
    do: escaped == reason

  defp same_error?(%{__struct__: Plug.Conn.WrapperError, reason: escaped}, reason),
    do: escaped == reason

  defp same_error?(_escaped, _reason), do: false

  defp update_request(fun) do
    case Process.get(@request_key) do
      nil -> :ok
      request -> Process.put(@request_key, fun.(request))
    end

    :ok
  end

  @doc """
  Ends the calling process's trace, always clearing it along with the request context, and queues
  it for delivery when the root took at least `trace_capture_threshold` milliseconds or the request
  errored. `started_at` is a `DateTime`. Under `strict_privacy` every span goes out as
  `ForgeOpsTracker.StrictPrivacy.span/1` leaves it.
  """
  @spec finish_trace(String.t(), String.t(), DateTime.t(), number()) :: :ok
  def finish_trace(name, kind, %DateTime{} = started_at, duration_ms) do
    trace = Process.delete(@key)
    request = Process.delete(@request_key)
    errored = match?(%{errored: true}, request)
    config = Configuration.get()

    if trace && (errored or duration_ms >= config.trace_capture_threshold) do
      root =
        build(
          config,
          trace.root_span_id,
          trace.remote_parent_span_id,
          name,
          kind,
          started_at,
          duration_ms,
          %{}
        )

      spans = [root | Enum.reverse(trace.spans)]

      spans =
        if config.strict_privacy, do: Enum.map(spans, &StrictPrivacy.span/1), else: spans

      DeliveryQueue.push_trace(%{trace_id: trace.trace_id, spans: spans})
    end

    :ok
  end

  @doc """
  Times `fun` as a child span of whatever span is open (or of the root), returning its result.
  Outside a trace it just runs `fun`. Recorded even if `fun` raises, throws or exits, which then
  propagates unchanged.
  """
  @spec span(String.t(), String.t(), map(), (-> result)) :: result when result: var
  def span(name, kind, data, fun) when is_function(fun, 0),
    do: span(TraceParent.generate_span_id(), name, kind, data, fun)

  @doc """
  Makes one outgoing HTTP call inside the calling process's trace: records it as an `"http"` span
  named `"<METHOD> <host>"` (never the path or query, which could carry an id or a token) and calls
  `fun` with a list of `{name, value}` headers to add to the request, currently a W3C
  `traceparent` whose parent id is that span's own id. The headers are `[]` outside a trace, when
  `propagate_traces` is off, or when the host isn't in `trace_propagation_targets`; outside a trace
  no span is recorded either, and with `track_tracing` off the header is still handed over but no
  span is kept.
  """
  @spec http_span(String.t() | atom(), String.t() | URI.t(), map(), (headers() -> result)) ::
          result
        when result: var
  def http_span(method, url, data, fun) when is_function(fun, 1) do
    case Process.get(@request_key) do
      nil ->
        fun.([])

      request ->
        host = url |> URI.parse() |> Map.get(:host) |> then(&(&1 && String.downcase(&1)))
        span_id = TraceParent.generate_span_id()

        headers =
          if Configuration.propagate_trace?(Configuration.get(), host),
            do: [{TraceParent.header(), TraceParent.build(request.trace_id, span_id)}],
            else: []

        name = "#{method |> to_string() |> String.upcase()} #{host || "unknown"}"
        span(span_id, name, "http", data, fn -> fun.(headers) end)
    end
  end

  defp span(id, name, kind, data, fun) do
    case Process.get(@key) do
      nil ->
        fun.()

      trace ->
        parent = current_parent(trace)
        Process.put(@key, %{trace | open: [id | trace.open]})
        started_at = DateTime.utc_now()
        started = System.monotonic_time()

        try do
          fun.()
        after
          duration_ms =
            System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond) /
              1000

          close(id, parent, name, kind, started_at, duration_ms, data)
        end
    end
  end

  @doc "Records a span you timed yourself under the current one; a no-op outside a trace."
  @spec record_span(String.t(), String.t(), DateTime.t(), number(), map()) :: :ok
  def record_span(name, kind, %DateTime{} = started_at, duration_ms, data \\ %{}) do
    case Process.get(@key) do
      nil ->
        :ok

      trace ->
        add(
          trace,
          TraceParent.generate_span_id(),
          current_parent(trace),
          name,
          kind,
          started_at,
          duration_ms,
          data
        )
    end
  end

  defp close(id, parent, name, kind, started_at, duration_ms, data) do
    case Process.get(@key) do
      nil ->
        :ok

      trace ->
        add(
          %{trace | open: List.delete(trace.open, id)},
          id,
          parent,
          name,
          kind,
          started_at,
          duration_ms,
          data
        )
    end
  end

  defp add(trace, id, parent, name, kind, started_at, duration_ms, data) do
    trace =
      if trace.count >= @max_spans - 1 do
        trace
      else
        span = build(Configuration.get(), id, parent, name, kind, started_at, duration_ms, data)
        %{trace | spans: [span | trace.spans], count: trace.count + 1}
      end

    Process.put(@key, trace)
    :ok
  end

  defp current_parent(%{open: [top | _]}), do: top
  defp current_parent(%{root_span_id: root}), do: root

  defp build(config, id, parent, name, kind, started_at, duration_ms, data) do
    %{
      span_id: id,
      parent_span_id: parent,
      name: name,
      kind: if(kind in @kinds, do: kind, else: "other"),
      started_at: started_at |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
      duration_ms: Float.round(duration_ms * 1.0, 2),
      environment: config.environment,
      release: config.release,
      data: data
    }
  end
end
