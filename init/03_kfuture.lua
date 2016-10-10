local objects = kobject.objects

--Kernel futures--
--Futures are callbacks, basically--
--They are kinda implemented like Streams, but they don't broadcast--

local Future = kobject.mt {
  __index = {threadSpawning = true},
  __type = "Future"
}

function Future.__index:init()
  kobject.checkType(self, Future)

  local data = objects[self].data

  if data.future then
    --os.logf("KFUTURE", "Deleting old future %s %d", data.future.object, objects[data.future.object].owner)
    kobject.delete(data.future.object) --delete older futures binded to the completer
  end

  --always overwrite previous future
  data.future = {
    object = self,
    callback = nil,
    errorHandler = nil
  }
end

function Future.__index:delete()
  kobject.checkType(self, Future)

  local data = objects[self].data

  --remove future from list
  data.future = nil
end

function Future.__index:after(callback, errorHandler)
  kobject.checkType(self, Future)
  checkArg(1, callback, "function")
  checkArg(2, errorHandler, "function", "nil")

  local data = objects[self].data

  if data.future.object == self then
    local completer, future = kobject.newFuture()
    data.future.callback = function(...)
      local t = table.pack(xpcall(callback, debug.traceback, ...))

      if kobject.isValid(completer) then --if the completer is still valid
        if t[1] then
          completer:complete(table.unpack(t, 2, t.n))
        else
          completer:error(t[2])
        end
      end
    end
    data.future.errorHandler = function(err)
      local nerr = errorHandler and errorHandler(err) or nil
      if nerr and kobject.isValid(completer) then
        completer:error(nerr)
      end
    end

    return future
  else
    return nil, "future replaced by cloned object"
  end
end

function Future.__index:notify(data)
  kobject.checkType(self, Future)

  kobject.notify(self, data)
end

function Future.__index:onNotification(d)
  kobject.checkType(self, Future)

  local data = objects[self].data
  if data.future and data.future.object == self then
    if d.type == "message" then
      if data.future.callback then
        proc.scheduleMicrotask(data.future.callback, d, objects[self].owner)
      end
    elseif d.type == "error" then
      if data.future.errorHandler then
        proc.scheduleMicrotask(data.future.errorHandler, d, objects[self].owner)
      else
        os.logf("KFUTURE", "Error in %s: %s", self, d[1])
      end
    end

    --os.logf("KFUTURE", "%s completed %d", self, objects[self].owner)
    data.future = nil
    if kobject.isValid(self) then --dont delete if the object is not valid
      kobject.delete(self)
    end
  end
end

local Completer = kobject.mt {
  __index = {},
  __type = "Completer"
}

function Completer.__index:complete(...)
  kobject.checkType(self, Completer)

  local message = table.pack(...)
  for i=1, message.n do
    kobject.checkMarshallable(i, message[i])
  end
  message.type = "message"

  if kobject.isA(message[1], Future) then
    message[1]:after(function(...)
      self:complete(...)
    end, function(err)
      self:error(err)
    end)
    return
  end

  local data = objects[self].data
  if data.future then
    data.future.object:notify(message)

    if kobject.isValid(self) then --dont delete if the object is not valid
      kobject.delete(self)
    end
    return true
  end

  if kobject.isValid(self) then
    kobject.delete(self)
  end

  return false, "endpoint not connected"
end

function Completer.__index:error(message)
  kobject.checkType(self, Completer)

  local data = objects[self].data
  if data.future then
    os.log("KFUTURE", message)
    data.future.object:notify({type = "error", message})
    if kobject.isValid(self) then --dont delete if the object is not valid
      kobject.delete(self)
    end
    return true
  end

  if kobject.isValid(self) then
    kobject.delete(self)
  end

  return false, "endpoint not connected"
end

function Completer.__index:assert(success, ...)
  kobject.checkType(self, Completer)

  if success then
    return self:complete(...)
  else
    return self:error(...)
  end
end

function kobject.newFuture()
  --creates a new kernel future--
  --this returns two objects: a completer and a future

  --os.logf("KFUTURE", "New future %s", debug.traceback())

  local c = kobject.new(Completer)
  local f = kobject.clone(c, Future)

  kobject.own(c)
  kobject.own(f)

  return c, f
end

--Completed Future--

local CompletedFuture = kobject.mt {
  __index = {},
  __type = "CompletedFuture",
  __extend = Future
}

function CompletedFuture.__index:init(...)
  kobject.checkType(self, CompletedFuture)

  local data = objects[self].data
  if not data.value then
    data.value = table.pack(...)
  end
end

function CompletedFuture.__index:after(callback)
  kobject.checkType(self, CompletedFuture)

  local data = objects[self].data

  local completer, future = kobject.newFuture()

  proc.scheduleMicrotask(function(...)
    local t = table.pack(xpcall(callback, debug.traceback, ...))

    if t[1] then
      completer:complete(table.unpack(t, 2, t.n))
    else
      completer:error(t[2])
    end

    kobject.delete(self)
  end, data.value, objects[self].owner)

  return future
end

function kobject.newCompletedFuture(...)
  --creates a new kernel completed future--

  local c = kobject.new(CompletedFuture, ...)

  kobject.own(c)

  return c
end
