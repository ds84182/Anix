local term = {}

term.debug = false

local srv = nil
local handle = nil

local function debug(...)
	if term.debug then os.logf("TERMLIB", ...) end
end

function term.init()
	debug("Getting service")
	srv = await(service.get "TERM")
	
	if not srv then
		debug("Service not found!")
		debug("Waiting for service...")
		srv = await(await(service.await "TERM"))
	end
	
	term.switch(proc.getEnv "TERM" or "main")
end

function term.get(name)
	if not srv then
		term.init()
	end
	
	debug("Getting handle for %s", name)
	
	return await(srv:invoke("get", name))
end

function term.switch(h)
	if not srv then
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

function term.write(str)
	if not srv then
		term.init()
	end
	
	str = tostring(str)
	
	srv:invoke("write", handle, str)
end

return term
