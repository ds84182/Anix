function kapi.patches.fsapi(env, pid, trustLevel)
	if pid > 0 then
		local fs
    
    local function wrapAsync(func)
      return function(...)
        return env.async(func, ...)
      end
    end

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

			return env.await(fs:invoke("open", path, mode))
		end
    env.fs.open = wrapAsync(env.fs.open)

		function env.fs.getHandleInfo(handle)
			if not fs then
				env.await(env.fs.init())
			end

			return env.await(fs:invoke("getHandleInfo", handle))
		end
    env.fs.getHandleInfo = wrapAsync(env.fs.getHandleInfo)

		function env.fs.read(handle, bytes)
			if not fs then
				env.await(env.fs.init())
			end

			return env.await(fs:invoke("read", handle, bytes))
		end
    env.fs.read = wrapAsync(env.fs.read)

		function env.fs.readAsStream(handle, chunks)
      checkArg(2, chunks, "number", "nil")
			chunks = chunks or math.huge
      
      local readStream, writeStream = env.kobject.newStream()
      
      env.async(function()
        if not fs then
          env.await(env.fs.init())
        end

        local handleInfo = env.await(env.fs.getHandleInfo(handle))
        env.kobject.setLabel(readStream, "Read Stream for "..handleInfo.path)

        -- TODO: setAsyncContextName("read_stream_"..handleInfo.path.."_"..handle:getId())
        
        while true do
          local bytes = env.await(env.fs.read(handle, blockSize))

          if bytes then
            writeStream:send(bytes)
          else
            break
          end
        end

        writeStream:close()
      end)

			return readStream
		end

		function env.fs.write(handle, bytes)
			if not fs then
				env.await(env.fs.init())
			end

			return env.await(fs:invoke("write", handle, bytes))
		end
    env.fs.write = wrapAsync(env.fs.write)

		function env.fs.close(handle)
			if not fs then
				env.await(env.fs.init())
			end

			return env.await(fs:invoke("close", handle))
		end
    env.fs.close = wrapAsync(env.fs.close)

		function env.fs.exists(path)
			if not fs then
				env.await(env.fs.init())
			end

			return env.await(fs:invoke("exists", path))
		end
    env.fs.exists = wrapAsync(env.fs.exists)

		function env.fs.list(path)
			if not fs then
				env.await(env.fs.init())
			end

			return env.await(fs:invoke("list", path))
		end
    env.fs.list = wrapAsync(env.fs.list)
	end
end
