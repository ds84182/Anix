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
		
		--service API
		env.service.get = rpcCall "service_get"
		env.service.registerLocal = rpcCall "service_registerlocal"
		env.service.registerGlobal = rpcCall "service_registerglobal"
		env.service.await = rpcCall "service_await"
		
		--process API extension: fills in environmental variable API if not defined
		env.proc.spawn = rpcCall "proc_spawn"
	end
end
