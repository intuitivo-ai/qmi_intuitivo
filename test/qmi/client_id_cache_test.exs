# SPDX-License-Identifier: Apache-2.0
defmodule QMI.ClientIDCacheTest do
  use ExUnit.Case

  setup do
    qmi = :"Elixir.CacheTestQMI"
    cache_pid = start_supervised!({QMI.ClientIDCache, [name: qmi]})
    {:ok, qmi: qmi, cache_pid: cache_pid}
  end

  test "clear/1 invalidates all cached client IDs", %{qmi: qmi, cache_pid: pid} do
    :sys.replace_state(pid, fn _state ->
      %{1 => 10, 2 => 20, 3 => 30}
    end)

    assert map_size(:sys.get_state(pid)) == 3

    :ok = QMI.ClientIDCache.clear(qmi)

    # Allow the cast to be processed
    _ = :sys.get_state(pid)
    assert :sys.get_state(pid) == %{}
  end

  test "clear/1 is idempotent on empty cache", %{qmi: qmi, cache_pid: pid} do
    assert :sys.get_state(pid) == %{}

    :ok = QMI.ClientIDCache.clear(qmi)
    _ = :sys.get_state(pid)

    assert :sys.get_state(pid) == %{}
  end

  test "clear/1 allows re-population after clearing", %{qmi: qmi, cache_pid: pid} do
    :sys.replace_state(pid, fn _state ->
      %{1 => 10}
    end)

    :ok = QMI.ClientIDCache.clear(qmi)
    _ = :sys.get_state(pid)

    assert :sys.get_state(pid) == %{}

    :sys.replace_state(pid, fn _state ->
      %{5 => 50}
    end)

    assert :sys.get_state(pid) == %{5 => 50}
  end
end
