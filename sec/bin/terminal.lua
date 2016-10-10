async(function()

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
  return async(component.invoke, self.address, method, ...)
end

function ComponentObject.__index:isDisconnected()
  return component.get(self.address) == nil
end

----

local handles = {}
local terminalState = {}
local boundList = {}

local function startTerminalHandlerThread(state)
  return async(function()
    local completer, future = kobject.newFuture()

    local cursorOn = false
    local char
    local exit = false
    local onExit

    local function checkField(event, fieldName, ...)
      local typ = type(event[fieldName])
      for i=1, select("#", ...) do
        if typ == select(i, ...) then
          return true
        end
      end

      if event.done and kobject.isA(event.done, "Completer") then
        event.done:error("expected "..table.concat(table.pack(...), " or ").." in event."..fieldName..", got "..typ)
      else
        os.logf("TERM", "expected %s in event.%s, got %s", table.concat(table.pack(...), " or "), fieldName, typ)
      end

      return false
    end

    local function inside(x, y, w, h)
      return x <= 0 or y <= 0 or x > w or y > h
    end

    local function checkInside(x, y, w, h)
      if inside(x, y, w, h) then
        os.logf("TERM", "(%d, %d) is outside of (%d, %d)", x, y, w, h)
        return false
      end
      return true
    end

    local function processEvent(event)
      if event.type == "set_blink" then
        state.cursorBlink = event.blink
        --[[completer:complete()
        completer, future = kobject.newFuture()]]
      elseif event.type == "move_cursor" then
        if not checkField(event, "x", "number") then
          return
        end

        if not checkField(event, "y", "number") then
          return
        end

        local w,h = await(state.gpu:invoke("getResolution"))

        if not checkInside(event.x, event.y, w, h) then
          return
        end

        if cursorOn then
          await(state.gpu:invoke("set", state.cursorX, state.cursorY, char))
          cursorOn = false
        end

        state.cursorX = event.x
        state.cursorY = event.y
      elseif event.type == "write" then
        if not checkField(event, "text", "string") then
          return
        end

        if cursorOn then
          await(state.gpu:invoke("set", state.cursorX, state.cursorY, char))
          cursorOn = false
        end

        local text = event.text
        local w,h = await(state.gpu:invoke("getResolution"))

        local old = state.cursorBlink
        state.cursorBlink = false
        while #text > 0 do
          await(state.gpu:invoke("set", state.cursorX, state.cursorY, text))

          state.cursorX = state.cursorX+#text

          if state.cursorX > w then
            -- fix cursor and go to next line
            text = text:sub(w-state.cursorX+1)
            state.cursorX = 1
            state.cursorY = state.cursorY+1
            if state.cursorY > h then
              -- Scroll screen up by one line
              await(state.gpu:invoke("copy", 1, 1, w, h, 0, -1))
              state.cursorY = h
            end
          else
            break
          end
        end
        state.cursorBlink = old

        char = await(state.gpu:invoke("get", state.cursorX, state.cursorY))
      elseif event.type == "put" then
        if not checkField(event, "x", "number") then
          return
        end

        if not checkField(event, "y", "number") then
          return
        end

        if not checkField(event, "text", "string") then
          return
        end

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
        if not checkField(event, "x", "number") then
          return
        end

        if not checkField(event, "y", "number") then
          return
        end

        if not checkField(event, "width", "number") then
          return
        end

        if not checkField(event, "height", "number") then
          return
        end

        if not checkField(event, "destx", "number") then
          return
        end

        if not checkField(event, "desty", "number") then
          return
        end

        if cursorOn then
          await(state.gpu:invoke("set", state.cursorX, state.cursorY, char))
          cursorOn = false
        end

        local old = state.cursorBlink
        state.cursorBlink = false
        await(state.gpu:invoke("copy", event.x, event.y, event.width, event.height, event.destx-event.x, event.desty-event.y))
        state.cursorBlink = old

        char = await(state.gpu:invoke("get", state.cursorX, state.cursorY))
      elseif event.type == "scroll_vertical" then
        if not checkField(event, "amount", "number", "nil") then
          return
        end

        local w,h = await(state.gpu:invoke("getResolution"))
        local amount = event.amount or 1
        await(state.gpu:invoke("copy", 1, 1, w, h, 0, -amount))
        for i=1, amount do
          await(state.gpu:invoke("set", 1, h-i+1, (" "):rep(w)))
        end
      elseif event.type == "exit" then
        exit = true --exit the blinking thread

        if kobject.isA(event.onExit, "Completer") then
          onExit = event.onExit
        end
      elseif event.type == "get_state" then
        return {
          cursorX = state.cursorX,
          cursorY = state.cursorY,
          cursorBlink = state.cursorBlink
        }
      elseif event.type == "get_resolution" then
        local w,h = await(state.gpu:invoke("getResolution"))

        return {width = w, height = h}
      end
      return true
    end
    processEvent = makeAsync(processEvent)

    state.stream:listen(function(event)
      os.logf("TERM", "Recv %s", event.type)
      state.mutex:performAtomic(processEvent, event):after(function(value)
        if event.done and kobject.isA(event.done, "Completer") then
          os.logf("TERM", "%s %s %s", event.type, tostring(event.done), tostring(value))
          event.done:complete(value)
        end
      end)
    end)

    while not exit do
      await(state.mutex:lock())

      if exit then
        state.mutex:unlock()
        break
      end

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

    state.stream:close()
    state.events:close()
    kobject.delete(state.mutex)

    if onExit then
      onExit:complete()
    end
  end) -- "terminal_handler_"..state.name
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
  kobject.setLabel(handle, "Terminal::"..name)
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
  kobject.checkType(handle, "Handle")

  local state = terminalState[handle:getId()]

  if state then
    local completer, future = kobject.newFuture()

    state.events:send({type = "exit", onExit = completer})

    await(future)

    handles[state.name] = nil

    for i, v in pairs(boundComponentList) do
      if v == state.object then
        boundComponentList[i] = nil
        break
      end
    end
    boundList[state.object] = nil

    terminalState[handle:getId()] = nil

    return true
  end

  return false
end

function term.get(pid, name)
  checkArg(1, name, "string")
  return handles[name]
end

function term.sendEvent(pid, handle, event)
  kobject.checkType(handle, "Handle")

  local state = terminalState[handle:getId()]

  if state then
    state.events:send(event)
  else
    error("invalid terminal handle")
  end
end

--XXX: These term functions are depreciated and will be removed soon.

function term.setCursor(pid, handle, x, y)
  kobject.checkType(handle, "Handle")
  checkArg(2, x, "number")
  checkArg(3, y, "number")

  local state = terminalState[handle:getId()]

  if state then
    state.events:send({type = "move_cursor", x = x, y = y})
  else
    error("invalid terminal handle")
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
  else
    error("invalid terminal handle")
  end
end

function term.setCursorBlink(pid, handle, blink)
  kobject.checkType(handle, "Handle")
  checkArg(2, blink, "boolean")

  local state = terminalState[handle:getId()]

  if state then
    state.events:send({type = "set_blink", blink = blink})
  else
    error("invalid terminal handle")
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
  else
    error("invalid terminal handle")
  end
end

function term.getSize(pid, handle)
  kobject.checkType(handle, "Handle")

  local state = terminalState[handle:getId()]

  if state then
    return state.gpu:invoke("getResolution")
  else
    error("invalid terminal handle")
  end
end

function term.write(pid, handle, str)
  kobject.checkType(handle, "Handle")
  str = tostring(str)

  local state = terminalState[handle:getId()]

  if state then
    state.events:send({type = "write", text = str})
  else
    error("invalid terminal handle")
  end
end

function term.put(pid, handle, x, y, str)
  kobject.checkType(handle, "Handle")
  str = tostring(str)

  local state = terminalState[handle:getId()]

  if state then
    state.events:send({type = "put", x = x, y = y, text = str})
  else
    error("invalid terminal handle")
  end
end

function term.copy(pid, handle, x, y, width, height, destx, desty)
  kobject.checkType(handle, "Handle")

  local state = terminalState[handle:getId()]

  if state then
    state.events:send({type = "copy", x = x, y = y, width = width, height = height, destx = destx, desty = desty})
  else
    error("invalid terminal handle")
  end
end

--TODO: Maybe move term.read to per process termlib, and then have term.moveCursor for relative movements
function term.read(pid, handle, signalStream, line, history, tabResolver, pwchar)
  kobject.checkType(handle, "Handle")
  kobject.checkType(signalStream, "ReadStream")
  checkArg(2, line, "string", "nil")
  checkArg(3, history, "table", "nil")
  if tabResolver then kobject.checkType(tabResolver, "Export") end
  checkArg(4, pwchar, "string", "nil")

  local state = terminalState[handle:getId()]

  if not state then
    error("invalid terminal handle")
  end

  line = line or ""
  local cursor = #line
  local baseCursorX, baseCursorY = await(term.getCursor(pid, handle))
  local width, height = await(term.getSize(pid, handle))
  local lineWidth = width-baseCursorX+1
  local scroll = math.max(#line-lineWidth+1, 0)

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
      elseif signal[3] == 0x1C then
        completer:complete(line)
        signalStream:close()
      end
    end
  end)

  return future
end

--Init:

local gpu = component.list("gpu", true)()

if gpu then
  local handle = term.add(proc.getCurrentProcess(), "main", gpu)

  --[[term.write(proc.getCurrentProcess(), handle, "Terminal is working!")
  term.getCursor(proc.getCurrentProcess(), handle):after(function(x, y)
    os.logf("TERM", "Tp %d %d", x, y)
  end)
  local width = await(term.getSize(proc.getCurrentProcess(), handle))
  term.setCursor(proc.getCurrentProcess(), handle, 1, 2)--width-5, 2)
  term.read(proc.getCurrentProcess(), handle, await(getSignalStream())):after(function(line)
    os.logf("TERM", "Line %s", line)
  end)]]

  require "foo".bar()
end

--Service Exporting:

local functionList = {}
for i, v in pairs(term) do functionList[i] = true end

local serviceExport, serviceExportClient = kobject.newExport(functionList, function(method, arguments, pid)
  return term[method](pid, table.unpack(arguments))
end)
kobject.setLabel(serviceExport, "Service::TERM")

service.registerGlobal("TERM", serviceExportClient)

end)
