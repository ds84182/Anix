--inet: manages internet interfaces
--If you want to sandbox a process, look into using a dummy INET service, or a whole new ZEROAPI implementation
--the default interface is card0

--[[
inet.isAvailable():after(function(avail)
	if avail then
		local handle = await(inet.request("http://example.com"))
		inet.readAsStream(handle, math.huge):join():after(print)
	end
end)
]]

--[[
local cardName = await(inet.registerInterface("dummy", export))
cardName == "dummy"..(number from 0 to inf)
]]

--[[
local interfaceHandle = await(inet.getInteface("card1"))
inet.requestOn(interfaceHandle, "http://example.com")
inet.connectOn(interfaceHandle, "irc.esper.net", 6667)
]]

function debug(...)
	os.logf("INET", ...)
end

local dev = require "dev"

local interfaces = {}
local handles = {}
local nextInterfaceID = {}

local function getNextInterfaceName(name)
	if nextInterfaceID[name] then
		local id = nextInterfaceID[name]
		nextInterfaceID[name] = id+1
		return name..id
	else
		nextInterfaceID[name] = 1
		return name.."0"
	end
end

local function addInterface(name, object)
	interfaces[name] = object
end

local function removeInterface(name)
	interfaces[name] = nil
end

local function request(interfaceName, url, data, headers)
	checkArg(1, interfaceName, "string")
	checkArg(2, url, "string")
	checkArg(3, data, "string", "table", "nil")
	checkArg(4, headers, "table", "nil")
	
	local interface = interfaces[interfaceName]
	
	if not interface then
		error("Interface not found ("..interfaceName..")")
	end
	
	local post
	if type(data) == "string" then
		post = data
	elseif data then
		for k, v in pairs(data) do
			post = post and (post.."&") or ""
			post = post..tostring(k).."="..tostring(v)
		end
	end
	
	return interface:invoke("request", url, data, headers):after(function(requestHandle)
		handles[requestHandle] = {
			handle = requestHandle,
			interface = interface,
			url = url
		}
		return requestHandle
	end)
end

local function read(handle, count)
	kobject.checkType(handle, "Handle")
	checkArg(2, count, "number", "nil")
	
	local handleData = handles[handle]
	
	assert(handleData, "unknown handle")
	
	return handleData.interface:invoke("read", handle, count or math.huge)
end

local function response(handle)
	kobject.checkType(handle, "Handle")
	
	local handleData = handles[handle]
	
	assert(handleData, "unknown handle")
	
	return handleData.interface:invoke("response", handle)
end

local function write(handle, data)
	kobject.checkType(handle, "Handle")
	checkArg(2, data, "string")
	
	local handleData = handles[handle]
	
	assert(handleData, "unknown handle")
	
	return handleData.interface:invoke("write", handle, data)
end

local function close(handle)
	kobject.checkType(handle, "Handle")
	
	local handleData = handles[handle]
	
	assert(handleData, "unknown handle")
	
	return handleData.interface:invoke("close", handle):after(function(s)
		if s then
			handles[handle] = nil
		end
		
		return s
	end)
end

--we create an internal object like kexports to manage component mounts
--the internal object and kexports are basically alike

--TODO: Put all component calls over to the dev process

local ComponentObject = {
	__index = {}
}

function ComponentObject.__index:init(address)
	self.address = address
	self.handleToObject = {}
	return self
end

function ComponentObject.__index:invoke(method, ...)
	local completer, future = kobject.newFuture()
	
	if method == "request" or method == "connect" then
		local obj, err
		proc.createThread(function(...)
			obj, err = component.invoke(self.address, method, ...)
			completer:complete(true)
		end, nil, table.pack(...))
		
		--create a handle
		future = future:after(function()
			if not obj then error(err, 0) end
			
			local handle = kobject.newHandle()
			self.handleToObject[handle] = obj
			
			return handle
		end)
	elseif method == "read" then
		local handle, count = ...
		local object = self.handleToObject[handle]
		
		proc.createThread(function()
			completer:complete(object:read(count or math.huge))
		end, nil, nil)
	elseif method == "response" then
		local handle = ...
		local object = self.handleToObject[handle]
		
		proc.createThread(function()
			completer:complete(object:response())
		end, nil, nil)
	elseif method == "write" then
		local handle, data = ...
		local object = self.handleToObject[handle]
		
		proc.createThread(function()
			while #data > 0 do
				local count = object:write(data)
				if count < #data then
					data = data:sub(count+1)
				else
					break
				end
			end
			
			completer:complete(true)
		end, nil, nil)
	elseif method == "close" then
		local handle = ...
		local object = self.handleToObject[handle]
		
		proc.createThread(function()
			object:close()
			self.handleToObject[handle] = nil
			completer:complete(true)
		end, nil, nil)
	end
	
	return future
end

function ComponentObject.__index:isDisconnected()
	return component.get(self.address) == nil
end

local componentToInterfaceName = {}

local function addComponentInterface(addr)
	local name = getNextInterfaceName "component"
	
	debug("Adding component %s as interface %s", addr, name)
	
	addInterface(name, setmetatable({}, ComponentObject):init(addr))
	componentToInterfaceName[addr] = name
end

for addr in component.list("internet", true) do
	addComponentInterface(addr)
end

dev.onComponentAdded "internet" :listen(function(addr)
	addComponentInterface(addr)
end)

dev.onComponentRemoved "internet" :listen(function(addr)
	if interfaces[componentToInterfaceName[addr]] then
		removeInterface(componentToInterfaceName[addr])
	end
	
	componentToInterfaceName[addr] = nil
end)

request("component0", "http://example.com"):after(function(handle)
	debug("Request opened %s", handle)
	local bytes = await(read(handle, 8))
	debug("First 8 bytes %s", bytes)
	await(close(handle))
	debug("Closed")
end)

-- export api --

local inet = {}

function inet.addInterface(pid, name, object)
	if not proc.isTrusted(pid) then
		error("Permission Denied")
	end
	
	name = getNextInterfaceName(name)
	
	addInterface(name, object)
	
	return name
end

function inet.removeInterface(pid, name)
	if not proc.isTrusted(pid) then
		error("Permission Denied")
	end
	
	removeInterface(name)
	
	return true
end

function inet.request(pid, interface, url, data, headers)
	return await(request(interface, url, data, headers))
end

function inet.read(pid, handle, count)
	return await(read(handle, count))
end

function inet.response(pid, handle)
	return await(response(handle))
end

function inet.write(pid, handle, data)
	return await(write(handle, data))
end

function inet.close(pid, handle)
	return await(close(handle))
end

--Service Exporting:

local functionList = {}
for i, v in pairs(inet) do functionList[i] = true end

local serviceExport, serviceExportClient = kobject.newExport(functionList, function(method, arguments, pid)
	return inet[method](pid, table.unpack(arguments))
end)
kobject.setLabel(serviceExport, "Service::INET")

service.registerGlobal("INET", serviceExportClient)
