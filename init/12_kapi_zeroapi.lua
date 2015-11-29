function kapi.patches.zeroapi(env, pid, trustLevel)
	if pid > 0 then
		local api, replyStream, replyStreamOut
		local replyId = 0
		local apiCallbacks = {}
	
		function env.initAPI()
			api = proc.getEnv "API"
			replyStream, replyStreamOut = kobject.newStream()
			
			replyStream:listen(function(rpc)
				if rpc.id and apiCallbacks[rpc.id] then
					apiCallbacks[rpc.id]:complete(rpc)
					apiCallbacks[rpc.id] = nil
				end
			end)
			
			api:send({method = "init", arguments = {}, replyId = replyId, replyStream = replyStreamOut})
			local completer, future = kobject.newFuture()
			apiCallbacks[replyId] = completer
			
			replyId = replyId+1
			
			return future
		end
		
		local function rpcCall(method)
			return function(...)
				if not api then
					env.await(env.initAPI())
				end
			
				api:send({method = method, arguments = table.pack(...), replyId = replyId, replyStream = replyStreamOut})
				local completer, future = kobject.newFuture()
				apiCallbacks[replyId] = completer
			
				replyId = replyId+1
			
				return future:after(function(rpc)
					return table.unpack(rpc)
				end)
			end
		end
	
		function env.os.log(...)
			if not api then
				env.await(env.initAPI())
			end
			
			api:send({method = "log", arguments = {...}, replyId = replyId, replyStream = replyStreamOut})
			replyId = replyId+1
		end
		
		function env.os.logf(tag, format, ...)
			env.os.log(tag, format:format(...))
		end
		
		env.hello = rpcCall "hello"
		
		function env.service.get(name)
			if not api then
				env.await(env.initAPI())
			end
			
			api:send({method = "service_get", arguments = {name}, replyId = replyId, replyStream = replyStreamOut})
			local completer, future = kobject.newFuture()
			apiCallbacks[replyId] = completer
			
			replyId = replyId+1
			
			return future:after(function(rpc)
				return table.unpack(rpc)
			end)
		end
		
		function env.service.registerLocal(name, ko)
			if not api then
				env.await(env.initAPI())
			end
			
			api:send({method = "service_registerlocal", arguments = {name, ko}, replyId = replyId, replyStream = replyStreamOut})
			local completer, future = kobject.newFuture()
			apiCallbacks[replyId] = completer
			
			replyId = replyId+1
			
			return future:after(function(rpc)
				return table.unpack(rpc)
			end)
		end
		
		function env.service.registerGlobal(name, ko)
			if not api then
				env.await(env.initAPI())
			end
			
			api:send({method = "service_registerglobal", arguments = {name, ko}, replyId = replyId, replyStream = replyStreamOut})
			local completer, future = kobject.newFuture()
			apiCallbacks[replyId] = completer
			
			replyId = replyId+1
			
			return future:after(function(rpc)
				return table.unpack(rpc)
			end)
		end
	end
end
