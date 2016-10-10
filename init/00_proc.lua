proc = {}

local currentProcess = nil

local processes = {}

local nextPID = 0

function proc.spawn(source, name, args, vars, trustLevel, parent)
	checkArg(1,source,"string")
	checkArg(2,name,"string","nil")
	checkArg(3,args,"table","nil")
	checkArg(4,vars,"table","nil")
	checkArg(5,trustLevel,"number","nil")

	parent = parent or (proc.getCurrentProcess() or -1)

	trustLevel = trustLevel or proc.getTrustLevel(parent)+1

	local currentTrustLevel = proc.getTrustLevel(parent)
	if currentTrustLevel >= 1000 and trustLevel < currentTrustLevel then
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
		secureStorage = {}, --secure process variables, like current user
    microtaskQueue = {
      {function()
        os.logf("PROC", "Microtask queue test for pid %d", id)
      end, {}}
    },
    eventQueue = {}
	}
	processes[id] = object
  
  proc.scheduleMicrotask(func, kobject.copy(args or {}, id), id)

	os.logf("PROC", "Creating process \"%s\" with pid of %d, parent of %d, trust level %d", name, id, parent, trustLevel)
	return id
end

function proc.scheduleMicrotask(func, args, pid)
  pid = pid or proc.getCurrentProcess() or -1
  
  local process = processes[pid]
  process.microtaskQueue[#process.microtaskQueue+1] = {func, args}
end

function proc.scheduleEvent(func, args, delay, pid)
  pid = pid or proc.getCurrentProcess() or -1
  
  local process = processes[pid]
  process.eventQueue[#process.eventQueue+1] = {func, args, computer.uptime()+delay}
end

local signalStream

function proc.run(callback, ss)
	os.log("PROC", "Process Space started")
	proc.run = nil
	signalStream = ss
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
      
      for id, process in pairs(processes) do
        currentProcess = process
        
        if not process.dead then
          table.sort(process.eventQueue, function(a,b)
            return a[3] < b[3]
          end)
        
          while process.eventQueue[1] and process.eventQueue[1][3] <= computer.uptime() do
            process.microtaskQueue[#process.microtaskQueue+1] = table.remove(process.eventQueue, 1)
          end
        
          local start = computer.uptime()
          while process.microtaskQueue[1] and computer.uptime()-start < 0.1 do
            local mqt = table.remove(process.microtaskQueue, 1)
            local func, args = mqt[1], mqt[2]
            
            local success, err
            if args then
              success, err = xpcall(func, debug.traceback, table.unpack(args, 1, args.n or #args))
            else
              success, err = xpcall(func, debug.traceback)
            end
            
            if not success then
              process.dead = true
              process.reason = {peaceful = false, error = err}
              os.logf("PROC", "Error %s", err)
              break
            end
          end
        end
      end
      currentProcess = nil

			--very end...--
			--test to see if any threads have pending signals--
			pps = false
      for id, process in pairs(processes) do
        if process.microtaskQueue[1] then
          pps = true
          break
        else
          local pendingEvent = process.eventQueue[1]
          if pendingEvent then
            minWait = math.min(minWait, pendingEvent[3]-computer.uptime())
          end
        end
      end
			executionCountdown = executionCountdown-1

			if not pps then
				break
			end
		end

		--check and end processes--
		for id, process in pairs(processes) do
			if proc.canEnd(id) then
				os.logf("PROC", "Can end process %s (%d)", process.name, id)
				kobject.deleteProcessObjects(id)
				if proc.canEnd(id) then
					--some of the delete methods create new threads for their owner process
					--however, if the process is already dead (due to an error) we ignore them and continue
					proc.reparentChildren(id)
					processes[id] = nil
					signalStream:send({"process_death", id, process.parent, process.reason or {peaceful = true}})
				else
					os.logf("PROC", "Process %d spawned new threads or objects in object deletion", id)
				end
			end
		end

		callback(pps, minWait)
	end
end

function proc.kill(pid, reason)
	local process = processes[pid]

	os.logf("PROC", "Killing process %s (%d)", process.name, pid)
	process.dead = true
	process.reason = reason
end

function proc.getCurrentProcess()
	return currentProcess and currentProcess.id or nil
end

function proc.getTrustLevel(pid)
  pid = pid or proc.getCurrentProcess()
	if pid == -1 then return -1 end
	return processes[pid].trustLevel or -1
end

function proc.isTrusted(pid)
	return proc.getTrustLevel(pid) < 1000
end

function proc.getParentProcess(pid)
	pid = pid or proc.getCurrentProcess()
	return processes[pid].parent
end

function proc.getProcessName(pid)
	pid = pid or proc.getCurrentProcess()
	return processes[pid].name
end

function proc.canProcessModifyProcess(pidA, pidB)
	if (not processes[pidA]) or (not processes[pidB]) then
		return false
	end

	if pidA == pidB then
		return true
	end

	if processes[pidB].parent == pidA then
		return true
	end

	if proc.isTrusted(pidA) then
		return true
	end
end

function proc.getEnv(name, pid)
	checkArg(1, name, "string")
	checkArg(2, pid, "number", "nil")

	pid = pid or proc.getCurrentProcess()
	if not proc.canProcessModifyProcess(proc.getCurrentProcess(), pid) then
		return nil, "Permission Denied"
	end

	return kobject.copy(processes[pid].variables[name], proc.getCurrentProcess())
end

function proc.setEnv(name, value, pid)
	checkArg(1, name, "string")
	checkArg(3, pid, "number", "nil")

	pid = pid or proc.getCurrentProcess()
	if not proc.canProcessModifyProcess(proc.getCurrentProcess(), pid) then
		return nil, "Permission Denied"
	end

	local m, why = kobject.isMarshallable(value)
	if not m then
		error(("Environmental variable contains unmarshallable objects (%s)"):format(why))
	end
	processes[pid].variables[tostring(name)] = kobject.copy(value, pid)
end

function proc.listEnv(env, pid)
	checkArg(1, env, "table","nil")
	checkArg(2, pid, "number", "nil")

	pid = pid or proc.getCurrentProcess()
	if not proc.canProcessModifyProcess(proc.getCurrentProcess(), pid) then
		return nil, "Permission Denied"
	end

	env = env or {}
	for name, value in pairs(processes[pid].variables) do
		env[name] = kobject.copy(value, proc.getCurrentProcess())
	end
	return env
end

function proc.getSecureStorage(pid)
	checkArg(2, pid, "number", "nil")

	pid = pid or proc.getCurrentProcess()

	if not proc.isTrusted() then
		return nil, "Permission Denied"
	end

	return processes[pid].secureStorage
end

function proc.getGlobals(pid)
	pid = pid or proc.getCurrentProcess()

	return processes[pid].globals
end

function proc.canEnd(pid)
  local process = processes[pid]
	if process then
    if process.dead then return true end
    if process.microtaskQueue[1] or process.eventQueue[1] then
      return false
    end

		--check if we have any thread spawning kernel objects--
		--also, check if those objects have any references to itself in other processes if they spawn threads externally
			--(from other processes, not CPU events or anything super<process>natural)
		--threadSpawning = true
		for object, o in pairs(kobject.objects) do
			if o.owner == pid
				and object.threadSpawning
				and ((not object.closeable) and true or (not object:isClosed()))
				and (object.threadSpawningInternal and false or kobject.countOwningProcesses(object) > 1)
				and ((not object.activatable) and true or (object:isActive()))
				and not kobject.weakObjects[object] then
				--[[os.logf("PROC", "Process %d owns thread spawning object %s (opened %s, active %s)", pid, object,
					((not object.closeable) and true or (not object:isClosed())),
					((not object.activatable) and true or (object:isActive())))]]
				return false
			end
		end

		return true
	end
end

function proc.reparentChildren(ppid)
	for id, process in pairs(processes) do
		if process.parent == ppid then
			process.parent = 0
		end
	end
end

function proc.listProcesses()
	local list = {}

	for id in pairs(processes) do
		list[#list+1] = id
	end

	table.sort(list)

	return list
end

function proc.getProcessInfo(pid)
	checkArg(1, pid, "number")

	if not processes[pid] then
		return nil
	end

	local info = {}

	local p = processes[pid]

	info.id = pid
	info.name = p.name
	info.trustLevel = p.trustLevel
	info.parent = p.parent
	info.user = p.secureStorage.user

	info.kernelObjectCount = kobject.countProcessObjects(pid)
	info.threadCount = 0

	for id, thread in pairs(threads) do
		if thread.process == pid then
			info.threadCount = info.threadCount+1
		end
	end

	return info
end

function proc.getProcessKernelObjects(pid)
	if pid and pid ~= proc.getCurrentProcess() and not proc.isTrusted() then
		return nil, "Permission Denied"
	end

	pid = pid or proc.getCurrentProcess()

	local list = {}

	for object, objectData in pairs(kobject.objects) do
		if objectData.owner == pid then
			list[#list+1] = object
		end
	end

	return list
end
