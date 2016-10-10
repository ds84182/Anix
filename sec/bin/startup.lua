--Startup: reads /sec/etc/startup for the next executables to run

local function split(line, pattern)
  local tab = {}

  for s in line:gmatch("([^"..pattern.."]+)") do
    tab[#tab+1] = s
  end

  return tab
end

local execute = makeAsync(function(path, options)
  local handle, err = await(fs.open(path, "r"))
  if handle then
    local source = await(fs.readAsStream(handle, math.huge):join())
    fs.close(handle)

    local trustLevel = nil
    if options.untrusted then trustLevel = 1000 end
    local pid, err = await(proc.spawn(source, path:match("/?([^/]+)$"):gsub("%.lua$", ""), nil, nil, trustLevel))

    if not pid then
      os.logf("EXECUTE", "Error while starting %s: %s", path, err)
    end
  else
    os.logf("EXECUTE", "Error while starting %s: %s", path, err)
  end
end)

local a = os.clock()
fs.open("/sec/etc/startup", "r"):after(function(handle)
  os.logf("BENCH", "%s ms", (os.clock()-a)*1000)
  os.logf("MAIN", "%s", tostring(handle))
  if handle then
    fs.readAsStream(handle, math.huge)
      :transform(utils.newLineSplitter())
      :where(function(line) return line:sub(1,1) ~= "#" and #line > 0 end)
      :listen(function(line)
        os.logf("MAIN", "Starting %s", line)
        local s = split(line, " ")
        local options = {}

        for i=2, #s do
          local opt = s[i]

          local key,val = opt:match("^(.-)=(.+)$")

          if key then
            --TODO: Parse val for a list or something
            options[key] = val
          else
            os.logf("MAIN", "%s", opt)
            options[opt] = true
          end
        end

        execute(s[1], options)
      end)
      :onClose(function()
        fs.close(handle)
      end)
  else
    os.log("MAIN", "Startup list not found at /sec/etc/startup!")
  end
end)
