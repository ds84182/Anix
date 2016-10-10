async(function()

local io = require "io"
local term = require "term"

print(_VERSION)

while true do
	io.write "> "
	local line = await(io.read("*l"))
	print()

	if not line then break end

	local f,err = load("return "..line, "=in")

	if not f then
		f,err = load(line, "=in")
	end

	if f then
		local ret = table.pack(pcall(f))
		if not ret[1] then
			print(ret[2])
		else
			for i=2, ret.n do
				ret[i] = tostring(ret[i])
			end
			print(table.concat(ret, ", ", 2, ret.n))
		end
	else
		print(err)
	end
end

end)
