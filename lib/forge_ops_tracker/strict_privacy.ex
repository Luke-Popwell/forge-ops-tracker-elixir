defmodule ForgeOpsTracker.StrictPrivacy do
  @moduledoc """
  Strict privacy (`Configuration.t/0`'s `strict_privacy`) is for apps that can't let personal or
  health data leave their own servers: an event carries only structured facts (the error's type,
  its stack frames, release, environment, server, which route it happened in), never free text a
  person could have typed. The rules, and the vectors every client's tests check against, are in
  this repo's `sdks/STRICT_PRIVACY.md`; the server applies the same rules again on arrival
  (`app/services/strict_privacy.rb`) when the project's own Strict privacy setting is on.
  """

  @fingerprint_length 32

  # Matched against the raw bytes (no /u), so a word character is ASCII [A-Za-z0-9_] only, never a
  # letter or digit in another script, whatever PCRE would otherwise consider one.
  @hex_object_id ~r/0x[0-9a-fA-F]{4,}/
  @uuid ~r/(?<![A-Za-z0-9_])[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![A-Za-z0-9_])/
  @number ~r/(?<![A-Za-z0-9_])[0-9]+(?![A-Za-z0-9_])/

  @http_method ~r/\A(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+(\S+)/i
  @scheme ~r{\A[a-z][a-z0-9+.-]*://}i
  @port ~r/:[0-9]+\z/
  @route_parameter ~r/\A(?::.+|\{.+\}|<.+>|\[.+\]|\*.*)\z/

  # Span data that's structure, not content: the masked statement and which database it ran on.
  @span_data_keys ["db.statement", "db.system"]

  @doc """
  The message with hex object ids, UUIDs and standalone numbers replaced, in that order: `"0x"`
  plus 4 or more hex digits becomes `"0x"`, a UUID becomes `"<uuid>"` and a run of digits becomes
  `"<n>"`, the last two only where no ASCII word character touches them.
  """
  @spec normalize_message(String.t() | nil) :: String.t()
  def normalize_message(message) do
    normalized = Regex.replace(@hex_object_id, to_string(message), "0x")
    normalized = Regex.replace(@uuid, normalized, "<uuid>")
    Regex.replace(@number, normalized, "<n>")
  end

  @doc """
  The first 32 hex characters of the SHA-256 of `normalize_message/1`'s UTF-8 bytes: lets ForgeOps
  group errors whose messages differ only in ids, without the message being sent.
  """
  @spec message_fingerprint(String.t() | nil) :: String.t()
  def message_fingerprint(message) do
    :crypto.hash(:sha256, normalize_message(message))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @fingerprint_length)
  end

  @doc """
  A request or page path under strict privacy, with no query or fragment. A route template
  (`"/patients/:id/notes"`, `"/orders/{id}"`) is kept as it is: its words are a developer's and its
  parameters are already placeholders. A raw path keeps only its first segment (`":id"` when it
  holds an ASCII digit or is longer than 40 characters), then `"/:path"` if there was more, since
  anything after it can name a person: `"/patients/jane-doe/12"` is `"/patients/:path"`. No
  segments at all is `"/"`.
  """
  @spec strict_path(String.t() | nil) :: String.t()
  def strict_path(path) do
    [path | _] = String.split(to_string(path), ["?", "#"], parts: 2)

    if route_template?(path) do
      path
    else
      case String.split(path, "/", trim: true) do
        [] ->
          "/"

        [first | rest] ->
          # Characters as the server counts them (code points), not graphemes.
          first =
            if first =~ ~r/[0-9]/ or length(String.codepoints(first)) > 40, do: ":id", else: first

          leading = if String.starts_with?(path, "/"), do: "/", else: ""
          leading <> first <> if(rest == [], do: "", else: "/:path")
      end
    end
  end

  @doc false
  @deprecated "Use strict_path/1"
  def path_without_ids(path), do: strict_path(path)

  # Whether any segment of the path is a route parameter: ":id", "{id}", "<int:id>", "[slug]" or
  # "*path".
  defp route_template?(path) do
    path |> String.split("/") |> Enum.any?(&(&1 =~ @route_parameter))
  end

  @doc """
  A span's name under strict privacy: an outbound call keeps its method and host
  (`"GET https://api.example.com/patients/42?x=1"` is `"GET api.example.com"`), a request named by
  its path goes through `strict_path/1` (`"GET /patients/42/notes"` is `"GET /patients/:path"`), so
  does a bare path (`"/42/edit"` is `"/:id/:path"`), and any other name
  (`"OrdersController#create"`) is kept.
  """
  @spec span_name(String.t()) :: String.t()
  def span_name("/" <> _ = name), do: strict_path(name)

  def span_name(name) do
    case Regex.run(@http_method, to_string(name)) do
      [_match, method, "/" <> _ = target] ->
        "#{String.upcase(method)} #{strict_path(target)}"

      [_match, method, target] ->
        "#{String.upcase(method)} #{host_of(target) || strict_path(target)}"

      nil ->
        name
    end
  end

  @doc """
  A transaction name under strict privacy: a route or a controller action is kept, but a raw path
  keeps only its first segment, by the same rule as `span_name/1`. A blank name is returned as it is.
  """
  @spec transaction_name(String.t() | nil) :: String.t() | nil
  def transaction_name(name) when is_binary(name) do
    if String.trim(name) == "", do: name, else: span_name(name)
  end

  def transaction_name(name), do: name

  # An outbound call's host, read by hand rather than with URI.parse/1 (so an address a parser
  # would choke on still loses its path): whatever comes before the first "/", "?" or "#", without
  # a scheme, credentials or port. It's a host when the address had a scheme or a port, or it has a
  # dot or is "localhost"; otherwise (a relative path) nil.
  defp host_of(target) do
    scheme = target =~ @scheme

    [authority | _] =
      target |> String.replace(@scheme, "") |> String.split(["/", "?", "#"], parts: 2)

    authority = String.replace(authority, ~r/\A.*@/s, "")
    port = authority =~ @port
    host = String.replace(authority, @port, "")

    if host != "" and
         (scheme or port or String.contains?(host, ".") or String.downcase(host) == "localhost"),
       do: host
  end

  @doc """
  An error event's payload (`ForgeOpsTracker.EventBuilder.build/7`'s shape) reduced to what strict
  privacy sends: `"message"` is `""` and `"message_fingerprint"` is added; breadcrumbs, endpoint,
  SQL statement and source context are dropped; a raw-path `"transaction_name"` keeps only its first segment (see
  `transaction_name/1`); context and tags keep only `allowed_fields` keys
  with plain values (left out when nothing is left); the user keeps only its id.
  """
  @spec event(map(), [String.t()]) :: map()
  def event(payload, allowed_fields) do
    payload
    |> Map.drop(["breadcrumbs", "endpoint", "sql_statement"])
    |> put_or_drop("transaction_name", transaction_name(payload["transaction_name"]))
    |> Map.merge(%{
      "message" => "",
      "message_fingerprint" => message_fingerprint(payload["message"]),
      "backtrace" =>
        Enum.map(
          payload["backtrace"] || [],
          &Map.drop(&1, ["context_line", "pre_context", "post_context"])
        )
    })
    |> put_or_drop("context", allowed(payload["context"], allowed_fields))
    |> put_or_drop("tags", allowed(payload["tags"], allowed_fields))
    |> put_or_drop("user", user(payload["user"]))
  end

  @doc """
  One finished span under strict privacy: its name per `span_name/1`, and its data reduced to
  `"db.statement"` and `"db.system"` (left out when neither is there).
  """
  @spec span(map()) :: map()
  def span(span) do
    data = Map.take(span.data || %{}, @span_data_keys)
    span = %{span | name: span_name(span.name)}
    if map_size(data) > 0, do: %{span | data: data}, else: Map.delete(span, :data)
  end

  @doc false
  # FORGE_OPS_STRICT_PRIVACY and FORGE_OPS_PRIVACY_ALLOWED_FIELDS out of `os_env`
  # (System.get_env/0's shape), for Configuration's initial state.
  @spec from_environment(%{optional(String.t()) => String.t()}) :: {boolean(), [String.t()]}
  def from_environment(os_env) do
    on = String.downcase(String.trim(Map.get(os_env, "FORGE_OPS_STRICT_PRIVACY", ""))) == "true"

    fields =
      os_env
      |> Map.get("FORGE_OPS_PRIVACY_ALLOWED_FIELDS", "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {on, fields}
  end

  defp put_or_drop(payload, key, nil), do: Map.delete(payload, key)
  defp put_or_drop(payload, key, value), do: Map.put(payload, key, value)

  # Keys are compared as strings, so a context map built with atom keys (%{error_code: "E42"})
  # matches an allowed "error_code" the same way.
  defp allowed(fields, allowed_fields) when is_map(fields) and allowed_fields != [] do
    allowed_fields = Enum.map(allowed_fields, &to_string/1)

    kept =
      for {key, value} <- fields,
          to_string(key) in allowed_fields,
          is_binary(value) or is_number(value) or is_boolean(value),
          into: %{},
          do: {to_string(key), value}

    if map_size(kept) > 0, do: kept
  end

  defp allowed(_fields, _allowed_fields), do: nil

  defp user(user) when is_map(user) do
    case Map.get(user, "id", Map.get(user, :id)) do
      nil ->
        nil

      id ->
        id =
          if is_binary(id) or is_number(id) or is_atom(id), do: to_string(id), else: inspect(id)

        if String.trim(id) != "", do: %{"id" => id}
    end
  end

  defp user(_user), do: nil
end
