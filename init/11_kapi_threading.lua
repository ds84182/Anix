-- Utilities to implement async/await on top of process microtasks

function kapi.patches.threading(env, pid, trustLevel)
  local threadData = setmetatable({}, {__mode="k"})

  env.await = function(future, delay)
    local coro = coroutine.running()
    local data = threadData[coro]
    assert(data, "Attempt to await in non-async context")
    if not future and delay then
      proc.schedule(function()
        assert(coroutine.resume(coro, true))
      end, {}, delay)
    elseif future and delay then
      local waiting = true
      proc.schedule(function()
        if waiting then
          waiting = false
          assert(coroutine.resume(coro, true))
        end
      end, {}, delay)

      future:after(function(...)
        if waiting then
          waiting = false
          assert(coroutine.resume(coro, true, ...))
        end
      end, function(err)
        if waiting then
          waiting = false
          assert(coroutine.resume(coro, false, err))
        end
      end)
    else
      future:after(function(...)
        assert(coroutine.resume(coro, true, ...))
      end, function(err)
        assert(coroutine.resume(coro, false, err))
      end)
    end
    local ret = table.pack(coroutine.yield())
    if not ret[1] then error(ret[2], 0) end
    return table.unpack(ret, 2)
  end
  env.async = function(func, ...)
    local completer, future = env.kobject.newFuture()
    local data = {}
    local coro = coroutine.create(function(...)
      local res = table.pack(xpcall(func, debug.traceback, ...))

      if res[1] then
        completer:complete(table.unpack(res, 2, res.n))
      else
        completer:error(res[2])
      end
    end)
    threadData[coro] = data
    proc.schedule(function(...)
      assert(coroutine.resume(coro, ...))
    end, table.pack(...))
    return future
  end
  env.yield = function()
    local coro = coroutine.running()
    local data = threadData[coro]
    assert(data, "Attempt to yield in non-async context")
    proc.schedule(function()
      assert(coroutine.resume(coro))
    end, {})
    return coroutine.yield()
  end
  env.sleep = function(delay)
    return env.await(nil, delay)
  end
  env.makeAsync = function(func)
    return function(...)
      return env.async(func, ...)
    end
  end
end
