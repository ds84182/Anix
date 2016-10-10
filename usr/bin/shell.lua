async(function()

local term = require "term"
local io = require "io"
local path = require "path"

term.debug = true
io.debug = true

print("Totally a shell v0.0")

local deathStream = await(getSignalStream()):where(function(sig) return sig[1] == "process_death" end)

local function execute(path, args)
  local handle, err = await(fs.open(path, "r"))
  if handle then
    local source = await(fs.readAsStream(handle, math.huge):join())
    fs.close(handle)
    local pid, err = await(proc.spawn(source, path:match("/?([^/]+)$"):gsub("%.lua$", ""), args))

    if not pid then
      printf("Error while starting %s: %s", path, err)
    else
      --TODO: We need Broadcast Streams!
      await(deathStream:duplicate():firstWhere(function(sig)
        local reason = sig[4]

        if reason and not reason.peaceful then
          print(reason.error)
        end

        return sig[2] == pid
      end))
    end
  else
    printf("Error while starting %s: %s", path, err)
  end
end

local shellFunc = {}

function shellFunc.get(what, a, b, c)
  if what == "trustlevel" then
    local pid = tonumber(a)

    print(proc.getTrustLevel(pid))
  elseif what == "process" or what == "processes" then
    local list = proc.listProcesses()

    print((#list).." process(es) running")

    for i=1, #list do
      local info = proc.getProcessInfo(list[i])

      printf("  %s pid %d trustLevel %d nkobj %d nthreads %d",
        info.name, info.id, info.trustLevel, info.kernelObjectCount, info.threadCount)
    end
  elseif what == "kobjects" or what == "kernelObjects" then
    local pid = tonumber(a)

    if pid and not proc.isTrusted() then
      print("Shell needs to be trusted in order to query kernel objects for other processes")
    end

    local objects = proc.getProcessKernelObjects(pid)

    for _, object in pairs(objects) do
      print("  "..tostring(object))
    end
  elseif what == "services" then
    local list = await(service.list(a))

    for _, name in pairs(list) do
      print("  "..name)
    end
  elseif what == "perm" then
    local target, p = a, b
    local result, reason = await(perm.query(target, p))
    print(tostring(result).." "..tostring(reason))
  else
    print("Unknown parameter "..what)
  end
end

function shellFunc.set(what, a, b, c)
  if what == "perm" then
    local target, p, val = a, b, c

    if val == "true" then
      val = true
    elseif val == "false" then
      val = false
    else
      val = nil
    end

    local result, reason = await(perm.set(target, p, val))
    print(tostring(result).." "..tostring(reason))
  else
    print("Unknown parameter "..what)
  end
end

function shellFunc.cd(to)
  local cwd = path.fixPath(proc.getEnv("PWD") or "")
  to = path.fixPath(to)
  if path.isAbsolute(to) then
    proc.setEnv("PWD", to)
  else
    proc.setEnv("PWD", path.combine(cwd, to))
  end
end

if not proc.getEnv("PATH") then
  proc.setEnv("PATH", "/sec/bin/?;/sec/bin/?.lua;/usr/bin/?;/usr/bin/?.lua;./?;./?.lua")
end

local function split(line, pattern)
  local tab = {}

  for s in line:gmatch("([^"..pattern.."]+)") do
    tab[#tab+1] = s
  end

  return tab
end

local function findBinaryPath(path)
  if await(fs.exists(path)) then
    return path
  end

  local found = false
  local failed = 0
  local count = 0
  local completer, future = kobject.newFuture()

  for binaryPath in proc.getEnv("PATH"):gmatch("[^;]+") do
    count = count+1
    binaryPath = binaryPath:gsub("%?", path)

    fs.exists(binaryPath):after(function(exists)
      if exists then
        if not found then
          completer:complete(binaryPath)
          found = true
        end
      else
        failed = failed+1

        if failed == count then
          completer:complete(nil)
        end
      end
    end)
  end

  return await(future)
end

while true do
  io.write(proc.getEnv("PWD") or "/")
  io.write "> "
  local line = await(io.read("*l"))
  print()
  yield() --let the screen flush

  local list = split(line, " ")
  local commandName = table.remove(list, 1)
  local func = shellFunc[commandName]

  if func then
    func(table.unpack(list))
  else
    local bin = findBinaryPath(commandName)
    if bin then
      execute(bin, list)
    else
      print("Unknown Command: "..line)
    end
  end
end

end)
