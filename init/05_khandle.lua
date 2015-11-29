local objects = kobject.objects

--An object that represents another internal object
--[[
For example: Say you have a global filesystem, where files are opened globally instead of per process.
If you allocate the numbers sequentially, you can easily use someone else's file handle.
	On the other hand, if you restrict file handles to the process that opened them, then you can't send a file handle to another
		process.

Handles allow you to uniquely identify a resource via non guessable ids.
]]

--xorshift implementation in lua, compatible with 5.2 and 5.3--
local randomseed, random_int32, random
do
	local seed128 = {}
	local bit = bit32

	function randomseed(s)
		for i = 0, 3 do
			-- s = 1812433253 * (bit.bxor(s, bit.rshift(s, 30))) + i
			s = bit.bxor(s, bit.rshift(s, 30))
			local s_lo = bit.band(s, 0xffff)
			local s_hi = bit.rshift(s, 16)
			local s_lo2 = bit.band(1812433253 * s_lo, 0xffffffff)
			local s_hi2 = bit.band(1812433253 * s_hi, 0xffff)
			s = bit.bor(bit.lshift(bit.rshift(s_lo2, 16) + s_hi2, 16),
			bit.band(s_lo2, 0xffff))
			-- s = bit.band(s + i, 0xffffffff)
			local s_lim = -s --bit.tobit(s)
			-- assumes i<2^31
			if (s_lim > 0 and s_lim <= i) then
				s = i - s_lim
			else
				s = s + i
			end
			seed128[i+1] = s
		end
	end

	function random_int32()
		local t = bit.bxor(seed128[1], bit.lshift(seed128[1], 11))
		seed128[1], seed128[2], seed128[3] = seed128[2], seed128[3], seed128[4]
		seed128[4] = bit.bxor(bit.bxor(seed128[4], bit.rshift(seed128[4], 19)), bit.bxor(t, bit.rshift(t, 8)))
		return seed128[4]
	end

	function random(...)
		-- local r = xorshift.random_int32() * (1.0/4294967296.0)
		local rtemp = random_int32()
		local r = (bit.band(rtemp, 0x7fffffff) * (1.0/4294967296.0)) + (bit.tobit(rtemp) < 0 and 0.5 or 0)
		local arg = {...}
		if #arg == 0 then
			return r
		elseif #arg == 1 then
			local u = math.floor(arg[1])
			if 1 <= u then
				return math.floor(r*u)+1
			else
				error("bad argument #1 to 'random' (internal is empty)")
			end
		elseif #arg == 2 then
			local l, u = math.floor(arg[1]), math.floor(arg[2])
			if l <= u then
				return math.floor((r*(u-l+1))+l)
			else
				error("bad argument #2 to 'random' (internal is empty)")
			end
		else
			error("wrong number of arguments")
		end
	end
	
	randomseed(math.random(0, 2^32-1)+(os.clock()*10000))
	os.logf("XORSHIFT", "%d", random_int32())
end

local function reseed()
	randomseed(random_int32()+(os.clock()*10000))
end

local gen = 0

local Handle = kobject.mt {
	__index = {},
	__type = "Handle"
}

function Handle.__index:init(num)
	kobject.checkType(self, Handle)
	
	local data = objects[self].data
	
	if not data.numid then
		data.numid = num
	end
end

function Handle.__index:getId()
	kobject.checkType(self, Handle)
	
	local data = objects[self].data
	
	return data.numid
end

function kobject.newHandle()
	local num = random_int32()
	gen = gen+1
	if gen%16 == 0 then reseed() end
	
	local handle = kobject.new(Handle, num)
	
	kobject.own(handle)
	
	return handle
end
