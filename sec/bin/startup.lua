--Startup: reads /sec/etc/startup for the next executables to run

local a = os.clock()
fs.open("/sec/etc/startup", "r"):after(function(handle)
	os.logf("BENCH", "%s ms", (os.clock()-a)*1000)
	os.logf("MAIN", "%s", tostring(handle))
	if handle then
		await(fs.readAsStream(handle, math.huge))
			:transform(utils.newLineSplitter())
			:where(function(line) return line:sub(1,1) ~= "#" and #line > 0 end)
			:listen(function(line)
				os.logf("MAIN", "Read line %s", line)
			end)
	end
end)
