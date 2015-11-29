function kapi.patches.fsapi(env, pid, trustLevel)
	if pid > 0 then
		local fs
		
		env.fs = {}
		function env.fs.init()
			return env.service.get("FS"):after(function(s)
				fs = s
				return s
			end)
		end
		
		function env.fs.open(path, mode)
			if not fs then
				env.await(env.fs.init())
			end
			
			return fs:invoke("open", path, mode)
		end
		
		function env.fs.read(handle, bytes)
			if not fs then
				env.await(env.fs.init())
			end
			
			return fs:invoke("read", handle, bytes)
		end
		
		function env.fs.readAsStream(handle, chunks)
			if not fs then
				env.await(env.fs.init())
			end
			
			return fs:invoke("readAsStream", handle, chunks)
		end
		
		function env.fs.write(handle, bytes)
			if not fs then
				env.await(env.fs.init())
			end
			
			return fs:invoke("write", handle, bytes)
		end
		
		function env.fs.close(handle)
			if not fs then
				env.await(env.fs.init())
			end
			
			return fs:invoke("close", handle)
		end
	end
end
