--Permision API--

--Users (Includes Groups), Filesystem, and Process Permissions

--[[
  User, Group, and Process Permissions

  Hierarchal Permission model:

  A target is defined as either a pid, or a special formatted string.
  You can query:
    User permissions with "u:<username>"
    Group permissions with "g:<groupname>"
    Process permissions with "p:<pid>" (for compat)
    Current User, Group, or Process with "c:<process|user>"
    Filesystem permissions with "f:/absolute/directory<context of another target>"

  Say you wanted to query the filesystem permissions of the user "pixeltoast" on the directory /home/gamax92.
  You would use perm.query("f:/home/gamax92<u:pixeltoast>", "filesystem.canRead")
  Filesystem permissions work their way up, like how permissions queries do.

  ---

  perm.query(<target>, "device.list")

  What that does is query to see if the "device.list" permission is defined.
  If it is not defined, then it sees if the "device" permission is defined.
  If still undefined after walking through all steps then the permission is denied
  else, it is accepted or denied depending on what the permission is defined as.
  If the process is trusted, perm.query always returns true. This can be configured using
  perm.set("c:process", "perm.alwaysTrusted", false).

  perm.query can be used by all processes on all processes.

  ---

  perm.set(<target>, "proc.spawn", false)

  This defines proc.spawn as false. You can also define things as true or nil. Defining as nil undefines it.
  If the process is trusted, perm.set always succeeds. This can be configured using
  perm.set("c:process", "perm.alwaysTrusted", false)

  perm.set can be used by all processes, but untrusted processes can only modify a direct child of their own.
  Untrusted processes cannot define permissions they don't have access to in a child process.

  ---

  perm.list(<target>)

  This lists all the permissions defined for <target>. If <target> is a process, gets user permissions, which get group
  permissions.
]]

local zeroapi, processSpawnHandlers, processCleanupHandlers = ...

--users and groups can be created arbitrarily at runtime
--the only thing that matters is if the user's permissions are reloaded at load time
local groups = {}
local users = {
  root = {
    permissions = { -- test permissions for root
      ["test"] = true,
      ["test.higher"] = false,
      ["test.higher.backdoor"] = true,
    }
  }
}

function processSpawnHandlers.perm(newPID, fromPID)
  --copy the user from fromPID or "root"
  local newSS = proc.getSecureStorage(newPID)
  local oldSS = proc.getSecureStorage(fromPID)

  newSS.user = oldSS.user or "root"
  newSS.permissions = {}

  --inherit permissions from oldSS
  if oldSS.permissions then
    for i, v in pairs(oldSS.permissions) do
      newSS.permissions[i] = v
    end
  end
end

local function parseTarget(target, cpid)
  if type(target) == "number" then
    return {type = "process", pid = target}
  else
    local domain = target:sub(1,2)
    local subdomain = target:sub(3)

    if domain == "u:" then
      return {type = "user", username = subdomain}
    elseif domain == "g:" then
      return {type = "group", groupname = subdomain}
    elseif domain == "p:" then
      return {type = "process", pid = assert(tonumber(cpid), "Invalid process id given")}
    elseif domain == "c:" then
      if subdomain == "process" then
        return {type = "process", pid = cpid}
      elseif subdomain == "user" then
        return {type = "user", username = proc.getSecureStorage(cpid).user or "root"}
      else
        error("Unknown target subdomain "..subdomain.." under domain c:")
      end
    elseif domain == "f:" then
      local path, context = subdomain:match("^(.+)<(.+)>$")

      if not path or not context then
        error("Error parsing filesystem subdomain "..subdomain)
      end

      local contextTarget = parseTarget(context, cpid)

      if contextTarget.type == "filesystem" then
        error("Cannot use the filesystem target "..context.." as a context to another filesystem target")
      end

      return {type = "filesystem", path = path, context = contextTarget}
    else
      error("Unknown target domain "..domain)
    end
  end
end

local domainLevels = {process = 3, user = 2, group = 1}

local function queryTable(tab, query)
  if not tab then return nil end

  while true do
    os.logf("PERM", "Query %s result: %s", query, tostring(tab[query]))
    if tab[query] ~= nil then
      return tab[query]
    end

    query = query:match("(.+)%.[^.]+")
    if not query then break end
  end

  return nil
end

local function getUserFromTarget(target)
  if target.type == "process" then
    return proc.getSecureStorage(target.pid).user
  else
    return assert(target.username, "Target cannot be coerced into username!")
  end
end

local function getGroupsFromTarget(target)
  if target.type == "process" or target.type == "user" then
    local user = getUserFromTarget(target)

    if users[user] then
      return users[user].groups
    end

    return nil
  else
    return assert(target.groupname, "Target cannot be coerced into groupname!")
  end
