function kapi.patches.zeroapi(env, pid, trustLevel)
	if pid > 0 then
		local api
	
		function env.initAPI()
			api = proc.getEnv "API"
			
			return api:invoke("init")
		end
		
		local function rpcCall(method)
			return function(...)
				if not api then
					env.await(env.initAPI())
				end
				
				return api:invoke(method, ...)
			end
		end
	
		function env.os.log(...)
			if not api then
				env.await(env.initAPI())
			end
			
			api:invoke("log", ...)
		end
		
		function env.os.logf(tag, format, ...)
			env.os.log(tag, format:format(...))
		end
		
		env.hello = rpcCall "hello"
		env.getSignalStream = rpcCall "signalstream"
		
		--service API
		env.service.get = rpcCall "service_get"
		env.service.list = rpcCall "service_list"
		env.service.registerLocal = rpcCall "service_registerlocal"
		env.service.registerGlobal = rpcCall "service_registerglobal"
		env.service.await = rpcCall "service_await"
		
		--permission API
		env.perm.query = rpcCall "perm_query"
		env.perm.set = rpcCall "perm_set"
		
		--process API extension: fills in environmental variable API if not defined
		env.proc.spawn = rpcCall "proc_spawn"
	end
end
