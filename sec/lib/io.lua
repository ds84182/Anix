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

local stdout, stdin, stdinLF, stderr

function io.init()
	debug "Getting IO Streams"
	
	stdout = proc.getEnv "STDOUT"
	
	if not stdout then
		debug "Using STDOUT Terminal Implementation"
		local term = require "term"
		term.init() --init before setting up streams
		local rs, ws = kobject.newStream()
		stdout = ws
		rs:listen(function(lines)
			lines = tostring(lines):gsub("\t", "    ")
			for line in lines:gmatch("[^\n]*\n?") do
				if line:sub(-1,-1) == "\n" then
					term.write(line:sub(1,-2))
					--term.nextLine()
					local x, y = term.getCursor()
					term.setCursor(1, y+1)
				else
					term.write(line)
				end
			end
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
			return await(term.read())
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
end

local function read(stream, amount)
	amount = amount or math.huge
	if kobject.isA(stream, "ExportClient") then
		return exportClient:invoke("read", amount)
	else
		--reading bytes--
		if type(amount) == "number" then
			if amount == 1 then
				return stdin:single()
			else
				return stdin:count(amount):join()
			end
		elseif amount == "*l" then
			error("TODO: Read line")
		end
	end
end

function io.write(...)
	if not stdout then
		io.init()
	end
	
	stdout:send(table.concat(table.pack(...)))
end

function io.read(amount)
	return read(stdin, amount)
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
