------------
-- Allows you to manage kernel side objects
-- @module kobject

--Kernel Objects: Objects that are passed to usermode processes from the kernel--
--KObjects should be duplicated when sent to other processes. This is usually done by invoking kobject.clone with the pid of the
	--other process

kobject = {}

local pairs = pairs
local type = type
local getmetatable = getmetatable
local setmetatable = setmetatable
local tostring = tostring
local error = error

local MODE_KEYS = {__mode="k"}
local MODE_VALUES = {__mode="v"}

local objects = setmetatable({}, MODE_KEYS) -- keys: object id, value: {objectdata = {}, owner = pid, clonedFrom = kobject}
kobject.objects = objects
local dataToInstances = setmetatable({}, MODE_KEYS)
local weakObjects = setmetatable({}, MODE_KEYS) --weak objects are objects that are not depended on to keep the process running
--this fixes stdlib bugs where keeping a signalStream open while the rest of the application has already ended
kobject.weakObjects = weakObjects

local isMarshallable, copy

--- Checks whether an object is marshallable
-- @param v The object to test
-- @param hit Table of values already tested
-- @treturn boolean Whether the passed object is marshallable or not
-- @treturn string|nil Error Message if the object is not marshallable
function kobject.isMarshallable(v, hit)
	if hit and hit[v] then return true end --Table that was already hit before
	
	local t = type(v)
	if t == "table" then
		if objects[v] then
			if v.notMarshallable then
				return false, "contains unmarshallable "..tostring(v)
			end
			
			return true --Kernel Objects are safe to Marshall
		end
		
		if getmetatable(v) ~= nil then return false, "contains metatable" end --Metatables are unsafe to Marshall
		
		hit = hit or {}
		hit[v] = true
		
		for i, v in pairs(v) do
			local m, reason = isMarshallable(i, hit)
			if not m then return m, reason end --Index is not Marshallable
			
			m, reason = isMarshallable(v, hit)
			if not m then return m, reason end --Value is not Marshallable
		end
		
		return true
	elseif t == "thread" then
		return false, "contains thread" --Threads are not Marshallable
	elseif t == "function" then
		return false, "contains function" --Functions are not Marshallable
	else
		return true --Everything else is Marshallable
	end
end

isMarshallable = kobject.isMarshallable

--- Checks if a value is marshallable (usually used when checking arguments).
--- It throws an error if the passed value is not marshallable in the format
--- "bad argument #<argn> (<value type> not marshallable: <why>)"
-- @int argn The number for the argument it's checking, for formmating purposes
-- @param val The value to check
function kobject.checkMarshallable(argn, val)
	local m, why = isMarshallable(val)
	
	if not m then
		error(("bad argument #%d (%s not marshallable: %s)"):format(argn, type(val), why), 3)
	end
end

--- Copies a marshallable value from one process to another
-- @local
-- @param v Value to copy
-- @int pid Process to copy the value for
-- @tab[opt] cache Object cache
-- @return The value copied for the process given
function kobject.copy(v, pid, cache)
	--copys a value for marshall
	--this also gets a pid passed in for kobject clone ownership
	
	--if not cache then
	--	os.log("KOBJECT", "Copy!")
	--end
	
	if cache and cache[v] then return cache[v] end
	cache = cache or {}
	
	local t = type(v)
	if t == "table" then
		if objects[v] then
			local clone
			
			local instances = dataToInstances[objects[v].data]
			for instance in pairs(instances) do
				if objects[instance].owner == pid and objects[instance].metatable == objects[v].metatable and objects[instance].identity == objects[v].identity then
					clone = instance
					break
				end
			end
			
			if not clone then
				clone = kobject.clone(v)
			
				if pid then
					kobject.own(clone, pid)
				end
			end
			
			cache[v] = clone
			
			return clone
		end
		
		local nt = {}
		
		cache[v] = nt
		
		for i, v in pairs(v) do
			local ni = copy(i, pid, cache)
			local nv = copy(v, pid, cache)
			nt[ni] = nv
		end
		
		return nt
	else
		return v
	end
end
copy = kobject.copy

--- Creates a metatable for KObject types over an existing metatable.
---
--- The passed metatable must be in the format {__type = string, __index = table}
-- @local
-- @tab m The metatable to modify
-- @treturn table The modified metatable
function kobject.mt(m)
	m.__tostring = function(s)
		local o = objects[s].data
		return o.label and m.__type..": "..o.label or tostring(o.id):gsub("table", m.__type)
	end
	
	m.__metatable = "Not allowed."
	
	if not m.__newindex then
		m.__newindex = function()
			error("Bad.")
		end
	end
	
	m.__gc = function(s)
		if objects[s] then
			--os.logf("KOBJECT", "Collecting %s owned by %d", tostring(s), objects[s].owner)
		
			local su, e = pcall(kobject.delete, s)
			
			if not su then
				os.logf("KOBJECT", "Error in garbage collection: %s", e)
			end
		end
	end
	
	m.__superclasses = {}
	if m.__extend then
		local current = m.__extend
		while current do
			m.__superclasses[current] = true
			m.__superclasses[current.__type] = true
			current = current.__extend
		end
		
		for i, v in pairs(m.__extend.__index) do
			if not m.__index[i] then
				m.__index[i] = v
			end
		end
	end
	
	return m
