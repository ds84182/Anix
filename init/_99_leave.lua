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
	assert(ps.spawn(table.concat(buffer), "zero"))
	
	ps.run(function()
		kobject.update()
	end)
end
