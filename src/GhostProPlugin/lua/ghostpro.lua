--[[
  GhostPro — server-pushed client script
  ==============================================================
  Pushed by GhostProPlugin (AssettoServer). Replaces GhostPassive v25 and the
  HardBrain free plugins with one script.

  WHY THIS IS ONE FILE
  An online script is compiled with `withoutIO = true`, so io.load/require of
  local files is unavailable. Everything must be inlined. Sections are marked so
  it stays navigable.

  SECTIONS
    1  Server-injected config
    2  Theme tokens (Car Customizer's look)
    3  Protocol
    4  Settings
    5  Colour maths
    6  Spring animation
    7  Input
    8  Speedo HUD
    9  Lock button + menu
   10  Colour panel
   11  Skins
   12  Physics helpers (boost/repair/rewind/teleport)
   13  Personal time + weather
   14  Perf mode (hide distant cars)
   15  Frame loop

  KEYS
    M  menu        N  next tab     T  teleport      B  boost
    V  repair      R  rewind       C  colour        X  skins
    G  ghost       P  perf mode    H  hide UI
]]

-- ===== 1. Server-injected config =========================================
-- Substituted by GhostProScriptPusher. The defaults are what a client sees if
-- the token survives unsubstituted, which would mean a mis-deployed build.
local ANNOUNCE_INTERVAL = tonumber('{{ANNOUNCE_INTERVAL}}') or 4
local STATE_TTL = tonumber('{{STATE_TTL}}') or 14
local ALLOW_REMOTE_PAINT = ('{{ALLOW_REMOTE_PAINT}}' == 'true')
local ALLOW_BOTS = ('{{ALLOW_BOTS}}' == 'true')
local PERSONAL_TIME = ('{{PERSONAL_TIME}}' == 'true')

-- ===== 2. Theme tokens =====================================================
-- Shared with Car Customizer: same accents, same three appearances, so a
-- server running both looks like one product.
local THEMES = {
  { name = 'Emerald', acc = { 0.29, 0.87, 0.50 }, panel = { 0.06, 0.07, 0.08 } },
  { name = 'Ice',     acc = { 0.38, 0.75, 1.00 }, panel = { 0.04, 0.07, 0.11 } },
  { name = 'Neon',    acc = { 0.96, 0.32, 0.85 }, panel = { 0.07, 0.03, 0.09 } },
  { name = 'Sunset',  acc = { 1.00, 0.62, 0.22 }, panel = { 0.10, 0.06, 0.04 } },
  { name = 'Mono',    acc = { 0.95, 0.95, 0.95 }, panel = { 0.02, 0.02, 0.02 } },
}
local APPEARANCES = { 'Transparent', 'Light', 'Dark' }
local MOTION = {
  spring = { k = 220, d = 16, scaleFrom = 0.60, slide = 16, slideY = 14, round = 1.00 },
  slide  = { k = 300, d = 20, scaleFrom = 0.75, slide = 10, slideY = 8,  round = 1.00 },
}
-- Transparent needs less opacity than Light to stay legible over a bright
-- track; Dark sits between. One number per appearance, not per call site.
local SURFACE_ALPHA = { Transparent = 0.72, Light = 0.86, Dark = 0.78 }

local function clamp01(x) return math.max(0, math.min(1, x)) end

local function themeIndexOf(list, value)
  for i = 1, #list do if list[i] == value then return i end end
  return nil
end

local cfg = ac.storage{
  theme = 'Emerald', appearance = 'Transparent', motion = 'spring',
  speedoX = -1, speedoY = -1, speedoScale = 1.0,
  speedoVisible = true, speedoUnits = 'kmh',
  bodyOn = false, bodyH = 0, bodyS = 0.85, bodyV = 0.85,
  rimOn  = false, rimH  = 0, rimS  = 0.85, rimV  = 0.85,
  lastSkin = '', lockX = -1, lockY = -1,
}

local themeIdx = themeIndexOf(THEMES, cfg.theme) or 1
local appearanceIdx = themeIndexOf(APPEARANCES, cfg.appearance) or 1
local motion = cfg.motion == 'slide' and 'slide' or 'spring'

-- Smoothed copies. Values transition rather than snap, which is why consumers
-- read these instead of the theme table directly.
local cur = { acc = {}, muted = {}, pan = {}, alpha = SURFACE_ALPHA[APPEARANCES[appearanceIdx]] }
do
  local t = THEMES[themeIdx]
  cur.acc = { t.acc[1], t.acc[2], t.acc[3] }
  cur.muted = { (t.acc[1] + 0.55) / 2, (t.acc[2] + 0.55) / 2, (t.acc[3] + 0.55) / 2 }
  cur.pan = { t.panel[1], t.panel[2], t.panel[3] }
end

local function targetTokens()
  local t = THEMES[themeIdx]
  return {
    acc = t.acc,
    -- Off-state is desaturated, never the same hue at lower brightness: the
    -- lock must read as inactive without relying on brightness alone.
    muted = { (t.acc[1] + 0.55) / 2, (t.acc[2] + 0.55) / 2, (t.acc[3] + 0.55) / 2 },
    pan = t.panel,
    alpha = SURFACE_ALPHA[APPEARANCES[appearanceIdx]],
    motion = MOTION[motion],
  }
end

local function accent(a) return rgbm(cur.acc[1], cur.acc[2], cur.acc[3], a or 1) end
local function muted(a)  return rgbm(cur.muted[1], cur.muted[2], cur.muted[3], a or 1) end
local function panel(a)
  return rgbm(cur.pan[1], cur.pan[2], cur.pan[3], math.min(1, cur.alpha * (a or 1)))
end

local function stepTheme(dt)
  local tt = targetTokens()
  local k = math.min(1, dt * 8)
  for i = 1, 3 do
    cur.acc[i] = cur.acc[i] + (tt.acc[i] - cur.acc[i]) * k
    cur.muted[i] = cur.muted[i] + (tt.muted[i] - cur.muted[i]) * k
    cur.pan[i] = cur.pan[i] + (tt.pan[i] - cur.pan[i]) * k
  end
  cur.alpha = cur.alpha + (tt.alpha - cur.alpha) * k
end

local function cycleTheme()
  themeIdx = themeIdx % #THEMES + 1
  cfg.theme = THEMES[themeIdx].name
  ac.setMessage('GhostPro', 'Theme: ' .. cfg.theme)
end

local function cycleAppearance()
  appearanceIdx = appearanceIdx % #APPEARANCES + 1
  cfg.appearance = APPEARANCES[appearanceIdx]
  ac.setMessage('GhostPro', 'Appearance: ' .. cfg.appearance)
end

-- ===== 3. Protocol =========================================================
-- Keys and field names MUST match src/GhostProPlugin/Packets/GhostProPackets.cs.
-- Sizes are explicit because the server parses the layout, not just the names.
local serverPassive, serverAllowBots, serverMode = false, false, 0
local serverMinBrightness = 0
local grantMask = 0
local serverSeen = false

local passive, ghostTimer = false, 0
local remoteSeen = {}          -- [carIndex] = last announce time (seconds)
local remotePaint = {}         -- [carIndex] = { body = {r,g,b}, rim = {r,g,b} }
local appliedPaint = {}        -- [carIndex][part] = packed key
local collisionApplied = {}    -- [carIndex] = desired state
local lastReset = {}           -- [carIndex] = resetCounter seen
local ownPaint = {}            -- [part] = { r, g, b }

local function simTime()
  local sim = ac.getSim()
  return sim and (sim.time / 1000) or 0
end

-- --- server -> client: decision ------------------------------------------
-- Every field below must match [OnlineEventField(Name = ...)] in
-- src/GhostProPlugin/Packets/GhostProPackets.cs. AssettoServer derives the wire
-- layout from those attributes and reorders fields for packing using CSP's own
-- algorithm, so declaration order here is cosmetic but NAMES are not.
local grantEvent = ac.OnlineEvent({
  ac.StructItem.key('ghostProGrant'),
  passive = ac.StructItem.boolean(),
  allowBots = ac.StructItem.boolean(),
  mode = ac.StructItem.uint8(),
  minBrightness = ac.StructItem.uint8(),
}, function(sender, msg)
  if sender ~= nil then return end   -- only a server may speak for the server
  serverSeen = true
  serverPassive = msg.passive == true
  serverAllowBots = msg.allowBots == true
  serverMode = msg.mode or 0
  serverMinBrightness = (msg.minBrightness or 0) / 255
end)

-- --- server -> all: bitmask of passable cars ------------------------------
local stateEvent = ac.OnlineEvent({
  ac.StructItem.key('ghostProState'),
  granted = ac.StructItem.uint32(),
}, function(sender, msg)
  if sender ~= nil then return end
  grantMask = msg.granted or 0
end)

-- --- server -> all: someone else's paint ---------------------------------
local paintRelay = ac.OnlineEvent({
  ac.StructItem.key('ghostProPaintRelay'),
  carIndex = ac.StructItem.uint8(),
  part = ac.StructItem.uint8(),
  r = ac.StructItem.uint8(),
  g = ac.StructItem.uint8(),
  b = ac.StructItem.uint8(),
  reset = ac.StructItem.boolean(),
}, function(sender, msg)
  if sender ~= nil then return end
  local index = msg.carIndex
  if index == 0 then return end   -- never repaint our own car from the relay
  local part = (msg.part == 1) and 'rim' or 'body'
  remotePaint[index] = remotePaint[index] or {}
  if msg.reset then
    remotePaint[index][part] = false
  elseif not tooDark({ r = msg.r / 255, g = msg.g / 255, b = msg.b / 255 }) then
    remotePaint[index][part] = { r = msg.r / 255, g = msg.g / 255, b = msg.b / 255 }
  end
end)

-- --- client -> server: request --------------------------------------------
-- Sent to the server specifically. The relay key is only understood by the
-- plugin, so peers never see it and there is no way to fake a grant.
local reqEvent = ac.OnlineEvent({
  ac.StructItem.key('ghostProReq'),
  mode = ac.StructItem.string(4),
  bots = ac.StructItem.boolean(),
}, function() end)

local paintEvent = ac.OnlineEvent({
  ac.StructItem.key('ghostProPaint'),
  part = ac.StructItem.uint8(),
  r = ac.StructItem.uint8(),
  g = ac.StructItem.uint8(),
  b = ac.StructItem.uint8(),
  reset = ac.StructItem.boolean(),
}, function() end)

local timeEvent = ac.OnlineEvent({
  ac.StructItem.key('ghostProTime'),
  mode = ac.StructItem.string(4),
  seconds = ac.StructItem.string(8),
}, function() end)

local weatherEvent = ac.OnlineEvent({
  ac.StructItem.key('ghostProWeather'),
  mode = ac.StructItem.string(4),
  type = ac.StructItem.string(24),
}, function() end)

local function askServer(mode, bots)
  -- repeatForNewConnections is false here: a request is not durable state, and
  -- the server re-broadcasts the decision itself.
  pcall(function() reqEvent({ mode = mode, bots = bots == true }, false, 255) end)
end

local function sendPaint(part, colour, reset)
  if not ALLOW_REMOTE_PAINT then return end
  pcall(function()
    paintEvent({
      part = (part == 'rim') and 1 or 0,
      r = colour and math.floor(clamp01(colour.r) * 255 + 0.5) or 0,
      g = colour and math.floor(clamp01(colour.g) * 255 + 0.5) or 0,
      b = colour and math.floor(clamp01(colour.b) * 255 + 0.5) or 0,
      reset = reset == true,
    }, false, 255)
  end)
end

-- ===== 4. Settings =========================================================
local function tooDark(c)
  if serverMinBrightness <= 0 then return false end
  return math.max(c.r or 0, c.g or 0, c.b or 0) < serverMinBrightness
end

-- ===== 5. Colour maths ====================================================
-- HSV because the brightness floor is a brightness rule, and clamping V is
-- clearer than deriving a max channel from RGB.
local hsv = {
  body = { h = 0, s = 0.85, v = 0.85 },
  rim  = { h = 0, s = 0.85, v = 0.85 },
}
local activePart = 'body'
local PARTS = { 'body', 'rim' }
local PART_LABEL = { body = 'Body', rim = 'Rim' }
local SWATCHES = {
  { 0, 0, 0 }, { 0, 0, 1 }, { 0, 0.85, 0.9 }, { 25, 0.9, 1 }, { 50, 0.9, 1 },
  { 125, 0.8, 0.85 }, { 180, 0.8, 0.9 }, { 215, 0.85, 0.95 }, { 275, 0.7, 0.9 },
  { 325, 0.7, 0.95 },
}

local function hsvToRgb(h, s, v)
  h = (h % 360) / 60
  local i, f = math.floor(h), h - math.floor(h)
  local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
  i = i % 6
  if i == 0 then return v, t, p
  elseif i == 1 then return q, v, p
  elseif i == 2 then return p, v, t
  elseif i == 3 then return p, q, v
  elseif i == 4 then return t, p, v
  else return v, p, q end
end

local function currentRgb(part)
  local st = hsv[part or activePart]
  return hsvToRgb(st.h, st.s, st.v)
end

local function hsvRgbm(h, s, v, a)
  local r, g, b = hsvToRgb(h, s, v)
  return rgbm(r, g, b, a or 1)
end

-- ===== 6. Spring animation =================================================
-- Frame-rate independent. A per-frame lerp would make animation speed depend
-- on the player's machine, which reads as a bug.
local function spring(value, velocity, goal, dt, k, d)
  local step = math.max(0, math.min(dt, 0.04))
  local force = (goal - value) * k - velocity * d
  local v = velocity + force * step
  return value + v * step, v
end

local function settle(value, velocity, epsilon)
  if math.abs(value) < (epsilon or 0.01) and math.abs(velocity) < 0.05 then
    return 0, 0
  end
  return value, velocity
end

local function approach(current, goal, dt, rate)
  return current + (goal - current) * clamp01(dt * rate)
end

-- ===== 7. Input ============================================================
-- ac.ControlButton keeps bindings in the settings UI. Each is optional: a build
-- without it falls back to a raw key check rather than failing to load.
local function bind(name, defaults)
  local ok, button = pcall(ac.ControlButton, name, defaults)
  return ok and button or nil
end

local keyMenu     = bind('ghostPro/Menu',     { keyboard = { key = ui.KeyIndex.M } })
local keyGhost    = bind('ghostPro/Ghost',    { keyboard = { key = ui.KeyIndex.G } })
local keyColour   = bind('ghostPro/Colour',   { keyboard = { key = ui.KeyIndex.C } })
local keyPerf     = bind('ghostPro/Perf',     { keyboard = { key = ui.KeyIndex.P } })
local keyHideUi   = bind('ghostPro/HideUI',   { keyboard = { key = ui.KeyIndex.H } })
local keyTheme    = bind('ghostPro/Theme',    { keyboard = { key = ui.KeyIndex.T, ctrl = true } })

local menuOpen, colourOpen = false, false
local menuAnim, menuVel = 0, 0
local colourAnim, colourVel = 0, 0
local knob = 0
local uiHidden = false

local function pressed(button, fallbackIndex, ctrl)
  if button then
    local ok, hit = pcall(function() return button:pressed() end)
    if ok then return hit == true end
  end
  local ok, hit = pcall(ui.keyboardButtonPressed, fallbackIndex, ctrl == true)
  return ok and hit == true
end

-- ===== 8. Speedo HUD ======================================================
-- Drag to move, wheel to resize, both persisted. Copied in behaviour from
-- HardBrain's SpeedoPlugin with the theme applied so it matches the menu.
local SPEEDO_W, SPEEDO_H = 680, 130
local speedoDrag, speedoOff = false, vec2(0, 0)

local function drawArc(cx, cy, r, thickness, colour)
  local segments = 28
  local startA = math.pi * 0.75
  local span = (math.pi * 0.25 - startA) + math.pi * 2
  for i = 0, segments - 1 do
    local t0 = startA + span * (i / segments)
    local t1 = startA + span * ((i + 1) / segments)
    ui.drawLine(
      vec2(cx + math.cos(t0) * r, cy + math.sin(t0) * r),
      vec2(cx + math.cos(t1) * r, cy + math.sin(t1) * r),
      colour, thickness)
  end
end

local function assistFlag(car, field)
  if not car then return false end
  local ok, v = pcall(function() return car[field] end)
  if not ok or v == nil then return false end
  if type(v) == 'boolean' then return v end
  if type(v) == 'number' then return v > 0 end
  return false
end

local function drawSpeedo(dt)
  if not cfg.speedoVisible or uiHidden then return end
  local car = ac.getCar(0)
  if not car then return end
  local okUi, uiState = pcall(function() return ac.getUI() end)
  if okUi and uiState and uiState.appsHidden then return end
  pcall(function() if ac.isInReplayMode() then return end end)

  local screen = ui.windowSize()
  local scale = math.max(0.55, math.min(1.85, tonumber(cfg.speedoScale) or 1))
  cfg.speedoScale = scale

  local w = math.floor(SPEEDO_W * scale + 0.5)
  local h = math.floor(SPEEDO_H * scale + 0.5)

  local x, y = tonumber(cfg.speedoX) or -1, tonumber(cfg.speedoY) or -1
  if x < 0 or y < 0 then
    x = (screen.x - w) * 0.5
    y = screen.y - h - 18
    cfg.speedoX, cfg.speedoY = x, y
  end
  local function clampPos(px, py)
    return math.max(8, math.min(screen.x - w - 8, px)),
           math.max(8, math.min(screen.y - h - 8, py))
  end
  x, y = clampPos(x, y)

  local mp = ui.mousePos()
  local down = ui.mouseDown(ui.MouseButton.Left)

  if down and not speedoDrag then
    if mp.x >= x and mp.x <= x + w and mp.y >= y and mp.y <= y + h then
      speedoDrag = true
      speedoOff = vec2(mp.x - x, mp.y - y)
    end
  end
  if speedoDrag then
    if down then
      x, y = clampPos(mp.x - speedoOff.x, mp.y - speedoOff.y)
      cfg.speedoX, cfg.speedoY = x, y
    else
      speedoDrag = false
    end
  end

  local hovered = mp.x >= x and mp.x <= x + w and mp.y >= y and mp.y <= y + h
  if hovered and not speedoDrag then
    local wheel = 0
    pcall(function() wheel = ac.getUI().mouseWheel or 0 end)
    if wheel ~= 0 then
      local cx, cy = x + w * 0.5, y + h * 0.5
      scale = math.max(0.55, math.min(1.85, scale + wheel * 0.08))
      cfg.speedoScale = scale
      w = math.floor(SPEEDO_W * scale + 0.5)
      h = math.floor(SPEEDO_H * scale + 0.5)
      x, y = clampPos(cx - w * 0.5, cy - h * 0.5)
      cfg.speedoX, cfg.speedoY = x, y
    end
  end

  local mph = (cfg.speedoUnits == 'mph')
  local speed = math.floor((mph and (car.speedKmh or 0) * 0.621371 or (car.speedKmh or 0)) + 0.5)
  local rpm = math.floor(car.rpm or 0)
  local gear = car.gear or 0
  local gearText = (gear == 0) and 'N' or (gear == -1) and 'R' or tostring(gear)
  local limiter = car.rpmLimiter or car.rpmLimit or 8000
  if limiter <= 0 then limiter = 8000 end
  local lights = math.floor(clamp01(rpm / limiter) * 7 + 0.001)

  local white = rgbm(1, 1, 1, 1)
  local dim = rgbm(1, 1, 1, 0.45)

  ui.transparentWindow('ghostpro_speedo', vec2(x, y), vec2(w, h), function()
    ui.drawRectFilled(vec2(0, 0), vec2(w, h), panel(0.94), 14)
    ui.drawRect(vec2(0, 0), vec2(w, h), accent(0.22), 14, nil, 1)

    local arcR = 46 * scale
    local arcT = math.max(3.5, 5 * scale)
    local leftX, midY = 72 * scale, h * 0.55
    local rightX = w - 72 * scale
    drawArc(leftX, midY, arcR, arcT, accent(0.95))
    drawArc(rightX, midY, arcR, arcT, accent(0.95))

    ui.pushFont(ui.Font.Title)
    local gw = ui.measureText(gearText).x
    ui.setCursor(vec2(leftX - gw * 0.5, midY - 22 * scale))
    ui.textColored(gearText, white)
    ui.popFont()

    local cx = w * 0.5
    local dotR = math.max(3.2, 4.5 * scale)
    for i = 1, 7 do
      local on = lights >= i
      local hot = i >= 6
      local c
      if on then c = hot and rgbm(1, 0.35, 0.45, 1) or rgbm(0.95, 0.25, 0.35, 1)
      else c = rgbm(1, 1, 1, 0.12) end
      ui.drawCircleFilled(vec2(cx - 36 * scale + (i - 1) * 12 * scale, 16 * scale), dotR, c, 16)
    end

    ui.pushFont(ui.Font.Small)
    local rl = ui.measureText('RPM').x
    ui.setCursor(vec2(cx - rl * 0.5, 28 * scale))
    ui.textColored('RPM', dim)
    ui.popFont()

    ui.pushFont(ui.Font.Title)
    local rs = tostring(rpm)
    local rw = ui.measureText(rs).x
    ui.setCursor(vec2(cx - rw * 0.5, 44 * scale))
    ui.textColored(rs, white)
    ui.popFont()

    ui.pushFont(ui.Font.Small)
    ui.setCursor(vec2(cx - 42 * scale, 92 * scale))
    ui.textColored('ABS', assistFlag(car, 'absInAction') and white or rgbm(1, 1, 1, 0.28))
    ui.sameLine(0, 18 * scale)
    ui.textColored('TC', assistFlag(car, 'tractionControlInAction') and white or rgbm(1, 1, 1, 0.28))
    ui.popFont()

    ui.pushFont(ui.Font.Small)
    local unit = mph and 'MPH' or 'KMH'
    local uw = ui.measureText(unit).x
    ui.setCursor(vec2(rightX - uw * 0.5, midY - 38 * scale))
    ui.textColored(unit, dim)
    ui.popFont()

    ui.pushFont(ui.Font.Title)
    local ss = tostring(speed)
    local sw = ui.measureText(ss).x
    ui.setCursor(vec2(rightX - sw * 0.5, midY - 14 * scale))
    ui.textColored(ss, white)
    ui.popFont()

    if hovered then
      ui.drawTriangleFilled(
        vec2(w - 4, h - 18), vec2(w - 4, h - 4), vec2(w - 18, h - 4),
        rgbm(1, 1, 1, 0.22))
    end
  end)
end

-- ===== 9. Lock button + menu ==============================================
local BTN, GAP, MARGIN_LEFT = 38, 10, 20
local MENU_W, MENU_H, GLOW_PAD = 236, 42, 10
local LOCK_AUTOHIDE, LOCK_LINGER = true, 0.9
local reveal, linger = LOCK_AUTOHIDE and 0 or 1, 0
local hoverNow = false

local TABS = { 'Ghost', 'Paint', 'Utility', 'Time', 'Weather', 'Skins', 'Settings' }
local tabIndex = 1

local function drawLockIcon(c, size, colour)
  local w, h = size * 0.62, size * 0.46
  local top = c.y - size * 0.02
  ui.drawCircle(vec2(c.x, top), w * 0.30, colour, 20, 2)
  ui.drawRectFilled(vec2(c.x - w / 2, top), vec2(c.x + w / 2, top + h), colour, 2)
end

local function drawGhostIcon(pos, size, colour, dark)
  local r = size * 0.36
  local cx, top = pos.x + size / 2, pos.y + size * 0.10
  ui.drawCircleFilled(vec2(cx, top + r), r, colour, 20)
  ui.drawRectFilled(vec2(cx - r, top + r), vec2(cx + r, top + size * 0.72), colour)
  local bw = (r * 2) / 3
  for k = 0, 2 do
    ui.drawCircleFilled(vec2(cx - r + bw * (k + 0.5), top + size * 0.72), bw / 2, colour, 10)
  end
  ui.drawCircleFilled(vec2(cx - r * 0.38, top + r * 0.95), size * 0.06, dark, 8)
  ui.drawCircleFilled(vec2(cx + r * 0.38, top + r * 0.95), size * 0.06, dark, 8)
end

local function blurRect(a, b, rounding)
  if ui.beginBlurredBackground then
    ui.beginBlurredBackground()
    ui.drawRectFilled(a, b, rgbm(1, 1, 1, 1), rounding)
    ui.endBlurredBackground()
  end
end

local function blurCircle(c, r)
  if ui.beginBlurredBackground then
    ui.beginBlurredBackground()
    ui.drawCircleFilled(c, r, rgbm(1, 1, 1, 1), 32)
    ui.endBlurredBackground()
  end
end

local function roundBtn(id, cx, cy, kind, enabled, a)
  ui.setCursor(vec2(cx - 13, cy - 13))
  local clicked = ui.invisibleButton(id, vec2(26, 26))
  local hover, down = ui.itemHovered(), ui.itemActive()
  local radius = down and 11 or (hover and 13.5 or 13)
  local alpha = enabled and 1 or 0.3
  ui.drawCircleFilled(vec2(cx, cy), radius, rgbm(1, 1, 1, (hover and 0.16 or 0.09) * a * alpha), 24)
  ui.drawCircle(vec2(cx, cy), radius, rgbm(1, 1, 1, 0.35 * a * alpha), 24, 1.2)
  local line = rgbm(1, 1, 1, 0.9 * a * alpha)
  ui.drawLine(vec2(cx - 5, cy), vec2(cx + 5, cy), line, 1.8)
  if kind == 'plus' then ui.drawLine(vec2(cx, cy - 5), vec2(cx, cy + 5), line, 1.8) end
  return clicked and enabled
end

local function pillBtn(id, x0, y0, w, label, isAccent, a)
  ui.setCursor(vec2(x0, y0))
  local clicked = ui.invisibleButton(id, vec2(w, 26))
  local hover, down = ui.itemHovered(), ui.itemActive()
  local inset = down and 2 or 0
  local pa = vec2(x0 + inset, y0 + inset)
  local pb = vec2(x0 + w - inset, y0 + 26 - inset)
  local fill = isAccent and accent((hover and 0.32 or 0.2) * a)
    or rgbm(1, 1, 1, (hover and 0.14 or 0.08) * a)
  ui.drawRectFilled(pa, pb, fill, 13)
  ui.drawRect(pa, pb, isAccent and accent(0.9 * a) or rgbm(1, 1, 1, 0.25 * a), 13, 1.2)
  ui.drawTextClipped(label, pa, pb, isAccent and accent(a) or rgbm(0.92, 0.94, 0.95, a), vec2(0.5, 0.5))
  return clicked
end

-- ===== 12. Physics helpers ================================================
-- Every one of these exists in CSP's binary but is NOT in the public Lua SDK,
-- so each is probed before use. Calling a missing function would abort the
-- frame, and an aborted frame inside drawUI takes the whole HUD with it.
local function physicsFn(name)
  local fn = physics and physics[name]
  return type(fn) == 'function' and fn or nil
end

local hasDisableCollisions = physicsFn('disableCarCollisions') ~= nil

local boostTimer, repairTimer = 0, 0
local rewindTrail, rewinding = {}, false

local function currentCar()
  local ok, car = pcall(ac.getCar, 0)
  return ok and car or nil
end

local function doBoost(seconds)
  local setGas = physicsFn('setCarGas') or physicsFn('overrideCarState')
  if not setGas then
    ac.setMessage('GhostPro', 'Boost is not available in this CSP build')
    return
  end
  boostTimer = seconds or 3
end

local function doRepair()
  local fix = physicsFn('setCarDamage') or physicsFn('resetCarDamage')
  if not fix then
    ac.setMessage('GhostPro', 'Repair is not available in this CSP build')
    return
  end
  pcall(function() fix(0, 0) end)
  repairTimer = 0.5
  ac.setMessage('GhostPro', 'Car repaired')
end

local function recordRewind()
  local car = currentCar()
  if not car then return end
  rewindTrail[#rewindTrail + 1] = { pos = car.position + vec3(0, 0.5, 0), vel = car.velocity or vec3(0, 0, 0) }
  -- Bounded: an unbounded trail would grow all session and be walked on every
  -- frame during rewind.
  if #rewindTrail > 600 then table.remove(rewindTrail, 1) end
end

local function doRewind(seconds)
  local car = currentCar()
  if not car then return end
  local setPos = physicsFn('setCarPosition')
  local setVel = physicsFn('setCarVelocity')
  if not setPos then
    ac.setMessage('GhostPro', 'Rewind is not available in this CSP build')
    return
  end
  if #rewindTrail == 0 then
    ac.setMessage('GhostPro', 'No trajectory recorded yet')
    return
  end
  rewinding = true
  local steps = math.floor((seconds or 3) * 20)
  for _ = 1, steps do
    local entry = table.remove(rewindTrail)
    if not entry then break end
    -- Ghost during rewind: teleporting into someone at speed is how you cause
    -- the incident this feature exists to avoid.
    if not passive then setPassive(true, true) end
    pcall(function() setPos(0, entry.pos, car.look) end)
    if setVel then pcall(function() setVel(0, entry.vel) end) end
  end
  rewinding = false
  ac.setMessage('GhostPro', 'Rewound')
end

local function teleport(distance)
  local car = currentCar()
  local setPos = physicsFn('setCarPosition')
  local setVel = physicsFn('setCarVelocity')
  if not car or not setPos then
    ac.setMessage('GhostPro', 'Teleport is not available in this CSP build')
    return
  end
  local look = car.look
  local target = car.position + vec3(0, 0.1, 0) - look * (distance or 8)
  if not passive then setPassive(true, true) end
  pcall(function() setVel(0, vec3(0, 0, 0)) end)
  pcall(function() setPos(0, target, look) end)
end

-- ===== 13. Personal time + weather ========================================
-- Weather names come from the server, generated from the WeatherFxType enum of
-- the AssettoServer build actually running. Two reasons this is a token rather
-- than a hardcoded list:
--   * WeatherFxType's numeric values shift between versions, so indices would
--     mean different weather on client and server
--   * a name the server cannot Enum.TryParse would be silently dropped there,
--     making the button look broken
-- The server substitutes {{WEATHER_NAMES}}; if it does not, nothing is offered.
local WEATHER_TYPES = {{WEATHER_NAMES}}

local SUPPORTED_WEATHER = {}
for _, n in ipairs(WEATHER_TYPES) do SUPPORTED_WEATHER[n] = true end

local function setPersonalTime(seconds)
  if not PERSONAL_TIME then
    ac.setMessage('GhostPro', 'Personal time is disabled on this server')
    return
  end
  pcall(function() timeEvent({ mode = 'set', seconds = tostring(math.floor(seconds)) }, false, 255) end)
end

local function syncPersonalTime()
  pcall(function() timeEvent({ mode = 'sync', seconds = '0' }, false, 255) end)
end

local function setPersonalWeather(index)
  if not PERSONAL_TIME then
    ac.setMessage('GhostPro', 'Personal weather is disabled on this server')
    return
  end
  local name = WEATHER_TYPES[index]
  if not name then return end
  pcall(function() weatherEvent({ mode = 'set', type = name }, false, 255) end)
  ac.setMessage('GhostPro', 'Personal weather: ' .. name)
end

local function weatherNameToIndex(name)
  for i, n in ipairs(WEATHER_TYPES) do if n == name then return i end end
  return nil
end

local function syncPersonalWeather()
  pcall(function() weatherEvent({ mode = 'sync', type = '0' }, false, 255) end)
end

-- ===== 14. Perf mode ======================================================
-- Hides distant cars to cut draw calls. Colliders stay, so hiding is a
-- rendering decision only and never affects the race.
local perfMode, perfTick, hiddenCars = false, 0, {}

local function perfApply()
  if not perfMode then
    for index in pairs(hiddenCars) do
      pcall(function() ac.findNodes('carRoot:' .. index):setVisible(true) end)
    end
    hiddenCars = {}
    return
  end
  local me = currentCar()
  if not me then return end
  local sim = ac.getSim()
  local RADIUS = 260
  for index = 1, (sim.carsCount or 1) - 1 do
    local car = ac.getCar(index)
    if car then
      local d = (car.position - me.position):length()
      local want = d > RADIUS
      if want ~= (hiddenCars[index] or false) then
        pcall(function() ac.findNodes('carRoot:' .. index):setVisible(not want) end)
        hiddenCars[index] = want
      end
    end
  end
end

local function togglePerf()
  perfMode = not perfMode
  perfTick = 0.5
  ac.setMessage('GhostPro', perfMode and 'Perf mode: hiding distant cars' or 'Perf mode off')
end

-- ===== Paint ===============================================================
-- Car Customizer's backend is bound to car 0 (`ac.findNodes('carRoot:0')`), so
-- only our own car can be delegated to it. Remote cars use the direct material
-- write below. Do not merge these two paths.
local BODY_MATERIALS = {
  'ext_bodypaint', 'carpaint', 'body', 'material #14031', 'ext_carpaint',
  'csr2_carpaint', 'ext_body', 'carpaint_ext', 'paint',
  'vehicle_generic_smallspecmap__paint_1_', 'extbody',
  'material #6831', 'material #46242', 'material #9031', 'material #11231',
}
local RIM_MATERIALS = {}

local function paintRemote(index, part, colour, force)
  local okRoot, root = pcall(ac.findNodes, 'carRoot:' .. index)
  if not okRoot or not root or root:empty() then return 0 end

  local wanted
  if part == 'body' then wanted = BODY_MATERIALS else wanted = RIM_MATERIALS end
  if #wanted == 0 then return 0 end

  local meshes = root:findMeshes('?')
  local target = ac.emptySceneReference()
  local ref = ac.emptySceneReference()
  for i = 1, #meshes do
    meshes:at(i, ref)
    local name = string.lower(tostring(ref:materialName()))
    for _, w in ipairs(wanted) do
      if name == w then target:append(ref); break end
    end
  end
  if #target == 0 then return 0 end
  -- Without this, two cars sharing a material name would share the write.
  target:ensureUniqueMaterials()
  target:setMaterialTexture('txDiffuse', rgbm(colour.r, colour.g, colour.b, 1))
  pcall(ac.refreshCarColor, index)
  return #target
end

local function applyOwnPaint(part)
  local r, g, b = currentRgb(part)
  if tooDark({ r = r, g = g, b = b }) then
    ac.setMessage('GhostPro', PART_LABEL[part] .. ': colour too dark, choose another')
    return
  end
  ownPaint[part] = { r = r, g = g, b = b }
  cfg[part .. 'On'] = true
  cfg[part .. 'H'], cfg[part .. 'S'], cfg[part .. 'V'] = hsv[part].h, hsv[part].s, hsv[part].v
  pcall(paintRemote, 0, part, ownPaint[part], false)
  -- The server is the relay, so the paint only reaches other drivers by going
  -- through it. Sending straight to peers would bypass the brightness floor.
  sendPaint(part, ownPaint[part], false)
end

local function resetOwnPaint(part)
  ownPaint[part] = nil
  cfg[part .. 'On'] = false
  sendPaint(part, nil, true)
  -- Restore by skin rather than a stored filename: a texture written earlier in
  -- the session has no reliable inverse, but the original skin always does.
  pcall(function() ac.findNodes('carRoot:0'):resetSkin() end)
end

local function reconcilePaint()
  for index, parts in pairs(remotePaint) do
    appliedPaint[index] = appliedPaint[index] or {}
    for _, part in ipairs(PARTS) do
      local colour = parts[part]
      if colour ~= nil then
        local key = colour and string.format('%.3f,%.3f,%.3f', colour.r, colour.g, colour.b) or 'reset'
        if appliedPaint[index][part] ~= key then
          local ok, count
          if colour then
            ok, count = pcall(paintRemote, index, part, colour, false)
          else
            ok, count = pcall(function()
              local node = ac.findNodes('carRoot:' .. index)
              node:resetSkin()
            end)
          end
          if ok and (colour == nil or (count and count > 0)) then
            appliedPaint[index][part] = key
          else
            -- Do not cache a failed write, or it is never retried.
            ac.log('[GhostPro] remote paint failed on car ' .. index .. ': ' .. tostring(count))
          end
        end
      end
    end
  end
end

-- ===== Ghost toggle =======================================================
local function setPassive(value, silent)
  passive = value == true
  if passive then ghostTimer = math.max(ghostTimer, 3) end
  if not silent then
    -- Ask, then wait for the grant. Assuming success would make an admin
    -- denial look like a broken toggle.
    askServer(passive and 'ask' or 'revoke', ALLOW_BOTS)
    ac.setMessage('Ghost Mode', passive and 'Requesting…' or 'Revoked')
  end
  if not passive and hasDisableCollisions then
    pcall(function() physics.disableCarCollisions(0, false, true) end)
  end
end

local function shouldPassThrough(index)
  -- Bit 0 is never granted by the server, so we cannot pass through ourselves
  -- through this path.
  if (grantMask & (1 << index)) ~= 0 then return true end
  if not serverSeen then
    -- No server: fall back to HardBrain's client-to-client announcement so a
    -- stock acServer still works.
    local last = remoteSeen[index]
    return last ~= nil and (simTime() - last) < STATE_TTL
  end
  return false
end

local function applyCollisions()
  local sim = ac.getSim()
  if not sim then return end
  for index = 1, (sim.carsCount or 1) - 1 do
    local car = ac.getCar(index)
    local counter = car and car.resetCounter or 0
    local respawned = lastReset[index] ~= counter
    lastReset[index] = counter

    local want = serverPassive and shouldPassThrough(index)
    -- Re-apply whenever the desired state is `true`, even if unchanged: a
    -- respawn or a CSP physics reload restores collisions silently, without
    -- changing anything we can observe. Re-asserting is cheap; discovering a
    -- ghost we are driving through is not.
    if hasDisableCollisions and (respawned or collisionApplied[index] ~= want or want) then
      pcall(function() physics.disableCarCollisions(index, want, true) end)
      collisionApplied[index] = want
    end
  end
end

-- ===== Skins ===============================================================
local skinNames = {}
local skinIndex = 0

local function loadSkins()
  skinNames = {}
  local okDir, dir = pcall(function()
    return ac.getFolder(ac.FolderID.ContentCars) .. '/' .. ac.getCarID(0)
  end)
  if not okDir then return end
  pcall(function()
    io.scanDir(dir .. '/skins', '*', function(name)
      skinNames[#skinNames + 1] = name
    end)
    table.sort(skinNames)
  end)
end

local function applySkin(name)
  local car = currentCar()
  if not car then return end
  local dir = ac.getFolder(ac.FolderID.ContentCars) .. '/' .. ac.getCarID(0) .. '/skins/' .. name
  local node = ac.findNodes('carRoot:0')
  -- resetSkin() first: a base layer only partly covered by the chosen skin
  -- lets the default white show through, which looks like a broken skin.
  pcall(function() node:resetSkin() end)
  if not pcall(function() node:applySkin(dir) end) then
    -- Older CSP builds have no folder-based applySkin; fall back to a map.
    pcall(function()
      local files = io.scanDir(dir, '*')
      if not files or #files == 0 then return end
      local map = {}
      for i = 1, #files do
        local f = files[i]
        local lower = tostring(f):lower()
        if lower ~= 'preview.jpg' and lower ~= 'preview.png'
           and not lower:match('%.json$') and not lower:match('%.ini$') then
          map[f] = dir .. '/' .. f
        end
      end
      if next(map) then node:applySkin(map) end
    end)
  end
  cfg.lastSkin = name
  ac.setMessage('GhostPro', 'Skin: ' .. name)
end

local function nextSkin(step)
  if #skinNames == 0 then loadSkins() end
  if #skinNames == 0 then
    ac.setMessage('GhostPro', 'No skins found for this car')
    return
  end
  skinIndex = (skinIndex + (step or 1) - 1) % #skinNames + 1
  applySkin(skinNames[skinIndex])
end

-- ===== 10. Colour panel ===================================================
local COLOUR_W, COLOUR_H, PAD = 250, 244, 12
local shownH, shownS, shownV = 0, 0.85, 0.85
local tabX, applyPulse, idleT = 0, 0, 0

local function drawColourPanel()
  if colourAnim <= 0.01 and not colourOpen then return end
  local tt = MOTION[motion]
  local win = ui.windowSize()
  local a = math.max(0, math.min(1, colourAnim))
  local pos = motion == 'slide'
    and vec2(MARGIN_LEFT - (1 - a) * 34, win.y / 2 + 40)
    or vec2(MARGIN_LEFT, win.y / 2 + 40 + (1 - colourAnim) * math.max(tt.slideY, 12))

  ui.transparentWindow('ghostpro_colour', pos, vec2(COLOUR_W, COLOUR_H), true, true, function()
    local p = ui.getCursor()
    local mouse = ui.mouseLocalPos()
    local inside = mouse.x >= p.x and mouse.x <= p.x + COLOUR_W
      and mouse.y >= p.y and mouse.y <= p.y + COLOUR_H
    if inside then idleT = 0
    elseif colourOpen then
      idleT = idleT + 0.016
      if idleT >= 5 then colourOpen = false end
    end

    local pw = COLOUR_W - PAD * 2
    local x0 = p.x + PAD
    local st = hsv[activePart]
    local vMin = serverMinBrightness > 0 and math.min(1, serverMinBrightness + 0.02) or 0

    blurRect(p, vec2(p.x + COLOUR_W, p.y + COLOUR_H), math.max(4, 16 * tt.round))
    ui.drawRectFilled(p, vec2(p.x + COLOUR_W, p.y + COLOUR_H), panel(0.80 * a), math.max(4, 16 * tt.round))
    ui.drawRect(p, vec2(p.x + COLOUR_W, p.y + COLOUR_H), rgbm(1, 1, 1, 0.14 * a), math.max(4, 16 * tt.round), 1)

    local tabW, tabH, tabY = 90, 28, p.y + 10
    ui.drawRectFilled(vec2(x0, tabY), vec2(x0 + tabW * 2 + 6, tabY + tabH), rgbm(1, 1, 1, 0.07 * a), 14)
    local ix = x0 + tabX * (tabW + 6)
    ui.drawRectFilled(vec2(ix, tabY), vec2(ix + tabW, tabY + tabH), accent(0.22 * a), 14)
    ui.drawRect(vec2(ix, tabY), vec2(ix + tabW, tabY + tabH), accent(0.9 * a), 14, 1.2)
    for k, part in ipairs(PARTS) do
      local tx = x0 + (k - 1) * (tabW + 6)
      ui.setCursor(vec2(tx, tabY))
      if ui.invisibleButton('gp_tab_' .. part, vec2(tabW, tabH)) then activePart = part end
      local hover = ui.itemHovered()
      local col = activePart == part and accent(a)
        or rgbm(0.9, 0.93, 0.94, (hover and 0.95 or 0.65) * a)
      ui.drawTextClipped(PART_LABEL[part], vec2(tx, tabY), vec2(tx + tabW, tabY + tabH), col, vec2(0.5, 0.5))
    end

    local cx0 = p.x + COLOUR_W - PAD - 24
    ui.setCursor(vec2(cx0, tabY + 2))
    if ui.invisibleButton('gp_colour_close', vec2(24, 24)) then colourOpen = false end
    local hc = ui.itemHovered()
    local cc = vec2(cx0 + 12, tabY + 14)
    local xc = rgbm(1, 1, 1, (hc and 0.9 or 0.45) * a)
    ui.drawLine(vec2(cc.x - 5, cc.y - 5), vec2(cc.x + 5, cc.y + 5), xc, 1.6)
    ui.drawLine(vec2(cc.x - 5, cc.y + 5), vec2(cc.x + 5, cc.y - 5), xc, 1.6)

    local grow = applyPulse * 4
    local m1 = vec2(x0 - grow, p.y + 50 - grow)
    local m2 = vec2(x0 + pw + grow, p.y + 84 + grow)
    ui.drawRectFilled(m1, m2, hsvRgbm(shownH, shownS, shownV, a), 10)
    ui.drawRect(m1, m2, rgbm(1, 1, 1, (0.25 + applyPulse * 0.5) * a), 10, 1.2)

    local hy0, seg = p.y + 94, 36
    local segW = pw / seg
    for i = 0, seg - 1 do
      local c1 = hsvRgbm(i * 360 / seg, 1, 1, a)
      local c2 = hsvRgbm((i + 1) * 360 / seg, 1, 1, a)
      ui.drawRectFilledMultiColor(vec2(x0 + i * segW, hy0),
        vec2(x0 + (i + 1) * segW + 0.5, hy0 + 20), c1, c2, c2, c1)
    end
    ui.drawRect(vec2(x0, hy0), vec2(x0 + pw, hy0 + 20), rgbm(1, 1, 1, 0.18 * a), 0, 1)
    ui.setCursor(vec2(x0, hy0))
    ui.invisibleButton('gp_hue', vec2(pw, 20))
    if ui.itemHovered() and ui.mouseWheel then
      local wheel = ui.mouseWheel()
      if wheel ~= 0 then
        st.h = (st.h + wheel * 10) % 360
        if st.s < 0.3 then st.s = 0.85 end
        if st.v < 0.1 then st.v = 0.6 end
      end
    end
    if ui.itemActive() then
      local mp = ui.mouseLocalPos()
      st.h = clamp01((mp.x - x0) / pw) * 360
      if st.s < 0.3 then st.s = 0.85 end
      if st.v < 0.1 then st.v = 0.6 end
    end
    local hx = x0 + (shownH % 360) / 360 * pw
    ui.drawCircleFilled(vec2(hx, hy0 + 10), 8, hsvRgbm(shownH, 1, 1, a), 20)
    ui.drawCircle(vec2(hx, hy0 + 10), 8, rgbm(1, 1, 1, a), 20, 2)

    local sy, count, size = p.y + 138, #SWATCHES, 18
    local gap = (pw - count * size) / (count - 1)
    local selBlack = st.v < 0.08
    for k, sw in ipairs(SWATCHES) do
      local cx = x0 + size / 2 + (k - 1) * (size + gap)
      local isBlack = sw[3] == 0
      ui.setCursor(vec2(cx - size / 2, sy - size / 2))
      if ui.invisibleButton('gp_sw_' .. k, vec2(size, size)) then
        st.h, st.s, st.v = sw[1], sw[2], math.max(sw[3], vMin)
      end
      local hover = ui.itemHovered()
      -- Staggered overshoot so the row cascades instead of popping as one block.
      local pop = 1
      if motion == 'spring' then
        local tt2 = clamp01((colourAnim - (k - 1) * 0.05) / (1 - (k - 1) * 0.05))
        local u = tt2 - 1
        pop = 1 + 2.70158 * u * u * u + 1.70158 * u * u
      end
      local r = (size / 2) * (hover and 1.25 or 1) * math.max(0, pop)
      ui.drawCircleFilled(vec2(cx, sy), r, hsvRgbm(sw[1], sw[2], sw[3], a), 20)
      if isBlack then
        ui.drawCircle(vec2(cx, sy), r, rgbm(1, 1, 1, 0.55 * a), 20, 1)
        local tp = (ui.time() * 0.5) % 1
        ui.drawCircle(vec2(cx, sy), r + 2 + tp * 7, rgbm(1, 1, 1, (1 - tp) * 0.5 * a), 24, 1)
      end
      local selected
      if isBlack then selected = selBlack
      elseif sw[2] == 0 then selected = (not selBlack) and st.s < 0.2
      else
        local dh = math.abs(((st.h - sw[1] + 180) % 360) - 180)
        selected = (not selBlack) and st.s >= 0.2 and dh < 8
      end
      if selected then ui.drawCircle(vec2(cx, sy), size / 2 + 3.5, rgbm(1, 1, 1, a), 24, 1.8) end
    end

    local by = p.y + 176
    local bx0, bx1 = x0 + 34, x0 + pw - 34
    ui.drawRectFilledMultiColor(vec2(bx0, by - 6), vec2(bx1, by + 6),
      hsvRgbm(shownH, shownS, vMin, a), hsvRgbm(shownH, shownS, 1, a),
      hsvRgbm(shownH, shownS, 1, a), hsvRgbm(shownH, shownS, vMin, a))
    ui.drawRect(vec2(bx0, by - 6), vec2(bx1, by + 6), rgbm(1, 1, 1, 0.2 * a), 0, 1)
    ui.setCursor(vec2(bx0 - 8, by - 12))
    ui.invisibleButton('gp_value', vec2(bx1 - bx0 + 16, 24))
    if ui.itemActive() then
      local mp = ui.mouseLocalPos()
      st.v = vMin + clamp01((mp.x - bx0) / (bx1 - bx0)) * (1 - vMin)
    end
    if ui.itemHovered() and ui.mouseWheel then
      local wheel = ui.mouseWheel()
      if wheel ~= 0 then st.v = math.max(vMin, math.min(1, st.v + wheel * 0.05)) end
    end
    local fv = clamp01((shownV - vMin) / math.max(1e-6, 1 - vMin))
    local vx = bx0 + fv * (bx1 - bx0)
    ui.drawCircleFilled(vec2(vx, by), 8, hsvRgbm(shownH, shownS, shownV, a), 20)
    ui.drawCircle(vec2(vx, by), 8, rgbm(1, 1, 1, a), 20, 2)
    if roundBtn('gp_v_minus', x0 + 13, by, 'minus', st.v > vMin + 0.001, a) then
      st.v = math.max(vMin, st.v - 0.1)
    end
    if roundBtn('gp_v_plus', x0 + pw - 13, by, 'plus', st.v < 0.999, a) then
      st.v = math.min(1, st.v + 0.1)
    end

    local ay, bw = p.y + 204, (pw - 8) / 2
    if pillBtn('gp_apply', x0, ay, bw, 'Apply', true, a) then
      applyOwnPaint(activePart)
      applyPulse = 1
    end
    if pillBtn('gp_reset', x0 + bw + 8, ay, bw, 'Reset', false, a) then
      resetOwnPaint(activePart)
    end
  end)
end

-- ===== Menu content ========================================================
local function menuRow(id, x, y, w, label, isAccent, enabled)
  if not enabled then
    ui.setCursor(vec2(x, y))
    ui.invisibleButton(id, vec2(w, 26))
    ui.drawRectFilled(vec2(x, y), vec2(x + w, y + 26), rgbm(1, 1, 1, 0.04), 13)
    ui.drawTextClipped(label, vec2(x, y), vec2(x + w, y + 26), rgbm(0.6, 0.62, 0.65, 0.7), vec2(0.5, 0.5))
    return false
  end
  return pillBtn(id, x, y, w, label, isAccent, 1)
end

-- Rows a tab needs. The panel height follows this, so a tab with many weather
-- entries gets a taller popout instead of having its last rows clipped off.
local function weatherEntryCount()
  local count = 0
  for _, name in ipairs(WEATHER_TYPES) do
    if SUPPORTED_WEATHER[name] then count = count + 1 end
  end
  return count
end

local function tabRowCount()
  local tab = TABS[tabIndex]
  local n
  if tab == 'Weather' then
    n = PERSONAL_TIME and weatherEntryCount() or 1
  elseif tab == 'Utility' then
    n = 6
  elseif tab == 'Settings' then
    n = 6
  elseif tab == 'Ghost' then
    n = 3
  elseif tab == 'Time' then
    n = PERSONAL_TIME and 4 or 1
  elseif tab == 'Paint' then
    n = 3
  else
    n = 3
  end
  return math.max(1, math.ceil(n / 3))
end

local function drawMenuBody(x, y, w, h, alpha)
  -- Tab strip
  local tw = w / #TABS
  for i, name in ipairs(TABS) do
    local tx = x + (i - 1) * tw
    local active = (i == tabIndex)
    ui.setCursor(vec2(tx, y))
    if ui.invisibleButton('gp_tab_' .. i, vec2(tw - 2, 22)) then tabIndex = i end
    local hover = ui.itemHovered()
    ui.drawRectFilled(vec2(tx + 2, y), vec2(tx + tw - 2, y + 22),
      active and accent(0.24 * alpha) or rgbm(1, 1, 1, (hover and 0.10 or 0.05) * alpha), 8)
    ui.drawTextClipped(name, vec2(tx + 2, y), vec2(tx + tw - 2, y + 22),
      active and accent(alpha) or rgbm(0.85, 0.87, 0.90, (hover and 0.95 or 0.6) * alpha), vec2(0.5, 0.5))
  end

  local by, colW = y + 30, (w - 12) / 3
  local function grid(index, action, accent1, enabled)
    local col = (index - 1) % 3
    local row = math.floor((index - 1) / 3)
    local bx = x + col * (colW + 6)
    local byy = by + row * 32
    if menuRow('gp_a' .. index, bx, byy, colW, action, accent1, enabled) then return true end
    return false
  end

  local tab = TABS[tabIndex]
  if tab == 'Ghost' then
    grid(1, serverPassive and 'Ghost: ON' or 'Ghost: OFF', true)
    grid(2, serverSeen and 'Server linked' or 'P2P fallback', false, false)
    grid(3, 'Revoke', false)
  elseif tab == 'Paint' then
    grid(1, 'Open picker', true, ALLOW_REMOTE_PAINT)
    grid(2, 'Body reset', false)
    grid(3, 'Rim reset', false)
  elseif tab == 'Utility' then
    grid(1, 'Boost', true)
    grid(2, 'Repair', false)
    grid(3, 'Rewind 3s', false)
    grid(4, 'Teleport 8m', false)
    grid(5, 'Teleport 30m', false)
    grid(6, perfMode and 'Perf: ON' or 'Perf: OFF', false)
  elseif tab == 'Time' then
    if not PERSONAL_TIME then
      grid(1, 'Disabled', false, false)
    else
      grid(1, '06:00', false)
      grid(2, '12:00', false)
      grid(3, '18:00', false)
      grid(4, 'Sync server', false)
    end
  elseif tab == 'Weather' then
    if not PERSONAL_TIME then
      grid(1, 'Disabled', false, false)
    else
      -- Only show weather the current server build knows. A name the server
      -- cannot parse is dropped, not sent and silently ignored.
      for i, name in ipairs(WEATHER_TYPES) do
        if SUPPORTED_WEATHER[name] then
          grid(i, name, i == 1)
        end
      end
    end
  elseif tab == 'Skins' then
    grid(1, 'Next skin', true)
    grid(2, 'Prev skin', false)
    grid(3, 'Reset skin', false)
    if #skinNames > 0 then
      ui.setCursor(vec2(x, by + 64))
      ui.drawTextClipped('Current: ' .. tostring(cfg.lastSkin or 'default'),
        vec2(x, by + 64), vec2(x + w, by + 84), rgbm(1, 1, 1, 0.55 * alpha))
    end
  elseif tab == 'Settings' then
    grid(1, 'Theme: ' .. THEMES[themeIdx].name, true)
    grid(2, APPEARANCES[appearanceIdx], false)
    grid(3, motion == 'spring' and 'Motion: spring' or 'Motion: slide', false)
    grid(4, cfg.speedoVisible and 'Speedo: on' or 'Speedo: off', false)
    grid(5, 'Units: ' .. tostring(cfg.speedoUnits):upper(), false)
    grid(6, 'Hide UI', false)
  end
end

-- A menu click during drawUI only records intent. `script.update` executes it,
-- so a click never mutates state in the middle of laying out the frame.
local lastClick = {}
local function drawLockAndMenu()
  local tt = MOTION[motion]
  local win = ui.windowSize()
  local expanded = menuAnim > 0.01 or menuOpen
  local width = expanded and (GLOW_PAD + BTN + GAP + MENU_W + 8) or (BTN + GLOW_PAD * 2)
  local height = MENU_H + 20

  ui.transparentWindow('ghostpro_lock',
    vec2(MARGIN_LEFT - GLOW_PAD, win.y / 2 - height / 2),
    vec2(width, height), true, true, function()
      local p = ui.getCursor()
      local cy = p.y + height / 2
      local btnC = vec2(p.x + GLOW_PAD + BTN / 2, cy)
      local mlp = ui.mouseLocalPos()
      hoverNow = mlp.x >= p.x and mlp.x <= p.x + width and mlp.y >= p.y and mlp.y <= p.y + height

      local pulse = 0.5 + 0.5 * math.sin(ui.time() * 3)
      local gr, gg, gb = cur.acc[1], cur.acc[2], cur.acc[3]
      if not serverPassive then gr, gg, gb = cur.muted[1] * 0.6, cur.muted[2] * 0.6, cur.muted[3] * 0.6 end
      local glow = serverPassive and (0.75 + 0.25 * pulse) or 0.55
      for g = 5, 1, -1 do
        ui.drawCircleFilled(btnC, BTN / 2 + g * 1.9 * (0.85 + 0.15 * pulse),
          rgbm(gr, gg, gb, 0.035 * glow * (6 - g)), 32)
      end
      if reveal > 0.5 then blurCircle(btnC, BTN / 2) end
      ui.drawCircleFilled(btnC, BTN / 2, panel(0.72 * reveal), 32)
      local lockColour = serverPassive and accent(reveal) or muted(reveal)
      ui.drawCircle(btnC, BTN / 2, lockColour, 32, 1.5)
      drawLockIcon(btnC, BTN * 0.5, lockColour)

      ui.setCursor(vec2(p.x + GLOW_PAD, cy - BTN / 2))
      local clicked = ui.invisibleButton('gp_lock', vec2(BTN, BTN))
      if ui.itemHovered() then
        ui.drawCircle(btnC, BTN / 2 + 2, rgbm(1, 1, 1, 0.35 * reveal), 32, 1.5)
      end
      if clicked then
        menuOpen = not menuOpen
        if not menuOpen then colourOpen = false end
      end

      local a = math.max(0, math.min(1, menuAnim))
      if a <= 0.02 then return end

      local scale = math.max(0.3, math.min(1.15, tt.scaleFrom + (1 - tt.scaleFrom) * menuAnim))
      local mx = p.x + GLOW_PAD + BTN + GAP - (1 - a) * tt.slide
      local mw, mh = MENU_W * scale, MENU_H * scale
      -- Height follows the active tab: 3 rows of buttons plus the tab strip and
      -- the ghost toggle, with room for the Skins status line below its buttons.
      local rows = math.max(tabRowCount(), 4)
      local contentH = 30 + rows * 32 + (TABS[tabIndex] == 'Skins' and 28 or 0)
      local expandedH = contentH * scale
      local mp = vec2(mx, cy - expandedH / 2)
      local mq = vec2(mx + mw, cy + expandedH / 2)
      local mr = math.max(4, expandedH / 2 * tt.round)

      blurRect(mp, mq, mr)
      ui.drawRectFilled(mp, mq, panel(0.90 * a), mr)
      ui.drawRect(mp, mq, rgbm(1, 1, 1, 0.14 * a), mr, 1)
      if a <= 0.6 then return end
      local fade = (a - 0.6) / 0.4

      -- Ghost toggle row at the top
      local ip = vec2(mp.x + 12, cy - expandedH / 2 + 8)
      local iq = vec2(mq.x - 12, ip.y + 30)
      ui.setCursor(ip)
      local clickGhost = ui.invisibleButton('gp_ghost', vec2(iq.x - ip.x, 30))
      local hoverGhost = ui.itemHovered()
      if clickGhost then lastClick = { tab = 'Ghost', index = 1 } end
      ui.drawRectFilled(ip, iq, rgbm(1, 1, 1, (hoverGhost and 0.11 or 0.07) * fade), 15)
      ui.drawRectFilled(ip, iq, accent(0.16 * fade * knob), 15)

      local textCol = rgbm(
        0.91 + (cur.acc[1] + (1 - cur.acc[1]) * 0.35 - 0.91) * knob,
        0.93 + (cur.acc[2] + (1 - cur.acc[2]) * 0.35 - 0.93) * knob,
        0.94 + (cur.acc[3] + (1 - cur.acc[3]) * 0.35 - 0.94) * knob, fade)
      drawGhostIcon(vec2(ip.x + 6, ip.y + 6), 18, textCol, rgbm(0.05, 0.05, 0.08, textCol.mult))
      ui.setCursor(vec2(ip.x + 30, ip.y + 6))
      ui.textColored('Ghost mode', textCol)

      local sw, sh = 26, 15
      local sx, sy = iq.x - 8 - sw, cy - expandedH / 2 + 23 - sh / 2
      ui.drawRectFilled(vec2(sx, sy), vec2(sx + sw, sy + sh), rgbm(
        0.29 + (cur.acc[1] * 0.85 - 0.29) * knob,
        0.30 + (cur.acc[2] * 0.85 - 0.30) * knob,
        0.35 + (cur.acc[3] * 0.85 - 0.35) * knob, fade), 8)
      ui.drawCircleFilled(vec2(sx + 7.5 + knob * 11, sy + sh / 2), 5.5, rgbm(1, 1, 1, fade), 14)

      drawMenuBody(mp.x + 10, mp.y + 46, mw - 20, expandedH - 56, fade)

      -- Theme shortcut
      local thC = vec2(mq.x - 20, mp.y + 16)
      ui.setCursor(vec2(thC.x - 12, thC.y - 12))
      if ui.invisibleButton('gp_theme', vec2(24, 24)) then cycleTheme() end
      local hovTheme = ui.itemHovered()
      ui.drawCircle(thC, 12, rgbm(1, 1, 1, (hovTheme and 0.45 or 0.22) * fade), 24, 1.2)
      ui.drawCircleFilled(thC, 6, accent(fade), 18)
      ui.drawCircleFilled(thC, 2.5, panel(fade), 12)
    end)
end

-- ===== 15. Frame loop =====================================================
local announceT, applyT, reconcileT, repaintT = 0, 0, 0, 0
local reassertT, startupT, startupTries = 0, 0, 0
local startupDone = false
local loggedErr = false

local function announceOwn()
  -- Peer announcement is only needed when no server is present. The server
  -- relays state itself, so this is a no-op on a properly linked server.
  if serverSeen then return end
  pcall(function()
    reqEvent({ mode = 'ask', bots = ALLOW_BOTS }, true)
  end)
end

local function stepAnim(dt)
  local tt = MOTION[motion]
  menuAnim, menuVel = spring(menuAnim, menuVel, menuOpen and 1 or 0, dt, tt.k, tt.d)
  if not menuOpen then menuAnim, menuVel = settle(menuAnim, menuVel) end
  colourAnim, colourVel = spring(colourAnim, colourVel, colourOpen and 1 or 0, dt, tt.k, tt.d)
  if not colourOpen then colourAnim, colourVel = settle(colourAnim, colourVel) end
  knob = approach(knob, serverPassive and 1 or 0, dt, 14)
  applyPulse = math.max(0, applyPulse - dt * 3)
  stepTheme(dt)

  local st = hsv[activePart]
  shownH = approach(shownH, st.h, dt, 14)
  shownS = approach(shownS, st.s, dt, 14)
  shownV = approach(shownV, st.v, dt, 14)
  tabX = approach(tabX, activePart == 'rim' and 1 or 0, dt, 14)

  if hoverNow or menuOpen or colourOpen then linger = LOCK_LINGER end
  linger = math.max(0, linger - dt)
  local targetReveal = (LOCK_AUTOHIDE and linger <= 0) and 0 or 1
  reveal = approach(reveal, targetReveal, dt, targetReveal > reveal and 20 or 7)
end

function script.update(dt)
  if type(dt) ~= 'number' then dt = 0.02 end

  if pressed(keyGhost, ui.KeyIndex.G) then setPassive(not passive) end
  if pressed(keyMenu, ui.KeyIndex.M) then
    menuOpen = not menuOpen
    if not menuOpen then colourOpen = false end
  end
  if pressed(keyColour, ui.KeyIndex.C) then colourOpen = not colourOpen end
  if pressed(keyPerf, ui.KeyIndex.P) then togglePerf() end
  if pressed(keyHideUi, ui.KeyIndex.H) then uiHidden = not uiHidden end
  if pressed(keyTheme, ui.KeyIndex.T, true) then cycleTheme() end

  -- Menu actions. Collected during drawing, executed here so a click never
  -- mutates state mid-layout.
  if lastClick then
    local tab, index = lastClick.tab, lastClick.index
    lastClick = nil
    if tab == 'Ghost' then
      if index == 1 then setPassive(not passive)
      elseif index == 3 then setPassive(false) end
    elseif tab == 'Paint' then
      if index == 1 then colourOpen = true
      elseif index == 2 then resetOwnPaint('body')
      elseif index == 3 then resetOwnPaint('rim') end
    elseif tab == 'Utility' then
      if index == 1 then doBoost(3)
      elseif index == 2 then doRepair()
      elseif index == 3 then doRewind(3)
      elseif index == 4 then teleport(8)
      elseif index == 5 then teleport(30)
      elseif index == 6 then togglePerf() end
    elseif tab == 'Time' then
      if PERSONAL_TIME then
        if index == 1 then setPersonalTime(6 * 3600)
        elseif index == 2 then setPersonalTime(12 * 3600)
        elseif index == 3 then setPersonalTime(18 * 3600)
        elseif index == 4 then syncPersonalTime() end
      end
    elseif tab == 'Weather' then
      if PERSONAL_TIME and WEATHER_TYPES[index] then
        setPersonalWeather(index)
      end
    elseif tab == 'Skins' then
      if index == 1 then nextSkin(1)
      elseif index == 2 then nextSkin(-1)
      elseif index == 3 then
        cfg.lastSkin = ''
        pcall(function() ac.findNodes('carRoot:0'):resetSkin() end)
      end
    elseif tab == 'Settings' then
      if index == 1 then cycleTheme()
      elseif index == 2 then cycleAppearance()
      elseif index == 3 then
        motion = motion == 'spring' and 'slide' or 'spring'
        cfg.motion = motion
      elseif index == 4 then
        cfg.speedoVisible = not cfg.speedoVisible
      elseif index == 5 then
        cfg.speedoUnits = cfg.speedoUnits == 'kmh' and 'mph' or 'kmh'
      elseif index == 6 then uiHidden = not uiHidden end
    end
  end

  if ghostTimer > 0 then
    ghostTimer = ghostTimer - dt
    if ghostTimer <= 0 then setPassive(false) end
  end

  if boostTimer > 0 then boostTimer = boostTimer - dt end
  if repairTimer > 0 then repairTimer = repairTimer - dt end

  if not rewinding then recordRewind() end

  if perfMode then
    perfTick = perfTick - dt
    if perfTick <= 0 then perfTick = 0.5; pcall(perfApply) end
  end

  announceT = announceT + dt
  if announceT >= ANNOUNCE_INTERVAL then
    announceT = 0
    announceOwn()
    -- Re-assert on a slow cadence too: a respawn or a CSP physics reload can
    -- restore collisions without our view of the world changing.
    reassertT = reassertT + ANNOUNCE_INTERVAL
  end

  applyT = applyT + dt
  if applyT >= 0.5 then
    applyT = 0
    applyCollisions()
  end

  reconcileT = reconcileT + dt
  if reconcileT >= 2 then
    reconcileT = 0
    pcall(reconcilePaint)
  end

  -- Repaint after a car model reloads; the scene references we cached are gone.
  repaintT = repaintT + dt
  if repaintT >= 10 then
    repaintT = 0
    for index, parts in pairs(remotePaint) do
      for _, part in ipairs(PARTS) do
        local colour = parts[part]
        if colour then pcall(paintRemote, index, part, colour, true) end
      end
    end
  end

  -- Startup retries: the car model is not always loaded on the first frame, and
  -- a single attempt silently loses the saved colour.
  if not startupDone then
    startupT = startupT + dt
    if startupT >= 2 then
      startupT = 0
      startupTries = startupTries + 1
      local any, allOk = false, true
      for _, part in ipairs(PARTS) do
        if cfg[part .. 'On'] then
          any = true
          local st = hsv[part]
          local r, g, b = hsvToRgb(st.h, st.s, st.v)
          if not tooDark({ r = r, g = g, b = b }) then
            ownPaint[part] = { r = r, g = g, b = b }
            local ok, count = pcall(paintRemote, 0, part, ownPaint[part], true)
            if ok and count and count > 0 then sendPaint(part, ownPaint[part], false)
            else allOk = false end
          end
        end
      end
      if not any or allOk or startupTries >= 8 then startupDone = true end
    end
  end
end

function script.drawUI(dt)
  stepAnim(dt)

  local ok, err = pcall(function()
    if not uiHidden then
      drawLockAndMenu()
      drawColourPanel()
      drawSpeedo(dt)
    end
  end)
  if not ok and not loggedErr then
    loggedErr = true
    ac.log('[GhostPro] draw error: ' .. tostring(err))
  end
end

-- ===== start ==============================================================
pcall(loadSkins)

if not hasDisableCollisions then
  ac.log('[GhostPro] WARNING: physics.disableCarCollisions not present in this CSP build — ' ..
    'ghost mode will be cosmetic only. Requires CSP with car-collision API.')
end

ac.log('[GhostPro] loaded — server=' .. tostring(serverSeen) ..
  ', paintSync=' .. tostring(ALLOW_REMOTE_PAINT) ..
  ', personalTime=' .. tostring(PERSONAL_TIME))