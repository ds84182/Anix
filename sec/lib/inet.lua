local inet = {}

inet.debug = false

local ready = false
local srv = nil
local currentInterface = nil

local function debug(...)
  if inet.debug then os.logf("INETLIB", ...) end
end

local waitInit

function inet.init()
  --TODO: kSignalQueue would be GREAT here
  if not waitInit then
    local completer, future = kobject.newFuture()
    waitInit = future

    debug("Getting service")
    srv = await(service.get "INET")

    if not srv then
      debug("Service not found!")
      debug("Waiting for service...")
      srv = await(await(service.await "INET"))
    end

    ready = true
    debug("Ready!")

    inet.switch(proc.getEnv "INET_INTERFACE" or await(inet.listInterfaces())[1])

    completer:complete()
    waitInit = nil
  else
    local oldWaitInit = waitInit
    local completer, future = kobject.newFuture()
    waitInit = future

    await(oldWaitInit)
    completer:complete()
  end
end

----

function inet.switch(newInterface)
  local oldInterface = currentInterface
  debug("Switching interface %s for %s", oldInterface, newInterface)
  currentInterface = newInterface
  return oldInterface
end

function inet.addInterface(name, export)
  if not ready then
    inet.init()
  end

  return srv:invoke("addInterface", name, export)
end

function inet.removeInterface(name)
  if not ready then
    inet.init()
  end

  return srv:invoke("removeInterface", name)
end

function inet.listInterfaces()
  if not ready then
    inet.init()
  end

  return srv:invoke("listInterfaces")
end

function inet.request(url, data, headers)
  if not ready then
    inet.init()
  end

  return srv:invoke("request", currentInterface, url, data, headers)
end

function inet.requestOn(interface, url, data, headers)
  if not ready then
    inet.init()
  end

  return srv:invoke("request", interface, url, data, headers)
end

function inet.read(handle, count)
  if not ready then
    inet.init()
  end

  return srv:invoke("read", handle, count)
end

function inet.response(handle)
  if not ready then
    inet.init()
  end

  return srv:invoke("response", handle)
end

function inet.write(handle, data)
  if not ready then
    inet.init()
  end

  return srv:invoke("write", handle, data)
end

function inet.close(handle)
  if not ready then
    inet.init()
  end

  return srv:invoke("close", handle)
end

return inet
