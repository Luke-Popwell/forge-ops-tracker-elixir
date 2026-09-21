defmodule ForgeOpsTracker.EventBuilderTest do
  use ExUnit.Case, async: true

  alias ForgeOpsTracker.{Configuration, EventBuilder, PiiScrubber}

  defmodule SampleError do
    defexception message: "boom"
  end

  defp new_configuration(overrides \\ %{}) do
    struct(
      %Configuration{environment: "production", release: "abc123", server_name: "web-1"},
      overrides
    )
  end

  # A real __STACKTRACE__ from an actual raise/rescue, not a hand-constructed one: verified
  # directly against a real crashed GenServer's own log event before relying on this shape (see
  # ForgeOpsTracker.LoggerHandler's own moduledoc), so this test exercises the exact same tuple
  # shape production code sees.
  defp raise_and_rescue do
    raise SampleError
  rescue
    e -> {e, __STACKTRACE__}
  end

  test "builds payload with exception class, message, and configured metadata" do
    config = new_configuration()
    {error, stacktrace} = raise_and_rescue()

    payload = EventBuilder.build(config, error, stacktrace, %{order_id: 42})

    assert payload["exception_class"] == "ForgeOpsTracker.EventBuilderTest.SampleError"
    assert payload["message"] == "boom"
    assert payload["environment"] == "production"
    assert payload["release"] == "abc123"
    assert payload["server_name"] == "web-1"
    assert payload["context"] == %{order_id: 42}
    assert is_binary(payload["occurred_at"])
    assert payload["sdk_name"] == "elixir"
  end

  test "parses real stack frames with method, file, and line" do
    config = new_configuration()
    {error, stacktrace} = raise_and_rescue()

    frames = EventBuilder.build(config, error, stacktrace)["backtrace"]

    assert length(frames) > 0
    frame = hd(frames)
    assert is_binary(frame["file"])
    assert is_integer(frame["line"])
    assert frame["method"] =~ "ForgeOpsTracker.EventBuilderTest"
  end

  test "marks a frame from this module as in_app when app_module_prefix matches" do
    config = new_configuration(%{app_module_prefix: "ForgeOpsTracker.EventBuilderTest"})
    {error, stacktrace} = raise_and_rescue()

    frames = EventBuilder.build(config, error, stacktrace)["backtrace"]

    assert Enum.any?(frames, & &1["in_app"]),
           "the frame that raised should be in this test module"
  end

  test "no frame is in_app when app_module_prefix is unset" do
    config = new_configuration()
    {error, stacktrace} = raise_and_rescue()

    frames = EventBuilder.build(config, error, stacktrace)["backtrace"]

    assert Enum.all?(frames, &(&1["in_app"] == false))
  end

  test "handles a raised non-exception term (an atom) without crashing" do
    config = new_configuration()

    try do
      throw(:some_atom)
    catch
      :some_atom -> :ok
    end

    stacktrace =
      try do
        raise "placeholder"
      rescue
        _ -> __STACKTRACE__
      end

    payload = EventBuilder.build(config, :some_atom, stacktrace)

    assert payload["exception_class"] == "Atom (raised)"
    assert payload["message"] == ":some_atom"
  end

  test "scrubs likely pii out of message and context by default" do
    config = new_configuration()

    stacktrace =
      try do
        raise SampleError, message: "failed for user@example.com"
      rescue
        _ -> __STACKTRACE__
      end

    payload =
      EventBuilder.build(
        config,
        %SampleError{message: "failed for user@example.com"},
        stacktrace,
        %{
          "user" => %{"email" => "ada@example.com", "password" => "hunter2"}
        }
      )

    assert payload["message"] == "failed for [EMAIL FILTERED]"

    assert payload["context"] == %{
             "user" => %{"email" => "[EMAIL FILTERED]", "password" => PiiScrubber.redacted()}
           }
  end

  test "leaves payload untouched when scrub_pii is disabled" do
    config = new_configuration(%{scrub_pii: false})
    {_error, stacktrace} = raise_and_rescue()

    payload =
      EventBuilder.build(config, %SampleError{message: "contact user@example.com"}, stacktrace, %{
        "email" => "ada@example.com"
      })

    assert payload["message"] == "contact user@example.com"
    assert payload["context"] == %{"email" => "ada@example.com"}
  end

  test "includes the user when given one, never scrubbed even though it's an email" do
    config = new_configuration()
    {error, stacktrace} = raise_and_rescue()

    payload =
      EventBuilder.build(config, error, stacktrace, %{}, %{
        "id" => 42,
        "email" => "ada@example.com"
      })

    assert payload["user"] == %{"id" => 42, "email" => "ada@example.com"}
  end

  test "omits the user key entirely when none was given" do
    config = new_configuration()
    {error, stacktrace} = raise_and_rescue()

    payload = EventBuilder.build(config, error, stacktrace)

    refute Map.has_key?(payload, "user")
  end

  test "includes breadcrumbs when given" do
    config = new_configuration()
    {error, stacktrace} = raise_and_rescue()

    crumb = %{
      "category" => "controller",
      "message" => "GET /orders/42",
      "level" => "info",
      "timestamp" => "2024-01-15T10:29:58Z",
      "data" => %{status: 200}
    }

    payload = EventBuilder.build(config, error, stacktrace, %{}, nil, [crumb])

    assert payload["breadcrumbs"] == [crumb]
  end

  test "omits the breadcrumbs key entirely when none were given" do
    config = new_configuration()
    {error, stacktrace} = raise_and_rescue()

    payload = EventBuilder.build(config, error, stacktrace)

    refute Map.has_key?(payload, "breadcrumbs")
  end

  test "scrubs breadcrumb message and data but leaves category level and timestamp untouched" do
    config = new_configuration()
    {error, stacktrace} = raise_and_rescue()

    crumb = %{
      "category" => "custom",
      "message" => "emailed alice@example.com",
      "level" => "info",
      "timestamp" => "2024-01-15T10:29:58Z",
      "data" => %{"email" => "alice@example.com", "password" => "hunter2"}
    }

    payload = EventBuilder.build(config, error, stacktrace, %{}, nil, [crumb])

    [scrubbed] = payload["breadcrumbs"]
    refute scrubbed["message"] =~ "alice@example.com"
    assert scrubbed["category"] == "custom"
    assert scrubbed["level"] == "info"
    assert scrubbed["timestamp"] == "2024-01-15T10:29:58Z"
    assert scrubbed["data"]["password"] == PiiScrubber.redacted()
  end

  describe "source context capture" do
    # A unique subdirectory per test run rather than a fixed fixture path: keeps concurrent
    # `async: true` test runs from ever colliding on the same file.
    defp tmp_source_path(name \\ "app_file.ex") do
      dir =
        Path.join(
          System.tmp_dir!(),
          "forge_ops_tracker_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      Path.join(dir, name)
    end

    defp write_source_file!(line_count) do
      path = tmp_source_path()
      content = Enum.map_join(1..line_count, "\n", &"line #{&1}")
      File.write!(path, content)
      path
    end

    defp in_app_frame(file, line) do
      %{"file" => file, "line" => line, "method" => "call", "in_app" => true}
    end

    test "attaches context_line/pre_context/post_context around an in_app frame's culprit line, by default" do
      config = new_configuration()
      path = write_source_file!(20)

      frame = EventBuilder.attach_source_context(config, in_app_frame(path, 10))

      assert frame["context_line"] == "line 10"
      assert frame["pre_context"] == Enum.map(5..9, &"line #{&1}")
      assert frame["post_context"] == Enum.map(11..15, &"line #{&1}")
    end

    test "clamps pre_context/post_context at the start and end of the file rather than raising" do
      config = new_configuration()
      path = write_source_file!(3)

      first_frame = EventBuilder.attach_source_context(config, in_app_frame(path, 1))
      last_frame = EventBuilder.attach_source_context(config, in_app_frame(path, 3))

      assert first_frame["pre_context"] == []
      assert first_frame["post_context"] == ["line 2", "line 3"]
      assert last_frame["pre_context"] == ["line 1", "line 2"]
      assert last_frame["post_context"] == []
    end

    test "truncates an individual line longer than the max context line length" do
      config = new_configuration()
      path = tmp_source_path()
      overlong = String.duplicate("x", 600)
      File.write!(path, overlong)

      frame = EventBuilder.attach_source_context(config, in_app_frame(path, 1))

      assert frame["context_line"] == "#{String.duplicate("x", 500)}..."
    end

    test "never attaches context to a frame that is not in_app" do
      config = new_configuration()
      path = write_source_file!(20)
      frame = %{in_app_frame(path, 10) | "in_app" => false}

      result = EventBuilder.attach_source_context(config, frame)

      refute Map.has_key?(result, "context_line")
      refute Map.has_key?(result, "pre_context")
      refute Map.has_key?(result, "post_context")
    end

    test "leaves a frame untouched, with no file read attempted, when capture_source_context is disabled" do
      config = new_configuration(%{capture_source_context: false})
      fifo_path = tmp_source_path("fifo")
      {_output, 0} = System.cmd("mkfifo", [fifo_path])
      frame = in_app_frame(fifo_path, 1)

      # A FIFO with no writer connected blocks a reader on open/read indefinitely: if
      # attach_source_context/2 ever actually tried to read this file despite
      # capture_source_context being off, this task would still be running (never yielding a
      # result) after the timeout below. This proves no read was even attempted, not merely that
      # the frame came back unchanged (which a differently-broken gate could also produce).
      task = Task.async(fn -> EventBuilder.attach_source_context(config, frame) end)

      result =
        case Task.yield(task, 200) do
          {:ok, value} ->
            value

          nil ->
            Task.shutdown(task, :brutal_kill)

            flunk(
              "attach_source_context/2 attempted to read the file despite capture_source_context being false"
            )
        end

      assert result == frame
      refute Map.has_key?(result, "context_line")
    end

    test "leaves a frame untouched when the recorded file can't be read" do
      config = new_configuration()
      missing_path = tmp_source_path("this-file-does-not-exist.ex")

      frame = EventBuilder.attach_source_context(config, in_app_frame(missing_path, 1))

      refute Map.has_key?(frame, "context_line")
    end

    test "scrubs likely pii out of captured source context too, by default" do
      config = new_configuration(%{app_module_prefix: "ForgeOpsTracker.EventBuilderTest"})
      path = tmp_source_path()
      File.write!(path, "# filler\ncontact user@example.com\n# filler")
      # A hand-built stacktrace entry, the same {module, function, arity, location} shape
      # __STACKTRACE__ itself produces: lets this frame's file/line point at the known fixture
      # above rather than this test file's own (real, but unpredictable-content) source, while
      # still exercising the real build/4 pipeline end to end, source capture and scrubbing both.
      stacktrace = [{__MODULE__, :dummy, 0, [file: path, line: 2]}]

      payload = EventBuilder.build(config, %SampleError{}, stacktrace)
      frame = hd(payload["backtrace"])

      assert frame["context_line"] == "contact [EMAIL FILTERED]"
      assert frame["pre_context"] == ["# filler"]
      assert frame["post_context"] == ["# filler"]
    end
  end
end
