------------
-- Allows you to communicate asynchronously with other processes
-- @module kstream

local objects = kobject.objects

--Kernel streams--

--- ReadStreams are attached to WriteStreams.
-- @type ReadStream
local ReadStream = kobject.mt {
	__index = {
		--async = true, --Async objects need update() to be called every now and then
		threadSpawning = true,
		closeable = true,
		activatable = true --call isActive to determine if it's active or not when doing the threadSpawning check
	},
	__type = "ReadStream"
}

--TODO: Maybe move init, notify, and delete to the metatable?
--TODO: Add WriteStream:newReadStream() to create non clone version of a readstream

--- Initializes a ReadStream object.
-- @local
-- @function ReadStream:init
function ReadStream.__index:init()
	kobject.checkType(self, ReadStream)

	--We want to have a unique per object identity for each ReadStream
	kobject.divergeIdentity(self)

	local o = objects[self]
	local data = o.data
	local identity = o.identity

	data.readStreams = data.readStreams or {}
	data.readStreams[identity] = {
		stream = kobject.weakref(self),
		mailbox = {},
		callback = nil,
		onCloseCallback = nil
	}
end

--- Initializes a ReadStream object after being cloned.
--- This method will move a ReadStream unless init is true.
-- @local
-- @function ReadStream:initClone
-- @tparam ReadStream other ReadStream being cloned from
-- @bool init Whether the stream should be unique or not
function ReadStream.__index:initClone(other, init)
	kobject.checkType(self, ReadStream)

	if init or kobject.isA(other, "WriteStream") then
		--if init then os.logf("READSTREAM", "Forced duplicate") end
		self:init()
	else
		--ReadStream clone, this should delete the older one and take over it
		local o = objects[self]
		local data = o.data
		local identity = o.identity
		local otherIdentity = objects[other].identity
		local stream = data.readStreams[otherIdentity]
		stream.stream = kobject.weakref(self)
		stream.callback = nil
		stream.onCloseCallback = nil
		kobject.delete(other)
		data.readStreams[identity] = stream
	end
end

--- Duplicates a ReadStream to a new unique instance.
-- @function ReadStream:duplicate
-- @treturn ReadStream New duplicated ReadStream object
function ReadStream.__index:duplicate()
	kobject.checkType(self, ReadStream)

	return kobject.clone(self, ReadStream, true)
end

--- Returns whether the ReadStream has been used or not.
-- @function ReadStream:isActive
-- @treturn boolean Whether the ReadStream has been used or not
function ReadStream.__index:isActive()
	kobject.checkType(self, ReadStream)

	local o = objects[self]
	local data = o.data
	local identity = o.identity
	local stream = data.readStreams[identity]

	return stream and stream.callback ~= nil
end

