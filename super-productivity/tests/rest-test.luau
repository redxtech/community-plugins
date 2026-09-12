--!nonstrict
local rest = require("../rest")

local TOKEN = string.rep("A", 32)
local NATIVE_TOKEN = "/xdg/superProductivity/local-rest-api-token"
local FLATPAK_TOKEN = "/home/test/.var/app/com.super_productivity.SuperProductivity/config/superProductivity/local-rest-api-token"

local function make_runtime(config, files)
  local runtime = {
    config = config or {},
    files = files or {},
    requests = {},
    callbacks = {},
    encoded = {},
    now = 1000,
  }
  runtime.getConfig = function(key) return runtime.config[key] end
  runtime.getenv = function(key) return key == "XDG_CONFIG_HOME" and "/xdg" or "" end
  runtime.expandPath = function(path) return path:gsub("^~", "/home/test") end
  runtime.flatpakAppInstalled = function() return runtime.config.flatpak_installed == true end
  runtime.readFile = function(path) return runtime.files[path] end
  runtime.nowMs = function() return runtime.now end
  runtime.json = {
    encode = function(value)
      table.insert(runtime.encoded, value)
      if type(value) == "string" then return '"' .. value .. '"' end
      return "encoded-" .. tostring(#runtime.encoded)
    end,
    decode = function(value) return value end,
  }
  runtime.http = function(request, callback)
    table.insert(runtime.requests, request)
    table.insert(runtime.callbacks, callback)
    return true
  end
  runtime.respond = function(response)
    local callback = table.remove(runtime.callbacks, 1)
    assert(callback ~= nil)
    callback(response)
  end
  return runtime
end

local function response(status, data)
  return { ok = true, status = status, body = { ok = true, data = data } }
end

local function header(request, prefix)
  for _, value in ipairs(request.headers or {}) do
    if value:sub(1, #prefix) == prefix then return value end
  end
  return nil
end

local candidates = rest.token_candidates({
  rest_token_file = "~/token",
  expand = function(path) return path:gsub("^~", "/home/test") end,
})
assert(#candidates == 1 and candidates[1] == "/home/test/token")

candidates = rest.token_candidates({
  xdg_config_home = "/xdg",
  prefer_flatpak = true,
  expand = function(path) return path:gsub("^~", "/home/test") end,
})
assert(candidates[1] == FLATPAK_TOKEN)
assert(candidates[2] == NATIVE_TOKEN)
assert(rest.valid_token("\n" .. TOKEN .. "\t"))
assert(not rest.valid_token(string.rep("A", 31)))
local function task(is_done)
  return { id = "task-1", title = "Task", isDone = is_done == true }
end

local runtime = make_runtime({ launch_method = "native" }, { [NATIVE_TOKEN] = TOKEN })
local client = rest.new(runtime)
local results = {}
client:tasks(function(result) table.insert(results, result) end)
client:projects(function(result) table.insert(results, result) end)
client:tags(function(result) table.insert(results, result) end)
client:status(function(result) table.insert(results, result) end)
client:add_task("Ship +Work #urgent @tomorrow 30m", function(result) table.insert(results, result) end)
client:set_done("task-1", true, function(result) table.insert(results, result) end)
client:start_task("task-1", function(result) table.insert(results, result) end)
client:stop_task(function(result) table.insert(results, result) end)
assert(#runtime.requests == 8)
assert(runtime.requests[1].url == rest.BASE_URL .. "/tasks?source=active&includeDone=true")
assert(runtime.requests[2].url == rest.BASE_URL .. "/projects")
assert(runtime.requests[3].url == rest.BASE_URL .. "/tags")
assert(runtime.requests[4].url == rest.BASE_URL .. "/status")
assert(runtime.requests[5].url == rest.BASE_URL .. "/tasks")
assert(runtime.requests[6].url == rest.BASE_URL .. "/tasks/task-1")
assert(runtime.requests[7].url == rest.BASE_URL .. "/tasks/task-1/start")
assert(runtime.requests[8].url == rest.BASE_URL .. "/task-control/stop")
for _, request in ipairs(runtime.requests) do
  assert(request.url:sub(1, #rest.BASE_URL) == rest.BASE_URL)
  assert(not request.url:find(TOKEN, 1, true))
  assert(header(request, "Authorization: ") == "Authorization: Bearer " .. TOKEN)
  assert(request.follow_redirects == false)
end
assert(runtime.encoded[1].title == "Ship +Work #urgent @tomorrow 30m")
assert(runtime.encoded[2].isDone == true)

runtime.respond(response(200, {}))
runtime.respond(response(200, {}))
runtime.respond(response(200, {}))
runtime.respond(response(200, { currentTaskId = "task-1", taskCount = 1, currentTask = task(false) }))
runtime.respond(response(201, task(false)))
runtime.respond(response(200, task(true)))
runtime.respond(response(200, { currentTaskId = "task-1" }))
runtime.respond(response(200, {}))
assert(#results == 8)
for _, result in ipairs(results) do assert(result.ok == true and result.dispatched == true) end

local hour_body = rest.reschedule_body(runtime.json, "hour", 1000)
assert(hour_body == '{"dueWithTime":3601000,"dueDay":null}')
local local_now = os.time({ year = 2026, month = 1, day = 30, hour = 15, min = 0, sec = 0 }) * 1000
local tomorrow_body = rest.reschedule_body(runtime.json, "tomorrow", local_now)
assert(tomorrow_body == '{"dueDay":"2026-01-31","dueWithTime":null}')
local week_body = rest.reschedule_body(runtime.json, "week", local_now)
assert(week_body == '{"dueDay":"2026-02-06","dueWithTime":null}')
assert(rest.reschedule_body(runtime.json, "later", local_now) == nil)
assert(rest.reschedule_body(runtime.json, "hour", nil) == nil)

runtime = make_runtime({ rest_token_file = "~/custom-token" }, { ["/home/test/custom-token"] = TOKEN })
client = rest.new(runtime)
results = {}
client:status(function(result) table.insert(results, result) end)
assert(#runtime.requests == 1)
runtime.respond({ ok = true, status = 401, body = "malformed" })
assert(results[1].kind == "auth_required" and client.token == nil)
assert(#runtime.requests == 1, "authentication failures must not replay requests")
runtime = make_runtime({ launch_method = "native" }, { [NATIVE_TOKEN] = TOKEN })
client = rest.new(runtime)
results = {}
client:tasks(function(result) table.insert(results, result) end)
runtime.respond(response(200, { unexpected = true }))
assert(results[1].kind == "invalid_response")

runtime = make_runtime({ launch_method = "native" }, { [NATIVE_TOKEN] = TOKEN })
client = rest.new(runtime)
results = {}
client:add_task("Task", function(result) table.insert(results, result) end)
runtime.respond(response(200, task(false)))
assert(results[1].kind == "invalid_response", "mutations must enforce status and data contracts")

runtime = make_runtime({ launch_method = "native" }, { [NATIVE_TOKEN] = TOKEN })
client = rest.new(runtime)
results = {}
client:set_done("task-1", true, function(result) table.insert(results, result) end)
runtime.now += rest.REQUEST_TIMEOUT_MS
client:update(runtime.now)
assert(#results == 1 and results[1].kind == "timeout" and results[1].dispatched == true)
runtime.respond(response(200, { id = "task-1" }))
assert(#results == 1, "late responses must be ignored and never replayed")

runtime = make_runtime({ launch_method = "native" }, { [NATIVE_TOKEN] = TOKEN })
client = rest.new(runtime)
results = {}
local callbacks = 0
assert(client:set_done("a..b", true, function(result)
  callbacks += 1
  table.insert(results, result)
end) == false)
assert(callbacks == 1 and results[1].kind == "request_error" and results[1].dispatched == false)
assert(#runtime.requests == 0, "rejected task paths must not dispatch HTTP")
runtime.now += rest.REQUEST_TIMEOUT_MS
client:update(runtime.now)
assert(#results == 1, "rejected task paths must not later time out")
local leading_hyphen_id = "-RKlbAoHNzOJtpzsUW2YP"
assert(client:reschedule_task(leading_hyphen_id, "tomorrow", runtime.now, function(result)
  table.insert(results, result)
end))
assert(runtime.requests[1].url == rest.BASE_URL .. "/tasks/" .. leading_hyphen_id)
runtime.respond(response(200, { id = leading_hyphen_id, title = "Get bloodwork", isDone = false }))
assert(#results == 2 and results[2].ok == true, "task IDs may start with a hyphen")

local leading_underscore_id = "_task-1"
assert(client:set_done(leading_underscore_id, true, function(result) table.insert(results, result) end))
assert(runtime.requests[2].url == rest.BASE_URL .. "/tasks/" .. leading_underscore_id)
runtime.respond(response(200, { id = leading_underscore_id, title = "Task", isDone = true }))
assert(#results == 3 and results[3].ok == true, "task IDs may start with an underscore")

print("REST client tests passed")
