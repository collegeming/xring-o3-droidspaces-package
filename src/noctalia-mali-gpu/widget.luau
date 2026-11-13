-- mali-gpu: Noctalia bar widget for the XRING-O3 Mali GPU and MaliBridge budget.
--
-- Default state is icon-only (no numbers). Hover shows the merged view that the
-- old mb-tray SNI tooltip exposed:
--   GPU model, frequency, temperature, bridge usage/budget, MemAvailable,
--   client count, per-client bytes, applied total/client/floor, per-app FPS.
--
--
-- Mali kbase has no usable busy counter (debugfs dvfs_utilization is frozen),
-- so no fabricated "GPU load" percentage is shown.

noctalia.setUpdateInterval(2000)

local MODEL_PATH = "/sys/class/misc/mali0/device/gpuinfo"
local FREQ_CUR = "/sys/class/devfreq/gpufreq_core/cur_freq"
local FREQ_MAX = "/sys/class/devfreq/gpufreq_core/max_freq"
local REPORT_PATH = "/opt/mb-sock/malibridge-report.json"
local MBCTL = "/opt/mali-stack/current/bin/mbctl"

local tempPath = nil
local tick = 0
local bridge = {
  used = nil,
  total = nil,
  pid = nil,
  floor = nil,
  mapLimit = nil,
  availKb = nil,
  clientsCount = nil,
  clients = {},
}
local topFps = {}

local function readTrim(path)
  local s = noctalia.readFile(path)
  if not s then
    return nil
  end
  return (string.gsub(s, "%s+$", ""))
end

local function readNum(path)
  local s = readTrim(path)
  if not s or s == "" then
    return nil
  end
  return tonumber(s)
end

local function findGpuTemp()
  local entries = noctalia.listDir("/sys/class/thermal")
  if not entries then
    return
  end
  local fallback = nil
  for _, name in ipairs(entries) do
    if string.sub(name, 1, 12) == "thermal_zone" then
      local kind = readTrim("/sys/class/thermal/" .. name .. "/type")
      if kind and string.find(kind, "gpu", 1, true) then
        local candidate = { kind = kind, path = "/sys/class/thermal/" .. name .. "/temp" }
        if kind == "gpu-ss-max" then
          tempPath = candidate.path
          return
        end
        if not fallback then
          fallback = candidate
        end
      end
    end
  end
  if fallback then
    tempPath = fallback.path
  end
end

local function refreshBridge()
  noctalia.runAsync(MBCTL .. " status --json", function(result)
    if not result or result.exitCode ~= 0 or not result.stdout then
      return
    end
    local ok, data = pcall(function()
      return noctalia.json.decode(result.stdout)
    end)
    if not ok or type(data) ~= "table" then
      return
    end
    if type(data.usage) == "table" then
      bridge.used = tonumber(data.usage.total_bytes)
      bridge.clients = {}
      if type(data.usage.clients) == "table" then
        for _, c in ipairs(data.usage.clients) do
          local pid = tonumber(c.pid)
          local bytes = tonumber(c.bytes)
          if pid and bytes then
            bridge.clients[#bridge.clients + 1] = { pid = pid, bytes = bytes }
          end
        end
        table.sort(bridge.clients, function(a, b)
          return a.bytes > b.bytes
        end)
      end
    end
    if type(data.budget) == "table" then
      bridge.total = tonumber(data.budget.total_mb)
      bridge.pid = tonumber(data.budget.pid_mb)
      bridge.floor = tonumber(data.budget.floor_mb)
      bridge.mapLimit = tonumber(data.budget.map_limit)
    end
    if type(data.system) == "table" then
      bridge.availKb = tonumber(data.system.mem_available_kb)
      bridge.clientsCount = tonumber(data.clients_count)
    end
  end)
end

local function refreshReport()
  local raw = noctalia.readFile(REPORT_PATH)
  if not raw then
    return
  end
  local ok, data = pcall(function()
    return noctalia.json.decode(raw)
  end)
  if not ok or type(data) ~= "table" or type(data.processes) ~= "table" then
    return
  end
  local list = {}
  for _, proc in ipairs(data.processes) do
    local fps = tonumber(proc.fps_p50) or 0
    if proc.alive and fps > 0.5 then
      list[#list + 1] = { name = proc.name or proc.comm or "?", fps = fps }
    end
  end
  table.sort(list, function(a, b)
    return a.fps > b.fps
  end)
  topFps = {}
  for i = 1, math.min(3, #list) do
    topFps[#topFps + 1] = string.format("%s %.0f", list[i].name, list[i].fps)
  end
end

local function formatMhz(hz)
  if not hz then
    return "?"
  end
  return string.format("%.0f", hz / 1000000)
end

local function gb(bytes)
  if not bytes then
    return "?"
  end
  return string.format("%.2f", bytes / 1073741824)
end

local function topClients()
  local parts = {}
  for i = 1, math.min(3, #bridge.clients) do
    parts[#parts + 1] = string.format("%d:%.0fM", bridge.clients[i].pid, bridge.clients[i].bytes / 1048576)
  end
  return table.concat(parts, " ")
end

findGpuTemp()

function update()
  tick = tick + 1
  if tick % 15 == 1 then
    refreshBridge()
  end
  if tick % 5 == 1 then
    refreshReport()
  end

  local cur = readNum(FREQ_CUR)
  local max = readNum(FREQ_MAX)
  local temp = nil
  if tempPath then
    local milli = readNum(tempPath)
    if milli then
      temp = milli / 1000
    end
  end

  -- Icon-only default; the numbers live in the hover tooltip.
  barWidget.setText("")
  barWidget.setGlyph("cpu")

  local rows = {
    { key = "GPU", value = readTrim(MODEL_PATH) or "Mali GPU" },
    { key = "Freq", value = formatMhz(cur) .. " / " .. formatMhz(max) .. " MHz" },
  }
  if temp then
    rows[#rows + 1] = { key = "Temp", value = string.format("%.1f °C", temp) }
  end
  if bridge.used then
    rows[#rows + 1] = { key = "Bridge", value = gb(bridge.used) .. " / " .. (bridge.total and string.format("%.1f", bridge.total / 1024) or "?") .. " G" }
  end
  if bridge.availKb then
    rows[#rows + 1] = { key = "MemAvailable", value = string.format("%.0f MB", bridge.availKb / 1024) }
  end
  if bridge.clientsCount then
    local value = string.format("%d", bridge.clientsCount)
    local top = topClients()
    if top ~= "" then
      value = value .. " · " .. top
    end
    rows[#rows + 1] = { key = "Clients", value = value }
  end
  if bridge.total then
    rows[#rows + 1] = {
      key = "Budget",
      value = string.format("%.0f / %.0f / %.1f G", bridge.total / 1024, (bridge.pid or 0) / 1024, (bridge.floor or 0) / 1024),
    }
  end
  if #topFps > 0 then
    rows[#rows + 1] = { key = "FPS", value = table.concat(topFps, " · ") }
  end
  if bridge.used and bridge.total and bridge.used > bridge.total * 1048576 then
    rows[#rows + 1] = { key = "WARN", value = "usage above total budget" }
  end
  barWidget.setTooltip(rows)
end

function onClick()
  noctalia.togglePanel("collegeming/mali-gpu:budget")
end