--- Listens to all event coming to a ReadStream with a callback.
--- The callback is executed in a new thread in the context of the process that owns this object.
-- @function ReadStream:listen
-- @func callback Callback function that gets executed for every data item received
-- @treturn ReadStream The ReadStream, used for function chaining
function ReadStream.__index:listen(callback)
	kobject.checkType(self, ReadStream)
	checkArg(1, callback, "function")

	local o = objects[self]
	local data = o.data
	local identity = o.identity
	local stream = data.readStreams[identity]
	stream.callback = callback

	self:notify()

	local writeStreamData = data.writeStream
	if writeStreamData then
		writeStreamData.mailbox[#writeStreamData.mailbox+1] = {"listen"}
		writeStreamData.stream.ref:notify()
	end

	return self
end

--- Allows the ReadStream to handle closure events.
--- The callback is called when the WriteStream is closed and when this ReadStream is explicitly closed.
-- @function ReadStream:onClose
-- @func callback The callback that is called in a new thread when the ReadStream is closed.
-- @treturn ReadStream The ReadStream, used for function chaining
function ReadStream.__index:onClose(callback)
	kobject.checkType(self, ReadStream)
	checkArg(1, callback, "function")

	local o = objects[self]
	local data = o.data
	local identity = o.identity
	local stream = data.readStreams[identity]

	if stream then
		stream.onCloseCallback = callback
	else
		--already closed
		proc.scheduleMicrotask(callback, {}, o.owner)
	end

	return self
end

--- Whether the ReadStream is closed or not.
-- @function ReadStream:isClosed
-- @treturn boolean Whether the ReadStream has been closed or not
function ReadStream.__index:isClosed()
	kobject.checkType(self, ReadStream)
	local o = objects[self]
	local data = o.data
	local identity = o.identity
	return data.readStreams[identity] == nil
end

--- Closes the ReadStream.
-- @function ReadStream:close
function ReadStream.__index:close()
	kobject.checkType(self, ReadStream)

	local o = objects[self]
	local data = o.data
	local identity = o.identity
	local stream = data.readStreams[identity]

	--[[if stream then
		os.logf("RS", "INVOKE CLOSE")
	end]]

	if stream and stream.onCloseCallback then -- and kobject.inOwnerProcess(self) then
		--This means that close events will not be fired in the event of a GC call
		--We could be in a different process or in the kernel when the GC fires
		--This is basically a safety measure
		--os.logf("RS", "INVOKE CLOSE SPAWN")
		proc.scheduleMicrotask(stream.onCloseCallback, {}, o.owner)
	end

	local writeStreamData = data.writeStream
	if writeStreamData then
		writeStreamData.mailbox[#writeStreamData.mailbox+1] = {"close"}
		writeStreamData.stream.ref:notify()
	end

	data.readStreams[identity] = nil

	--[[if not next(data.readStreams) then
		os.logf("RS", "No more readstreams!")
	end]]
end

--- Deletes the ReadStream. This also closes the ReadStream.
-- @function ReadStream:delete
function ReadStream.__index:delete()
	kobject.checkType(self, ReadStream)

	self:close()
end

--TODO: Remove mailbox crap maybe? Or make it so that :notify does mailbox stuff

--- Sends a notification to the ReadStream.
-- @local
-- @function ReadStream:notify
function ReadStream.__index:notify()
	kobject.checkType(self, ReadStream)

	kobject.notify(self)
end

--- Receives a notification and updates the ReadStream.
-- @local
-- @function ReadStream:onNotification
function ReadStream.__index:onNotification()
	kobject.checkType(self, ReadStream)

	self:update()
end

--- Updates the ReadStream by reading mailbox contents.
-- @local
-- @function ReadStream:update
function ReadStream.__index:update()
	kobject.checkType(self, ReadStream)

	local o = objects[self]
	local data = o.data
	local identity = o.identity
	local stream = data.readStreams[identity]

	if stream then
		local messageCountdown = 60 --process 60 messages before stopping
		while stream.mailbox[1] and messageCountdown > 0 do
			messageCountdown = messageCountdown-1
			local message = table.remove(stream.mailbox, 1)
			--os.logf("RS", "Receive message %s", message)

			if stream.callback then
				if message.type == "message" then
					proc.scheduleMicrotask(stream.callback, {message.data, message.source, self}, o.owner)
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
	--High Order Function ReadStream API--

	--- Creates a new stream from this stream that converts each message into zero or more messages.
	-- @function ReadStream:expand
	-- @func convert Converts one piece of input data into a table with multiple output values.
	-- @treturn ReadStream The newly created ReadStream
	function ReadStream.__index:expand(convert)
		kobject.checkType(self, ReadStream)
		checkArg(1, convert, "function")

		local rs, ws = kobject.newStream()

		ws:onListen(function() --start processing the data when needed
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
		end)

		return rs
	end

	--- Creates a new stream that converts each message of this stream to a new value using the convert function.
	-- @function ReadStream:map
	-- @func convert Converts one piece of input data into another output value.
	-- @treturn ReadStream The newly created ReadStream
	function ReadStream.__index:map(convert)
		kobject.checkType(self, ReadStream)
		checkArg(1, convert, "function")

		local rs, ws = kobject.newStream()

		ws:onListen(function()
			self:listen(function(data, source)
				ws:send(convert(data, source))
			end)

			self:onClose(function()
				ws:close()
			end)
		end)

		return rs
	end

	--- Creates a new stream that converts each message of this stream to a new value using the convert function.
	---
	--- nil values from convert are not sent. if you want this to be an error, use @{ReadStream:expand}
	---
	--- convert = function(hasData, data, source). hasData = false: source closing
	-- @function ReadStream:transform
	-- @func convert Converts one piece of input data into zero or more pieces of output data.
	-- @treturn ReadStream The newly created ReadStream
	function ReadStream.__index:transform(convert)
		kobject.checkType(self, ReadStream)
		checkArg(1, convert, "function")

		local rs, ws = kobject.newStream()

		ws:onListen(function()
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
		end)

		return rs
	end

	--- Pipe the messages of this stream into a WriteStream.
	-- @function ReadStream:pipe
	-- @tparam WriteStream WriteStream to pipe input into
	-- @treturn Future Future that completes when the stream closes
	function ReadStream.__index:pipe(ws)
		kobject.checkType(self, ReadStream)
		kobject.checkType(ws, WriteStream)

		local completer, future = kobject.newFuture()

		ws:onListen(function()
			self:listen(function(data)
				ws:send(data)
			end)

			self:onClose(function()
				completer:complete()
			end)
		end)

		return future
	end

	--- Converts all the data from the ReadStream into a list.
	-- @function ReadStream:toList
	-- @treturn Future Future that completes with the list when the ReadStream closes.
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

	--- Joins stream items together with an optional delimeter after it closes. Uses table.concat.
	-- @function ReadStream:join
	-- @string delim Delimeter to join the data together with.
	-- @treturn Future Future that completes with the joined data.
	function ReadStream.__index:join(delim)
		return self:toList():after(function(list)
			return table.concat(list, delim)
		end)
	end

	--- Omits items from a ReadStream if they do not belong.
	-- @function ReadStream:where
	-- @func test Tests to see if a piece of data should be sent or not.
	-- @treturn ReadStream The newly created ReadStream
	function ReadStream.__index:where(test)
		kobject.checkType(self, ReadStream)
		checkArg(1, test, "function")

		local rs, ws = kobject.newStream()

		ws:onListen(function()
			self:listen(function(data, source)
				if test(data, source) then
					ws:send(data)
				end
			end)

			self:onClose(function()
				ws:close()
			end)
		end)

		return rs
	end

	--- Gets a single value from the ReadStream then closes it.
	-- @function ReadStream:single
	-- @treturn Future Future that completes with a value or an error if the stream closes
	function ReadStream.__index:single()
		kobject.checkType(self, ReadStream)

		local completer, future = kobject.newFuture()

		self:listen(function(data)
			completer:complete(data)
			self:close()
		end)

		self:onClose(function()
			if kobject.isA(completer, "Completer") then
				completer:error("Stream closed")
			end
		end)

		return future
	end

	--- Gets only cnt values from the ReadStream then closes it.
	-- @function ReadStream:count
	-- @int cnt Number of values to get.
	-- @treturn ReadStream The newly created ReadStream
	function ReadStream.__index:count(cnt)
		kobject.checkType(self, ReadStream)

		local rs, ws = kobject.newStream()

		ws:onListen(function()
			self:listen(function(data)
				ws:send(data)
				cnt = cnt-1
				if cnt <= 0 then
					ws:close()
				end
			end)

			self:onClose(function()
				if kobject.isA(ws, "WriteStream") then
					ws:close()
				end
			end)
		end)

		return rs
	end

	--- Gets a single value from the ReadStream that matches test then closes it.
	-- @function ReadStream:single
	-- @func test Tests to see if a piece of data should be sent or not.
	-- @treturn Future Future that completes with a value or an error if the stream closes
	function ReadStream.__index:firstWhere(test)
		kobject.checkType(self, ReadStream)

		local completer, future = kobject.newFuture()

		self:listen(function(data)
			if test(data) then
				completer:complete(data)
				self:close()
			end
		end)

		self:onClose(function()
			if kobject.isA(completer, "Completer") then
				completer:error("Stream closed")
			end
		end)

		return future
	end
end

local WriteStream = kobject.mt {
	__index = {},
	__type = "WriteStream"
}

--TODO: data.writeStreams, onListen handler

function WriteStream.__index:init()
	local data = objects[self].data

	data.writeStream = {
		stream = kobject.weakref(self),
		mailbox = {},
		onReadStreamListen = nil,
		onReadStreamClose = nil
	}
end

function WriteStream.__index:initClone(other)
	kobject.checkType(self, WriteStream)
	kobject.checkType(other, WriteStream)

	local data = objects[self].data

	assert(data == objects[other].data, "WriteStreams are not the same!")

	data.writeStream = {
		stream = kobject.weakref(self),
		mailbox = {},
		onReadStreamListen = nil,
		onReadStreamClose = nil --TODO: Pause and resume support
	}
	kobject.delete(other)

	os.logf("WRITESTREAM", "WriteStream cloned!")
	--TODO: Single WriteStream, multiple ReadStream, method to merge multiple write streams together
	--When a writestream is cloned, it's MOVED (the source gets deleted)
end

function WriteStream.__index:close()
	kobject.checkType(self, WriteStream)

	--close all attached read streams--
	local data = objects[self].data
	data.writeStream = nil
	if data.readStreams then
		for _, v in pairs(data.readStreams) do
			local stream = v.stream.ref

			if stream then
				v.mailbox[#v.mailbox+1] = {type = "close"}

				stream:notify()
			end
		end
	end
end

function WriteStream.__index:delete()
	kobject.checkType(self, WriteStream)

	local data = objects[self].data

	if data.writeStream and data.writeStream.stream.ref == self then
		self:close()
	end
end

function WriteStream.__index:onListen(func)
	kobject.checkType(self, WriteStream)

	local data = objects[self].data

	data.writeStream.onReadStreamListen = func
end

function WriteStream.__index:onClose(func)
	kobject.checkType(self, WriteStream)

	local data = objects[self].data

	data.writeStream.onReadStreamClose = func
end

function WriteStream.__index:send(message)
	kobject.checkType(self, WriteStream)

	kobject.checkMarshallable(1, message)

	local data = objects[self].data
	if data.readStreams then
		for _, v in pairs(data.readStreams) do
			local stream = v.stream.ref

			if stream then
				v.mailbox[#v.mailbox+1] = {type = "message", data = kobject.copyFor(stream, message), source = proc.getCurrentProcess()}
				--os.logf("WS", "Send message %s", v.mailbox[#v.mailbox])

				stream:notify()
			end
		end
	end
end

function WriteStream.__index:notify()
	kobject.checkType(self, WriteStream)

	kobject.notify(self)
end

function WriteStream.__index:onNotification(val)
	kobject.checkType(self, WriteStream)

	local o = objects[self]
	local data = o.data
	local identity = o.identity
	local stream = data.writeStream

	if stream then
		local messageCountdown = 60 --process 60 messages before stopping
		while stream.mailbox[1] and messageCountdown > 0 do
			messageCountdown = messageCountdown-1
			local message = table.remove(stream.mailbox, 1)
			--os.logf("RS", "Receive message %s", message)

			if message[1] == "close" and stream.onReadStreamClose then
				proc.scheduleMicrotask(stream.onReadStreamClose, {}, o.owner)
			elseif message[1] == "listen" and stream.onReadStreamListen then
				proc.scheduleMicrotask(stream.onReadStreamListen, {}, o.owner)
			end
		end
	end
end

function kobject.newStream()
	--creates a new kernel stream--
	--this returns two objects: a read stream and a write stream

	local ws = kobject.new(WriteStream)
	local rs = kobject.clone(ws, ReadStream)

	kobject.own(ws)
	kobject.own(rs)

	return rs, ws
end
