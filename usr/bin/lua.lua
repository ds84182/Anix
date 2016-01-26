require "io"

print(_VERSION)

while true do
	io.write "> "
	local line = await(term.read())
	print()
	
	if not line then break end
end
