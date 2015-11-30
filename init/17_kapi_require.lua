function kapi.patches.require(env, pid, trustLevel)
	if pid > 0 then
		env.package = {
			loaded = {filesystem = env.fs},
			path = "/sec/lib/?.lua;/sec/lib/?/init.lua;./?.lua;./?/init.lua"
		}
		
		env.require = function(name)
			--HERE IS ANOTHER INSTANCE WHERE kobject.newValueFuture would need to be used. GOD DAMMIT
			
			local pathname = name:gsub("%.", "/")
			
			local completer, future = kobject.newFuture()
			local completed = false
			local failed = 0
			local count = 0
			
			for path in env.package.path:gmatch("[^;]+") do
				count = count+1
				
				path = path:gsub("%?", pathname)
				os.logf("PACKAGE", "%s", path)
				env.fs.exists(path):after(function(e)
					os.logf("PACKAGE", "%s: %s", path, tostring(e))
					if not e then
						failed = failed+1
						if failed == count then
							completer:complete(nil)
						end
						return
					end
					
					os.logf("PACKAGE", "%s exists", path)
					if completed then return end
					completed = true
					completer:complete(path)
				end)
			end
			
			return env.await(future:after(function(path)
				if path then
					os.logf("PACKAGE", "Found package at %s", path)
					local handle = env.await(fs.open(path, "r"))
					env.await(env.fs.readAsStream(handle, math.huge)):join():after(function(src)
						local f, e = load(src, "="..name)
						if not f then error(e) end
						local pkg = f(path) or true
						env.package.loaded[name] = pkg
						return pkg
					end)
				else
					error("Package not found!")
				end
			end))
		end
	end
end