end

--- Creates a new unowned KObject from the passed in metatable
-- @local
-- @tab metatable Metatable that has been passed through @{kobject.mt}
-- @param ... KObject constructor arguments
-- @treturn KObject A new KObject
function kobject.new(metatable, ...)
	local o = setmetatable({}, metatable)
	objects[o] = {
		data = {id = {}, creator = nil},
		owner = nil,
		clonedFrom = nil,
		identity = {},
		metatable = metatable
	}
	
	dataToInstances[objects[o].data] = setmetatable({[o] = true}, MODE_KEYS)
	
	if o.init then
		o:init(...)
	end
	
	return o
end

local function checkObject(argn, obj)
	if not objects[obj] then
		error(("bad argument #%d (not a valid kernel object)"):format(argn), 3)
	end
end

--- Clones a KObject with an optional new metatable and arguments.
--- This clones by making a new object with the same underlying data reference.
--- Cloned KObjects will compare as equal with eachother.
-- @local
-- @tparam KObject other The object to clone
-- @tab[opt] metatable Metatable, will use old one if nil.
-- @param ... KObject clone constructor arguments
-- @treturn KObject A clone of the other KObject
function kobject.clone(other, metatable, ...)
	checkObject(1, other)
	
	--links the same data to a new kobject
	metatable = metatable or objects[other].metatable
	local o = setmetatable({}, metatable)
	local oother = objects[other]
	objects[o] = {
		data = oother.data,
		owner = oother.owner,
		clonedFrom = other,
		identity = oother.identity,
		metatable = metatable
	}
	
	dataToInstances[oother.data][o] = true
	
	if o.initClone then
		o:initClone(other, ...)
	elseif o.init then
		o:init(...)
	end
	
	return o
end

--- Creates a new identity for an existing object.
---
--- Identities allow specific cloned instances to identify themselves against other clones.
-- @local
-- @tparam KObject obj Object to diverge the identity of
-- @todo Use XORShift to generate identities instead of using tables
function kobject.divergeIdentity(obj)
	checkObject(1, obj)
	
	objects[obj].identity = {}
end

--- Set the label of a KObject
-- @tparam KObject obj Object to set the label of
-- @string label The new label to set
-- @todo Compare the creator field with the current process when deciding on changing the label, and factor in trustedness
function kobject.setLabel(obj, label)
	checkObject(1, obj)
	checkArg(2, label, "string")
	
	objects[obj].data.label = label
end

--- Get the label of a KObject
-- @tparam KObject obj Object to get the label of
-- @treturn string Object label
function kobject.getLabel(obj)
	checkObject(1, obj)
	
	return objects[obj].data.label
end

--- Sets the ownership of a KObject
-- @local
-- @tparam KObject obj Object to set the ownership of
-- @int[opt] pid Process to set the ownership to, or the current process
function kobject.own(obj, pid)
	checkObject(1, obj)
	
	pid = pid or (proc.getCurrentProcess() or -1)
	
	local o = objects[obj]
	o.owner = pid
	if not o.data.creator then
		o.data.creator = pid
	end
end

--- Removes ownership from a KObject
-- @local
-- @tparam KObject obj Object to remove the ownership from
function kobject.disown(obj)
	checkObject(1, obj)
	
	objects[obj].owner = nil
end

--- Compares the owners of two KObjects
-- @local
-- @tparam KObject a The first object to test
-- @tparam KObject b The second object to test
-- @treturn boolean Whether the object have the same owner
function kobject.hasSameOwners(a, b)
	checkObject(1, a)
	checkObject(2, b)
	
	return objects[a].owner == objects[b].owner
end

--- Compares the owner of a KObject with the current running process
-- @local
-- @tparam KObject obj The object to test
-- @treturn boolean Whether the system is running under the same process that owns the KObject
function kobject.inOwnerProcess(obj)
	checkObject(1, obj)
	
	return proc.getCurrentProcess() == objects[obj].owner
end

--- Gets the process that created a KObject
-- @tparam KObject obj Object to get the creator from
-- @treturn int The process that created the object
function kobject.getCreator(obj)
	checkObject(1, obj)
	return objects[obj].data.creator
end

