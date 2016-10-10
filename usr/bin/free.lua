async(function()

local io = require "io"

local rows = {}

function addRow(...)
  rows[#rows+1] = table.pack(...)
end

local total, free = computer.totalMemory(), computer.freeMemory()

addRow("", "Total", "Used", "Free")
addRow("Mem:", tostring(total), tostring(total-free), tostring(free))

local columnMax = {}

for i=1, #rows do
  local row = rows[i]
  for j=1, #row do
    columnMax[j] = math.max(columnMax[j] or 0, #row[j])
  end
end

for i=1, #rows do
  local row = rows[i]
  for j=1, #row do
    local s = row[j]
    local padding = (" "):rep(columnMax[j]-#s)
    io.write(padding..s.." ")
  end
  io.write("\n")
end

end)
