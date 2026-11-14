-- Budget panel: replicates mb-tray's SNI menu actions inside Noctalia.
-- Values are MB; presets mirror mb-tray (total 2/3/4/6/8 G, per-client 1/2/3/4 G,
-- MemAvailable floor 1.5/2/2.5/3 G). Apply writes through mbctl, the same socket
-- and permissions mb-tray used. Kept separate from widget.luau so the widget can
-- stay icon-only and light.

local MBCTL = "/opt/mali-stack/current/bin/mbctl"

local TOTALS = { 2, 3, 4, 6, 8 }
local CLIENTS = { 1, 2, 3, 4 }
local FLOORS = { 1.5, 2, 2.5, 3 }

local selTotal = 4
local selPid = 2
local selFloor = 2
local st = { used = nil, total = nil, clients = nil, availKb = nil }
local busy = false
local statusMsg = nil
local statusErr = false

local function refresh(cb)
  noctalia.runAsync(MBCTL .. " status --json", function(result)
    if result and result.exitCode == 0 and result.stdout then
      local ok, data = pcall(function()
        return noctalia.json.decode(result.stdout)
      end)
      if ok and type(data) == "table" then
        st.used = data.usage and tonumber(data.usage.total_bytes) or nil
        st.total = data.budget and tonumber(data.budget.total_mb) or nil
        st.clients = tonumber(data.clients_count)
        st.availKb = data.system and tonumber(data.system.mem_available_kb) or nil
        if st.total then
          selTotal = math.floor(st.total / 1024 + 0.5)
        end
        if data.budget then
          local p = tonumber(data.budget.pid_mb)
          local f = tonumber(data.budget.floor_mb)
          if p then selPid = math.floor(p / 1024 + 0.5) end
          if f then selFloor = f / 1024 end
        end
      end
    end
    if cb then cb() end
  end)
end

local function gb(bytes)
  if not bytes then
    return "?"
  end
  return string.format("%.2f", bytes / 1073741824)
end

local function apply(persist)
  if busy then
    return
  end
  busy = true
  statusMsg = persist and "正在应用并保存…" or "正在应用…"
  statusErr = false
  render()
  local cmd = string.format(
    "%s set --total %d --pid %d --floor %d%s --json",
    MBCTL,
    selTotal * 1024,
    selPid * 1024,
    math.floor(selFloor * 1024),
    persist and " --persist" or ""
  )
  noctalia.runAsync(cmd, function(result)
    busy = false
    local ok = result and result.exitCode == 0
    local detail = nil
    if result and result.stdout and result.stdout ~= "" then
      local parsed, data = pcall(function()
        return noctalia.json.decode(result.stdout)
      end)
      if parsed and type(data) == "table" then
        if data.ok == false then
          ok = false
        end
        if data.error then
          detail = tostring(data.error)
        end
      end
    end
    if ok then
      statusMsg = string.format(
        "%s：总预算 %g G / 单客户端 %g G / 下限 %g G",
        persist and "已应用并保存" or "已应用",
        selTotal, selPid, selFloor
      )
      statusErr = false
    else
      statusMsg = string.format(
        "应用失败%s",
        detail and (": " .. detail) or (result and (" (exit " .. tostring(result.exitCode) .. ")") or "：未执行")
      )
      statusErr = true
    end
    refresh(render)
  end)
end

local function presetRow(title, values, current, unit, choose)
  local buttons = {}
  for _, v in ipairs(values) do
    local selected = math.abs(current - v) < 0.001
    local label
    if unit == "G" then
      if v % 1 == 0 then
        label = string.format("%d G", v)
      else
        label = string.format("%.1f G", v)
      end
    else
      label = tostring(v)
    end
    buttons[#buttons + 1] = ui.button({
      text = label,
      variant = selected and "primary" or "default",
      onClick = function()
        choose(v)
        render()
      end,
    })
  end
  return ui.column({ gap = 6 }, {
    ui.label({ text = title, fontWeight = "bold", color = "on_surface" }),
    ui.row({ gap = 6 }, buttons),
  })
end

function render()
  local info = {}
  if st.used and st.total then
    info[#info + 1] = string.format("Bridge %.2f / %.1f G", st.used / 1073741824, st.total / 1024)
  end
  if st.clients then
    info[#info + 1] = string.format("clients %d", st.clients)
  end
  if st.availKb then
    info[#info + 1] = string.format("MemAvailable %.0f MB", st.availKb / 1024)
  end

  panel.render(ui.column({ gap = 12, padding = 16 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "MaliBridge 预算", fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
      ui.button({ glyph = "close", onClick = function()
        panel.close()
      end }),
    }),
    ui.label({ text = table.concat(info, "  |  "), color = "on_surface" }),
    statusMsg and ui.label({
      text = statusMsg,
      color = statusErr and "error" or "primary",
      fontWeight = "bold",
    }) or nil,
    ui.separator({}),
    presetRow("总预算", TOTALS, selTotal, "G", function(v)
      selTotal = v
    end),
    presetRow("单客户端上限", CLIENTS, selPid, "G", function(v)
      selPid = v
    end),
    presetRow("MemAvailable 下限", FLOORS, selFloor, "G", function(v)
      selFloor = v
    end),
    ui.separator({}),
    ui.row({ gap = 8 }, {
      ui.button({ text = "立即应用", variant = "primary", onClick = function()
        apply(false)
      end }),
      ui.button({ text = "应用并保存", onClick = function()
        apply(true)
      end }),
    }),
    ui.row({ gap = 8 }, {
      ui.button({ text = "打开报告", variant = "ghost", onClick = function()
        noctalia.runInTerminal("less /opt/mb-sock/malibridge-report.md")
      end }),
      ui.button({ text = "打开日志", variant = "ghost", onClick = function()
        noctalia.runInTerminal("less /opt/mb-sock/server.log")
      end }),
    }),
  }))
end

function onOpen()
  refresh(render)
end
