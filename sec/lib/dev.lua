--dev: library for working with devices (components)

local dev = {}

function dev.onComponentAdded(typ)
	checkArg(1, typ, "string", "nil")
	
	if typ then
		return await(getSignalStream()):where(function(sig)
			return sig[1] == "component_added" and sig[3] == typ
		end):map(function(sig)
			return sig[2]
		end)
	else
		return await(getSignalStream()):where(function(sig)
			return sig[1] == "component_added"
		end):map(function(sig)
			return sig[2]
		end)
	end
end

function dev.onComponentRemoved(typ)
	--this tracks both type and address
	checkArg(1, typ, "string", "nil")
	
	if typ then
		return await(getSignalStream()):where(function(sig)
			return sig[1] == "component_removed" and (sig[2] == typ or sig[3] == typ)
		end):map(function(sig)
			return sig[2]
		end)
	else
		return await(getSignalStream()):where(function(sig)
			return sig[1] == "component_removed"
		end):map(function(sig)
			return sig[2]
		end)
	end
end

-- the rest of these functions interface with the dev process

return dev
