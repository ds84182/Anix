--zero.lua: Kernel's Advocate
--Manages:
	--API Calls
		--Pushing events from process to process
		--Kernel object creation
	--Process Spawning
	--OC Signal -> Events

zero = {}

local signalStream, signalStreamOut = kobject.newStream()
kobject.delete(signalStream)
signalStream = nil

function zero.handleSignal(sig)
	os.logf("ZERO", "Handle signal %s", sig[1])
	
	--Morph signal stream here--
	
	signalStreamOut:send(sig)
end

do
	--zeroapi stuff
	zeroapi = {}
	
	function zero.createNewAPIStream()
		local readStream, to_writeStream = kobject.newStream()
		
		--api: {method = "name", arguments = {}, replyId = number, replyStream = WriteStream}
		
		readStream:listen(zero.handleRPC)
		
		return to_writeStream
	end
	
	function zero.handleRPC(rpc, source)
		if rpc.replyId and rpc.replyStream then
			--os.logf("ZERO:RPC", "Method %s", rpc.method)
			
			local method = zeroapi[rpc.method]
		
			if not method then
				zero.replyErrorRPC(rpc, "method not found")
				return
			end
			
			if type(rpc.arguments) ~= "table" then
				zero.replyErrorRPC(rpc, "invalid argument data type")
				return
			end
			
			local t = table.pack(pcall(method, source, table.unpack(rpc.arguments)))
			
			if not t[1] then
				zero.replyErrorRPC(rpc, t[2])
				return
			else
				zero.replyRPC(rpc, table.pack(table.unpack(t, 2)))
			end
		end
		--If we don't have a place to send an error, we can't send an error. AMIRITE?
	end
	
	function zero.replyRPC(rpc, message)
		message.ok = true
		message.id = rpc.replyId
		rpc.replyStream:send(message)
	end
	
	function zero.replyErrorRPC(rpc, error)
		local message = {ok = false, id = rpc.replyId, error = error}
		rpc.replyStream:send(message)
	end
	
	--The ACTUAL exported API starts here--
	
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
	
	--Service API--
	
	local globalServices = {}
	local localServices = {}
	
	function zeroapi.service_get(pid, name)
		--os.logf("ZERO:API", "Get service %s for pid %s", name, tostring(pid))
		if globalServices[name] then
			return globalServices[name]
		end
		
		if pid == -1 then return end
		
		local ls = localServices[pid]
		if ls and ls[name] then
			return ls[name]
		end
		
		--service get through parent local services--
		return zeroapi.service_get(proc.getParentProcess(pid), name)
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
		
		proc.createThread(function()
			while true do
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
	assert(proc.spawn(table.concat(buffer), "filesystem", nil, {API = zero.createNewAPIStream()}))
	
	local fs = await(zeroapi.service_await(0, "FS"))
	os.log("ZERO", "Loading startup processes")
	local a = os.clock()
	fs:invoke("open", "/sec/bin/startup.lua", "r"):after(function(handle)
		os.logf("ZERO", "%s ms", (os.clock()-a)*1000)
		local stream = await(fs:invoke("readAsStream", handle, math.huge))
		stream:join():after(function(source)
			os.logf("ZERO", "%s ms", (os.clock()-a)*1000)
			assert(proc.spawn(source, "startup", nil, {API = zero.createNewAPIStream()}))
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
]], "zapi_test", nil, {API = zero.createNewAPIStream()}))
