--OS Name List:
--Securos (BETTER NAME PENDING)
--Midore (M'Dory *tips fin*)
--AsyncOS (Buut it sounds terrible)
--AOS (Shortened AsyncOS)
--<nxsupert> Just think of 3 random letters and stick os on the end.
  --Alrighty.
  --finos
  --dilos :)
  --rekos
--Anix. Not to be confused with Anus or Unix. Anix.

local err
local s,e = xpcall(function()

function hang()
  while true do computer.pullSignal() end
end

function assertHang(c, ...)
  if not c then
    os.logf(...)
    hang()
  end
end

--LOGGING--
do
  local ocemucomponent = component.list("ocemu")[1]

  if ocemucomponent then
    computer.log = component.proxy(ocemucomponent).log
  elseif not computer.log then
    function computer.log() end
    computer.notNativeLogging = true
    os.logfilter = {} --disable logging
  end

  function os.log(tag, ...)
    if os.logfilter == nil or os.logfilter[tag] then
      computer.log("["..tag.."]", ...)
    end
  end

  function os.logf(tag, format, ...)
    if os.logfilter == nil or os.logfilter[tag] then
      computer.log("["..tag.."]", format:format(...))
    end
  end

  os.log("INIT", "Logging functions added")
end

--BOOT FILESYSTEM--
local bootfs = component.proxy(computer.getBootAddress())

assertHang(bootfs, "INIT", "Boot Filesystem not found!")
assertHang(bootfs.exists("init"), "INIT", "Boot Initialization Files not found!")

local list = bootfs.list("init")
table.sort(list)
for i=1, #list do
  local name = list[i]

  if name:sub(1,1) ~= "_" then
    os.logf("INIT", "Loading %s...", name)
    local fh = bootfs.open("init/"..name, "r")
    local buffer = {}
    while true do
      local s = bootfs.read(fh, math.huge)
      if not s then break end
      buffer[#buffer+1] = s
    end
    bootfs.close(fh)

    local f, e = load(table.concat(buffer), "="..list[i])
    assertHang(f, "INIT", e)
    local s, e = pcall(f)
    assertHang(s, "INIT", e)
  end
end

assertHang(LeaveINIT, "INIT", "LeaveINIT not defined!")

LeaveINIT()

--ERROR HANDLING--
end,function(e) err = debug.traceback(e,2) end)

if err then
  --depending on how setup we are we can opt to multiple ways of logging a kernel panic--
  if os.log then
    os.log("PANIC", err)
  elseif not computer.notNativeLogging then
    computer.log("PANIC", err)
  else --TODO: Maybe test to see if a gpu is available first?
    error(err,0)
  end

  --hang the computer to prevent further panic stuff--
  while true do
    computer.pullSignal(math.huge)
  end
end
