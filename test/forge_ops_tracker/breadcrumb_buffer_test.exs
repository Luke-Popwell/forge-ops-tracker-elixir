defmodule ForgeOpsTracker.BreadcrumbBufferTest do
  use ExUnit.Case, async: true

  alias ForgeOpsTracker.BreadcrumbBuffer

  setup do
    on_exit(&BreadcrumbBuffer.clear/0)
    :ok
  end

  test "returns entries in insertion order, each carrying the given fields plus a timestamp" do
    BreadcrumbBuffer.add("User Load", "query", "info", %{duration_ms: 1.2}, 3)

    [entry] = BreadcrumbBuffer.all()
    assert entry["category"] == "query"
    assert entry["message"] == "User Load"
    assert entry["level"] == "info"
    assert entry["data"] == %{duration_ms: 1.2}
    assert String.ends_with?(entry["timestamp"], "Z")
  end

  test "defaults category to custom, level to info, and data to an empty map" do
    BreadcrumbBuffer.add("checkpoint", "custom", "info", %{}, 3)

    [entry] = BreadcrumbBuffer.all()
    assert entry["category"] == "custom"
    assert entry["level"] == "info"
    assert entry["data"] == %{}
  end

  test "drops the oldest entry once max_size is exceeded" do
    for n <- 0..3 do
      BreadcrumbBuffer.add("entry #{n}", "custom", "info", %{}, 3)
    end

    messages = Enum.map(BreadcrumbBuffer.all(), & &1["message"])
    assert messages == ["entry 1", "entry 2", "entry 3"]
  end

  test "adds nothing at all when max_size is zero" do
    BreadcrumbBuffer.add("one", "custom", "info", %{}, 0)

    assert BreadcrumbBuffer.all() == []
  end

  test "clear empties the trail" do
    BreadcrumbBuffer.add("one", "custom", "info", %{}, 3)
    assert BreadcrumbBuffer.all() != []

    BreadcrumbBuffer.clear()

    assert BreadcrumbBuffer.all() == []
  end

  test "each process has its own independent trail" do
    BreadcrumbBuffer.add("on this process", "custom", "info", %{}, 3)

    task =
      Task.async(fn ->
        BreadcrumbBuffer.add("on the other process", "custom", "info", %{}, 3)
        BreadcrumbBuffer.all()
      end)

    other_process_trail = Task.await(task)

    assert Enum.map(BreadcrumbBuffer.all(), & &1["message"]) == ["on this process"]
    assert Enum.map(other_process_trail, & &1["message"]) == ["on the other process"]
  end
end
