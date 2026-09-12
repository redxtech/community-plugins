--!nonstrict
-- headless owner of super productivity REST state and companion notifications.

local common = require("./common.luau")
local rest = require("./rest.luau")
local rest_state = require("./rest_state.luau")

local FLATPAK_ID = rest.FLATPAK_ID
local BRIDGE_NAME = "noctalia-super-productivity"
local PACKAGE_ARCHIVE_NAME = "noctalia-super-productivity.zip"
local PACKAGE_METADATA_NAME = "companion-package.json"
local PLUGIN_DIR = tostring(noctalia.pluginDir() or "")
local SCHEMA_VERSION = 1
local BRIDGE_PROTOCOL_VERSION = common.PROTOCOL_VERSION
local COMMAND_TIMEOUT_MS = 12000
local OPEN_TIMEOUT_MS = 30000
local UNDO_WINDOW_MS = 30000
local MAX_FUTURE_SKEW_MS = 5000
local MAX_CHANGE_REASON = 120
local SOUND_NAME = "task-complete"
local BRIDGE_POLL_MS = 2000
local CONNECTION_GRACE_MS = 30000

local state = {
  status = "starting",
  restStatus = "starting",
  restError = "",
  bridgeStatus = "starting",
  bridgeError = "",
  hookStatus = "starting",
  hookError = "",
  bridgeDir = "",
  companionVersion = "",
  protocolVersion = nil,
  requiredCompanionVersion = "",
  companionUpdateRequired = false,
  packageStatus = "missing",
  packageError = "",
  packagePath = "",
  generatedAt = 0,
  receivedAt = 0,
  currentTask = nil,
  upcoming = {},
  view = nil,
  counts = { active = 0, due = 0, overdue = 0 },
  appRunning = false,
  appAvailable = false,
  launchMethod = "",
  error = "",
  lastError = "",
  lastCommandAt = 0,
  lastResponseAt = 0,
  connectionUpdatedAt = 0,
  changeSequence = nil,
  changedAt = 0,
  changeReason = "",
  undo = nil,
}

local action = { status = "idle" }
local bridge_dir = ""
local selected_bridge_method = ""
local connection_path = ""
local change_path = ""
local bridge_error_path = ""
local command_dir = ""
local response_dir = ""
local connection_signature = nil
local bridge_error_signature = nil
local last_change_sequence = nil
local command_sequence = 0
local browse_index = 1
local last_file_poll_ms = 0
local last_bridge_search_ms = 0
local last_process_check_ms = 0
local last_due_check_ms = noctalia.nowMs()
local service_started_at = last_due_check_ms
local auto_start_attempted = false
local pending_open_request = nil
local pending_select = nil
local reset_view_on_refresh = false
local sound_ready = false
local active_rest_action = nil
local refreshed_current_task_id = nil
local refresh_running = false
local refresh_again = false
local refresh_waiters = {}
local queued_refresh_waiters = {}
local rest_client = rest.new(noctalia)
local request_rest_state

local function trim(value)
  return common.trim(value)
end

local without_trailing_slash = common.without_trailing_slash


local function max_upcoming()
  local value = tonumber(noctalia.getConfig("max_upcoming")) or 30
  return math.max(5, math.min(50, math.floor(value)))
end

local function decode_file(path)
  local raw = noctalia.readFile(path)
  if type(raw) ~= "string" or raw == "" then return nil end
  local decoded, decode_error = noctalia.json.decode(raw)
  if type(decoded) == "table" then return decoded end
  noctalia.log("super-productivity: invalid JSON in " .. path .. ": " .. tostring(decode_error or "unknown error"))
  return nil
end

local function file_signature(path)
  local info = noctalia.fileInfo(path)
  if type(info) ~= "table" then return nil end
  return tostring(info.mtime or "") .. ":" .. tostring(info.size or "")
end

local function file_mtime(path)
  local info = noctalia.fileInfo(path)
  return type(info) == "table" and tonumber(info.mtime) or 0
end

local function bridge_timestamp(value)
  local timestamp = tonumber(value)
  if timestamp == nil or timestamp <= 0 or timestamp > noctalia.nowMs() + MAX_FUTURE_SKEW_MS then return nil end
  return timestamp
end

local function compatible_bridge_file(value)
  return type(value) == "table"
    and tonumber(value.schemaVersion) == SCHEMA_VERSION
    and tonumber(value.protocolVersion) == BRIDGE_PROTOCOL_VERSION
end

local function data_home()
  local configured = trim(noctalia.getenv("XDG_DATA_HOME"))
  if configured ~= "" then return without_trailing_slash(configured) end
  return without_trailing_slash(noctalia.expandPath("~/.local/share"))
end

local function package_directory()
  return data_home() .. "/" .. BRIDGE_NAME
end

local function package_path()
  return package_directory() .. "/" .. PACKAGE_ARCHIVE_NAME
end

local function package_metadata_path()
  return package_directory() .. "/" .. PACKAGE_METADATA_NAME
end

