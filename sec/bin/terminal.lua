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
		
		local function processEvent(event)
			if event.type == "set_blink" then
				state.cursorBlink = event.blink
				--[[completer:complete()
				completer, future = kobject.newFuture()]]
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
				
				char = await(state.gpu:invoke("get", state.cursorX, state.cursorY))
			elseif event.type == "put" then
				if cursorOn then
					await(state.gpu:invoke("set", state.cursorX, state.cursorY, char))
					cursorOn = false
				end
				
				local old = state.cursorBlink
				state.cursorBlink = false
				await(state.gpu:invoke("set", event.x, event.y, event.text))
				state.cursorBlink = old
				
				char = await(state.gpu:invoke("get", state.cursorX, state.cursorY))
			elseif event.type == "copy" then
				if cursorOn then
					await(state.gpu:invoke("set", state.cursorX, state.cursorY, char))
					cursorOn = false
				end
				
				local old = state.cursorBlink
				state.cursorBlink = false
				await(state.gpu:invoke("copy", event.x, event.y, event.width, event.height, event.destx-event.x, event.desty-event.y))
				state.cursorBlink = old
				
				char = await(state.gpu:invoke("get", state.cursorX, state.cursorY))
			end
		end
	
		state.stream:listen(function(event)
			state.mutex:performAtomic(processEvent, event)
			
			if event.done then
				event.done:complete()
			end
		end)
		
		while true do
			state.mutex:awaitLock()
			if state.cursorBlink then
				if not cursorOn then
					char = await(state.gpu:invoke("get", state.cursorX, state.cursorY))
					await(state.gpu:invoke("set", state.cursorX, state.cursorY, "_"))
					cursorOn = true
				else
					await(state.gpu:invoke("set", state.cursorX, state.cursorY, char))
					cursorOn = false
				end
				
				state.mutex:unlock()
				await(future, 0.5)
			else
				if cursorOn then
					await(state.gpu:invoke("set", state.cursorX, state.cursorY, char))
					cursorOn = false
				end
				
				state.mutex:unlock()
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
		gpu = object, handle = handle, name = name, stream = rs, events = ws,
		mutex = kobject.newMutex()
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

function term.setCursor(pid, handle, x, y)
	kobject.checkType(handle, "Handle")
	checkArg(2, x, "number")
	checkArg(3, y, "number")
	
	local state = terminalState[handle:getId()]
	
	if state then
		state.events:send({type = "move_cursor", x = x, y = y})
	end
end

function term.getCursor(pid, handle)
	kobject.checkType(handle, "Handle")
	
	local state = terminalState[handle:getId()]
	
	if state then
		local completer, future = kobject.newFuture()
		state.events:send({type = "sync", done = completer})
		return future:after(function()
			return state.cursorX, state.cursorY
		end)
	end
end

function term.setCursorBlink(pid, handle, blink)
	kobject.checkType(handle, "Handle")
	checkArg(2, blink, "boolean")
	
	local state = terminalState[handle:getId()]
	
	if state then
		state.events:send({type = "set_blink", blink = blink})
	end
end

function term.getCursorBlink(pid, handle)
	kobject.checkType(handle, "Handle")
	
	local state = terminalState[handle:getId()]
	
	if state then
		local completer, future = kobject.newFuture()
		state.events:send({type = "sync", done = completer})
		return future:after(function()
			return state.cursorBlink
		end)
	end
end

function term.getSize(pid, handle)
	kobject.checkType(handle, "Handle")
	
	local state = terminalState[handle:getId()]
	
	if state then
		return state.gpu:invoke("getResolution")
	end
end

function term.write(pid, handle, str)
	kobject.checkType(handle, "Handle")
	str = tostring(str)
	
	local state = terminalState[handle:getId()]
	
	if state then
		state.events:send({type = "write", text = str})
	end
end

function term.put(pid, handle, x, y, str)
	kobject.checkType(handle, "Handle")
	str = tostring(str)
	
	local state = terminalState[handle:getId()]
	
	if state then
		state.events:send({type = "put", x = x, y = y, text = str})
	end
end

function term.copy(pid, handle, x, y, width, height, destx, desty)
	kobject.checkType(handle, "Handle")
	
	local state = terminalState[handle:getId()]
	
	if state then
		state.events:send({type = "copy", x = x, y = y, width = width, height = height, destx = destx, desty = desty})
	end
end

