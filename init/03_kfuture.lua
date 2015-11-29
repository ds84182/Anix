local objects = kobject.objects

--Kernel futures--
--Futures are callbacks, basically--
--They are kinda implemented like Streams, but they don't broadcast--

local Future = kobject.mt {
	__index = {},
	__type = "Future"
}

function Future.__index:init()
	kobject.checkType(self, Future)
	
	local data = objects[self].data
	
	if data.future then
		--os.logf("KFUTURE", "Deleting old future %s %d", data.future.object, objects[data.future.object].owner)
		kobject.delete(data.future.object) --delete older futures binded to the completer
	end
	
	--always overwrite previous future
	data.future = {
		object = self,
		callback = nil
	}
end

function Future.__index:after(callback)
	kobject.checkType(self, Future)
	
	local data = objects[self].data
	
	if data.future.object == self then
		local completer, future = kobject.newFuture()
		data.future.callback = function(...)
			completer:complete(callback(...))
		end
	
		return future
	else
		return nil, "future replaced by cloned object"
	end
end

function Future.__index:notify(data)
	kobject.checkType(self, Future)
	
	kobject.notify(self, data)
end

function Future.__index:onNotification(d)
	kobject.checkType(self, Future)
	
	local data = objects[self].data
	if data.future and data.future.object == self then
		if data.future.callback then
			proc.resumeThread(
			proc.createThread(data.future.callback, nil, d, objects[self].owner)
			)
		end
		
		--os.logf("KFUTURE", "%s completed %d", self, objects[self].owner)
		data.future = nil
		kobject.delete(self)
	end
end

local Completer = kobject.mt {
	__index = {},
	__type = "Completer"
}

function Completer.__index:complete(...)
	kobject.checkType(self, Completer)
	
	local message = table.pack(...)
	for i=1, message.n do
		kobject.checkMarshallable(i, message[i])
	end
	
	local data = objects[self].data
	if data.future then
		data.future.object:notify(message)
		kobject.delete(self)
		return true
	end
	
	object.delete(self)
	
	return false, "endpoint not connected"
end

function kobject.newFuture()
	--creates a new kernel stream--
	--this returns two objects: a completer and a future
	
	--os.logf("KFUTURE", "New future %s", debug.traceback())
	
	local c = kobject.new(Completer)
	local f = kobject.clone(c, Future)
	
	kobject.own(c)
	kobject.own(f)
	
	return c, f
end
