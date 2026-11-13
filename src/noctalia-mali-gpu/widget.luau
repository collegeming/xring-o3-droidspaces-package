-- mali-gpu: Noctalia bar widget for the XRING-O3 Mali GPU.
--
-- Data sources (all device-local, no network):
--   /sys/class/misc/mali0/device/gpuinfo         model string
--   /sys/class/devfreq/gpufreq_core/cur_freq     current GPU clock (Hz)
--   /sys/class/devfreq/gpufreq_core/max_freq     max GPU clock (Hz)
--   /sys/class/thermal/thermal_zone*/temp        gpu-ss-* temperatures (milli-C)
--   mbctl status --json                          MaliBridge budget/usage
--   /opt/mb-sock/malibridge-report.json          per-process fps_p50
--
-- Mali kbase does not expose a usable busy counter (debugfs dvfs_utilization
-- stays frozen/underflowed), so this widget shows frequency, temperature and
-- memory rather than a fabricated "GPU load" percentage.

noctalia.setUpdateInterval(2000)

local MODEL_PATH = "/sys/class/misc/mali0/device/gpuinfo"
local FREQ_CUR = "/sys/class/devfreq/gpufreq_core/cur_freq"
local FREQ_MAX = "/sys/class/devfreq/gpufreq_core/max_freq"
local REPORT_PATH = "/opt/mb-sock/malibridge-report.json"
local MBCTL = "/opt/mali-stack/current/bin/mbctl"

local tempPath = nil
local tick = 0
local bridgeUsed = nil
local bridgeTotal = nil
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
      bridgeUsed = tonumber(data.usage.total_bytes)
    end
    if type(data.budget) == "table" then
      local mb = tonumber(data.budget.total_mb)
      if mb then
        bridgeTotal = mb * 1024 * 1024
      end
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

  local parts = {}
  if cur then
    parts[#parts + 1] = formatMhz(cur) .. "M"
  end
  if temp then
    parts[#parts + 1] = string.format("%.0f°", temp)
  end
  if #parts == 0 then
    parts[1] = "?"
  end
  barWidget.setText("GPU " .. table.concat(parts, " "))

  local rows = {
    { key = "GPU", value = readTrim(MODEL_PATH) or "Mali GPU" },
    { key = "Freq", value = formatMhz(cur) .. " / " .. formatMhz(max) .. " MHz" },
  }
  if temp then
    rows[#rows + 1] = { key = "Temp", value = string.format("%.1f °C", temp) }
  end
  if bridgeUsed and bridgeTotal then
    rows[#rows + 1] = {
      key = "Bridge",
      value = string.format("%.2f / %.2f GB", bridgeUsed / 1073741824, bridgeTotal / 1073741824),
    }
  end
  if #topFps > 0 then
    rows[#rows + 1] = { key = "FPS", value = table.concat(topFps, " · ") }
  end
  barWidget.setTooltip(rows)
end
