local objects = kobject.objects

--Kernel streams--
local ReadStream = kobject.mt {
	__index = {
		--async = true, --Async objects need update() to be called every now and then
	},
	__type = "ReadStream"
}

--TODO: Maybe move init, notify, and delete to the metatable?
--TODO: Add WriteStream:newReadStream() to create non clone version of a readstream
function ReadStream.__index:init()
	kobject.checkType(self, ReadStream)
	
	local data = objects[self].data
	
	data.readStreams = data.readStreams or {}
	data.readStreams[self] = {
		mailbox = {},
		callback = nil,
		onCloseCallback = nil
	}
	
	--[[local count = 0
	for i, v in pairs(data.readStreams) do
		count = count+1
	end
	if count > 1 then
		os.logf("READSTREAM", "%d others listening", count-1)
	end]]
	
	--[[for other in pairs(kobject.instancesOf(self)) do
		if kobject.isA(other, WriteStream) then
			os.logf("READSTREAM", "%s", tostring(other))
			other:notify({type = "stream_connected", stream = self})
		end
	end]]
end

function ReadStream.__index:initClone(other)
	kobject.checkType(self, ReadStream)
	
	if kobject.isA(other, "WriteStream") then
		--error("CLONE FROM WS")
		self:init()
	else
		--ReadStream clone, this should delete the older one and take over it
		--os.logf("READSTREAM", "Stream duplicated and closed")
		local data = objects[self].data
		local stream = data.readStreams[other]
		stream.callback = nil
		stream.onCloseCallback = nil
		data.readStreams[self] = stream
		data.readStreams[other] = nil
		kobject.delete(other)
	end
end

function ReadStream.__index:listen(callback)
	kobject.checkType(self, ReadStream)
	checkArg(1, callback, "function")
	
	local data = objects[self].data
	local stream = data.readStreams[self]
	stream.callback = callback
	
	self:notify()
	
	return self
end

function ReadStream.__index:onClose(callback)
	kobject.checkType(self, ReadStream)
	checkArg(1, callback, "function")
	
	local data = objects[self].data
	local stream = data.readStreams[self]
	
	if stream then
		stream.onCloseCallback = callback
	else
		--already closed
		os.logf("RS", "INVOKE CLOSE SPAWN LATE")
		proc.createThread(callback, nil, nil, objects[self].owner)
	end
	
	return self
end

function ReadStream.__index:close()
	kobject.checkType(self, ReadStream)
	
	local data = objects[self].data
	local stream = data.readStreams[self]
	
	--[[if stream then
		os.logf("RS", "INVOKE CLOSE")
	end]]
	
	if stream and stream.onCloseCallback then -- and kobject.inOwnerProcess(self) then
		--This means that close events will not be fired in the event of a GC call
		--We could be in a different process or in the kernel when the GC fires
		--This is basically a safety measure
		--os.logf("RS", "INVOKE CLOSE SPAWN")
		proc.createThread(stream.onCloseCallback, nil, nil, objects[self].owner)
	end
	
	data.readStreams[self] = nil
end

function ReadStream.__index:delete()
	kobject.checkType(self, ReadStream)
	
	self:close()
end

function ReadStream.__index:notify()
	kobject.checkType(self, ReadStream)
	
	kobject.notify(self)
end

function ReadStream.__index:onNotification(val)
	kobject.checkType(self, ReadStream)
	
	self:update()
end

function ReadStream.__index:update()
	kobject.checkType(self, ReadStream)
	
	local data = objects[self].data
	local stream = data.readStreams[self]
	
	if stream then
		local messageCountdown = 60 --process 60 messages before stopping
		while stream.mailbox[1] and messageCountdown > 0 do
			messageCountdown = messageCountdown-1
			local message = table.remove(stream.mailbox, 1)
			--os.logf("RS", "Receive message %s", message)
			
			if stream.callback then
				if message.type == "message" then
					proc.createThread(stream.callback, nil, {message.data, message.source, self}, objects[self].owner)
				elseif message.type == "close" then
					self:close()
				end
			else
				table.insert(stream.mailbox, 1, message)
				break
			end
		end
	end
end

