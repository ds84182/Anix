require "io"
local inet = require "inet"

inet.debug = true

inet.request("http://example.com"):after(function(handle)
	local data = await(inet.read(handle))
	print("Received "..(#data).." bytes")
	await(inet.close())
end)
