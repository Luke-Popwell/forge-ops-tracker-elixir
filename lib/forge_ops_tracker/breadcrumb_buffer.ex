defmodule ForgeOpsTracker.BreadcrumbBuffer do
  @moduledoc """
  A bounded, in-order trail of what happened right before an exception: the automatic
  `"controller"`/`"query"`/`"job"` entries `ForgeOpsTracker.Integrations.Phoenix`/`Ecto`/`Oban`
  record (see each one's own module doc), plus anything added by hand via
  `ForgeOpsTracker.add_breadcrumb/4`. Ported from
  `gems/forge_ops_tracker/lib/forge_ops_tracker/breadcrumb_buffer.rb`: a ring buffer capped at
  `Configuration.t/0`'s own `max_breadcrumbs`, oldest entry dropped once full.

  Stored in the calling process's own dictionary, not a separate module holding a struct the way
  every other SDK in this repo's own `BreadcrumbBuffer` class does: `set_user/1`/`current_user/0`
  in `ForgeOpsTracker` already use `Process.put/2`/`Process.get/1` directly for the exact same
  "one process per request, the direct Elixir analog to Thread.current" reasoning, and a process
  dictionary can already hold a plain list on its own, so there's no separate buffer object to
  instantiate the way a Ruby `Thread.current[...]` or a Java `ThreadLocal` needs one.
  """

  @breadcrumbs_key :forge_ops_tracker_breadcrumbs

  @doc """
  Records one entry into the calling process's own trail. `category` defaults to `"custom"` and
  `level` to `"info"`; `data` defaults to `%{}`. A no-op when `max_breadcrumbs` is `0` or less,
  the same "no crash, just nothing recorded" behavior every other client in this repo's own ring
  buffer has for the identical case.
  """
  @spec add(String.t(), String.t(), String.t(), map(), pos_integer()) :: :ok
  def add(message, category \\ "custom", level \\ "info", data \\ %{}, max_size) do
    if max_size > 0 do
      entry = %{
        "category" => category,
        "message" => message,
        "level" => level,
        "timestamp" => iso8601_now(),
        "data" => data
      }

      updated = (Process.get(@breadcrumbs_key, []) ++ [entry]) |> Enum.take(-max_size)
      Process.put(@breadcrumbs_key, updated)
    end

    :ok
  end

  @doc "The calling process's own trail, oldest first, or `[]` if nothing's been added."
  @spec all() :: [map()]
  def all, do: Process.get(@breadcrumbs_key, [])

  @doc "Empties the calling process's own trail."
  @spec clear() :: :ok
  def clear do
    Process.delete(@breadcrumbs_key)
    :ok
  end

  defp iso8601_now do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
