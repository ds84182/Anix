local term = {}

term.debug = true

local ready = false
local srv = nil
local handle = nil

local function debug(...)
	if term.debug then os.logf("TERMLIB", ...) end
end

local function debugCatch(future)
	if term.debug then
		await(future) --allows completer errors to be caught by waiting for the operation to finish
	end
end

local waitInit

function term.init()
	--TODO: kSignalQueue would be great here
	if not waitInit then
		local completer, future = kobject.newFuture()
		waitInit = future

		debug("Getting service")
		srv = await(service.get "TERM")

		if not srv then
			debug("Service not found!")
			debug("Waiting for service...")
			srv = await(await(service.await "TERM"))
		end

		ready = true
		debug("Ready!")

		term.switch(proc.getEnv "TERM" or "main")

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

--

function term.get(name)
	if not ready then
		term.init()
	end

	debug("Getting handle for %s", name)

	return await(srv:invoke("get", name))
end

function term.switch(h)
	if not ready then
		term.init()
	end

	if type(h) == "string" then
		h = term.get(h)
	end

	debug("Switching handle %s for %s", handle, h)

	local old = handle
	handle = h
	return old
end

--

function term.sendEventAsync(event)
  if not ready then
		term.init()
	end

	return srv:invoke("sendEvent", handle, event)
end

function term.sendEvent(event)
	local completer, future = kobject.newFuture()
  
  event.done = completer

  term.sendEventAsync(event)
	return future
end

--

function term.getState()
	return term.sendEvent {type = "get_state"}
end

function term.getSize()
	local size = await(term.sendEvent {type = "get_resolution"})
	return size.width, size.height
end

--

function term.setCursor(x, y)
	checkArg(1, x, "number")
	checkArg(2, y, "number")

	return term.sendEvent {type = "move_cursor", x = x, y = y}
end

function term.getCursor()
	local state = await(term.getState())

	return state.cursorX, state.cursorY
end

--

function term.setCursorBlink(blink)
	blink = not not blink

	return term.sendEvent {type = "set_blink", blink = blink}
end

function term.getCursorBlink()
	local state = await(term.getState())

	return state.cursorBlink
end

--

function term.write(str)
	str = tostring(str)

	return term.sendEvent {type = "write", text = str}
end

function term.put(x, y, str)
	str = tostring(str)

	return term.sendEvent {type = "put", x = x, y = y, text = str}
end

function term.copy(x, y, width, height, destx, desty)
	checkArg(1, x, "number")
	checkArg(2, y, "number")
	checkArg(3, width, "number")
	checkArg(4, height, "number")
	checkArg(5, destx, "number")
	checkArg(6, desty, "number")

	return term.sendEvent {type = "copy", x = x, y = y, width = width, height = height, destx = destx, desty = desty}
end

function term.scrollVertical(amount)
	checkArg(1, amount, "number", "nil")
	return term.sendEvent {type = "scroll_vertical", amount = amount}
end

--

function term.read(line, history, tabResolver, pwchar, signalStream)
	if not ready then
		term.init()
	end

	checkArg(1, line, "string", "nil")
	checkArg(2, history, "table", "nil")
	--TODO: Full tabResolver and pwchar support
	if tabResolver then kobject.checkType(tabResolver, "Export") end
	checkArg(4, pwchar, "string", "nil")
	signalStream = signalStream or await(getSignalStream())
	kobject.checkType(signalStream, "ReadStream")

	line = line or ""
	local cursor = #line
	local baseCursorX, baseCursorY = term.getCursor(pid, handle)
	local width, height = term.getSize(pid, handle)
	local lineWidth = width-baseCursorX+1
	local scroll = math.max(#line-lineWidth+1, 0)

	local function redraw()
		term.put(baseCursorX, baseCursorY, (" "):rep(lineWidth)) --writes, but does not do wrapping or cursor setting

		term.put(baseCursorX, baseCursorY, line:sub(scroll+1, scroll+lineWidth+1))

		term.setCursor(baseCursorX+(cursor-scroll), baseCursorY)
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

		term.setCursor(baseCursorX+(cursor-scroll), baseCursorY)

		return screenSpaceCursor > 0
	end

	local function insert(str)
		if cursor == #line then
			line = line..str
		elseif cursor == 0 then
			line = str..line
		else
			line = line:sub(1, cursor)..str..line:sub(cursor+1)
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

	local completer, future = kobject.newFuture()

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
			elseif signal[3] == 0xC7 then -- home
				cursor = 0
				checkCursor()
				redraw()
			elseif signal[3] == 0xCF then -- end
				cursor = #line
				checkCursor()
				redraw()
			elseif signal[3] == 0x1C then
        os.logf("TERM", "Complete line %s", line)
				completer:complete(line)
				signalStream:close()
			end
		end
	end)

	return future

	--return await(srv:invoke("read", handle, await(getSignalStream()), history))
end

return term