do
	--High level ReadStream API--
	
	--Creates a new stream from this stream that converts each message into zero or more messages
	function ReadStream.__index:expand(convert)
		kobject.checkType(self, ReadStream)
		checkArg(1, convert, "function")
	
		local rs, ws = kobject.newStream()
	
		self:listen(function(data, source)
			local list = convert(data, source)
			
			if type(list) == "table" then
				for i=1, #list do
					ws:send(list[i])
				end
			else
				--TODO Error
			end
		end)
	
		self:onClose(function()
			ws:close()
		end)
	
		return rs
	end

	--Creates a new stream that converts each message of this stream to a new value using the convert function
	function ReadStream.__index:map(convert)
		kobject.checkType(self, ReadStream)
		checkArg(1, convert, "function")
	
		local rs, ws = kobject.newStream()
	
		self:listen(function(data, source)
			ws:send(convert(data, source))
		end)
	
		self:onClose(function()
			ws:close()
		end)
	
		return rs
	end
	
	--Creates a new stream that converts each message of this stream to a new value using the convert function
	--nil values from convert are not sent. if you want this behavior, use :expand
	--convert = function(hasData, data, source). hasData = false: source closing
	function ReadStream.__index:transform(convert)
		kobject.checkType(self, ReadStream)
		checkArg(1, convert, "function")
	
		local rs, ws = kobject.newStream()
	
		self:listen(function(data, source)
			local list = convert(true, data, source)
			
			if type(list) == "table" then
				for i=1, #list do
					ws:send(list[i])
				end
			end
		end)
	
		self:onClose(function()
			local list = convert(false)
			
			if type(list) == "table" then
				for i=1, #list do
					ws:send(list[i])
				end
			end
			
			ws:close()
		end)
	
		return rs
	end

	--Pipe the messages of this stream into a WriteStream
	function ReadStream.__index:pipe(ws)
		kobject.checkType(self, ReadStream)
		kobject.checkType(ws, WriteStream)
	
		self:listen(function(data)
			ws:send(data)
		end)
	
		local completer, future = kobject.newFuture()
	
		self:onClose(function()
			completer:complete()
		end)
	
		return future
	end
	
	function ReadStream.__index:toList()
		local list = {}
		
		self:listen(function(data)
			list[#list+1] = data
		end)
		
		local completer, future = kobject.newFuture()
	
		self:onClose(function()
			completer:complete(list)
		end)
	
		return future
	end
	
	--Joins them... duh
	function ReadStream.__index:join(delim)
		return self:toList():after(function(list)
			return table.concat(list, delim)
		end)
	end
	
	function ReadStream.__index:where(test)
		kobject.checkType(self, ReadStream)
		checkArg(1, test, "function")
	
		local rs, ws = kobject.newStream()
	
		self:listen(function(data, source)
			if test(data, source) then
				ws:send(data)
			end
		end)
	
		self:onClose(function()
			ws:close()
		end)
	
		return rs
	end
end

local WriteStream = kobject.mt {
	__index = {},
	__type = "WriteStream"
}

function WriteStream.__index:close()
	--close all attached read streams--
	local data = objects[self].data
	if data.readStreams then
		for stream, v in pairs(data.readStreams) do
			v.mailbox[#v.mailbox+1] = {type = "close"}
			
			if stream.notify then
				stream:notify()
			end
		end
	end
end

function WriteStream.__index:delete()
	kobject.checkType(self, WriteStream)
	
	local hasWriteStream = false
	for other in pairs(kobject.instancesOf(self)) do
		if kobject.isA(other, WriteStream) then
			hasWriteStream = true
			break
		end
	end
	
	if not hasWriteStream then
		self:close()
	end
end

function WriteStream.__index:send(message)
	kobject.checkType(self, WriteStream)
	
	kobject.checkMarshallable(1, message)
	--if not kobject.isMarshallable(message) then return false, "not marshallable" end
	
	local data = objects[self].data
	if data.readStreams then
		for stream, v in pairs(data.readStreams) do
			v.mailbox[#v.mailbox+1] = {type = "message", data = kobject.copyFor(stream, message), source = proc.getCurrentProcess()}
			--os.logf("WS", "Send message %s", v.mailbox[#v.mailbox])
			
			if stream.notify then
				stream:notify()
			end
		end
	end
end

--[[function WriteStream.__index:notify(val)
	kobject.checkType(self, WriteStream)
	
	kobject.notify(self, val)
end

function WriteStream.__index:onNotification(val)
	kobject.checkType(self, WriteStream)
	
	if val.type == "stream_connected" then
		os.logf("WRITESTREAM", "%s connected", val.stream)
	end
end]]

function kobject.newStream()
	--creates a new kernel stream--
	--this returns two objects: a read stream and a write stream
	
	local ws = kobject.new(WriteStream)
	local rs = kobject.clone(ws, ReadStream)
	
	kobject.own(ws)
	kobject.own(rs)
	
	return rs, ws
end
