-- Utility methods to do various things

kapi.apienv.utils = {}

function kapi.apienv.utils.newSplitter(delim)
  local buffer = ""

  return function(hasData, data)
    if hasData then
      local i = 1
      local lines = {}
      while true do
        local nl = data:find(delim, i)
        if nl then
          local line = buffer..data:sub(i,nl-1)
          buffer = ""
          i = nl+1
          lines[#lines+1] = line
        else
          buffer = buffer..data:sub(i)
          break
        end
      end
      return lines
    else
      return {buffer}
    end
  end
end

function kapi.apienv.utils.newLineSplitter()
  return kapi.apienv.utils.newSplitter("\n")
end
