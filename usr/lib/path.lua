local path = {}

function path.splitPath(path)
	local pt = {}
	for p in path:gmatch("[^/]+") do
		if p == ".." then
			pt[#pt] = nil
		elseif p ~= "." and p ~= "" then
			pt[#pt+1] = p
		end
	end
	return pt
end

function path.combine(...)
	local np = {}
	for i, v in ipairs(table.pack(...)) do
		checkArg(i, v, "string")
		for i, v in ipairs(path.splitPath(v)) do
			np[#np+1] = v
		end
	end
	return "/"..table.concat(np,"/")
end

function path.fixPath(p)
	checkArg(1, p, "string")
	local sp = splitPath(p)
	return (p:sub(1,1) == "/" and "/" or "")..table.concat(sp,"/"), sp
end

function path.isChildOf(parent,child)
	local parent, sparent = path.fixPath(parent)
	local child, schild = path.fixPath(child)
	return child:sub(1,#parent) == parent, #schild-#sparent, schild, sparent
end

return path
