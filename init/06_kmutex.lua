local objects = kobject.objects

--Kernel mutexes--
--Mutexes are objects that can be locked by one thread at a time--
--When it is unlocked, it notifies the next mutex instance in the wait queue--
--Mutex isn't used much, only when two options that modify a shared resource are running at the same exact time--

--Example:
--[[
local mutexA = kobject.newMutex()
local mutexB = mutexA:duplicate()

--in a thread
mutexA:lock()
accessSharedResource()
mutexA:unlock()

--in another thread
mutexB:lock()
accessSharedResource()
mutexB:unlock()
]]

local Mutex = kobject.mt {
	__index = {},
	__type = "Mutex"
}

function Mutex.__index:init()
	kobject.checkType(self, Mutex)

	local data = objects[self].data

	if not data.waitList then
		data.waitList = {}
		data.locked = false
	end
end

function Mutex.__index:lock()
	kobject.checkType(self, Mutex)

	local data = objects[self].data

	if data.locked then
		local completer, future = kobject.newFuture()

		data.waitList[#data.waitList+1] = completer

		return future
	else
		data.locked = true
		return kobject.newCompletedFuture()
	end
end

--[[function Mutex.__index:awaitLock(timeout)
	kobject.checkType(self, Mutex)

	local future = self:lock()

	if future then
		proc.waitThread(future, timeout)
		return true
	else
		return false
	end
end]]

function Mutex.__index:performAtomic(func, ...)
	kobject.checkType(self, Mutex)

  local args = table.pack(...)
	return self:lock():after(function()
    local s = table.pack(xpcall(func, debug.traceback, table.unpack(args, 1, args.n)))
    
    if not s[1] then
      error(s[2], 2)
    else
      return table.unpack(s, 2)
    end
  end):after(function(...) -- Catches the case where another future is returned from func. We need to unlock when we return the value!
    self:unlock()
    return ...
  end, function(err)
    self:unlock()
    error(err)
  end)
end

function Mutex.__index:unlock()
	kobject.checkType(self, Mutex)

	local data = objects[self].data

	if data.locked then
		data.locked = false

		local completer = table.remove(data.waitList, 1)
		if completer then
			data.locked = true
			completer:complete()
		end
	end
end

function kobject.newMutex()
	--creates a new kernel mutex--

	local mutex = kobject.new(Mutex)

	kobject.own(mutex)

	return mutex
end
