--!nonstrict
-- real sources are bundled beside this test by test_service_launcher.py.
local sources = require("./service-launcher-sources")
local scenario = ...
local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = clone(item) end
  return result
end

local now = 1000000
local values, watchers, files, encoded = {}, {}, {}, {}
local requests, pending_http, commands, action_history, queued_intents, async_runs = {}, {}, {}, {}, {}, {}
local sync_http, queue_intents, deny_http = false, false, false
local query, cleared = "", 0
local timer_id, fail_refresh, omit_timer_task = nil, false, false
local function encode(value)
  local key = "json-" .. tostring(#encoded + 1)
  table.insert(encoded, clone(value))
  return key
end
local function decode(value)
  local index = tonumber(tostring(value):match("^json%-(%d+)$"))
  return index and clone(encoded[index]) or nil
end
local function write_metadata(name, value)
  files["/fixture/bridge/" .. name] = { text = encode(value), mtime = now }
end
local function heartbeat(status, timestamp)
  write_metadata("connection.json", {
    schemaVersion = 1, protocolVersion = 2, companionVersion = "2.0.0",
    status = status or "ready", updatedAt = timestamp or now,
  })
end
heartbeat()
write_metadata("change.json", {
  schemaVersion = 1, protocolVersion = 2, companionVersion = "2.0.0",
  sequence = 1, changedAt = now, reason = "ready",
})
local function deliver(key, value)
  for _, callback in ipairs(watchers[key] or {}) do callback(clone(value)) end
end
local function http_response(item)
  local request = item.request
  if fail_refresh and request.method == "GET" then
    item.callback({ ok = false, error = "confirmation unavailable" })
    return
  end
  local data, status = {}, 200
  if request.url:find("/status", 1, true) then data = { taskCount = 0, currentTaskId = timer_id, currentTask = not omit_timer_task and timer_id and { id = timer_id, title = "Timer", isDone = false } or nil } end
  if request.url:find("/start", 1, true) then
    data = { currentTaskId = "task-1" }
  elseif request.url:find("/task-control/stop", 1, true) then
    data = {}
  elseif request.method == "POST" then
    data = { id = "captured", title = "Task", isDone = false }
    status = 201
  end
  item.callback({ ok = true, status = status, body = encode({ ok = true, data = data }) })
end
local runtime = {
  pluginDir = function() return "/fixture/plugin" end,
  nowMs = function() return now end,
  getConfig = function(key)
    return ({ launch_method = "native", bridge_dir = "/fixture/bridge", sound_on_complete = false })[key]
  end,
  getenv = function(key) return key == "XDG_CONFIG_HOME" and "/fixture/config" or "/fixture/data" end,
  expandPath = function(value) return value:gsub("^~", "/fixture/home") end,
  flatpakAppInstalled = function() return false end,
  readFile = function(file)
    if file == "/fixture/config/superProductivity/local-rest-api-token" then return string.rep("A", 32) end
    return files[file] and files[file].text or nil
  end,
  fileInfo = function(file)
    local value = files[file]
    return value and { mtime = value.mtime, size = #value.text, isDir = false } or nil
  end,
  fileExists = function(file) return files[file] ~= nil end,
  mkdirAll = function() return true end,
  writeFile = function(file, text) files[file] = { text = text, mtime = now }; return true end,
  renameFile = function(source, target)
    files[target], files[source] = files[source], nil
    table.insert(commands, decode(files[target].text))
    return true
  end,
  removeFile = function(file) files[file] = nil; return true end,
  listDir = function(directory)
    local names = {}
    for file in pairs(files) do
      if file:sub(1, #directory + 1) == directory .. "/" then table.insert(names, file:sub(#directory + 2)) end
    end
    return names
  end,
  commandExists = function() return true end,
  processMatches = function(callback) callback(true) end,
  runAsync = function(spec, callback, timeout)
    table.insert(async_runs, { spec = clone(spec), callback = callback, timeout = timeout })
    return true
  end,
  setUpdateInterval = function() end,
  sound = { load = function(_, _, callback) callback(true); return true end, play = function() end },
  log = function() end,
  notify = function() end,
  notifyError = function() end,
  tr = function(key) return key end,
  string = { trim = function(value) return value:match("^%s*(.-)%s*$") end },
  json = { encode = encode, decode = decode },
  state = {
    get = function(key) return clone(values[key]) end,
    set = function(key, value)
      values[key] = clone(value)
      if key == "super-productivity.action" then table.insert(action_history, clone(value)) end
      if queue_intents and key == "super-productivity.intent" then
        table.insert(queued_intents, clone(value))
      else
        deliver(key, value)
      end
    end,
    watch = function(key, callback)
      watchers[key] = watchers[key] or {}
      table.insert(watchers[key], callback)
    end,
  },
  http = function(request, callback)
    table.insert(requests, clone(request))
    if deny_http then return false end
    local item = { request = request, callback = callback }
    if sync_http then http_response(item) else table.insert(pending_http, item) end
    return true
  end,
}
local cache = {}
local function load_source(name, extra)
  local env = setmetatable({ noctalia = runtime }, { __index = getfenv() })
  for key, value in pairs(extra or {}) do env[key] = value end
  env.require = function(path)
    local module = path:gsub("^%./", ""):gsub("%.luau$", "")
    if cache[module] == nil then cache[module] = load_source(module) end
    return cache[module]
  end
  local chunk = assert(loadstring(sources[name], "@" .. name .. ".luau"))
  setfenv(chunk, env)
  return chunk(), env
end
local _, service = load_source("service")
local _, launcher = load_source("launcher", {
  launcher = {
    setResults = function() end,
    setQuery = function(value) query = value; cleared += 1 end,
  },
})
local common = cache.common
local function action() return runtime.state.get(common.ACTION_KEY) end
local function snapshot() return runtime.state.get(common.SNAPSHOT_KEY) end
local function finish_http()
  local count = 0
  while #pending_http > 0 do
    count += 1
    assert(count <= 20, "unexpected REST replay")
    http_response(table.remove(pending_http, 1))
  end
end
local function capture(text)
  query = text
  launcher.onQuery(text)
  launcher.onActivate("add")
end
local function additions()
  local count = 0
  for _, request in ipairs(requests) do if request.method == "POST" then count += 1 end end
  return count
end
finish_http()
service.update()
finish_http()
assert(snapshot().restStatus == "ready" and snapshot().bridgeStatus == "ready")
assert(snapshot().appRunning == true)

if scenario:sub(1, 6) == "timer-" then
  local stopping = scenario:find("stop", 1, true) ~= nil
  local queued = scenario:find("queued", 1, true) ~= nil
  if stopping then
    timer_id = "task-1"
    common.send_intent("refresh")
    finish_http()
    assert(snapshot().currentTask.id == "task-1")
  end
  if queued then
    now += 2000
    write_metadata("change.json", {
      schemaVersion = 1, protocolVersion = 2, companionVersion = "2.0.0",
      sequence = 2, changedAt = now, reason = "test",
    })
    service.update()
    assert(#pending_http == 4)
  end
  local before = additions()
  local request_id = common.send_intent("timer_toggle", { taskId = "task-1" })
  assert(action().status == "working")
  -- Finish the mutation before any older refresh to exercise waiter ownership.
  http_response(table.remove(pending_http, queued and 5 or 1))
  assert(action().status == "working", "acknowledgement alone must not report success")
  if queued then
    for _ = 1, 4 do http_response(table.remove(pending_http, 1)) end
    assert(action().status == "working", "the older refresh cannot confirm a timer action")
    assert(#pending_http == 4, "confirmation must get its own queued refresh")
  end
  local expected = "success"
  if scenario:find("failed", 1, true) then
    fail_refresh = true
    expected = "unknown"
  elseif scenario:find("contradictory", 1, true) then
    timer_id = stopping and "task-1" or "other-task"
    expected = "error"
  elseif scenario:find("unresolved", 1, true) then
    timer_id, omit_timer_task = "other-task", true
    expected = "error"
  elseif scenario:find("missing", 1, true) then
    timer_id = nil
    expected = "error"
  else
    timer_id = if stopping then nil else "task-1"
  end
  finish_http()
  assert(action().status == expected and action().requestId == request_id)
  if expected ~= "success" then
    assert(action().error ~= nil and snapshot().lastError == action().error)
  end
  assert(additions() == before + 1, "timer changes must never replay")
  fail_refresh = false
  local refresh_id = common.send_intent("refresh")
  assert(action().status == "working" and action().requestId == refresh_id, "confirmation must release action ownership")
  finish_http()
  assert(action().status == "success")
elseif scenario == "busy-select" then
  local original_id = common.send_intent("open", { taskId = "task-1" })
  assert(action().status == "working" and action().requestId == original_id)
  local before = additions()
  capture("keep for retry")
  assert(runtime.state.get(common.INTENT_KEY).requestId == original_id, "published busy state must gate capture dispatch")
  assert(additions() == before and query == "keep for retry" and cleared == 0)
  assert(action().status == "working" and action().requestId == original_id, "capture cannot replace active ownership")
  local command = commands[#commands]
  assert(command and command.action == "select")
  write_metadata("responses/" .. command.id .. ".json", {
    schemaVersion = 1, protocolVersion = 2, id = command.id, action = "select", ok = true,
  })
  service.update()
  assert(action().status == "success" and action().requestId == original_id)
  launcher.onActivate("add")
  assert(additions() == before + 1, "capture must be retryable after the original action completes")
  launcher.onActivate("add")
  assert(additions() == before + 1, "pending capture must not dispatch twice")
  finish_http()
  assert(query == "" and cleared == 1)
elseif scenario == "queued-rejection" then
  queue_intents = true
  local original_id = common.send_intent("refresh")
  capture("queued capture")
  queue_intents = false
  for _, intent in ipairs(queued_intents) do deliver(common.INTENT_KEY, intent) end
  assert(additions() == 0 and query == "queued capture")
  for _, published in ipairs(action_history) do
    if published.requestId == original_id then assert(published.status == "working") end
  end
  assert(action().requestId == original_id and action().status == "working", "rejection preserves the active action")
  finish_http()
  assert(action().requestId == original_id and action().status == "success")
  launcher.onActivate("add")
  assert(additions() == 1, "a busy rejection after the launcher gate must release pending capture")
  finish_http()
  assert(query == "" and cleared == 1)
elseif scenario == "sync-success" then
  sync_http = true
  capture("synchronous capture")
  assert(additions() == 1 and query == "" and cleared == 1, "early success must clear the captured query")
  capture("another capture")
  assert(additions() == 2 and cleared == 2, "early success must release pending capture")
elseif scenario == "sync-error" then
  sync_http, deny_http = true, true
  capture("retry after error")
  assert(additions() == 1 and query == "retry after error" and cleared == 0)
  deny_http = false
  launcher.onActivate("add")
  assert(additions() == 2 and query == "" and cleared == 1, "early error must release pending capture without losing text")
elseif scenario == "package-build" then
  common.send_intent("package_build")
  assert(snapshot().packageStatus == "running", "package build intent must update visible state")
  assert(#async_runs == 1, "package build intent must start the packaging command")
  assert(async_runs[1].spec[1] == "python3")
  assert(async_runs[1].spec[2] == "/fixture/plugin/scripts/package-companion.py")
  assert(async_runs[1].spec[3] == "--machine-readable")
elseif scenario == "expiry" then
  local before = #requests
  for _ = 1, 4 do
    now += 10000
    heartbeat()
    service.update()
    assert(snapshot().hookStatus == "ready", "idle change metadata must not expire with fresh heartbeats")
  end
  assert(#requests == before, "heartbeats must not poll REST")
  now += 32000
  service.update()
  assert(snapshot().bridgeStatus == "stale" and snapshot().hookStatus == "stale", "unchanged ready files must age without an open request")
  assert(snapshot().appRunning == true and snapshot().restStatus == "ready" and #requests == before)
  now += 2000
  heartbeat()
  service.update()
  assert(snapshot().bridgeStatus == "ready" and snapshot().hookStatus == "ready")
  now += 30000
  service.update()
  assert(snapshot().bridgeStatus == "ready", "the heartbeat has a conservative 30s grace")
  now += 1
  common.send_intent("open", { taskId = "task-1" })
  assert(#commands == 0, "exact-task opening must check freshness even between file polls")
  now += 2000
  service.update()
  assert(snapshot().bridgeStatus ~= "ready", "unchanged connection metadata must expire")
  assert(snapshot().hookStatus ~= "ready", "stale companion hooks must not report ready")
  assert(snapshot().restStatus == "ready" and snapshot().status == "ready" and #requests == before)
  heartbeat()
  now += 2000
  service.update()
  assert(snapshot().bridgeStatus == "ready" and snapshot().hookStatus == "ready", "fresh heartbeat restores readiness")
  assert(#commands == 1, "waiting exact-task open dispatches once after recovery")
  local command = commands[1]
  write_metadata("responses/" .. command.id .. ".json", {
    schemaVersion = 1, protocolVersion = 2, id = command.id, action = "select", ok = true,
  })
  service.update()
  now += 2000
  heartbeat("unloaded")
  service.update()
  assert(snapshot().bridgeStatus == "offline" and snapshot().hookStatus ~= "ready", "unloaded companions are unavailable")
  assert(snapshot().restStatus == "ready" and snapshot().status == "ready")
  capture("REST without companion")
  finish_http()
  assert(additions() == 1 and cleared == 1, "REST actions remain usable without the companion")
  common.send_intent("open", { taskId = "task-1" })
  assert(#commands == 1, "unloaded companions must not receive selection commands")
else
  error("unknown scenario: " .. tostring(scenario))
end
print(scenario .. " passed")
