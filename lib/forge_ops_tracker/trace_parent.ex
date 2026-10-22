defmodule ForgeOpsTracker.TraceParent do
  @moduledoc """
  Reads and writes the W3C Trace Context `traceparent` header
  (https://www.w3.org/TR/trace-context/), the vendor-neutral format for carrying one trace across
  service boundaries: `00-<32 hex trace-id>-<16 hex parent-id>-<2 hex flags>`. Used in both
  directions: `ForgeOpsTracker.Integrations.Phoenix` parses an incoming one so the request
  continues the caller's trace instead of starting its own, and `ForgeOpsTracker.http_span/4`
  builds an outgoing one so the next service along continues this request's. Ported from
  `gems/forge_ops_tracker`'s `trace_parent.rb`.

  Deliberately strict on the way in, the same posture the spec asks receivers to take: a malformed
  value, uppercase hex, the reserved version `"ff"`, or an all-zero trace/parent id are all treated
  as "no usable header at all" (`parse/1` returns `nil` and the request starts a fresh trace). A
  version this client doesn't know yet is still accepted as long as its first four fields have
  version 00's shape, which is what the spec says a version-00 parser should do with a future
  version; version 00 itself must have exactly four fields.
  """

  @header "traceparent"

  # Always "01" (sampled) on the way out: whether a trace is actually sent is only decided once the
  # request is over, long after this header has gone out on an outbound call, so there's no honest
  # earlier answer than "this may be recorded."
  @sampled_flags "01"

  @pattern ~r/\A([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})(-.*)?\z/s
  @invalid_trace_id String.duplicate("0", 32)
  @invalid_parent_id String.duplicate("0", 16)

  @doc "The header's name, lowercase as HTTP/2 and Plug both want it."
  @spec header() :: String.t()
  def header, do: @header

  @doc """
  `%{trace_id: ..., parent_span_id: ...}` for a usable header value, `nil` for anything else
  (absent, blank, malformed, or one of the explicitly invalid values above).
  """
  @spec parse(term()) :: %{trace_id: String.t(), parent_span_id: String.t()} | nil
  def parse(value) when is_binary(value) do
    case Regex.run(@pattern, String.trim(value), capture: :all_but_first) do
      ["ff" | _] -> nil
      ["00", _trace_id, _parent_id, _flags, _rest] -> nil
      [_version, @invalid_trace_id | _] -> nil
      [_version, _trace_id, @invalid_parent_id | _] -> nil
      [_version, trace_id, parent_id | _] -> %{trace_id: trace_id, parent_span_id: parent_id}
      nil -> nil
    end
  end

  def parse(_value), do: nil

  @doc "Builds an outgoing header value naming `span_id` as the parent."
  @spec build(String.t(), String.t()) :: String.t()
  def build(trace_id, span_id), do: "00-#{trace_id}-#{span_id}-#{@sampled_flags}"

  @doc "32 lowercase hex characters, the W3C trace-id format; never all zeros."
  @spec generate_trace_id() :: String.t()
  def generate_trace_id, do: random_hex(16)

  @doc "16 lowercase hex characters, the W3C parent-id (span id) format; never all zeros."
  @spec generate_span_id() :: String.t()
  def generate_span_id, do: random_hex(8)

  defp random_hex(bytes) do
    hex = bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    if String.trim(hex, "0") == "", do: random_hex(bytes), else: hex
  end
end
