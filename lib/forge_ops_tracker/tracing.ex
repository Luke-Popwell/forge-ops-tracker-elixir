defmodule ForgeOpsTracker.Tracing do
  @moduledoc """
  One trace's worth of spans (a request's own call tree), kept in the calling process's own
  process dictionary: the same isolation boundary `ForgeOpsTracker.set_user/1` and
  `ForgeOpsTracker.add_breadcrumb/4` already use, and for the same reason (Phoenix and Oban both
  run one unit of work in one process). Not something app code normally calls directly; see
  `ForgeOpsTracker.span/4` and `ForgeOpsTracker.record_span/5`.

  Nesting comes from a stack of open span ids: a span opened while another is open becomes its
  child, and anything else parents under the root. A trace is sent only when its root span took at
  least `Configuration.trace_capture_threshold` milliseconds, decided here once the root finishes,
  so a fast request costs nothing on the wire.
  """

  alias ForgeOpsTracker.{Configuration, DeliveryQueue}

  @key :forge_ops_tracker_trace
  @max_spans 500

  # The kinds the ingestion API accepts; anything else would fail validation for the whole trace,
  # so an unknown kind is sent as "other" instead.
  @kinds ~w(controller service database redis http job other)

  @doc """
  Starts a fresh trace on the calling process, discarding any earlier one. A no-op (no trace
  started) when `track_tracing` is off or the client isn't enabled for this environment.
  """
  @spec start_trace() :: :ok
  def start_trace do
    config = Configuration.get()

    if config.track_tracing and Configuration.enabled?(config) do
      Process.put(@key, %{
        trace_id: random_hex(16),
        root_span_id: random_hex(8),
        spans: [],
        count: 0,
        open: []
      })
    else
      Process.delete(@key)
    end

    :ok
  end

  @doc "True when the calling process has an open trace."
  @spec active?() :: boolean()
  def active?, do: Process.get(@key) != nil

  @doc """
  Ends the calling process's trace, always clearing it, and queues it for delivery when the root
  took at least `trace_capture_threshold` milliseconds. `started_at` is a `DateTime`.
  """
  @spec finish_trace(String.t(), String.t(), DateTime.t(), number()) :: :ok
  def finish_trace(name, kind, %DateTime{} = started_at, duration_ms) do
    trace = Process.delete(@key)
    config = Configuration.get()

    if trace && duration_ms >= config.trace_capture_threshold do
      root = build(config, trace.root_span_id, nil, name, kind, started_at, duration_ms, %{})

      DeliveryQueue.push_trace(%{
        trace_id: trace.trace_id,
        spans: [root | Enum.reverse(trace.spans)]
      })
    end

    :ok
  end

  @doc """
  Times `fun` as a child span of whatever span is open (or of the root), returning its result.
  Outside a trace it just runs `fun`. Recorded even if `fun` raises, throws or exits, which then
  propagates unchanged.
  """
  @spec span(String.t(), String.t(), map(), (-> result)) :: result when result: var
  def span(name, kind, data, fun) when is_function(fun, 0) do
    case Process.get(@key) do
      nil ->
        fun.()

      trace ->
        id = random_hex(8)
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
          random_hex(8),
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

  defp random_hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
