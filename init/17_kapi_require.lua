function kapi.patches.require(env, pid, trustLevel)
  if pid > 0 then
    env.package = {
      loaded = {filesystem = env.fs},
      path = "/sec/lib/?.lua;/sec/lib/?/init.lua;/usr/lib/?.lua;/usr/lib/?/init.lua;./?.lua;./?/init.lua"
    }

    env.package.getRequireSource = function(name)
      return env.async(function()
        local pathname = name:gsub("%.", "/")

        local completer, future = kobject.newFuture()
        local completed = false
        local failed = 0
        local count = 0

        for path in env.package.path:gmatch("[^;]+") do
          count = count+1

          path = path:gsub("%?", pathname)
          env.fs.exists(path):after(function(e)
            if not e then
              failed = failed+1
              if failed == count then
                completer:complete(nil)
              end
              return
            end

            if completed then return end
            completed = true
            completer:complete(path)
          end)
        end

        local path = env.await(future)

        if path then
          local handle = env.await(env.fs.open(path, "r"))
          local src = env.await(env.fs.readAsStream(handle, math.huge):join())
          env.fs.close(handle)
          return src
        else
          error("Package not found!")
        end
      end)
    end

    env.package.loadRequireSource = function(src, name)
      local f, e = load(src, "="..name, nil, proc.getGlobals())
      if not f then error(e) end
      local pkg = f(path) or true
      env.package.loaded[name] = pkg
      return pkg
    end

    -- TODO: localFuture API that contains a future that executes locally (no marshall errors)
    env.require = function(name)
      if env.package.loaded[name] then
        return env.package.loaded[name]
      end

      return env.package.loadRequireSource(env.await(env.package.getRequireSource(name)), name)
    end

    env.requireAll = function(tab, ...)
      if type(tab) == "string" then
        tab = table.pack(tab, ...)
      end
      local loaded = {}
      local errors = {}
      local completer, future = kobject.newFuture()
      local loadCount = 0
      local packageCount = tab.n or #tab

      local function incrementCount()
        loadCount = loadCount+1
        if packageCount == loadCount then
          completer:complete()
        end
      end

      for i=1, packageCount do
        local pkg = tab[i]
        env.package.getRequireSource(name):after(function(src)
          if env.package.loaded[pkg] then
            loaded[i] = env.package.loaded[pkg]
          else
            loaded[i] = env.package.loadRequireSource(src)
          end
          incrementCount()
        end):after(function()end, function(err)
          errors[#errors+1] = "Error while loading package "..pkg.."\n"..err
          incrementCount()
        end)
      end

      env.await(future)
      if errors[1] then
        error(table.concat(errors, "\n"))
      else
        return table.unpack(loaded, 1, packageCount)
      end
    end
  end
end
