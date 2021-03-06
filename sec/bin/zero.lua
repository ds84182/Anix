--zero.lua: Kernel's Advocate
--Manages:
  --API Calls
    --Pushing events from process to process
    --Kernel object creation
  --Process Spawning
  --OC Signal -> Events

zero = {}

local kernelSignalStream = ...

local signalStream, signalStreamOut = kobject.newStream()
kobject.setLabel(signalStream, "Signal Stream")

local processSpawnHandlers = {}
local processCleanupHandlers = {}

function zero.handleSignal(sig)
  --Morph signal stream here--
  if sig[1] == "process_death" then
    for _, func in pairs(processCleanupHandlers) do
      func(sig[2], sig[3])
    end
  end

  signalStreamOut:send(sig)
end

kernelSignalStream:listen(zero.handleSignal)

local bootfs = component.proxy(computer.getBootAddress())

do
  --ZeroAPI--
  zeroapi = {}

  function zeroapi.init()
    return true
  end

  function zeroapi.hello(pid)
    os.log("ZERO:API", "Hello invoked")
    return "world"
  end

  function zeroapi.log(pid, tag, ...)
    tag = tostring(tag).."/"..pid.."/"..proc.getProcessName(pid)
    os.log(tag, ...)
  end

  local processStreams = {}

  function zeroapi.signalstream(pid)
    if not processStreams[pid] then
      processStreams[pid] = signalStream:duplicate():where(function(sig)
        if sig[1] == "process_death" and sig[3] ~= pid then
          return false
        end

        return true
      end)
      kobject.setLabel(processStreams[pid], "ZeroAPI::SignalStream")
    end

    return processStreams[pid]:duplicate()
  end

  -- "dynamic" modules --

  local function loadMod(name)
    os.log("ZERO", "Loading mod_"..name)
    local fh = bootfs.open("sec/bin/zero/mod_"..name..".lua", "r")
    local buffer = {}
    while true do
      local s = bootfs.read(fh, math.huge)
      if not s then break end
      buffer[#buffer+1] = s
    end
    bootfs.close(fh)

    assert(load(table.concat(buffer), "=mod_"..name))(zeroapi, processSpawnHandlers, processCleanupHandlers)
  end

  loadMod "service"
  loadMod "perm"

  --Process API--

  function zeroapi.proc_spawn(pid, source, name, args, env, trustLevel, options)
    if not zeroapi.perm_query(pid, pid, "proc.spawn", true) then
      return nil, "Permission Denied"
    end

    if not env then
      env = proc.listEnv(nil, pid)
    end

    if not env.API then
      env.API = zero.apiClient
    end

    local spawnPID, err = proc.spawn(source, name, args, env, trustLevel, pid)

    if spawnPID then
      for _, func in pairs(processSpawnHandlers) do
        func(spawnPID, pid, options)
      end
    end

    return spawnPID, err
  end

  --Export--

  local functionList = {}
  for i, v in pairs(zeroapi) do functionList[i] = true end

  zero.apiExport, zero.apiClient = kobject.newExport(functionList, function(method, arguments, pid)
    return zeroapi[method](pid, table.unpack(arguments, 1, arguments.n))
  end)
  kobject.setLabel(zero.apiExport, "ZeroAPI")
end

--start filesystem service--

if not bootfs.exists("sec/bin/filesystem.lua") then
  os.log("ZERO", "Filesystem service not found in /sec/bin/filesystem.lua")
  return
end

async(function()
  os.log("ZERO", "Loading filesystem service")
  local a = os.clock()
  local fh = bootfs.open("sec/bin/filesystem.lua", "r")
  local buffer = {}
  while true do
    local s = bootfs.read(fh, math.huge)
    if not s then break end
    buffer[#buffer+1] = s
  end
  bootfs.close(fh)
  os.logf("ZERO", "%s ms", (os.clock()-a)*1000)
  assert(proc.spawn(table.concat(buffer), "filesystem", nil, {API = zero.apiClient}))

  local fs = await(zeroapi.service_await(0, "FS"))
  os.log("ZERO", "Loading startup processes")
  local a = os.clock()
  fs:invoke("open", "/sec/bin/startup.lua", "r"):after(makeAsync(function(handle)
    os.logf("ZERO", "%s ms", (os.clock()-a)*1000)
    local stream = await(fs:invoke("readAsStream", handle, math.huge))
    stream:join():after(function(source)
      os.logf("ZERO", "%s ms", (os.clock()-a)*1000)
      assert(proc.spawn(source, "startup", nil, {API = zero.apiClient}))
      fs:invoke("close", handle)
    end)
  end))
end)
