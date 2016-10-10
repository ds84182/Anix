-- Leaves the init code after all init files have been loaded globally
-- It starts process zero with the kernel signal stream and then jumps to process management

function LeaveINIT()
  os.log("LEAVEINIT", "Leaving INIT")
  os.log("LEAVEINIT", "Starting 'zero'")

  local bootfs = component.proxy(computer.getBootAddress())

  assertHang(bootfs.exists("sec/bin/zero.lua"), "LEAVEINIT", "Process Zero not found in /sec/bin/zero.lua")

  local fh = bootfs.open("sec/bin/zero.lua", "r")
  local buffer = {}
  while true do
    local s = bootfs.read(fh, math.huge)
    if not s then break end
    buffer[#buffer+1] = s
  end
  bootfs.close(fh)

  local signalStream, signalStreamWrite = kobject.newStream()
  kobject.setLabel(signalStream, "Kernel Signal Stream")
  assert(proc.spawn(table.concat(buffer), "zero", {signalStream}))

  -- Recover some memory
  bootfs = nil
  buffer = nil
  fh = nil

  proc.run(function(pps, minWait)
    local signal = table.pack(computer.pullSignal(pps and 0 or minWait))
    if signal[1] then
      signalStreamWrite:send(signal)
    end
  end, signalStreamWrite)
end