end

function zeroapi.perm_query(pid, target, perm, default)
  checkArg(1, target, "string", "number")
  checkArg(2, perm, "string")

  target = parseTarget(target, pid)

  if target.type == "filesystem" then
    --ask the current filesystem service of the process
    --internally, filesystem service implementations should not use perm.query to get filesystem permissions
    --it can present a security hole if the current process filesystem service ~= the calling filesystem service!

    local fs = zeroapi.service_get(pid, "FS")

    if not fs then
      return false, "No Filesystem service found"
    elseif not kobject.isA(fs, "ExportClient") then
      return false, "Filesystem service is not an ExportClient"
    else
      return fs:invoke("queryPermission", target.path, target.context)
    end
  else
    local domainLevel = domainLevels[target.type]

    if domainLevel >= domainLevels.process then
      local targetPID = target.pid -- FIXME: If I add a new domain level above this one

      if perm ~= "perm.alwaysTrusted" and proc.isTrusted(targetPID) then
        local always = zeroapi.perm_query(targetPID, targetPID, "perm.alwaysTrusted")
        if always == nil then always = true end
        if always then return true, "trusted" end
      end

      local val = queryTable(proc.getSecureStorage(targetPID).permissions, perm)

      if val ~= nil then
        return val, "p:"..targetPID
      end
    end

    if domainLevel >= domainLevels.user then
      local targetUser = getUserFromTarget(target)

      if users[targetUser] then
        local val = queryTable(users[targetUser].permissions, perm)

        if val ~= nil then
          return val, "u:"..targetUser
        end
      end
    end

    if domainLevel >= domainLevels.group then
      local targetGroups = getGroupsFromTarget(target)

      if type(targetGroups) == "string" then
        local targetGroup = targetGroups

        if groups[targetGroup] then
          local val = queryTable(groups[targetGroup], perm)

          if val ~= nil then
            return val, "g:"..targetGroup
          end
        end
      elseif targetGroups then
        for _, targetGroup in ipairs(targetGroups) do
          local targetGroup = targetGroups

          if groups[targetGroup] then
            local val = queryTable(groups[targetGroup], perm)

            if val ~= nil then
              return val, "g:"..targetGroup
            end
          end
        end
      end
    end

    return default, "undefined"
  end
end

function zeroapi.perm_set(pid, target, perm, value)
  checkArg(1, target, "string", "number")
  checkArg(2, perm, "string")
  checkArg(3, value, "boolean", "nil")

  target = parseTarget(target, pid)

  if target.type == "filesystem" then
    --ask the current filesystem service of the process
    --internally, filesystem service implementations should not use perm.query to get filesystem permissions
    --it can present a security hole if the current process filesystem service ~= the calling filesystem service!

    local fs = zeroapi.service_get(pid, "FS")

    if not fs then
      return false, "No Filesystem service found"
    elseif not kobject.isA(fs, "ExportClient") then
      return false, "Filesystem service is not an ExportClient"
    else
      if zeroapi.perm_query(pid, pid, "filesystem.changePermissions") then
        return fs:invoke("setPermission", target.path, formatTarget(target.context), value)
      else
        return false, "Permission Denied - Cannot change filesystem permissions"
      end
    end
  else
    local domainLevel = domainLevels[target.type]

    if zeroapi.perm_query(pid, pid, perm) == false then
      return false, "Permission Denied - Cannot set a permission that you have no right of"
    end

    if domainLevel == domainLevels.process then
      local targetPID = target.pid

      proc.getSecureStorage(targetPID).permissions[perm] = value

      return true, "p:"..targetPID
    end

    if domainLevel == domainLevels.user then
      local targetUser = getUserFromTarget(target)

      if not proc.isTrusted(pid) and proc.getSecureStorage(pid).user ~= targetUser then
        return false, "Permission Denied - Cannot set permissions for another user"
      end

      if not users[targetUser] then
        users[targetUser] = {
          permissions = {}
        }
      end

      users[targetUser].permissions[perm] = val

      return true, "u:"..targetUser
    end

    if domainLevel == domainLevels.group then
      if not proc.isTrusted(pid) then
        return false, "Permission Denied - Cannot set permissions for entire group"
      end

      local targetGroups = getGroupsFromTarget(target)

      if type(targetGroups) == "string" then
        local targetGroup = targetGroups

        if not groups[targetGroup] then
          groups[targetGroup] = {}
        end

        groups[targetGroup][perm] = val

        return true, "g:"..targetGroup
      elseif targetGroups then
        error("???")
      end
    end

    return false, "Generic Failure Message"
  end
end
