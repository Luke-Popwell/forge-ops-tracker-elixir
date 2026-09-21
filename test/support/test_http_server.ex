defmodule ForgeOpsTracker.TestHttpServer do
  @moduledoc """
  A minimal, real local HTTP server over a raw `:gen_tcp` socket: used only in tests, so
  `Client`/`DeliveryQueue`/`Reporter` tests exercise actual bytes/headers over an actual socket
  rather than a mock, the same "test against something real" approach this repo's Java/Kotlin/
  Rust/Go/C clients' own Client tests take (each with their own small hand-rolled test server, for
  the same reason: no HTTP server test dependency is worth adding just for this).

  Header names in the returned `%{headers: ...}` map are always lowercase, regardless of how a
  client actually sent them: confirmed directly that `:httpc` (the client every SDK module in
  this repo actually uses) lowercases every header it sends, including ones this server's own
  `Client` module sets with mixed case like `"Authorization"`. Query the map with a lowercase key.
  """

  @doc """
  Starts a server that accepts connections until 2 seconds pass with none, responds to each with
  `status`, and returns `{port, requests_agent}`: `requests_agent` is an `Agent` you can read
  via `Agent.get(requests_agent, & &1)` for the list of
  `%{request_line: binary, headers: map, body: binary}` maps received so far.

  `hold_for` (default `nil`), if given a pid, makes every accepted connection wait for a
  `:release` message sent to that pid *from the test*: i.e. pass `self()` and then
  `send(pid, :release)` when the test is ready to let the response go out. Used to hold a
  delivery attempt open for as long as a test needs (see `DeliveryQueueTest`'s own "drops when
  full" test), without depending on fragile real-time sleeps.
  """
  def start(status \\ 202, hold_for \\ nil) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    {:ok, requests} = Agent.start_link(fn -> [] end)

    spawn(fn -> accept_loop(listen_socket, status, requests, hold_for) end)

    {port, requests}
  end

  defp accept_loop(listen_socket, status, requests, hold_for) do
    case :gen_tcp.accept(listen_socket, 2_000) do
      {:ok, socket} ->
        handle_connection(socket, status, requests, hold_for)
        accept_loop(listen_socket, status, requests, hold_for)

      {:error, _reason} ->
        # :timeout (this test server's own idle-shutdown signal, see start/2's own doc) or
        # :closed (the listen socket already closed, e.g. by a caller done with this server):
        # either way, nothing left to accept.
        :gen_tcp.close(listen_socket)
    end
  end

  defp handle_connection(socket, status, requests, hold_for) do
    {headers_text, leftover} = read_until_headers_done(socket, "")
    [request_line | header_lines] = String.split(headers_text, "\r\n", trim: true)

    headers =
      Map.new(header_lines, fn line ->
        [key, value] = String.split(line, ": ", parts: 2)
        {String.downcase(key), value}
      end)

    content_length = headers |> Map.get("content-length", "0") |> String.to_integer()
    body = read_body(socket, leftover, content_length)

    Agent.update(requests, fn list ->
      list ++ [%{request_line: request_line, headers: headers, body: body}]
    end)

    if hold_for, do: await_release(hold_for)

    response = "HTTP/1.1 #{status} status\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
  end

  defp await_release(pid) do
    send(pid, {:held, self()})

    receive do
      :release -> :ok
    after
      5_000 -> :ok
    end
  end

  # Returns {headers_text, leftover_bytes_already_read_past_the_header_terminator}: a single
  # :gen_tcp.recv call can easily return headers *and* part (or all) of the body together, so
  # whatever comes back past "\r\n\r\n" has to be carried forward into read_body below rather than
  # discarded, or read_body would then wait forever for bytes the socket already delivered.
  defp read_until_headers_done(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [headers, leftover] ->
        {headers, leftover}

      [_no_terminator_yet] ->
        case :gen_tcp.recv(socket, 0, 2_000) do
          {:ok, chunk} -> read_until_headers_done(socket, acc <> chunk)
          {:error, _} -> {acc, ""}
        end
    end
  end

  defp read_body(_socket, leftover, content_length) when byte_size(leftover) >= content_length do
    binary_part(leftover, 0, content_length)
  end

  defp read_body(socket, leftover, content_length) do
    remaining = content_length - byte_size(leftover)

    case :gen_tcp.recv(socket, remaining, 2_000) do
      {:ok, rest} -> leftover <> rest
      {:error, _} -> leftover
    end
  end
end
