--zero.lua: Kernel's Advocate
--Manages:
	--API Calls
		--Pushing events from process to process
		--Kernel object creation
	--Process Spawning
	--OC Signal -> Events

zero = {}

local kernelSignalStream = ...

local signalStream, signalStreamOut = kobject.newStream()
kobject.setLabel(signalStream, "Signal Stream")

local processCleanupHandlers = {}

function zero.handleSignal(sig)
	os.logf("ZERO", "Handle signal %s", sig[1])
	
	--Morph signal stream here--
	if sig[1] == "process_death" then
		for _, func in pairs(processCleanupHandlers) do
			func(sig[2], sig[3])
		end
	end
	
	signalStreamOut:send(sig)
end

kernelSignalStream:listen(zero.handleSignal)

do
	--ZeroAPI--
	zeroapi = {}
	
	function zeroapi.init()
		return true
	end
	
	function zeroapi.hello(pid)
		os.log("ZERO:API", "Hello invoked")
		return "world"
	end
	
	function zeroapi.log(pid, tag, ...)
		tag = tostring(tag).."/"..pid.."/"..proc.getProcessName(pid)
		os.log(tag, ...)
	end
	
	local processStreams = {}
	
	function zeroapi.signalstream(pid)
		if not processStreams[pid] then
			processStreams[pid] = signalStream:duplicate():where(function(sig)
				if sig[1] == "process_death" and sig[3] ~= pid then
					return false
				end
				
				return true
			end)
			kobject.setLabel(processStreams[pid], "ZeroAPI::SignalStream")
		end
		
		return processStreams[pid]:duplicate()
	end
	
	--Service API--
	
	local globalServices = {}
	local localServices = {}
	local awaitingProcesses = {}
	
	function zeroapi.service_get(pid, name)
		local ls = localServices[pid]
		if ls and ls[name] then
			return ls[name]
		end
		
		if pid >= 0 then
			--service get through parent local services--
			local service = zeroapi.service_get(proc.getParentProcess(pid), name)
			if service then return service end
		end
		
		if globalServices[name] then
			return globalServices[name]
		end
	end
	
	function zeroapi.service_list(pid, mode)
		local list = {}
		
		mode = mode or "both"
		
		if mode ~= "global" then
			local cpid = pid
			while cpid >= 0 do
				local ls = localServices[cpid]
				if ls then
					for name in pairs(ls) do
						list[#list+1] = name
					end
				end
				cpid = proc.getParentProcess(cpid)
			end
		end
		
		if mode ~= "local" then
			for name in pairs(globalServices) do
				list[#list+1] = name
			end
		end
		
		return list
	end
	
	function zeroapi.service_registerlocal(pid, name, ko)
		localServices[pid] = localServices[pid] or {}
		localServices[pid][name] = ko
	end
	
	function zeroapi.service_registerglobal(pid, name, ko)
		if proc.getTrustLevel(pid) <= 1000 then
			globalServices[name] = ko
			os.logf("ZERO", "Added global service %s (%s)", name, tostring(ko))
			return true
		else
			return false, "process not trusted"
		end
	end
	
	function zeroapi.service_await(pid, name)
		local completer, future = kobject.newFuture()
		
		awaitingProcesses[pid] = true
		
		proc.createThread(function()
			while awaitingProcesses[pid] do
				local svc = zeroapi.service_get(pid, name)
				if svc then
					completer:complete(svc)
					break
				end
				yield()
			end
		end, "service_check_"..name.."_for_"..pid)
		
		return future
	end
	
	function processCleanupHandlers.zeroapi(pid, ppid)
		awaitingProcesses[pid] = nil
		localServices[pid] = nil
	end
	
	--Process API--
	
	function zeroapi.proc_spawn(pid, source, name, args, env)
		env = env or {}
		
		if not env.API then
			env.API = zero.apiClient
		end
		
		return proc.spawn(source, name, args, env, trustLevel, pid)
	end
	
	--Export--
	
	local functionList = {}
	for i, v in pairs(zeroapi) do functionList[i] = true end
	
	zero.apiExport, zero.apiClient = kobject.newExport(functionList, function(method, arguments, pid)
		return zeroapi[method](pid, table.unpack(arguments))
	end)
	kobject.setLabel(zero.apiExport, "ZeroAPI")
end

--start filesystem service--
local bootfs = component.proxy(computer.getBootAddress())
	
if not bootfs.exists("sec/bin/filesystem.lua") then
	os.log("ZERO", "Filesystem service not found in /sec/bin/filesystem.lua")
else
	os.log("ZERO", "Loading filesystem service")
	local a = os.clock()
	local fh = bootfs.open("sec/bin/filesystem.lua", "r")
	local buffer = {}
	while true do
		local s = bootfs.read(fh, math.huge)
		if not s then break end
		buffer[#buffer+1] = s
	end
	bootfs.close(fh)
	os.logf("ZERO", "%s ms", (os.clock()-a)*1000)
	assert(proc.spawn(table.concat(buffer), "filesystem", nil, {API = zero.apiClient}))
	
	local fs = await(zeroapi.service_await(0, "FS"))
	os.log("ZERO", "Loading startup processes")
	local a = os.clock()
	fs:invoke("open", "/sec/bin/startup.lua", "r"):after(function(handle)
		os.logf("ZERO", "%s ms", (os.clock()-a)*1000)
		local stream = await(fs:invoke("readAsStream", handle, math.huge))
		stream:join():after(function(source)
			os.logf("ZERO", "%s ms", (os.clock()-a)*1000)
			assert(proc.spawn(source, "startup", nil, {API = zero.apiClient}))
			fs:invoke("close", handle)
		end)
	end)
end

--testing executable--

local export, client = kobject.newExport({func = true}, function(method, arguments, pid)
	return method.." called!"
end)
kobject.setLabel(export, "Service::TEST") --this sets the label associated with the object data, which is shared with client

zeroapi.service_registerglobal(0, "TEST", client)

assert(proc.spawn([[
	os.log("TEST", "MYFINGER")
	os.log("TEST", "Hello "..await(hello()))
	
	local testsrv = await(service.get("TEST"))
	--os.log("TEST", tostring(testsrv))
	os.log("TEST", await(testsrv:invoke("func")))
]], "zapi_test", nil, {API = zero.apiClient}))