local function package_script_path()
  return PLUGIN_DIR ~= "" and PLUGIN_DIR .. "/scripts/package-companion.py" or "scripts/package-companion.py"
end

local function refresh_package_state(force)
  if (state.packageStatus == "running" or state.packageStatus == "checking") and force ~= true then return end
  if state.packageStatus == "error" and force ~= true then return end
  local manifest_path = PLUGIN_DIR ~= "" and PLUGIN_DIR .. "/companion/manifest.json" or "companion/manifest.json"
  local manifest = decode_file(manifest_path)
  local required_version = type(manifest) == "table" and trim(manifest.version) or ""
  local path = package_path()
  local info = noctalia.fileInfo(path)
  local metadata = decode_file(package_metadata_path())
  state.requiredCompanionVersion = required_version
  state.packagePath = path

  local current = type(info) == "table"
    and info.isDir ~= true
    and type(metadata) == "table"
    and tonumber(metadata.schemaVersion) == 1
    and trim(metadata.companionVersion) == required_version
    and tonumber(metadata.archiveSize) == tonumber(info.size)
    and trim(metadata.archivePath) == path
  if current then
    state.packageStatus = "ready"
    state.packageError = ""
  elseif type(info) == "table" or type(metadata) == "table" then
    state.packageStatus = "stale"
  else
    state.packageStatus = "missing"
  end
end

local function flatpak_bridge_path()
  return without_trailing_slash(noctalia.expandPath(
    "~/.var/app/" .. FLATPAK_ID .. "/data/" .. BRIDGE_NAME
  ))
end

local function bridge_candidates()
  local flatpak_path = flatpak_bridge_path()
  local native_paths = {
    data_home() .. "/" .. BRIDGE_NAME,
    without_trailing_slash(noctalia.expandPath("~/.local/share/" .. BRIDGE_NAME)),
  }
  local method = trim(noctalia.getConfig("launch_method"))
  local candidates = method == "flatpak" and { flatpak_path } or native_paths
  if method == "" or method == "auto" then table.insert(candidates, 1, flatpak_path) end

  local unique, seen = {}, {}
  for _, candidate in ipairs(candidates) do
    if candidate ~= "" and not seen[candidate] then
      seen[candidate] = true
      table.insert(unique, candidate)
    end
  end
  return unique
end

local function update_overall_status()
  if state.restStatus == "ready" or (state.restStatus == "checking" and state.generatedAt > 0) then
    state.status = "ready"
  elseif state.restStatus == "starting" or state.restStatus == "checking" then
    state.status = "starting"
  else
    state.status = "offline"
  end
  state.error = state.restError
end

local function publish()
  if state.bridgeStatus ~= "ready" then
    state.hookStatus = state.bridgeStatus
    state.hookError = state.bridgeError
  end
  local installed_version = trim(state.companionVersion)
  local required_version = trim(state.requiredCompanionVersion)
  state.companionUpdateRequired = installed_version ~= "" and required_version ~= ""
    and installed_version ~= required_version
  update_overall_status()
  noctalia.state.set(common.SNAPSHOT_KEY, state)
end

local function publish_action(next_action)
  action = next_action or { status = "idle" }
  noctalia.state.set(common.ACTION_KEY, action)
end

local function set_bridge_dir(path)
  path = without_trailing_slash(path)
  if path == bridge_dir then return end
  bridge_dir = path
  selected_bridge_method = path == flatpak_bridge_path() and "flatpak" or "native"
  connection_path = path .. "/connection.json"
  change_path = path .. "/change.json"
  bridge_error_path = path .. "/bridge-error.json"
  command_dir = path .. "/commands"
  response_dir = path .. "/responses"
  state.bridgeDir = path
  state.bridgeStatus = "starting"
  state.bridgeError = ""
  state.hookStatus = "starting"
  state.hookError = ""
  state.connectionUpdatedAt = 0
  state.changeSequence = nil
  state.changedAt = 0
  state.changeReason = ""
  connection_signature = nil
  bridge_error_signature = nil
  last_change_sequence = nil
end

local function discover_bridge_dir()
  if pending_select ~= nil and bridge_dir ~= "" then return end
  local override = trim(noctalia.getConfig("bridge_dir"))
  if override ~= "" then
    set_bridge_dir(without_trailing_slash(noctalia.expandPath(override)))
    return
  end
  local candidates = bridge_candidates()
  local selected, best_score = candidates[1], -1
  for _, candidate in ipairs(candidates) do
    local score = math.max(
      file_mtime(candidate .. "/connection.json"),
      file_mtime(candidate .. "/change.json")
    )
    if score > best_score then
      selected = candidate
      best_score = score
    end
  end
  if selected ~= nil then set_bridge_dir(selected) end
end

local function task_list()
  local list, seen = {}, {}
  if noctalia.getConfig("prefer_tracked_task") ~= false
    and type(state.currentTask) == "table"
    and state.currentTask.isDone ~= true then
    table.insert(list, state.currentTask)
    seen[state.currentTask.id] = true
  end
  local limit = max_upcoming()
  for _, task in ipairs(state.upcoming or {}) do
    if type(task) == "table" and task.id ~= nil and not seen[task.id] then
      table.insert(list, task)
      seen[task.id] = true
      if #list >= limit then break end
    end
  end
  return list
