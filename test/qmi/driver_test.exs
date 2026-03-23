# SPDX-License-Identifier: Apache-2.0
defmodule QMI.DriverTest do
  use ExUnit.Case

  @pipe_filename "test_driver_pipe"

  setup do
    _ = File.rm(@pipe_filename)
    {"", 0} = System.cmd("mkfifo", [@pipe_filename])
    on_exit(fn -> File.rm(@pipe_filename) end)

    qmi = :"Elixir.DriverTestQMI"

    cache_pid = start_supervised!({QMI.ClientIDCache, [name: qmi]}, id: :cache)

    # Open a writer FIRST so the Driver's handle_continue(:open) doesn't block
    {:ok, writer} = start_supervised(QMI.DevBridge, id: :writer)
    {:ok, _wref} = QMI.DevBridge.open(writer, @pipe_filename, [:write])

    driver_pid =
      start_supervised!(
        {QMI.Driver,
         [
           name: qmi,
           device_path: @pipe_filename,
           indication_callback: nil
         ]},
        id: :driver
      )

    # Wait for handle_continue(:open) to complete
    Process.sleep(100)

    {:ok, qmi: qmi, driver_pid: driver_pid, cache_pid: cache_pid, writer: writer}
  end

  test "qmi_name is stored in driver state", %{driver_pid: pid} do
    state = :sys.get_state(pid)
    assert state.qmi_name == :"Elixir.DriverTestQMI"
  end

  test "consecutive_timeouts starts at 0", %{driver_pid: pid} do
    state = :sys.get_state(pid)
    assert state.consecutive_timeouts == 0
  end

  test "device error fails all pending transactions", %{driver_pid: pid} do
    state = :sys.get_state(pid)
    ref = state.ref

    # Inject a fake pending transaction
    timer = Process.send_after(self(), :never, 60_000)
    tag = make_ref()
    fake_from = {self(), tag}

    :sys.replace_state(pid, fn s ->
      %{s | transactions: Map.put(s.transactions, 999, {fake_from, %{}, timer})}
    end)

    assert map_size(:sys.get_state(pid).transactions) == 1

    send(pid, {:dev_bridge, ref, :error, :eio})
    Process.sleep(50)

    assert :sys.get_state(pid).transactions == %{}

    # The GenServer.reply sends a response matching the tag
    assert_received {^tag, {:error, {:device_error, :eio}}}
  end

  test "device closed clears client ID cache", %{driver_pid: dpid, cache_pid: cpid, qmi: _qmi} do
    # Inject cached client IDs
    :sys.replace_state(cpid, fn _state -> %{1 => 10, 2 => 20} end)
    assert map_size(:sys.get_state(cpid)) == 2

    state = :sys.get_state(dpid)
    ref = state.ref

    send(dpid, {:dev_bridge, ref, :closed})
    Process.sleep(200)

    # Cache should be cleared after device closed
    assert :sys.get_state(cpid) == %{}
  end

  test "device closed resets consecutive_timeouts", %{driver_pid: pid} do
    state = :sys.get_state(pid)
    ref = state.ref

    :sys.replace_state(pid, fn s -> %{s | consecutive_timeouts: 5} end)
    assert :sys.get_state(pid).consecutive_timeouts == 5

    send(pid, {:dev_bridge, ref, :closed})
    Process.sleep(200)

    assert :sys.get_state(pid).consecutive_timeouts == 0
  end

  test "device closed fails all pending transactions", %{driver_pid: pid} do
    state = :sys.get_state(pid)
    ref = state.ref

    timer = Process.send_after(self(), :never, 60_000)
    tag = make_ref()
    fake_from = {self(), tag}

    :sys.replace_state(pid, fn s ->
      %{s | transactions: Map.put(s.transactions, 888, {fake_from, %{}, timer})}
    end)

    send(pid, {:dev_bridge, ref, :closed})
    Process.sleep(200)

    assert_received {^tag, {:error, :device_closed}}
  end
end
