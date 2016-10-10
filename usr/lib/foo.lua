local foo = {}

function foo.bar()
  os.logf("FOO", "BAR")
  return "qux"
end

return foo
