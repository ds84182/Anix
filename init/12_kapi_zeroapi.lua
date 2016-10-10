function kapi.patches.zeroapi(env, pid, trustLevel)
  if pid > 0 then
    local api

    function env.initAPI()
      api = proc.getEnv "API"

      return api:invoke("init")
    end

    local function wrapAsync(func)
      return function(...)
        return env.async(func, ...)
      end
    end

    local function rpcCall(method)
      return wrapAsync(function(...)
        if not api then
          env.await(env.initAPI())
        end

        return env.await(api:invoke(method, ...))
      end)
    end

    env.os.log = rpcCall "log"

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