function term.read(pid, handle, signalStream, history, tabResolver, pwchar)
	kobject.checkType(handle, "Handle")
	kobject.checkType(signalStream, "ReadStream")
	checkArg(2, history, "table", "nil")
	if tabResolver then kobject.checkType(tabResolver, "Export") end
	checkArg(4, pwchar, "string", "nil")
	
	
	local state = terminalState[handle:getId()]
	
	if not state then
		return nil
	end
	
	local line = "so, this is kinda long. really, this is long. i'm telling you, this is... long.! if you don't... beleive me..."
	local cursor = #line
	local baseCursorX, baseCursorY = await(term.getCursor(pid, handle))
	local width, height = await(term.getSize(pid, handle))
	local lineWidth = width-baseCursorX+1
	local scroll = #line-lineWidth+2
	
	local function redraw()
		term.put(pid, handle, baseCursorX, baseCursorY, (" "):rep(lineWidth)) --writes, but does not do wrapping or cursor setting
		
		term.put(pid, handle, baseCursorX, baseCursorY, line:sub(scroll+1, scroll+lineWidth+1))
		
		term.setCursor(pid, handle, baseCursorX+(cursor-scroll), baseCursorY)
	end
	
	local function checkCursor()
		local screenSpaceCursor = (cursor-scroll+1)-lineWidth
		
		if screenSpaceCursor > 0 then
			scroll = scroll+screenSpaceCursor
			
			--[[term.copy(pid, handle,
				baseCursorX+screenSpaceCursor, baseCursorY,
				lineWidth-screenSpaceCursor, 1,
				baseCursorX, baseCursorY)
			term.put(pid, handle,
				baseCursorX+(lineWidth-screenSpaceCursor-1), baseCursorY,
				line:sub(scroll+(lineWidth-screenSpaceCursor), scroll+lineWidth))
			
			if #line-scroll < lineWidth then
				local c = lineWidth-(#line-scroll)
				term.put(pid, handle,
					baseCursorX+lineWidth-c, baseCursorY,
					(" "):rep(c))
			end]]
		elseif screenSpaceCursor <= (-lineWidth)+1 then
			screenSpaceCursor = screenSpaceCursor+lineWidth
			scroll = math.max(scroll-(lineWidth+1), 0) --lineWidth+1
			
			--[[term.copy(pid, handle,
				baseCursorX, baseCursorY,
				lineWidth-screenSpaceCursor, 1,
				baseCursorX+screenSpaceCursor, baseCursorY)
			term.put(pid, handle,
				baseCursorX, baseCursorY,
				line:sub(scroll+1, scroll+(lineWidth-screenSpaceCursor)+1))
			
			if #line-scroll < lineWidth then
				local c = lineWidth-(#line-scroll)
				term.put(pid, handle,
					baseCursorX+lineWidth-c, baseCursorY,
					(" "):rep(c))
			end]]
		end
		
		term.setCursor(pid, handle, baseCursorX+(cursor-scroll), baseCursorY)
		
		return screenSpaceCursor > 0
	end
	
	local function insert(str)
		if cursor == #line then
			line = line..str
		elseif cursor == 0 then
			line = str..line
		else
			line = line:sub(1, cursor-1)..str..line:sub(cursor+1)
		end
		
		cursor = cursor+#str
		
		if not checkCursor() then
			--term.put(pid, handle, baseCursorX+(cursor-scroll-1), baseCursorY, str)
		end
		
		redraw()
	end
	
	local function backspace()
		if cursor == #line+1 then
			line = line:sub(1, -2)
		elseif cursor > 0 then
			line = line:sub(1, cursor-1)..line:sub(cursor+1)
		else
			return
		end
		
		cursor = cursor-1
		
		if not checkCursor() then
			--[[local copyWidth = math.min(#line-cursor, lineWidth-(cursor-scroll))
			term.copy(pid, handle,
				baseCursorX+(cursor-scroll)+1, baseCursorY,
				copyWidth, 1,
				baseCursorX+(cursor-scroll), baseCursorY)
			
			local rep = line:sub(cursor+copyWidth, cursor+copyWidth)
			if #rep == 0 then rep = " " end
			os.logf("TERM", "copychar %s", rep)
			term.put(pid, handle,
				baseCursorX+(cursor-scroll)+copyWidth, baseCursorY,
				rep)]]
			--redraw() --TODO: Proper drawing logic
		else
			--term.put(pid, handle, baseCursorX+(cursor-scroll), baseCursorY, " ")
			--redraw()
		end
		
		os.logf("TERM", "%d %d %s", cursor, scroll, line)
		redraw()
	end
	
	redraw()
	
	signalStream:listen(function(signal)
		local typ = table.remove(signal, 1)
		
		if typ == "key_down" then
			local char = signal[2]
			if not (char < 0x20 or (char >= 0x7F and char <= 0x9F)) then
				insert(string.char(signal[2]))
			elseif signal[3] == 0x0E then
				backspace()
			elseif signal[3] == 0xCB and cursor > 0 then
				cursor = cursor-1
				checkCursor()
				redraw()
			elseif signal[3] == 0xCD and cursor < #line then
				cursor = cursor+1
				checkCursor()
				redraw()
			end
		end
	end)
end

--Init:

local gpu = component.list("gpu", true)()

if gpu then
	local handle = term.add(proc.getCurrentProcess(), "main", gpu)
	term.write(proc.getCurrentProcess(), handle, "Terminal is working!")
	term.getCursor(proc.getCurrentProcess(), handle):after(function(x, y)
		os.logf("TERM", "Tp %d %d", x, y)
	end)
	local width = await(term.getSize(proc.getCurrentProcess(), handle))
	term.setCursor(proc.getCurrentProcess(), handle, 1, 2)--width-5, 2)
	term.read(proc.getCurrentProcess(), handle, await(getSignalStream()))
end

--Service Exporting:

local functionList = {}
for i, v in pairs(term) do functionList[i] = true end

local serviceExport, serviceExportClient = kobject.newExport(functionList, function(method, arguments, pid)
	return term[method](pid, table.unpack(arguments))
end)
kobject.setLabel(serviceExport, "Service::TERM")

service.registerGlobal("TERM", serviceExportClient)
