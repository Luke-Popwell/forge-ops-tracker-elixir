defmodule ForgeOpsTracker.EventBuilder do
  @moduledoc """
  Turns an exception/reason plus an Elixir stacktrace into the payload shape the ingestion API
  expects. Unlike the Ruby/PHP/JS clients in this repo, backtrace parsing here is not a regex
  over a string: `__STACKTRACE__` is already a structured list of `{module, function, arity,
  location}` tuples (`location` a keyword list with `:file`/`:line`), the same situation Python's
  `traceback` module and Java's `Throwable.getStackTrace()` put those clients in. Verified
  directly against a real raised-and-rescued exception's `__STACKTRACE__` before relying on this
  shape, not assumed from documentation alone.
  """

  alias ForgeOpsTracker.{Configuration, PiiScrubber, SqlStatement, StrictPrivacy}

  @max_frames 500

  # How many lines of source to grab on either side of the culprit line (see
  # attach_source_context/2), and the longest a single captured line is allowed to be before
  # getting truncated: guards against a single pathological minified/generated line ballooning
  # the payload. ForgeOps itself re-truncates on arrival too, the same "don't just trust the SDK"
  # posture @max_frames already gets on the server side.
  @context_lines 5
  @max_context_line_length 500

  # Identifies this client to the server's auto language-detection on the project the event lands
  # in (see Project#note_sdk_platform server-side); matches this repo's own sdks/elixir directory
  # name, the same convention every other language's client follows.
  @sdk_name "elixir"

  @doc """
  `reason` is whatever was raised/thrown: typically an `Exception` struct, but Elixir permits
  raising any term, so this doesn't require one. `stacktrace` is `__STACKTRACE__` as captured at
  the rescue/catch site. `context` is an arbitrary map of additional data to attach.

  `request_fields` describes the request the error happened in (see
  `ForgeOpsTracker.Tracing.error_fields/1`): `"transaction_name"` (the same `"GET /users/:id"` name
  the request's root span and performance sample use), `"endpoint"` (the HTTP method plus the route
  pattern), and `"trace_id"` (the request's 32-character lowercase hex W3C trace id, which is also
  what links this error to errors other services reported for the same trace). Each key is only
  present when known, and the map is empty outside a request.
  """
  @spec build(
          Configuration.t(),
          term(),
          Exception.stacktrace(),
          map(),
          map() | nil,
          [map()],
          map()
        ) :: map()
  def build(
        %Configuration{} = config,
        reason,
        stacktrace,
        context \\ %{},
        user \\ nil,
        breadcrumbs \\ [],
        request_fields \\ %{}
      ) do
    payload = %{
      "exception_class" => exception_class(reason),
      "message" => exception_message(reason),
      "backtrace" => backtrace(config, stacktrace),
      "occurred_at" => iso8601_now(),
      "environment" => config.environment,
      "release" => config.release,
      "server_name" => config.server_name,
      "context" => context,
      "tags" => %{},
      "sdk_name" => @sdk_name
    }

    payload = if user && map_size(user) > 0, do: Map.put(payload, "user", user), else: payload

    # Omitted entirely rather than an empty list, the same "no key at all" shape the user field
    # above already gets when absent: matches gems/forge_ops_tracker's own
    # `if breadcrumbs && !breadcrumbs.empty?`.
    payload =
      if breadcrumbs != [], do: Map.put(payload, "breadcrumbs", breadcrumbs), else: payload

    payload =
      Map.merge(payload, Map.take(request_fields, ["transaction_name", "endpoint", "trace_id"]))

    payload = attach_sql(payload, config, reason)

    payload = if config.scrub_pii, do: scrub(payload), else: payload

    # After scrubbing, so the fingerprint is of the message as it would otherwise have been sent.
    if config.strict_privacy,
      do: StrictPrivacy.event(payload, config.privacy_allowed_fields),
      else: payload
  end

  # See SqlStatement for what's read off the error and how it's masked. The statement itself only
  # goes out when capture_sql_statement is on; the extracted names go out on their own
  # (capture_sql_objects) so an issue can still name the procedure or view involved.
  defp attach_sql(payload, %Configuration{} = config, reason) do
    if config.capture_sql_objects or config.capture_sql_statement do
      case SqlStatement.mask(SqlStatement.find_in(reason)) do
        nil ->
          payload

        masked ->
          objects = SqlStatement.objects(masked)

          payload
          |> put_if(config.capture_sql_objects and objects != nil, "sql_objects", objects)
          |> put_if(config.capture_sql_statement, "sql_statement", masked)
      end
    else
      payload
    end
  end

  defp put_if(payload, true, key, value), do: Map.put(payload, key, value)
  defp put_if(payload, false, _key, _value), do: payload

  # exception_class/occurred_at/environment/release/server_name/sdk_name/user/transaction_name/
  # endpoint/trace_id are left alone: structured fields this client sets deliberately, not free
  # text an exception or its context could accidentally spill sensitive data into (endpoint in
  # particular is a declared route pattern, never the literal path). user specifically is a deliberate exemption,
  # not an oversight: PiiScrubber's own email pattern would otherwise redact the exact thing this
  # field exists to carry.
  defp scrub(payload) do
    payload = %{
      payload
      | "message" => PiiScrubber.scrub_string(payload["message"]),
        "backtrace" => Enum.map(payload["backtrace"], &scrub_frame/1),
        "context" => PiiScrubber.scrub(payload["context"]),
        "tags" => PiiScrubber.scrub(payload["tags"])
    }

    payload =
      if Map.has_key?(payload, "sql_statement"),
        do: %{payload | "sql_statement" => PiiScrubber.scrub_string(payload["sql_statement"])},
        else: payload

    if Map.has_key?(payload, "breadcrumbs") do
      %{payload | "breadcrumbs" => Enum.map(payload["breadcrumbs"], &scrub_breadcrumb/1)}
    else
      payload
    end
  end

  # category/level/timestamp are left alone, the same "structured fields this client sets
  # deliberately, not free text" exemption exception_class/environment/etc. already get above:
  # only message (arbitrary text) and data (arbitrary caller-supplied values, the same shape
  # context already is) can carry anything worth scrubbing.
  defp scrub_breadcrumb(crumb) do
    %{
      crumb
      | "message" => PiiScrubber.scrub_string(crumb["message"]),
        "data" => PiiScrubber.scrub(crumb["data"])
    }
  end

  defp scrub_frame(frame) do
    frame = %{
      frame
      | "file" => scrub_maybe(frame["file"]),
        "method" => scrub_maybe(frame["method"])
    }

    if Map.has_key?(frame, "context_line") do
      %{
        frame
        | "context_line" => PiiScrubber.scrub_string(frame["context_line"]),
          "pre_context" => Enum.map(frame["pre_context"], &PiiScrubber.scrub_string/1),
          "post_context" => Enum.map(frame["post_context"], &PiiScrubber.scrub_string/1)
      }
    else
      frame
    end
  end

  defp scrub_maybe(nil), do: nil
  defp scrub_maybe(value), do: PiiScrubber.scrub_string(value)

  # A raised %SomeError{} struct has a real module name; anything else (an atom, a string, a
  # tuple: Elixir permits raising/throwing any term) is reported by its own type name instead,
  # the same "report something honest, never crash trying to classify it" approach every other
  # client in this repo takes for its own language's edge cases.
  defp exception_class(%struct{}), do: inspect(struct)
  defp exception_class(reason), do: "#{term_type(reason)} (raised)"

  defp exception_message(reason) when is_exception(reason), do: Exception.message(reason)
  defp exception_message(reason), do: inspect(reason)

  defp term_type(term) when is_atom(term), do: "Atom"
  defp term_type(term) when is_binary(term), do: "String"
  defp term_type(term) when is_tuple(term), do: "Tuple"
  defp term_type(term) when is_list(term), do: "List"
  defp term_type(term) when is_map(term), do: "Map"
  defp term_type(_term), do: "Term"

  defp backtrace(%Configuration{} = config, stacktrace) do
    stacktrace
    |> Enum.take(@max_frames)
    |> Enum.map(&frame(config, &1))
  end

  defp frame(%Configuration{} = config, {module, function, arity_or_args, location}) do
    arity = if is_list(arity_or_args), do: length(arity_or_args), else: arity_or_args

    frame = %{
      "file" => location |> Keyword.get(:file) |> file_to_string(),
      "line" => Keyword.get(location, :line),
      "method" => Exception.format_mfa(module, function, arity),
      "in_app" => in_app?(config, module)
    }

    attach_source_context(config, frame)
  end

  defp file_to_string(nil), do: nil
  defp file_to_string(file), do: to_string(file)

  # Reads a few lines of source straight off disk around the culprit line, at raise-time, in the
  # same running process the exception came from. Gated on two things: the frame has to be
  # in_app (never a third-party dependency: there'd be nothing meaningful to show, and it's not
  # the host app's own code to begin with), and configuration.capture_source_context has to be
  # true (see Configuration for why it defaults to true and why ForgeOps' own per-project
  # setting, not this flag, is the durable, protected way to turn it off), with strict_privacy
  # off. Best-effort: any file
  # that can't be read (deleted, permission denied, a path that only ever existed inside a build
  # step and isn't present in this deployment) just means this one frame gets no source context,
  # never a raised error of its own.
  #
  # Public (not private) so tests can exercise it directly against a synthetic frame, the same
  # reason `start_link/1` and a couple of other genuinely-internal functions elsewhere in this
  # SDK are `@doc false` rather than `defp`: Elixir has no "internal but testable from another
  # module" visibility short of that.
  @doc false
  @spec attach_source_context(Configuration.t(), map()) :: map()
  def attach_source_context(
        %Configuration{capture_source_context: true, strict_privacy: false},
        %{"in_app" => true} = frame
      ) do
    with file when is_binary(file) <- frame["file"],
         {:ok, content} <- File.read(file),
         lines = split_lines(content),
         index = (frame["line"] || 0) - 1,
         true <- index >= 0 and index < length(lines) do
      total = length(lines)
      from = max(index - @context_lines, 0)
      to = min(index + @context_lines, total - 1)

      Map.merge(frame, %{
        "context_line" => lines |> Enum.at(index) |> truncate_line(),
        "pre_context" => lines |> Enum.slice(from, index - from) |> Enum.map(&truncate_line/1),
        "post_context" => lines |> Enum.slice(index + 1, to - index) |> Enum.map(&truncate_line/1)
      })
    else
      _ -> frame
    end
  end

  def attach_source_context(_config, frame), do: frame

  # A single trailing newline (the common case for a saved source file) shouldn't count as an
  # extra, phantom blank final line: verified directly against String.split/2's own behavior on
  # such a file, not assumed. Any further trailing blank lines beyond that one are real and kept.
  defp split_lines(content) do
    content
    |> String.replace_suffix("\n", "")
    |> String.split("\n")
  end

  defp truncate_line(line) do
    if String.length(line) <= @max_context_line_length do
      line
    else
      String.slice(line, 0, @max_context_line_length) <> "..."
    end
  end

  # A module atom's own internal string form is "Elixir.MyApp.ChargeService": verified directly
  # (to_string/1 and Atom.to_string/1 both keep the "Elixir." prefix; only inspect/1 strips it
  # back off to the friendly "MyApp.ChargeService" form a developer actually writes and reads).
  # inspect/1 is what this compares against, so app_module_prefix should be set to that plain
  # "MyApp" form too, not the raw atom's own internal representation.
  defp in_app?(%Configuration{app_module_prefix: nil}, _module), do: false
  defp in_app?(%Configuration{app_module_prefix: ""}, _module), do: false

  defp in_app?(%Configuration{app_module_prefix: prefix}, module) do
    String.starts_with?(inspect(module), prefix)
  end

  defp iso8601_now do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
