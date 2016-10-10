local io = {}

io.debug = false

--We use the STDIN, STDOUT, and STDERR env vars
--They can be Streams or Exports
--However, STDIN can also have STDIN_LF, which reads lines
--By default, these are implemented by term
--STDOUT and STDERR (if an export) defines "write"
--STDIN (if an export) defines "read"

local function debug(...)
  if io.debug then os.logf("IOLIB", ...) end
end

local stdout, stdin, stdinLF, stderr, mutex
local initing, init = false, false
local initCompleters = {}

function io.init()
  if init then
    return kobject.newCompletedFuture()
  end

  if not initing then
    async(function()
      debug "Creating Kernel Mutex"
      mutex = kobject.newMutex()

      debug "Getting IO Streams"

      stdout = proc.getEnv "STDOUT"

      if not stdout then
        debug "Using STDOUT Terminal Implementation"
        local term = require "term"
        term.init() --init before setting up streams
        local rs, ws = kobject.newStream()
        stdout = ws
        rs:listen(function(lines)
          debug("Enter stdout term %s", lines)
          lines = tostring(lines):gsub("\t", "    ")
          mutex:performAtomic(makeAsync(function()
            debug("Really enter stdout term %s", lines)
            for line in lines:gmatch("[^\n]*\n?") do
              if line:sub(-1,-1) == "\n" then
                term.write(line:sub(1,-2))
                --term.nextLine()
                local x, y = term.getCursor()
                local w, h = term.getSize()
                local ny = y+1
                if ny > h then
                  term.scrollVertical(ny-h)
                  await(term.setCursor(1, h))
                else
                  await(term.setCursor(1, ny))
                end
              else
                await(term.write(line))
              end
            end
            debug("Exit stdout term %s", lines)
          end))
        end)
      end

      stdin = proc.getEnv "STDIN"

      if not stdin then
        --TODO: In order for this to work, term needs to implement something like VT100 (Or something custom :P)
        debug "Using STDIN Terminal Implementation"
        local term = require "term"
        stdin = await(getSignalStream())
          :where(function(sig)
            return sig[1] == "key_down" and sig[3] >= 0x20 and (sig[3] < 0x7F or sig[3] > 0x9F)
          end)
          :map(function(sig)
            return string.char(sig[3])
          end)
        kobject.setLabel(stdin, "Terminal STDIN")
        local export, exportClient = kobject.newExport({read = true}, function(method, arguments, pid)
          return mutex:performAtomic(makeAsync(function()
            return await(term.read())
          end))
        end)
        kobject.setLabel(export, "Terminal STDIN LF")
        stdinLF = exportClient
      else
        stdinLF = proc.getEnv "STDIN_LF"

        if not stdinLF and kobject.isA(stdinLF, "ReadStream") then
          stdinLF = stdin:duplicate():transform(utils.newLineSplitter())
        end
      end

      kobject.declareWeak(stdin)
      kobject.declareWeak(stdinLF)

      init = true

      for i, completer in pairs(initCompleters) do
        completer:complete()
      end
      initCompleters = nil
    end)

    initing = true
  end

  local completer, future = kobject.newFuture()
  initCompleters[#initCompleters+1] = completer
  return future
end

local function read(stream, streamLF, amount)
  amount = amount or math.huge
  if kobject.isA(stream, "ExportClient") then
    local out = stream:invoke("read", amount)
    return out
  else
    --reading bytes--
    if type(amount) == "number" then
      if amount == 1 then
        return stdin:single()
      else
        return stdin:count(amount):join()
      end
    elseif amount == "*l" then
      return read(streamLF, nil, 1)
    end
  end
end

function io.write(...)
  local s = table.concat(table.pack(...))
  io.init():after(function()
    stdout:send(s)
  end)
end

function io.read(amount)
  return io.init():after(function()
    return read(stdin, stdinLF, amount)
  end)
end

function print(...)
  local tab = table.pack(...)

  if tab.n == 0 then io.write("\n") return end

  for i=1, tab.n do
    tab[i] = tostring(tab[i])
  end

  io.write(table.concat(tab, "  ").."\n")
end

function printf(fmt, ...)
  return print(string.format(fmt, ...))
end

return io