end

local function rebuild_view(preferred_id)
  local list = task_list()
  if #list == 0 then
    browse_index = 1
    state.view = nil
    return
  end
  if type(preferred_id) == "string" and preferred_id ~= "" then
    for index, task in ipairs(list) do
      if task.id == preferred_id then
        browse_index = index
        break
      end
    end
  end
  browse_index = math.max(1, math.min(#list, browse_index))
  state.view = { task = list[browse_index], index = browse_index, count = #list }
end

local function due_notifications(now_ms)
  if noctalia.getConfig("notify_due") ~= true then
    last_due_check_ms = now_ms
    return
  end
  for _, task in ipairs(task_list()) do
    local due_at = common.task_due_at(task)
    if due_at ~= nil and due_at > last_due_check_ms and due_at <= now_ms then
      noctalia.notify(noctalia.tr("notify.due_title"), task.title or noctalia.tr("task.untitled"))
    end
  end
  last_due_check_ms = now_ms
end

local function rest_failure_message(result)
  if type(result) ~= "table" then return "The Super Productivity REST API returned no response." end
  if result.kind == "auth_required" then return "Super Productivity REST API authentication failed." end
  if result.kind == "timeout" then return "The Super Productivity REST API request timed out." end
  if result.kind == "transport_error" then return "The Super Productivity REST API is unavailable." end
  if result.kind == "invalid_response" then return "The Super Productivity REST API returned an invalid response." end
  if type(result.message) == "string" and result.message ~= "" then return result.message end
  if result.status ~= nil then return "Super Productivity REST API request failed (HTTP " .. tostring(result.status) .. ")." end
  return "Super Productivity REST API request failed."
end

local function rest_status_for_failure(result)
  if result.kind == "auth_required" then return "auth_required" end
  if result.kind == "timeout" then return "timeout" end
  if result.kind == "transport_error" then return "offline" end
  return "error"
end

local function complete_refresh(results)
  refresh_running = false
  local failure = nil
  for _, name in ipairs({ "tasks", "projects", "tags", "status" }) do
    local result = results[name]
    if type(result) ~= "table" or result.ok ~= true then
      failure = result or { kind = "invalid_response" }
      break
    end
  end

  if failure == nil and (type(results.tasks.data) ~= "table"
    or type(results.projects.data) ~= "table"
    or type(results.tags.data) ~= "table"
    or type(results.status.data) ~= "table") then
    failure = { kind = "invalid_response" }
  end

  if failure == nil then
    local now_ms = noctalia.nowMs()
    local previous_id = if reset_view_on_refresh then nil else state.view and state.view.task.id or nil
    local normalized = rest_state.normalize(
      results.tasks.data,
      results.projects.data,
      results.tags.data,
      results.status.data,
      now_ms
    )
    refreshed_current_task_id = results.status.data.currentTaskId
    state.currentTask = normalized.currentTask
    state.upcoming = normalized.upcoming
    state.counts = normalized.counts
    state.generatedAt = now_ms
    state.receivedAt = now_ms
    state.restStatus = "ready"
    state.restError = ""
    if reset_view_on_refresh then browse_index = 1 end
    rebuild_view(previous_id)
    reset_view_on_refresh = false
  else
    local message = rest_failure_message(failure)
    state.restStatus = rest_status_for_failure(failure)
    state.restError = message
    state.lastError = message
  end

  local waiters = refresh_waiters
  refresh_waiters = {}
  for _, callback in ipairs(waiters) do callback(failure == nil, failure) end
  publish()

  if refresh_again then
    refresh_again = false
    refresh_waiters = queued_refresh_waiters
    queued_refresh_waiters = {}
    request_rest_state()
  end
end

request_rest_state = function(callback)
  if refresh_running then
    refresh_again = true
    if type(callback) == "function" then table.insert(queued_refresh_waiters, callback) end
    return true
  end
  if type(callback) == "function" then table.insert(refresh_waiters, callback) end

  refresh_running = true
  state.restStatus = "checking"
  state.restError = ""
  publish()
  local results = {}
  local remaining = 4
  local function receive(name, result)
    results[name] = result
    remaining -= 1
    if remaining == 0 then complete_refresh(results) end
  end
  rest_client:tasks(function(result) receive("tasks", result) end)
  rest_client:projects(function(result) receive("projects", result) end)
  rest_client:tags(function(result) receive("tags", result) end)
  rest_client:status(function(result) receive("status", result) end)
  return true
end

local function connection_is_fresh()
  return state.connectionUpdatedAt > 0
    and noctalia.nowMs() - state.connectionUpdatedAt <= CONNECTION_GRACE_MS
end

local function refresh_connection_file()
  if connection_path == "" then return end
  local signature = file_signature(connection_path)
  if signature == nil then
    connection_signature = nil
    state.bridgeStatus = state.appRunning and "companion_missing" or "offline"
    return
  end
  if signature == connection_signature then
    if state.bridgeStatus == "ready" and not connection_is_fresh() then state.bridgeStatus = "stale" end
    return
  end
  connection_signature = signature
  local connection = decode_file(connection_path)
  if type(connection) ~= "table" then
    state.bridgeStatus = "error"
    state.bridgeError = "The companion connection metadata is invalid."
    state.lastError = state.bridgeError
    return
  end
  if tonumber(connection.schemaVersion) ~= SCHEMA_VERSION
    or tonumber(connection.protocolVersion) ~= BRIDGE_PROTOCOL_VERSION then
    state.bridgeStatus = "protocol_mismatch"
    state.bridgeError = noctalia.tr("error.protocol_mismatch")
    state.protocolVersion = tonumber(connection.protocolVersion)
    state.lastError = state.bridgeError
    return
  end

  state.companionVersion = tostring(connection.companionVersion or "")
  state.protocolVersion = BRIDGE_PROTOCOL_VERSION
  state.connectionUpdatedAt = bridge_timestamp(connection.updatedAt) or 0
  state.bridgeError = trim(connection.error)
  local status = trim(connection.status)
  if state.bridgeError ~= "" or status == "error" then
    state.bridgeStatus = "error"
    if state.bridgeError == "" then state.bridgeError = "The companion reported an error." end
    state.lastError = state.bridgeError
  elseif status == "ready" then
    state.bridgeStatus = connection_is_fresh() and "ready" or "stale"
  elseif status == "offline" or status == "stopped" or status == "unloaded" then
    state.bridgeStatus = "offline"
  else
    state.bridgeStatus = "starting"
  end
end

local function valid_change(change)
  if not compatible_bridge_file(change) then return false end
  local sequence = tonumber(change.sequence)
  return sequence ~= nil and sequence >= 0 and sequence % 1 == 0
    and bridge_timestamp(change.changedAt) ~= nil
    and type(change.companionVersion) == "string"
    and type(change.reason) == "string"
    and #change.reason <= MAX_CHANGE_REASON
end

local function refresh_change_file()
  if change_path == "" then return end
  local signature = file_signature(change_path)
  if signature == nil then
    if state.bridgeStatus == "ready" then state.hookStatus = "waiting" end
    return
  end
  local change = decode_file(change_path)
  if not valid_change(change) then
    state.hookStatus = type(change) == "table"
      and tonumber(change.protocolVersion) ~= BRIDGE_PROTOCOL_VERSION
      and "protocol_mismatch" or "error"
    state.hookError = state.hookStatus == "protocol_mismatch"
      and noctalia.tr("error.protocol_mismatch") or "The companion change notification is invalid."
    state.lastError = state.hookError
    return
  end

  local sequence = tonumber(change.sequence)
  if last_change_sequence ~= nil and sequence < last_change_sequence then
    state.hookStatus = "error"
    state.hookError = "The companion change sequence moved backwards."
    state.lastError = state.hookError
    return
  end

  state.companionVersion = tostring(change.companionVersion)
  state.protocolVersion = BRIDGE_PROTOCOL_VERSION
  state.hookStatus = "ready"
  state.hookError = ""
  state.changeSequence = sequence
  state.changedAt = tonumber(change.changedAt)
  state.changeReason = tostring(change.reason or "")
  if last_change_sequence == nil or sequence > last_change_sequence then
    request_rest_state()
  end
  last_change_sequence = sequence
end

local function refresh_bridge_error()
  if bridge_error_path == "" then return end
  local signature = file_signature(bridge_error_path)
  if signature == nil then
    bridge_error_signature = nil
    return
  end
  if signature == bridge_error_signature then return end
  bridge_error_signature = signature
  local result = decode_file(bridge_error_path)
  if type(result) == "table" then
    local message = trim(result.error)
    if message ~= "" then
      state.bridgeStatus = "error"
      state.bridgeError = message
      state.lastError = message
    end
  end
end

local function resolve_launch()
  local method = trim(noctalia.getConfig("launch_method"))
  if method == "" then method = "auto" end
  if method == "auto" then
    if state.bridgeStatus == "ready" and selected_bridge_method ~= "" then
      method = selected_bridge_method
    else
      method = noctalia.flatpakAppInstalled(FLATPAK_ID) and "flatpak" or "native"
    end
  end
  if method == "flatpak" then
    local available = noctalia.flatpakAppInstalled(FLATPAK_ID)
    return {
      spec = { "flatpak", "run", FLATPAK_ID },
      method = "flatpak",
      available = available,
      error = if available then nil else noctalia.tr("error.app_unavailable"),
    }
  end

  local command = trim(noctalia.getConfig("native_command"))
  if command == "" then command = "superproductivity" end
  if command:find("%s") then
    return { method = "native", available = false, error = noctalia.tr("error.native_command_single") }
  end
  local available
  if command:sub(1, 1) == "/" then
    local info = noctalia.fileInfo(command)
    available = type(info) == "table" and info.isDir ~= true
  else
    available = noctalia.commandExists(command)
  end
  return {
    spec = { command },
    method = "native",
    available = available,
    error = if available then nil else noctalia.tr("error.app_unavailable"),
  }
end

local function apply_launch_diagnostics(resolved)
  state.appAvailable = resolved.available == true
  state.launchMethod = tostring(resolved.method or "")
end

local function launch_app()
  local resolved = resolve_launch()
  apply_launch_diagnostics(resolved)
  if not resolved.available or resolved.spec == nil then
    state.bridgeError = resolved.error or noctalia.tr("error.app_unavailable")
    state.lastError = state.bridgeError
    publish()
    return false
  end
  local started = noctalia.runAsync(resolved.spec)
  if not started then
    state.bridgeError = noctalia.tr("error.launch_failed")
    state.lastError = state.bridgeError
  end
  publish()
  return started
end

local function probe_process()
  noctalia.processMatches(function(matched)
    state.appRunning = matched == true
    apply_launch_diagnostics(resolve_launch())
    if not state.appRunning and state.bridgeStatus == "ready" then state.bridgeStatus = "offline" end
    publish()
  end, "superproductivity")
end

local function command_id()
  command_sequence += 1
  return "noctalia-" .. tostring(math.floor(noctalia.nowMs())) .. "-" .. tostring(command_sequence)
end

local function write_select_command(task_id, request_id)
  if pending_select ~= nil then return false, "Another companion request is already active." end
  if bridge_dir == "" then discover_bridge_dir() end
  if bridge_dir == "" then return false, noctalia.tr("error.bridge_unavailable") end
  local ok, mkdir_error = noctalia.mkdirAll(command_dir)
  if not ok then return false, tostring(mkdir_error or noctalia.tr("error.bridge_unavailable")) end

  local id = command_id()
  local issued_at = noctalia.nowMs()
  local command = {
    schemaVersion = SCHEMA_VERSION,
    protocolVersion = BRIDGE_PROTOCOL_VERSION,
    id = id,
    action = "select",
    issuedAt = issued_at,
    expiresAt = issued_at + COMMAND_TIMEOUT_MS,
    payload = { taskId = task_id },
  }
  local encoded, encode_error = noctalia.json.encode(command, true)
  if type(encoded) ~= "string" then return false, tostring(encode_error or "JSON encode failed") end
  local final_path = command_dir .. "/" .. id .. ".json"
  local temp_path = final_path .. ".tmp"
  local wrote, write_error = noctalia.writeFile(temp_path, encoded)
  if not wrote then return false, tostring(write_error or "Command write failed") end
  local renamed, rename_error = noctalia.renameFile(temp_path, final_path)
  if not renamed then
    noctalia.removeFile(temp_path)
    return false, tostring(rename_error or "Command publish failed")
  end

  pending_select = {
    id = id,
    requestId = request_id,
    taskId = task_id,
    startedAt = issued_at,
    commandPath = final_path,
  }
  state.lastCommandAt = issued_at
  publish_action({
    status = "working",
    commandId = id,
    requestId = request_id,
    type = "select",
    taskId = task_id,
  })
  publish()
  return true
end

local function finish_select(response)
  local request = pending_select
  if request == nil then return end
  pending_select = nil
  local now_ms = noctalia.nowMs()
  state.lastResponseAt = now_ms
  if response.ok == true then
    publish_action({
      status = "success",
      commandId = request.id,
      requestId = request.requestId,
      type = "select",
      taskId = request.taskId,
      data = response.data,
      completedAt = now_ms,
    })
  else
    local message = trim(response.error)
    if message == "" then message = noctalia.tr("error.command_failed") end
    state.bridgeError = message
    state.lastError = message
    publish_action({
      status = "error",
      commandId = request.id,
      requestId = request.requestId,
      type = "select",
      taskId = request.taskId,
      error = message,
      completedAt = now_ms,
    })
    noctalia.notifyError(noctalia.tr("notify.command_failed_title"), message)
  end
end

local function valid_select_response(response, request)
  return type(response) == "table"
    and tonumber(response.schemaVersion) == SCHEMA_VERSION
    and tonumber(response.protocolVersion) == BRIDGE_PROTOCOL_VERSION
    and response.id == request.id
    and response.action == "select"
    and type(response.ok) == "boolean"
end

local function process_responses()
  if response_dir == "" then return end
  local entries = noctalia.listDir(response_dir)
  if type(entries) ~= "table" then return end
  for _, name in ipairs(entries) do
    local id = tostring(name):match("^(.-)%.json$")
    if id ~= nil then
      local path = response_dir .. "/" .. tostring(name)
      local response = decode_file(path)
      if pending_select ~= nil and pending_select.id == id then
        if valid_select_response(response, pending_select) then
          finish_select(response)
        else
          finish_select({ ok = false, error = noctalia.tr("error.protocol_mismatch") })
        end
      end
      noctalia.removeFile(path)
    end
  end
end

local function expire_select(now_ms)
  if pending_select == nil or now_ms - pending_select.startedAt <= COMMAND_TIMEOUT_MS then return end
  local request = pending_select
  pending_select = nil
  if request.commandPath ~= nil and noctalia.fileExists(request.commandPath) then
    noctalia.removeFile(request.commandPath)
  end
  local message = noctalia.tr("error.command_timeout")
  state.bridgeError = message
  state.lastError = message
  publish_action({
    status = "error",
    commandId = request.id,
    requestId = request.requestId,
    type = "select",
    taskId = request.taskId,
    error = message,
    completedAt = now_ms,
  })
end

local function try_pending_open(now_ms)
  local pending_open = pending_open_request
  if type(pending_open) ~= "table" then return end
  if now_ms >= pending_open.expiresAt then
    pending_open_request = nil
    local message = noctalia.tr("error.launch_failed")
    state.bridgeError = message
    state.lastError = message
    publish_action({
      status = "error",
      requestId = pending_open.requestId,
      type = "select",
      taskId = pending_open.taskId,
      error = message,
      completedAt = now_ms,
    })
    return
  end
  refresh_connection_file()
  local companion_ready = state.bridgeStatus == "ready"
    and (pending_open.readyAfter == 0 or state.connectionUpdatedAt >= pending_open.readyAfter)
  if companion_ready then
    local started, message = write_select_command(pending_open.taskId, pending_open.requestId)
    if started then
      pending_open_request = nil
    elseif message ~= nil then
      state.bridgeError = message
      state.lastError = message
    end
  end
end

local function operation_busy()
  return active_rest_action ~= nil or pending_open_request ~= nil or pending_select ~= nil
end

local function reject_overlapping_action(request_id)
  local message = "Another Super Productivity action is already active."
  state.lastError = message
  -- report the rejection without replacing the active operation's working state.
  local next_action = table.clone(action)
  next_action.rejectedRequestId = request_id
  publish_action(next_action)
  noctalia.notifyError(noctalia.tr("notify.command_failed_title"), message)
  publish()
end

local function open_task(task_id, request_id)
  if trim(task_id) == "" then return end
  if operation_busy() then
    reject_overlapping_action(request_id)
    return
  end
  local now_ms = noctalia.nowMs()
  refresh_connection_file()
  local bridge_ready = state.bridgeStatus == "ready"
  pending_open_request = {
    taskId = task_id,
    requestId = request_id,
    readyAfter = bridge_ready and 0 or now_ms,
    expiresAt = now_ms + OPEN_TIMEOUT_MS,
  }
  publish_action({ status = "working", requestId = request_id, type = "select", taskId = task_id })
  if not launch_app() then
    pending_open_request = nil
    publish_action({
      status = "error",
      requestId = request_id,
      type = "select",
      taskId = task_id,
      error = state.bridgeError,
      completedAt = now_ms,
    })
    return
  end
  try_pending_open(now_ms)
end

local function play_completion_sound()
  if noctalia.getConfig("sound_on_complete") == false then return end
  if sound_ready then noctalia.sound.play(SOUND_NAME) end
end
local function clear_rest_task_state()
  state.currentTask = nil
  state.upcoming = {}
  state.view = nil
  state.counts = { active = 0, due = 0, overdue = 0 }
  state.generatedAt = 0
  browse_index = 1
end

local function begin_rest_action(kind, task_id, request_id, metadata, dispatch)
  if operation_busy() then
    reject_overlapping_action(request_id)
    return false
  end
  active_rest_action = {
    type = kind,
    taskId = task_id,
    requestId = request_id,
    metadata = metadata or {},
    startedAt = noctalia.nowMs(),
  }
  publish_action({
    status = "working",
    requestId = request_id,
    type = kind,
    taskId = task_id,
  })

  dispatch(function(result)
    local current = active_rest_action
    if current == nil or current.requestId ~= request_id then return end
    local now_ms = noctalia.nowMs()
    if result.ok == true then
      local next_action = {
        status = "success",
        requestId = request_id,
        type = kind,
        taskId = task_id,
        data = result.data,
      }
      if kind == "complete" then
        local task = current.metadata.task
        if type(task) == "table" then
          state.undo = { task = task, expiresAt = now_ms + UNDO_WINDOW_MS }
          next_action.canUndo = true
        end
        browse_index = 1
        reset_view_on_refresh = true
        play_completion_sound()
      elseif kind == "restore" then
        state.undo = nil
      elseif kind == "add" and current.metadata.source == "launcher" then
        noctalia.notify(noctalia.tr("notify.added_title"), current.metadata.input or "")
      end
      request_rest_state(function(refreshed)
        local pending = active_rest_action
        if pending == nil or pending.requestId ~= request_id then return end
        active_rest_action = nil
        if not refreshed then clear_rest_task_state() end
        -- A timer acknowledgement is not proof that tracking changed. Confirm it
        -- from the post-action refresh (queued behind any refresh already running).
        -- The authoritative ID can exist even when the task details are absent.
        if kind == "timer_start" or kind == "timer_stop" then
          local confirmed = if kind == "timer_start"
            then state.currentTask ~= nil and state.currentTask.id == task_id
            else state.currentTask == nil and refreshed_current_task_id == nil
          if not refreshed then
            next_action.status = "unknown"
            next_action.error = noctalia.tr("error.timer_confirmation_unknown")
          elseif not confirmed then
            next_action.status = "error"
            next_action.error = noctalia.tr("error.timer_confirmation_mismatch")
          end
          if next_action.error ~= nil then
            state.lastError = next_action.error
            noctalia.notifyError(noctalia.tr("notify.command_failed_title"), next_action.error)
          end
        end
        next_action.completedAt = noctalia.nowMs()
        publish_action(next_action)
        publish()
      end)
      return
    end

    active_rest_action = nil
    local message = rest_failure_message(result)
    local uncertain = (result.kind == "timeout" or result.kind == "transport_error")
      and result.dispatched == true
    local status = uncertain and "unknown" or "error"
    state.lastError = message
    if result.kind == "auth_required" or result.kind == "timeout"
      or result.kind == "transport_error" or result.kind == "invalid_response" then
      state.restStatus = rest_status_for_failure(result)
      state.restError = message
    end
    publish_action({
      status = status,
      requestId = request_id,
      type = kind,
      taskId = task_id,
      error = message,
      completedAt = now_ms,
    })
    if status == "error" then
      noctalia.notifyError(noctalia.tr("notify.command_failed_title"), message)
    end
    publish()
  end)
  return true
end

local function verify_companion_package()
  refresh_package_state(true)
  if state.packageStatus ~= "ready" then return end
  if not noctalia.commandExists("python3") then
    state.packageStatus = "error"
    state.packageError = noctalia.tr("error.python_unavailable")
    return
  end

  state.packageStatus = "checking"
  state.packageError = ""
  local started = noctalia.runAsync(
    { "python3", package_script_path(), "--verify", "--machine-readable" },
    function(result)
      if result.exitCode ~= 0 or result.timedOut then
        local message = trim(result.stderr)
        state.packageStatus = "stale"
        state.packageError = message ~= "" and message or noctalia.tr("error.package_verification_failed")
      else
        refresh_package_state(true)
      end
      publish()
    end,
    60000
  )
  if not started then
    state.packageStatus = "error"
    state.packageError = noctalia.tr("error.package_verification_failed")
  end
end

local function build_companion_package()
  if state.packageStatus == "running" or state.packageStatus == "checking" then return end
  if not noctalia.commandExists("python3") then
    state.packageStatus = "error"
    state.packageError = noctalia.tr("error.python_unavailable")
    publish()
    noctalia.notifyError(noctalia.tr("notify.package_failed_title"), state.packageError)
    return
  end

  state.packageStatus = "running"
  state.packageError = ""
  publish()
  local started = noctalia.runAsync(
    { "python3", package_script_path(), "--machine-readable" },
    function(result)
      if result.exitCode ~= 0 or result.timedOut then
        local message = trim(result.stderr)
        state.packageStatus = "error"
        state.packageError = message ~= "" and message or noctalia.tr("error.package_build_failed")
        publish()
        noctalia.notifyError(noctalia.tr("notify.package_failed_title"), state.packageError)
        return
      end
      local path = tostring(result.stdout or ""):match("ZIP_PATH=([^\r\n]+)")
      if path == nil or not noctalia.fileExists(path) then
        state.packageStatus = "error"
        state.packageError = noctalia.tr("error.package_missing")
        publish()
        noctalia.notifyError(noctalia.tr("notify.package_failed_title"), state.packageError)
        return
      end
      refresh_package_state(true)
      if state.packageStatus ~= "ready" then
        state.packageStatus = "error"
        state.packageError = noctalia.tr("error.package_build_failed")
        noctalia.notifyError(noctalia.tr("notify.package_failed_title"), state.packageError)
      end
      publish()
    end,
    60000
  )
  if not started then
    state.packageStatus = "error"
    state.packageError = noctalia.tr("error.package_build_failed")
    publish()
    noctalia.notifyError(noctalia.tr("notify.package_failed_title"), state.packageError)
  end
end

local function open_companion_package_directory()
  if not noctalia.commandExists("xdg-open") then
    noctalia.notifyError(noctalia.tr("notify.package_failed_title"), noctalia.tr("error.xdg_open_unavailable"))
    return
  end
  if state.packageStatus ~= "ready" then
    noctalia.notifyError(noctalia.tr("notify.package_failed_title"), noctalia.tr("error.package_missing"))
    return
  end
  local started = noctalia.runAsync(
    { "xdg-open", package_directory() },
    function(result)
      if result.exitCode ~= 0 or result.timedOut then
        noctalia.notifyError(noctalia.tr("notify.package_failed_title"), noctalia.tr("error.open_package_failed"))
      end
    end,
    10000
  )
  if not started then
    noctalia.notifyError(noctalia.tr("notify.package_failed_title"), noctalia.tr("error.open_package_failed"))
  end
end

local function handle_intent(intent)
  if type(intent) ~= "table" then return end
  local kind = tostring(intent.type or "")
  local task_id = trim(intent.taskId)
  local request_id = trim(intent.requestId)

  if kind == "package_build" then
    build_companion_package()
  elseif kind == "package_open_directory" then
    open_companion_package_directory()
  elseif kind == "browse" then
    local list = task_list()
    if #list == 0 then return end
    local delta = tonumber(intent.delta) or 0
    if delta == 0 then return end
    browse_index = ((browse_index - 1 + delta) % #list) + 1
    rebuild_view()
    publish()
  elseif kind == "refresh" then
    if operation_busy() then
      reject_overlapping_action(request_id)
      return
    end
    active_rest_action = { type = "refresh", requestId = request_id, startedAt = noctalia.nowMs() }
    publish_action({ status = "working", requestId = request_id, type = "refresh" })
    request_rest_state(function(ok, failure)
      if active_rest_action == nil or active_rest_action.requestId ~= request_id then return end
      active_rest_action = nil
      local now_ms = noctalia.nowMs()
      if ok then
        publish_action({ status = "success", requestId = request_id, type = "refresh", completedAt = now_ms })
      else
        publish_action({
          status = "error",
          requestId = request_id,
          type = "refresh",
          error = rest_failure_message(failure),
          completedAt = now_ms,
        })
      end
    end)
  elseif kind == "launch" then
    launch_app()
  elseif kind == "open" then
    open_task(task_id, request_id)
  elseif kind == "complete" and task_id ~= "" then
    local task = state.view and state.view.task or nil
    if type(task) ~= "table" or task.id ~= task_id then
      state.lastError = noctalia.tr("error.task_changed")
      publish()
      return
    end
    begin_rest_action("complete", task_id, request_id, { task = task }, function(callback)
      rest_client:set_done(task_id, true, callback)
    end)
  elseif kind == "add" then
    local input = type(intent.input) == "string" and intent.input or ""
    if trim(input) ~= "" then
      begin_rest_action("add", nil, request_id, {
        input = input,
        source = intent.source,
      }, function(callback)
        rest_client:add_task(input, callback)
      end)
    end
  elseif kind == "timer_toggle" and task_id ~= "" then
    local is_current = type(state.currentTask) == "table" and state.currentTask.id == task_id
    local operation = is_current and "timer_stop" or "timer_start"
    begin_rest_action(operation, task_id, request_id, nil, function(callback)
      if is_current then rest_client:stop_task(callback) else rest_client:start_task(task_id, callback) end
    end)
  elseif kind == "snooze" and task_id ~= "" then
    local mode = tostring(intent.mode or "")
    begin_rest_action("snooze", task_id, request_id, nil, function(callback)
      rest_client:reschedule_task(task_id, mode, noctalia.nowMs(), callback)
    end)
  elseif kind == "undo" then
    local undo = state.undo
    if type(undo) == "table" and undo.expiresAt > noctalia.nowMs() then
      begin_rest_action("restore", undo.task.id, request_id, nil, function(callback)
        rest_client:set_done(undo.task.id, false, callback)
      end)
    end
  end
end

noctalia.state.watch(common.INTENT_KEY, handle_intent)

function update()
  local now_ms = noctalia.nowMs()
  rest_client:update(now_ms)

  if now_ms - last_bridge_search_ms >= 10000 then
    last_bridge_search_ms = now_ms
    discover_bridge_dir()
  end
  if now_ms - last_process_check_ms >= 10000 then
    last_process_check_ms = now_ms
    probe_process()
  end
  if now_ms - last_file_poll_ms >= BRIDGE_POLL_MS then
    last_file_poll_ms = now_ms
    refresh_connection_file()
    refresh_change_file()
    refresh_bridge_error()
  end
  process_responses()
  expire_select(now_ms)
  due_notifications(now_ms)

  if type(state.undo) == "table" and state.undo.expiresAt <= now_ms then state.undo = nil end
  try_pending_open(now_ms)

  if noctalia.getConfig("auto_start") == true and not auto_start_attempted
    and not state.appRunning and now_ms - service_started_at > 1500 and state.restStatus ~= "ready" then
    auto_start_attempted = true
    launch_app()
  end
  publish()
end

function onConfigChanged()
  auto_start_attempted = false
  discover_bridge_dir()
  rest_client:invalidate_for_config()
  rebuild_view(state.view and state.view.task.id or nil)
  request_rest_state()
  publish()
end

noctalia.setUpdateInterval(1000)
verify_companion_package()
discover_bridge_dir()
local accepted = noctalia.sound.load(SOUND_NAME, "sounds/ding-small-bell.mp3", function(ok, load_error)
  sound_ready = ok == true
  if not sound_ready and load_error ~= nil then noctalia.log("super-productivity: " .. tostring(load_error)) end
end)
if not accepted then noctalia.log("super-productivity: completion sound load was not accepted") end
publish_action(action)
publish()
request_rest_state()
