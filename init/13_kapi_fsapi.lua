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
		
		function env.fs.getHandleInfo(handle)
			if not fs then
				env.await(env.fs.init())
			end
			
			return fs:invoke("getHandleInfo", handle)
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
			
			checkArg(2, chunks, "number", "nil")
			chunks = chunks or math.huge

			local handleInfo = env.await(env.fs.getHandleInfo(handle))
			local readStream, writeStream = env.kobject.newStream()
			env.kobject.setLabel(readStream, "Read Stream for "..handleInfo.path)

			proc.createThread(function()
				while true do
					local bytes = env.await(env.fs.read(handle, blockSize))
		
					if bytes then
						writeStream:send(bytes)
					else
						break
					end
				end
				
				writeStream:close()
			end, "read_stream_"..handleInfo.path.."_"..handle:getId())

			return readStream
			
			--return fs:invoke("readAsStream", handle, chunks)
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
		
		function env.fs.exists(path)
			if not fs then
				env.await(env.fs.init())
			end
			
			return fs:invoke("exists", path)
		end
	end
end
