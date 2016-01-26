function kapi.patches.require(env, pid, trustLevel)
	if pid > 0 then
		env.package = {
			loaded = {filesystem = env.fs},
			path = "/sec/lib/?.lua;/sec/lib/?/init.lua;/usr/lib/?.lua;/usr/lib/?/init.lua;./?.lua;./?/init.lua"
		}
		
		env.require = function(name)
			if env.package.loaded[name] then
				return env.package.loaded[name]
			end
			
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
			
			local pkg --total HAXX to get a function through
			
			env.await(future:after(function(path)
				if path then
					os.logf("PACKAGE", "Found package at %s", path)
					local handle = env.await(env.fs.open(path, "r"))
					env.fs.readAsStream(handle, math.huge):join():after(function(src)
						env.fs.close(handle)
						local f, e = load(src, "="..name, nil, proc.getGlobals())
						if not f then error(e) end
						pkg = f(path) or true
						env.package.loaded[name] = pkg
					end)
				else
					error("Package not found!")
				end
			end))
			
			return pkg
		end
	end
end
