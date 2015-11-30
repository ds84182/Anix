function LeaveINIT()
	os.log("LEAVEINIT", "Leaving INIT")
	os.log("LEAVEINIT", "Starting 'zero'")
	
	--[==[local ws, rs = kobject.newStream()
	local ws2, rs2 = kobject.newStream()
	
	ps.spawn([[
		local ws, rs = ...
		ws:send({"TP", "Test process says hi"})
		
		rs:listen(function(f)
			ws:send({"TP", "Got '"..f.."' from kernel stream!"})
		end)
	]], "zero", {ws, rs2})
	
	rs:listen(function(message)
		os.log(table.unpack(message))
		
		--[[for i, v in pairs(kobject.objects) do
			os.logf("TEST", "Kernel object %s owned by %d", tostring(i), v.owner)
		end]]
	end)
	
	ws2:send("Hello!")]==]
	
	local bootfs = component.proxy(computer.getBootAddress())
	
	assertHang(bootfs.exists("sec/bin/zero.lua"), "LEAVEINIT", "Process Zero not found in /sec/bin/zero.lua")
	
	local fh = bootfs.open("sec/bin/zero.lua", "r")
	local buffer = {}
	while true do
		local s = bootfs.read(fh, math.huge)
		if not s then break end
		buffer[#buffer+1] = s
	end
	bootfs.close(fh)
	
	local signalStream, signalStreamWrite = kobject.newStream()
	assert(proc.spawn(table.concat(buffer), "zero", {signalStream}))
	
	--[=[local export, exportClient = kobject.newExport({func = true}, function(method)
		return method.."!"
	end)
	
	proc.spawn([[
		os.log("ZERO", "one")
		local rs, ws = kobject.newStream()
		local completer, future = kobject.newFuture()
		
		rs:listen(function(text)
			os.log("ZERO", text)
			
			if text == "doit" then
				completer:complete()
			end
		end)
		
		ws:send("Mom, please")
		
		proc.createThread(function()
			os.log("ONE", "two")
			await(future)
			os.log("ONE", "ONE!")
		end)
		
		ws:send("doit")
		
		local exportClient = ...
		ws:send(await(exportClient:invoke("func")))
	]], "zero", {exportClient})]=]
	
	proc.run(function(pps, minWait)
		local signal = table.pack(computer.pullSignal(pps and 0 or minWait))
		if signal[1] then
			signalStreamWrite:send(signal)
		end
	end)
end
