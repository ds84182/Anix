async(function(...)

local io = require "io"

local args = table.pack(...)

if args.n == 0 then
	while true do
		local content = await(io.read(2048))
		if not content then break end
		io.write(content)
	end
else
	for i=1, args.n do
		local fh, err = await(fs.open(args[i], "r"))
		if not fh then
			print(args[i]..": "..err)
		else
			local completer, future = kobject.newFuture()
			fs.readAsStream(fh):listen(function(chunk)
				io.write(chunk)
			end):onClose(function()
				completer:complete()
			end)

			await(future)
		end
	end
end

end, ...)
