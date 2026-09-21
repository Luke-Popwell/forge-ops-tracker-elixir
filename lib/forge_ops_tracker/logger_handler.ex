defmodule ForgeOpsTracker.LoggerHandler do
  @moduledoc """
  Reports any process crash anywhere in the whole BEAM VM, with zero further wiring needed:
  attached via `:logger.add_handler/3` (see `ForgeOpsTracker.install_handlers/0`), a standard
  `:logger_handler` behaviour implementation, the same technique other logger-integrated error
  trackers in the Elixir ecosystem use for the same purpose.

  This is a meaningfully stronger "automatic capture" story than the uncaught-exception hooks
  every other client in this repo installs for its own language: those catch one thread/goroutine/
  the main thread; Erlang's `:logger` already receives a structured crash report: via
  `:error_logger`/`proc_lib`, `gen_server`, `gen_statem`, and `Task` all forwarding into it, the
  same mechanism `Logger`'s own console backend uses to print "** (RuntimeError) ...": for *any*
  process that terminates abnormally anywhere in the whole VM, supervised or not, because that's
  simply how OTP's own "let it crash" supervision model already works. Attaching a handler is
  observing that existing stream, not building a new one.

  Filters for `meta.crash_reason` specifically (a `{reason, stacktrace}` tuple Erlang's own crash
  reporting attaches to the log event) rather than every `:error`-level log line: an ordinary
  `Logger.error("something went wrong")` call from application code has no `crash_reason` and is
  deliberately left alone; reporting every error-level log message, not just real crashes, would
  be far noisier than this client should be by default. Verified directly against a real crashed
  `GenServer`'s actual log event shape before relying on this filter, not assumed from
  documentation alone.
  """

  alias ForgeOpsTracker.Reporter

  @doc false
  # The single callback the :logger_handler behaviour requires. Deliberately not `use
  # GenServer`/any other behaviour macro: :logger calls this function directly and
  # synchronously from whatever process logged the event, so this has to stay fast and never
  # raise (see Reporter.report/3's own guarantee).
  @spec log(:logger.log_event(), :logger_handler.config()) :: :ok
  def log(%{level: :error, meta: %{crash_reason: {reason, stacktrace}}}, _handler_config)
      when is_list(stacktrace) do
    # ForgeOpsTracker.current_user/0, not a bare Process.get/1: whatever ForgeOpsTracker.set_user/1
    # last set for *this* process (a Phoenix request's own connection process, most commonly, via
    # ForgeOpsTracker.Integrations.Phoenix.UserContextPlug), attached to the crash report the same
    # way it already is for a manually-rescued ForgeOpsTracker.capture_exception/4 call. Correct
    # specifically because :logger dispatches a crash report synchronously, in the crashing
    # process's own context (verified directly, not assumed: see this module's own moduledoc).
    Reporter.report(
      reason,
      stacktrace,
      %{},
      ForgeOpsTracker.current_user(),
      ForgeOpsTracker.current_breadcrumbs()
    )
  end

  def log(_log_event, _handler_config), do: :ok
end
