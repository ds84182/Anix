proc = {}

local currentThread = nil

local processes = {}
local threads = {}
local scheduleNext = {}

local nextPID = 0
local nextTID = 1

local function createThread(coro, pid, name, args)
	local id = nextTID
	nextTID = nextTID+1
	
	threads[id] = {
		thread = coro,
		process = pid,
		name = name or "thread "..id,
		args = args or {},
		firstResume = true,
		error = nil,
		peaceful = nil,
		waiting = false,
		id = id
	}
	
	scheduleNext[#scheduleNext+1] = threads[id]
	
	--os.logf("PROC", "New thread %s (%d)", name or "thread "..id, id)
	
	return id
end

function proc.spawn(source, name, args, vars, trustLevel, parent)
	checkArg(1,source,"string")
	checkArg(2,name,"string","nil")
	checkArg(3,args,"table","nil")
	checkArg(4,vars,"table","nil")
	checkArg(5,trustLevel,"number","nil")
	
	parent = parent or (proc.getCurrentProcess() or -1)
	
	trustLevel = trustLevel or proc.getTrustLevel(parent)+1
	
	local currentTrustLevel = proc.getTrustLevel(parent)
	if currentTrustLevel > 1000 and trustLevel < currentTrustLevel then
		error(("Given trust level (%d) is less than the current trust level (%d)."):format(trustLevel, currentTrustLevel))
	end
	
	args = args or {}
	do
		local m, why = kobject.isMarshallable(args)
		if not m then
			error(("Arguments contain unmarshallable objects (%s)"):format(why))
		end
	end
	
	vars = vars or (currentThread and processes[currentThread.process].variables or {})
	do
		local m, why = kobject.isMarshallable(vars)
		if not m then
			error(("Environmental variables contain unmarshallable objects (%s)"):format(why))
		end
	end
	
	local globals = nextPID == 0 and kapi.newOverlay() or kapi.newSandbox()
	kapi.patch(globals, nextPID, trustLevel)
	
	name = name or "process_"..nextPID
	local func, err = load(source, "="..name, nil, globals)
	if not func then return nil, err end
	
	local id = nextPID
	nextPID = nextPID+1
	
	local object = {
		globals = globals,
		name = name,
		trustLevel = trustLevel,
		id = id,
		parent = parent,
		variables = kobject.copy(vars, id), --environmental variables
	}
	processes[id] = object
	
	object.mainThread = createThread(coroutine.create(func), id, "main thread", kobject.copy(args or {}, id))
	
	os.logf("PROC", "Creating process \"%s\" with pid of %d, parent of %d, trust level %d", name, id, parent, trustLevel)
	return id
end

function proc.createThread(func, name, args, pid)
	pid = pid or (currentThread and currentThread.process or -1)
	
	do
		local m, why = kobject.isMarshallable(args)
		if not m then
			error(("Arguments contain unmarshallable objects (%s)"):format(why))
		end
	end
	
	return createThread(coroutine.create(func), pid, name, kobject.copy(args or {}, pid))
end

function proc.createKernelThread(func, name, args)
	return createThread(coroutine.create(func), -1, name, args)
end

local _TIMEOUT = {true, nil, "timeout"}

local function resume(thread, ...)
	local oldThread = currentThread
	currentThread = thread
	local r = table.pack(coroutine.resume(thread.thread, ...))
	currentThread = oldThread
	
	local s = r[1]
	if coroutine.status(thread.thread) == "dead" then
		thread.peaceful = s
		thread.error = s and "process has finished execution" or debug.traceback(thread.thread, r[2])
		
		if not thread.peaceful then
			os.logf("PROC", "Process \"%s\" (%d) Thread \"%s\" (%d) has ended %s: %s", processes[thread.process].name, thread.process, thread.name, thread.id, thread.peaceful and "peacefully" or "violently", thread.error)
		end
		
		return
	end
	
	if r[2] then
		if kobject.isA(r[2], "Future") then
			--await
			thread.waiting = true
			thread.waitingOn = r[2]
			thread.waitUntil = (type(r[3]) == "number") and computer.uptime()+r[3] or math.huge
			thread.resumeOnTimeout = (type(r[4]) == "table") and r[4] or _TIMEOUT
			r[2]:after(function(...)
				thread.waiting = false
				thread.waitingOn = nil
				thread.waitUntil = nil
				thread.resumeOnTimeout = nil
				thread.resume = table.pack(true, ...)
				scheduleNext[#scheduleNext+1] = thread
			end, function(err)
				thread.waiting = false
				thread.waitingOn = nil
				thread.waitUntil = nil
				thread.resumeOnTimeout = nil
				thread.resume = table.pack(false, err)
				scheduleNext[#scheduleNext+1] = thread
			end)
		elseif type(r[2]) == "number" then
			--sleep
			thread.waiting = true
			thread.waitUntil = computer.uptime()+r[2]
		end
	end
end

local function handleThread(id, thread)
	if thread.waiting and thread.waitUntil then
		if thread.waitUntil <= computer.uptime() then
			thread.waiting = false
			thread.waitUntil = nil
			thread.resume = thread.resumeOnTimeout
			thread.resumeOnTimeout = nil
			thread.waitingOn = nil
		end
	end
	
	if (not thread.waiting) and (not thread.error) then
		--os.logf("PROC", "Resume thread %s (%d)", thread.name, thread.id)
		--local a = os.clock()
		if thread.firstResume then
			resume(thread, table.unpack(thread.args))
			thread.firstResume = false
		elseif thread.resume then
			resume(thread, table.unpack(thread.resume))
			thread.resume = nil
		else
			resume(thread)
		end
		--os.logf("PROC", "Thread time: %f", (os.clock()-a)*1000)
	
		if thread.error then
			if (not thread.peaceful) and thread.parent == nil then
				local term
				if require then
					term = require "term"
				end
				if term then
					--error(tostring(v.error),0)
					term.write(v.name.." "..tostring(thread.error).."\n")
				end
			end
		
			--[[local parent = thread.parent and processes[thread.parent] or nil
			if parent then
				parent.signalQueue[#parent.signalQueue+1] = {type = "child_death", child = i} --, source = {type = "kernel"}}
			end
			if processes[0] then
				local zero = processes[0]
				zero.signalQueue[#zero.signalQueue+1] = {type = "process_death", pid = i}
			end
			kobject.destroyProcessObjects(i)]]
			--threads[id] = nil
		end
		
		local sn = scheduleNext
		scheduleNext = {}
		for i=1, #sn do
			handleThread(sn[i].id, sn[i])
		end
	end
end

function proc.resumeThread(id)
	handleThread(id, threads[id])
end

function proc.run(callback)
	os.log("PROC", "Process Space started")
	proc.run = nil
	--enter a loop that runs processes--
	local minWait
	while true do
		local executionCountdown = 64 --resume a maximum of 64 times before pullSignal
		local pps = false
	
		while executionCountdown > 0 do
			--execute processes--
			minWait = math.huge
			
			--TODO: Actual scheduler that reorders threads depending on events
			--For instance, newly spawned threads are in the first scheduler group
			--Then threads that have a Future completed go in the second scheduler group
			--Lastly, threads that have just simply yielded go to the third scheduler group
			--This way, latency is minimized across futures
			--Also add direct resume, where new threads and threads that stopped waiting run next
				--if they haven't run in this iteration before
			
			for id, thread in pairs(threads) do
				handleThread(id, thread)
			end
			
			--os.logf("PROC", "%d new threads this loop", #scheduleNext)
			--[[for i=1, #scheduleNext do
				handleThread(scheduleNext[i].id, scheduleNext[i])
			end
			scheduleNext = {}]]
	
			--very end...--
			--test to see if any processes have pending signals--
			pps = false
			for id, thread in pairs(threads) do
				minWait = math.min(minWait, (thread.waitUntil or math.huge)-computer.uptime())
				if thread.error == nil and not thread.waiting then
					pps = true
					break
				end
			end
			executionCountdown = executionCountdown-1
			
			if not pps then
				break
			end
		end
		
		callback(pps, minWait)
	end
end

function proc.suspendThread()
	coroutine.yield()
end

function proc.waitThread(future, timeout, onTimeout)
	local t = table.pack(coroutine.yield(future, timeout, onTimeout))
	
	if not t[1] then
		error(t[2], 2)
	end
	
	return table.unpack(t, 2)
end

function proc.sleepThread(time)
	coroutine.yield(time)
end

function proc.getCurrentProcess()
	return currentThread and currentThread.process or nil
end

function proc.getTrustLevel()
	return currentThread and processes[currentThread.process].trustLevel or -1
end

function proc.getParentProcess(pid)
	pid = pid or proc.getCurrentProcess()
	return processes[pid].parent
end

function proc.getProcessName(pid)
	pid = pid or proc.getCurrentProcess()
	return processes[pid].name
end

function proc.getEnv(name, pid)
	checkArg(1,name,"string")
	pid = pid or proc.getCurrentProcess()
	
	return processes[pid].variables[tostring(name)]
end

function proc.setEnv(name, value, pid)
	checkArg(1,name,"string")
	pid = pid or proc.getCurrentProcess()
	
	local m, why = kobject.isMarshallable(value)
	if not m then
		error(("Environmental variable contains unmarshallable objects (%s)"):format(why))
	end
	processes[pid].variables[tostring(name)] = value
end

function proc.listEnv(env, pid)
	checkArg(1,env,"table","nil")
	pid = pid or proc.getCurrentProcess()
	
	env = env or {}
	for name, value in pairs(processes[pid].variables) do
		env[name] = value
	end
	return env
end

--[=[function ps.getInfo(id,info)
	checkArg(1,id,"number")
	checkArg(2,info,"table","nil")
	if not processes[id] then
		return nil, "No such process"
	end
	info = info or {}
	local proc = processes[id]
	info.name = proc.name
	info.trustLevel = proc.trustLevel
	info.error = proc.error
	info.status = coroutine.status(proc.thread)
	info.parent = proc.parent
	info.peaceful = proc.peaceful
	info.memory = proc.memory
	return info
end

function ps.getTrustLevel(pid)
	pid = pid or currentProcess
	return pid == nil and -1 or processes[pid].trustLevel
end

function ps.remove(id)
	--removes a process--
	checkArg(1,id,"number")
	if not processes[id] then
		return false, "No such process"
	end
	local proc = processes[id]
	if proc.kernelspace and not ps.isKernelMode() then
		return false, "Permission denied"
	end
	processes[id] = nil
end

function ps.getCurrentProcess()
	return currentProcess
end

function ps.getParentProcess(pid)
	return processes[pid or currentProcess].parent
end

function ps.getProcessName(pid)
	return processes[pid or currentProcess].name
end

function ps.getArguments()
	return processes[currentProcess].args
end

function ps.getGlobals()
	return processes[currentProcess].globals
end

function ps.hasEvents()
	return #processes[currentProcess].signalQueue > 0
end

function ps.getEnv(name)
	checkArg(1,name,"string")
	return processes[currentProcess].variables[tostring(name)]
end

function ps.setEnv(name,value)
	checkArg(1,name,"string")
	local m, why = kobject.isMarshallable(value)
	if not m then
		error(("Environmental variable contains unmarshallable objects (%s)"):format(why))
	end
	processes[currentProcess].variables[tostring(name)] = value
end

function ps.listEnv(env)
	checkArg(1,env,"table","nil")
	env = env or {}
	for name, value in pairs(processes[currentProcess].variables) do
		env[name] = value
	end
	return env
end

function ps.pushProcessSignal(...)
	local proc = processes[currentProcess]
	proc.signalQueue[#proc.signalQueue+1] = {...}
end

function ps.yield(...)
	local proc = processes[currentProcess]
	table.insert(proc.signalQueue,{...})
	coroutine.yield(0)
end

function ps.pushEventTo(id, event)
	checkArg(1,id,"number")
	if not processes[id] then
		return nil, "No such process"
	end
	--TODO: Better permission management
	--[[if ps.getTrustLevel() > 1000 then
		return false, "Permission denied"
	end]]
	local proc = processes[id]
	proc.signalQueue[#proc.signalQueue+1] = event
end

function ps.listProcesses(pl)
	checkArg(1,pl,"table","nil")
	--clear the table
	pl = pl or {}
	for i, v in ipairs(pl) do
		pl[i] = nil
	end
	for i, v in pairs(processes) do
		pl[#pl+1] = i
	end
	table.sort(pl)
	return pl
end

function ps.pause(id,...)
	local n = select("#",...)
	if not id then
		if n == 0 then
			coroutine.yield()
		else
			coroutine.yield("pause",...)
		end
	else
		if not processes[id] then
			return nil, "No such process"
		end
		if not ps.isKernelMode() then
			return false, "Permission denied"
		end
		processes[id].wait = nil
	end
end

function ps.resume(id)
	checkArg(1,id,"number")
	if not processes[id] then
		return nil, "No such process"
	end
	if not ps.isKernelMode() then
		return false, "Permission denied"
	end
	processes[id].wait = 0
end]=]
