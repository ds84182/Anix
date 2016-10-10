--Upcomming: The great threading refactor (Which was already finished by the way. This is just a reference comment at this point)
--Instead of having processes (bunch of coroutines) that invoke threads (bunch of coroutines)
--Merge them together!
--Processes are abstracted into a thread group, the main thread is the thread that started it all
--Objects will be marked as thread spawning. If a process has no threads and no thread spawning objects, it ends.
--This way, the kernel object APIs can access thread spawning features
--And it would pave way for a new thread scheduler
--No more object notifications, that would be handled as invoking the notification function directly, skipping the middle man
--Callbacks will be implemented as thread spawns under the owner process of the kernel object
--And the code for zero, filesystem, and startup should not change

--Reference benchmark values:
  --Old Core (You'll NEVER see the Old Core! MUHAHAHAHA):
  --filesystem.lua process load: 0.18ms
  --startup.lua loading handle open: 1.58 ms
  --startup.lua loading handle open+handle read stream+join: 4.52 ms
  --startup.lua loading startup list handle open+FS service get+zeroapi init: 3.48ms

  --New Core (Or Current Core...):
  --filesystem.lua process load: 0.159ms
  --startup.lua loading handle open: 0.835ms
  --startup.lua loading handle open+handle read stream+join: 2.107ms
  --startup.lua loading startup list handle open+FS service get+zeroapi init: 1.706ms

function kapi.patches.threading(env, pid, trustLevel)
  --[[local threads = {}
  local runningThread

  function env.spawn(func, name, ...)
    name = name or #threads+1
    threads[name] = {
      coro = coroutine.create(func),
      resumeValues = table.pack(...),
      resume = true,
      ok = true,
      waiting = nil
    }
  end]]

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
      completer:complete(func(...))
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

  --[=[function env.main(func, ...)
    --This is the async loop for every process--
    os.log("KAPI", "Main loop started")

    --threads.main = {coro = coroutine.create(func), resumeValues = {...}, resume = true, ok = true, waiting = nil}
    env.spawn(func, "main", ...)

    local function handleEvent(event)
      if event.type == "notify_object" then
        --os.logf("KAPI", "Notify object %s", event.object)
        env.spawn(function()
          event.object:onNotification(event.val)
        end)
      elseif event.type == "oc_signal" then --Sent to pid 0 only
        env.zero.handleSignal(event)
      elseif event.type == "process_death" then --Sent to pid 0 only
        env.zero.handleProcessDeath(event)
      end
    end

    while true do
      --env._updateOwnedObjects()

      for name, thread in pairs(threads) do
        if thread.resume then
          runningThread = thread
          thread.ok, thread.waiting = coroutine.resume(thread.coro, table.unpack(thread.resumeValues))
          thread.resume = false
          thread.resumeValues = nil

          if not thread.ok then
            os.logf("KAPI", "Error: %s", debug.traceback(thread.coro, thread.waiting))
          end

          if coroutine.status(thread.coro) ~= "suspended" then
            threads[name] = nil
          else
            if not thread.waiting then
              thread.resume = true
              thread.resumeValues = {}
            else
              thread.waiting:after(function(v)
                thread.resume = true
                thread.resumeValues = {v}
              end)
            end
          end
        end
      end

      runningThread = nil

      local instantResume = false
      for name, thread in pairs(threads) do
        instantResume = instantResume or thread.resume
      end

      if ps.hasEvents() then
        local countdown = 16
        while countdown > 0 and ps.hasEvents() do
          countdown = countdown-1
          local event = coroutine.yield(instantResume and 0 or math.huge)
          if event then
            handleEvent(event)
          else
            break
          end
        end
      else
        local event = coroutine.yield(instantResume and 0 or math.huge)
        if event then
          handleEvent(event)
        end
      end

      --TODO: Question whether we should auto exit when there are no more objects that can get notified and no more threads
    end
  end]=]
end
