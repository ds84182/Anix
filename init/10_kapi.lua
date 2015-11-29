kapi = {}

local apienv = {
	kobject = {
		newStream = kobject.newStream,
		newFuture = kobject.newFuture,
		newExport = kobject.newExport,
		newHandle = kobject.newHandle,
		delete = kobject.delete,
		setLabel = kobject.setLabel,
		getLabel = kobject.getLabel,
		countInstances = kobject.countInstances,
		getCreator = kobject.getCreator,
		isA = kobject.isA,
		checkType = kobject.checkType
	},
	proc = {
		getCurrentProcess = proc.getCurrentProcess,
		getEnv = proc.getEnv,
		setEnv = proc.setEnv,
		listEnv = proc.listEnv,
		getTrustLevel = proc.getTrustLevel,
		createThread = proc.createThread
		--[[createThread = function(func, name, args)
			return proc.createThread(func, name, args)
		end]]
	},
	os = {},
	service = {}
}

kapi.apienv = apienv
kapi.patches = {} --this contains a table of functions to call on an environment object during the patch phase

local function copyInto(dest, src)
	for i, v in pairs(src) do
		if type(v) == "table" then
			dest[i] = dest[i] or {}
			copyInto(dest[i], v)
		else
			dest[i] = v
		end
	end
end

function kapi.patch(env, pid, trustLevel)
	copyInto(env, apienv)
	
	for i, v in pairs(kapi.patches) do
		v(env, pid, trustLevel)
	end
end

function kapi.newOverlay()
	local e = setmetatable({}, {__index=_ENV})
	e._G = e
	return e
end

function kapi.newSandbox()
	return {
		pcall = _G.pcall,
		type = _G.type,
		rawget = _G.rawget,
		bit32 = {
			lshift = _G.bit32.lshift,
			bnot = _G.bit32.bnot,
			arshift = _G.bit32.arshift,
			band = _G.bit32.band,
			bxor = _G.bit32.bxor,
			lrotate = _G.bit32.lrotate,
			rrotate = _G.bit32.rrotate,
			rshift = _G.bit32.rshift,
			extract = _G.bit32.extract,
			replace = _G.bit32.replace,
			btest = _G.bit32.btest,
			bor = _G.bit32.bor,
		},
		getmetatable = _G.getmetatable,
		computer = {
			address = _G.computer.address,
			removeUser = _G.computer.removeUser,
			pullSignal = _G.computer.pullSignal,
			users = _G.computer.users,
			shutdown = _G.computer.shutdown,
			addUser = _G.computer.addUser,
			beep = _G.computer.beep,
			freeMemory = _G.computer.freeMemory,
			maxEnergy = _G.computer.maxEnergy,
			pushSignal = _G.computer.pushSignal,
			energy = _G.computer.energy,
			tmpAddress = _G.computer.tmpAddress,
			getBootAddress = _G.computer.getBootAddress,
			totalMemory = _G.computer.totalMemory,
			setBootAddress = _G.computer.setBootAddress,
			uptime = _G.computer.uptime,
		},
		pairs = _G.pairs,
		ipairs = _G.ipairs,
		setmetatable = _G.setmetatable,
		tonumber = _G.tonumber,
		checkArg = _G.checkArg,
		tostring = _G.tostring,
		os = {
			date = _G.os.date,
			clock = _G.os.clock,
			time = _G.os.time,
			difftime = _G.os.difftime,
		},
		math = {
			atan2 = _G.math.atan2,
			max = _G.math.max,
			pow = _G.math.pow,
			deg = _G.math.deg,
			atan = _G.math.atan,
			sinh = _G.math.sinh,
			sin = _G.math.sin,
			tan = _G.math.tan,
			sqrt = _G.math.sqrt,
			tanh = _G.math.tanh,
			exp = _G.math.exp,
			rad = _G.math.rad,
			random = _G.math.random,
			log = _G.math.log,
			ldexp = _G.math.ldexp,
			min = _G.math.min,
			cos = _G.math.cos,
			ceil = _G.math.ceil,
			huge = _G.math.huge,
			randomseed = _G.math.randomseed,
			pi = _G.math.pi,
			frexp = _G.math.frexp,
			acos = _G.math.acos,
			abs = _G.math.abs,
			modf = _G.math.modf,
			fmod = _G.math.fmod,
			asin = _G.math.asin,
			cosh = _G.math.cosh,
			floor = _G.math.floor,
		},
		rawset = _G.rawset,
		coroutine = {
			status = _G.coroutine.status,
			yield = _G.coroutine.yield,
			resume = _G.coroutine.resume,
			create = _G.coroutine.create,
			running = _G.coroutine.running,
			wrap = _G.coroutine.wrap,
		},
		xpcall = _G.xpcall,
		select = _G.select,
		load = _G.load,
		unicode = {
			upper = _G.unicode.upper,
			char = _G.unicode.char,
			wtrunc = _G.unicode.wtrunc,
			lower = _G.unicode.lower,
			wlen = _G.unicode.wlen,
			charWidth = _G.unicode.charWidth,
			len = _G.unicode.len,
			reverse = _G.unicode.reverse,
			sub = _G.unicode.sub,
			isWide = _G.unicode.isWide,
		},
		assert = _G.assert,
		_VERSION = _G._VERSION,
		rawlen = _G.rawlen,
		rawequal = _G.rawequal,
		string = {
			upper = _G.string.upper,
			char = _G.string.char,
			gmatch = _G.string.gmatch,
			byte = _G.string.byte,
			lower = _G.string.lower,
			sub = _G.string.sub,
			find = _G.string.find,
			reverse = _G.string.reverse,
			rep = _G.string.rep,
			match = _G.string.match,
			dump = _G.string.dump,
			gsub = _G.string.gsub,
			len = _G.string.len,
			format = _G.string.format,
		},
		next = _G.next,
		debug = {
			traceback = _G.debug.traceback,
		},
		component = {
			proxy = _G.component.proxy,
			slot = _G.component.slot,
			type = _G.component.type,
			doc = _G.component.doc,
			fields = _G.component.fields,
			invoke = _G.component.invoke,
			list = _G.component.list,
			methods = _G.component.methods,
		},
		error = _G.error,
		table = {
			sort = _G.table.sort,
			remove = _G.table.remove,
			concat = _G.table.concat,
			insert = _G.table.insert,
			pack = _G.table.pack,
			unpack = _G.table.unpack,
		},
	}
end