--- Deletes a KObject by removing it's attachment to it's data.
--- This method also calls the KObject's deconstructor.
--- Calling this method is not required. Garbage Collection also calls this.
-- @tparam KObject obj Object to delete
function kobject.delete(obj)
	--os.logf("KOBJECT", "Deleting %s owned by %d", tostring(obj), objects[obj].owner)
	checkObject(1, obj)
	
	if obj.delete then
		obj:delete()
	end
	
	dataToInstances[objects[obj].data][obj] = nil
	objects[obj] = nil
end

--- Deletes all objects owned by a specific process
-- @local
-- @int pid Process to delete all the objects of
function kobject.deleteProcessObjects(pid)
	checkArg(1, pid, "number")
	
	for object, od in pairs(objects) do
		if od.owner == pid then
			kobject.delete(object)
		end
	end
end

--- Counts all objects owned by a specific process
-- @local
-- @int pid Process to count number of owned object
-- @treturn int The number of KObjects owned by a specific process
function kobject.countProcessObjects(pid)
	checkArg(1, pid, "number")
	
	local num = 0
	
	for object, od in pairs(objects) do
		if od.owner == pid then
			num = num+1
		end
	end
	
	return num
end

--- Count number of processes that own a KObject (by data)
-- @local
-- @tparam KObject object Object to count references of
-- @treturn int The number of processes that own a reference to the KObject
function kobject.countOwningProcesses(object)
	checkObject(1, object)
	
	local notUniqueOwner = {}
	local count = 0
	
	for instance in pairs(dataToInstances[objects[object].data]) do
		if not notUniqueOwner[objects[instance].owner] then
			notUniqueOwner[objects[instance].owner] = true
			
			count = count+1
		end
	end
	assert(count ~= 0)
	
	return count
end

--- Utility method to call @{kobject.copy} for the owner of a specific object
-- @local
-- @tparam KObject obj Object owned by the copy target
-- @param v Value to copy
-- @return The value copied for the target process
function kobject.copyFor(obj, v)
	checkObject(1, obj)
	return copy(v, objects[obj].owner)
end

--- Utility method to get all instances of a piece of data from a KObject
-- @local
-- @tparam KObject obj Object to get the instances of
function kobject.instancesOf(obj)
	checkObject(1, obj)
	return dataToInstances[objects[obj].data]
end

function kobject.countInstances(obj)
	checkObject(1, obj)
	local count = 0
	for _ in pairs(dataToInstances[objects[obj].data]) do
		count = count+1
	end
	return count
end

function kobject.declareWeak(obj)
	checkObject(1, obj)
	weakObjects[obj] = true
end

function kobject.isWeak(obj)
	checkObject(1, obj)
	return not not weakObjects[obj]
end

local proxy_mt = {__mode = "k", __metatable="No."}

function kobject.weakref(ref)
	return setmetatable({ref=ref}, proxy_mt)
end

function kobject.isValid(obj)
	if not objects[obj] then return false end
	
	return true
end

function kobject.isA(obj, mt)
	local o = objects[obj]
	
	if not o then return false end
	
	if type(mt) == "string" then
		return mt == o.metatable.__type or o.metatable.__superclasses[mt]
	elseif type(mt) == "table" and type(getmetatable(mt)) == "nil" then
		return mt == o.metatable or o.metatable.__superclasses[mt]
	end
end

function kobject.checkType(obj, mt)
	if not kobject.isA(obj, mt) then
		if objects[obj] then
			error(("attempt to use %s as a %s"):format(objects[obj].metatable.__type, type(mt) == "table" and mt.__type or mt), 2)
		else
			error("not a valid kernel object", 2)
		end
	end
end

local notificationList = {}

function kobject.notify(obj, val)
	--objects can only be notified once per kobject.update
	--if you need multiple notifications, send one notify and push messages into a mailbox
	checkObject(1, obj)
	--[==[if objects[obj].owner == proc.getCurrentProcess() then
		--os.logf("KOBJECT", "Object notifying object in same process %s", tostring(obj))
		--obj:onNotification(val)
		proc.pushEventTo(proc.getCurrentProcess(), {type = "notify_object", object = obj, val = val})
		--[[ps.getGlobals().spawn(function()
			obj:onNotification(val)
		end)]]
	--[[elseif objects[obj].owner >= 0 then
		ps.pushEventTo(objects[obj].owner, {type = "notify_object", object = obj, val = kobject.copyFor(obj, val)})]]
	else
		notificationList[obj] = val or true
	end]==]
	obj:onNotification(kobject.copyFor(obj, val))
end

function kobject.update() --this gets called by the kernel
	--push all notifications
	--[[for o, v in pairs(notificationList) do
		local owner = objects[o].owner
		if owner >= 0 then
			proc.pushEventTo(owner, {type = "notify_object", object = o, val = kobject.copyFor(o, v)})
		else
			o:onNotification(v)
		end
		
		notificationList[o] = nil
	end]]
	
	--update async kernel objects
	--[[for o, v in pairs(kobject.objects) do
		if v.owner == -1 and o.async then
			o:update()
		end
	end]]
end
