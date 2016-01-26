--Service API--

local zeroapi, processSpawnHandlers, processCleanupHandlers = ...

local globalServices = {}
local localServices = {}
local awaitingProcesses = {}

function zeroapi.service_get(pid, name)
	checkArg(1, name, "string")
	
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
	checkArg(1, mode, "string", "nil")
	
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
	checkArg(1, name, "string")
	
	localServices[pid] = localServices[pid] or {}
	localServices[pid][name] = ko
end

function zeroapi.service_registerglobal(pid, name, ko)
	checkArg(1, name, "string")
	
	if proc.getTrustLevel(pid) <= 1000 then
		globalServices[name] = ko
		os.logf("ZERO", "Added global service %s (%s)", name, tostring(ko))
		return true
	else
		return false, "process not trusted"
	end
end

function zeroapi.service_await(pid, name)
	checkArg(1, name, "string")
	
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

function processCleanupHandlers.service(pid, ppid)
	awaitingProcesses[pid] = nil
	localServices[pid] = nil
end
