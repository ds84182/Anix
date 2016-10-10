local objects = kobject.objects

--Kernel exports--
--Objects that can export functions to another process--

--Example: Kernel exports can be used as a means to have a decent way to export services using the service API

local ExportClient = kobject.mt {
  __index = {},
  __type = "ExportClient"
}

function ExportClient.__index:init()
  kobject.checkType(self, ExportClient)
end

function ExportClient.__index:initClone()
  kobject.checkType(self, ExportClient)
end

function ExportClient.__index:delete()
  kobject.checkType(self, ExportClient)
end

function ExportClient.__index:invoke(method, ...)
  kobject.checkType(self, ExportClient)

  local data = objects[self].data

  if data.disconnected then
    error("export client disconnected", 2)
  end

  --api: {method = "name", arguments = {}, reply = Completer}

  local completer, future = kobject.newFuture()
  kobject.setLabel(completer, "kexport_client_"..method)

  data.waiting[#data.waiting+1] = {
    data = kobject.copyFor(data.export, {
      method = method,
      arguments = table.pack(...),
      reply = completer
    }),
    source = proc.getCurrentProcess()
  }
  data.export:notify()

  if not kobject.hasSameOwners(completer, data.export) then
    kobject.delete(completer) --delete the completer since we gave it to the export already
  end

  return future
end

function ExportClient.__index:isDisconnected()
  kobject.checkType(self, ExportClient)

  local data = objects[self].data

  return data.disconnected
end

local Export = kobject.mt {
  __index = {
    --async = true,
    notMarshallable = true,
    threadSpawning = true
  },
  __type = "Export"
}

function Export.__index:init(methods, handler)
  kobject.checkType(self, Export)

  local data = objects[self].data

  if not data.handler then
    data.methods = methods
    data.handler = handler
    data.waiting = {}
    data.export = self
    data.disconnected = false
  end
end

function Export.__index:close()
  kobject.delete(self)
end

function Export.__index:delete()
  local data = objects[self].data

  data.disconnected = true
end

function Export.__index:update()
  kobject.checkType(self, Export)

  local data = objects[self].data

  local messageCountdown = 60 --process 60 messages before stopping
  while data.waiting[1] and messageCountdown > 0 do
    messageCountdown = messageCountdown-1
    local message = table.remove(data.waiting, 1)
    --os.logf("RS", "Receive message %s", message)

    if data.handler then
      proc.scheduleMicrotask(function()
        local ret = table.pack(xpcall(data.handler, debug.traceback, message.data.method, message.data.arguments, message.source))

        if ret[1] then
          if kobject.isA(ret[2], "Future") then
            ret[2]:after(function(...)
              message.data.reply:complete(...)
            end, function(err)
              message.data.reply:error(err)
            end)
          else
            message.data.reply:complete(table.unpack(ret, 2, ret.n))
          end
        else
          message.data.reply:error(ret[2])
        end
      end, {}, objects[self].owner)
    end
  end
end

function Export.__index:notify()
  kobject.checkType(self, Export)

  kobject.notify(self)
end

function Export.__index:onNotification()
  kobject.checkType(self, Export)

  self:update()
end

function kobject.newExport(methods, handler)
  if not kobject.isMarshallable(methods) then return false, "method list not marshallable" end

  local export = kobject.new(Export, methods, handler)
  local client = kobject.clone(export, ExportClient)

  kobject.own(export)
  kobject.own(client)

  return export, client
end
