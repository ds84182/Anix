--filesystem.lua: Broker access to files by using a Kernel Export
  -- This is also in charge of filesystem permissions
  -- zero's mod_perm asks this service if a process can modify a file

local fs = {}

--filesystem manages ONLY file access
--no fancy functions like concat and stuff are implemented here

--we create an internal object like kexports to manage component mounts
--the internal object and kexports are basically alike

local ComponentObject = {
  __index = {}
}

function ComponentObject.__index:init(address)
  self.address = address
end

function ComponentObject.__index:invoke(method, ...)
  return async(component.invoke, self.address, method, ...)
end

function ComponentObject.__index:isDisconnected()
  return component.get(self.address) == nil
end

----

local mounts = {}

local function splitPath(path)
  local pt = {}
  for p in path:gmatch("[^/]+") do
    if p == ".." then
      pt[#pt] = nil
    elseif p ~= "." and p ~= "" then
      pt[#pt+1] = p
    end
  end
  return pt
end

local function combine(...)
  local np = {}
  for i, v in ipairs(table.pack(...)) do
    checkArg(i, v, "string")
    for i, v in ipairs(splitPath(v)) do
      np[#np+1] = v
    end
  end
  return "/"..table.concat(np,"/")
end

local function fixPath(path)
  checkArg(1, path, "string")
  local sp = splitPath(path)
  return "/"..table.concat(sp,"/"), sp
end

local function childOf(parent,child)
  local parent, sparent = filesystem.fixPath(parent)
  local child, schild = filesystem.fixPath(child)
  return child:sub(1,#parent) == parent, #schild-#sparent, schild, sparent
end

local function canModify(path)
  --[[if not ps.isKernelMode() then
    local allow,levelsDeep = false,#splitPath(path)
    for i, v in pairs(config.filesystem.allowed) do
      local ischild, levels = filesystem.childOf(v,path)
      if ischild and levelsDeep > levels then
        levelsDeep = levels
        allow = true
      end
    end
    for i, v in pairs(config.filesystem.disallowed) do
      local ischild, levels = filesystem.childOf(v,path)
      if ischild and levelsDeep > levels then
        levelsDeep = levels
        allow = false
      end
    end
    return allow
  end]]
  return true
end

local function getMountAndPath(path, pid)
  if path:sub(1,1) ~= "/" then
    if not pid then
      os.logf("FS", "Relative path %s used outside of a process context?", path)
    else
      local workdir = proc.getEnv("PWD", pid)
      if type(workdir) ~= "string" then
        workdir = ""
      end

      path = combine(workdir, path)
    end
  end

  local spath
  path,spath = fixPath(path)
  if mounts[path] then
    return mounts[path], "/"
  else
    for i=#spath-1, 1, -1 do
      local npath = "/"..table.concat({table.unpack(spath,1,i)},"/")
      if mounts[npath] then
        return mounts[npath], "/"..table.concat({table.unpack(spath,i+1)},"/")
      end
    end
  end
  return mounts["/"], path
end

function fs.mount(pid, path, object)
  --pid needs to be trusted (<= 1000)
  --path can be anything
  --object can either be a component address, or an kExport

  if proc.isTrusted(pid) then
    checkArg(1, path, "string")
    checkArg(2, object, "table", "string")

    if type(object) == "string" then
      local cobject = setmetatable({}, ComponentObject)
      cobject:init(object)
      object = cobject
    end

    local spath
    path,spath = fixPath(path)
    --if not canModify(path) then return false, "permission denied" end
    if mounts[path] then return false, "another filesystem is already mounted here" end
    mounts[path] = object
    os.logf("FS", "Mounted filesystem at %s", path)
    return true
  else
    return false, "process not trusted"
  end
end

function fs.unmount(pid, path)
  if proc.isTrusted(pid) then
    checkArg(1, path, "string")
    --if not filesystem.canModify(path) then return false, "permission denied" end
    mounts[fixPath(path)] = nil
    os.logf("FS", "Unmounted filesystem at %s", path)
    return true
  else
    return false, "process not trusted"
  end
end

local fileHandles = {}
local kHandleReferences = {}
--fileHandles contain per process file handles.
--They return kHandle objects
--kHandles return constant ids that are ensured random
--Also, since kHandle ids cannot change, kHandles are trusted with the integer id they have

function fs.open(pid, path, mode)
  checkArg(1, path, "string")
  mode = mode or "r"
  checkArg(2, mode, "string", "nil")

  local mount, subpath = getMountAndPath(path, pid)

  local fh, err = await(mount:invoke("open", subpath))

  if fh then
    local handle = kobject.newHandle()

    fileHandles[handle:getId()] = {handle = fh, mount = mount, path = path, subpath = subpath, owner = pid}
    kHandleReferences[handle] = true

    return handle
  else
    return nil, err
  end
end
fs.open = makeAsync(fs.open)

function fs.getHandleInfo(pid, handle)
  kobject.checkType(handle, "Handle")

  local handleRef = fileHandles[handle:getId()]

  return {
    path = handleRef.path,
    subpath = handleRef.subpath,
    owner = handleRef.owner
  }
end

function fs.read(pid, handle, bytes)
  kobject.checkType(handle, "Handle")
  bytes = bytes or math.huge
  checkArg(2, bytes, "number", "nil")

  local handleRef = fileHandles[handle:getId()]

  return await(handleRef.mount:invoke("read", handleRef.handle, bytes))
end
fs.read = makeAsync(fs.read)

--TODO: Should this be exported here?
--This spawns a new thread internal to the filesystem, but we could make
--a kapi version that spawns it inside it's own process instead of ours
function fs.readAsStream(pid, handle, blockSize)
  kobject.checkType(handle, "Handle")
  checkArg(2, blockSize, "number", "nil")

  blockSize = blockSize or math.huge

  local handleRef = fileHandles[handle:getId()]
  local readStream, writeStream = kobject.newStream()
  kobject.setLabel(readStream, "Read Stream for "..handleRef.path)

  async(function()
    while true do
      local bytes = await(fs.read(pid, handle, blockSize))

      if bytes then
        writeStream:send(bytes)
      else
        break
      end
    end
    writeStream:close()
  end) --, "read_stream_"..handleRef.path.."_"..handle:getId())

  return readStream
end

function fs.write(pid, handle, bytes)
  kobject.checkType(handle, "Handle")
  checkArg(2, bytes, "string")

  local handleRef = fileHandles[handle:getId()]

  return await(handleRef.mount:invoke("write", handleRef.handle, bytes))
end
fs.write = makeAsync(fs.write)

function fs.close(pid, handle)
  kobject.checkType(handle, "Handle")

  local handleRef = fileHandles[handle:getId()]

  await(handleRef.mount:invoke("close", handleRef.handle))

  fileHandles[handle:getId()] = nil
  for khandle in pairs(kHandleReferences) do
    if khandle:getId() == handle:getId() then
      kHandleReferences[khandle] = nil
      break
    end
  end

  return true
end
fs.close = makeAsync(fs.close)

function fs.exists(pid, path)
  checkArg(1, path, "string")

  local mount, subpath = getMountAndPath(path, pid)

  return await(mount:invoke("exists", subpath))
end
fs.exists = makeAsync(fs.exists)

function fs.list(pid, path)
  checkArg(1, path, "string")

  local mount, subpath = getMountAndPath(path, pid)

  return await(mount:invoke("list", subpath))
end
fs.list = makeAsync(fs.list)

--Init:

fs.mount(proc.getCurrentProcess(), "/", computer.getBootAddress())

--[=[fs.open(ps.getCurrentProcess(), "/init.lua", "r"):after(function(handle)
  fs.read(ps.getCurrentProcess(), handle, 8):after(function(bytes)
    os.logf("FS", "First 8 bytes of init.lua: %s", bytes)
    fs.close(ps.getCurrentProcess(), handle)
  end)
end)

fs.open(ps.getCurrentProcess(), "/sec/etc/startup", "r"):after(function(handle)
  fs.readAsStream(ps.getCurrentProcess(), handle, 8):join():after(function(entire)
    os.logf("FS", "%s", entire)
    fs.close(ps.getCurrentProcess(), handle)
  end)

  --[[:listen(function(bytes)
    os.logf("FS", "%s", bytes)
  end):onClose(function()
    fs.close(ps.getCurrentProcess(), handle)
    os.log("FS", "Closed")
  end)]]
end)]=]

async(function()
  while true do
    sleep(10)
    for handle in pairs(kHandleReferences) do
      if not handle:hasOthers() then
        os.logf("FS", "Closing unclosed handle %s", fileHandles[handle:getId()].path)
        fs.close(proc.getCurrentProcess(), handle)
      end
    end
  end
end)

--Service Exporting:

local functionList = {}
for i, v in pairs(fs) do functionList[i] = true end

local serviceExport, serviceExportClient = kobject.newExport(functionList, function(method, arguments, pid)
  return fs[method](pid, table.unpack(arguments))
end)
kobject.setLabel(serviceExport, "Service::FS")

service.registerGlobal("FS", serviceExportClient)
