local term = {}

--we create an internal object like kexports to manage component mounts
--the internal object and kexports are basically alike

local boundComponentList = {}

local ComponentObject = {
	__index = {}
}

function ComponentObject.__index:init(address)
	self.address = address
	
	local screen = await(self:invoke("getScreen"))
	
	if not screen then
		--bind a screen, any screen--
		for address in component.list("screen", true) do
			local invalid = false
			for _, object in pairs(boundComponentList) do
				if object.screen == address then
					invalid = true
					break
				end
			end
			
			if not invalid then
				self.screen = address
				await(self:invoke("bind", self.screen))
				break
			end
		end
	else
		self.screen = screen
	end
end

function ComponentObject.__index:invoke(method, ...)
	local completer, future = kobject.newFuture()
	
	proc.createThread(function(...)
		completer:complete(component.invoke(self.address, method, ...))
	end, nil, table.pack(...))
	
	return future
end

function ComponentObject.__index:isDisconnected()
	return component.get(self.address) == nil
end

----

local handles = {}
local terminalState = {}
local boundList = {}

local function startTerminalHandlerThread(state)
	return proc.createThread(function()
		local completer, future = kobject.newFuture()
		
		local cursorOn = false
		local char
	
		state.stream:listen(function(event)
			os.logf("HANDLER", event.type)
			if event.type == "set_blink" then
				state.cursorBlink = event.blink
				completer:complete()
				completer, future = kobject.newFuture()
			elseif event.type == "move_cursor" then
				if cursorOn then
					await(state.gpu:invoke("set", state.cursorX, state.cursorY, char))
					cursorOn = false
				end
				
				state.cursorX = event.x
				state.cursorY = event.y
			elseif event.type == "write" then
				if cursorOn then
					await(state.gpu:invoke("set", state.cursorX, state.cursorY, char))
					cursorOn = false
				end
				
				local old = state.cursorBlink
				state.cursorBlink = false
				await(state.gpu:invoke("set", state.cursorX, state.cursorY, event.text))
				state.cursorBlink = old
				
				state.cursorX = state.cursorX+#event.text
			end
		end)
		
		while true do
			if state.cursorBlink then
				cursorOn = not cursorOn
				if cursorOn then
					char = await(state.gpu:invoke("get", state.cursorX, state.cursorY))
					await(state.gpu:invoke("set", state.cursorX, state.cursorY, "_"))
				else
					await(state.gpu:invoke("set", state.cursorX, state.cursorY, char))
				end
				
				await(future, 0.5)
			else
				if cursorOn then
					await(state.gpu:invoke("set", state.cursorX, state.cursorY, char))
					cursorOn = false
				end
				
				await(future)
			end
		end
	end, "terminal_handler_"..state.name)
end

function term.add(pid, name, object)
	checkArg(1, name, "string")
	checkArg(2, object, "table", "string")
	
	if handles[name] then
		return nil, "handle name already taken"
	end
	
	if type(object) == "string" then
		if boundComponentList[object] then
			return nil, "already added"
		end
		
		local cobject = setmetatable({}, ComponentObject)
		cobject:init(object)
		object = cobject
		
		boundComponentList[object.address] = object
	else
		if boundList[object] then
			return nil, "already added"
		end
		
		boundList[object] = true
	end
	
	local handle = kobject.newHandle()
	handles[name] = handle
	local rs, ws = kobject.newStream()
	terminalState[handle:getId()] = {
		cursorX = 1, cursorY = 1, cursorBlink = true,
		gpu = object, handle = handle, name = name, stream = rs, events = ws
	}
	terminalState[handle:getId()].thread = startTerminalHandlerThread(terminalState[handle:getId()])
	
	return handle
end

function term.remove(pid, handle)
	
end

function term.get(pid, name)
	checkArg(1, name, "string")
	return handles[name]
end

function term.write(pid, handle, str)
	kobject.checkType(handle, "Handle")
	str = tostring(str)
	
	local state = terminalState[handle:getId()]
	
	if state then
		state.events:send({type = "write", text = str})
	end
end

--Init:

local gpu = component.list("gpu", true)()

if gpu then
	local handle = term.add(proc.getCurrentProcess(), "main", gpu)
	os.logf("TERM", "Handle %s", handle)
	term.write(proc.getCurrentProcess(), handle, "Terminal is working!")
end

--Service Exporting:

local functionList = {}
for i, v in pairs(term) do functionList[i] = true end

local serviceExport, serviceExportClient = kobject.newExport(functionList, function(method, arguments, pid)
	return term[method](pid, table.unpack(arguments))
end)
kobject.setLabel(serviceExport, "Service::TERM")

service.registerGlobal("TERM", serviceExportClient)
