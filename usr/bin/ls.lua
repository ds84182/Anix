async(function(...)

local io = require "io"

local args = table.pack(...)

local function printListing(path)
	return fs.list(path):after(function(list)
		print(table.concat(list, " "))
	end)
end

if args.n == 0 then
	await(printListing(proc.getEnv("PWD") or ""))
elseif args.n == 1 then
	await(printListing(args[1]))
else
	for i=1, args.n do
		print(args[i]..":")
		await(printListing(args[i]))
		print()
	end
end

end, ...)
