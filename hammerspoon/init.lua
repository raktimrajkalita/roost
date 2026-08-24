-- ===========================================================================
--  Roost  —  Claude Code session monitor for the notch
--  Your sessions come home to roost when they finish.
--  Reads ~/.claude-notch/state/*.json (written by the Claude Code hooks) and
--  shows every session in an absolute-black notch panel with glass edges,
--  per-session mute, and live status. The webview shell loads ONCE; rows are
--  pushed in via JS (no reload) so hovering never flashes.
-- ===========================================================================
require("hs.ipc")

local HOME       = os.getenv("HOME")
local ROOT       = HOME .. "/.claude-notch"
local STATE_DIR  = ROOT .. "/state"
local MUTE_DIR   = ROOT .. "/mutes"
local MUTED_FLAG = ROOT .. "/muted"
hs.fs.mkdir(MUTE_DIR)

local M = {
  sessions = {}, webview = nil, ucc = nil, menubar = nil,
  visible = false, pinnedUntil = 0, panelFrame = nil, sig = "", lastInside = 0,
  nameByUuid = {},   -- iTerm2 session uuid -> cleaned tab name (your renames)
}

-- geometry (points)
local W, SH, BP = 380, 40, 44
local ROW_H, PAD_TOP, PAD_BOT = 56, 10, 12
local TRIG_W = 300

local STATUS_ORDER = { waiting = 1, thinking = 2, done = 3 }

local function screenGeo()
  local scr  = hs.screen.primaryScreen()
  local full = scr:fullFrame()
  local menuH = scr:frame().y - full.y
  return full, math.max(menuH, 24)
end

-- --- load state -----------------------------------------------------------
local function loadSessions()
  local out = {}
  if hs.fs.attributes(STATE_DIR, "mode") == "directory" then
    pcall(function()
      for file in hs.fs.dir(STATE_DIR) do
        if file:sub(-5) == ".json" then
          local f = io.open(STATE_DIR .. "/" .. file, "r")
          if f then
            local raw = f:read("a"); f:close()
            local ok, data = pcall(hs.json.decode, raw)
            if ok and type(data) == "table" then
              if not data.updated or (os.time() - data.updated) < 20 * 60 then  -- drop sessions dormant > 20 min
                data._key = file
                data._fid = file:gsub("%.json$", "")
                data.muted = hs.fs.attributes(MUTE_DIR .. "/" .. data._fid) ~= nil
                -- normalize stale/ambiguous statuses so nothing gets stuck
                local age = os.time() - (data.updated or os.time())
                local act = (data.last_action or ""):lower()
                if data.status == "waiting" and act:find("waiting for") then
                  data.status = "done"                 -- idle ping, not a real prompt
                elseif data.status == "thinking" and age > 300 then
                  data.status = "done"                 -- no activity for 5 min -> treat as idle
                end
                out[file] = data
              end
            end
          end
        end
      end
    end)
  end
  M.sessions = out
end

local function sortedSessions()
  local list = {}
  for _, d in pairs(M.sessions) do list[#list + 1] = d end
  table.sort(list, function(a, b)
    local oa, ob = STATUS_ORDER[a.status] or 9, STATUS_ORDER[b.status] or 9
    if oa ~= ob then return oa < ob end
    return (a.updated or 0) > (b.updated or 0)
  end)
  return list
end

-- --- focus / mute ---------------------------------------------------------
local function focusSession(d)
  local uuid = (d.iterm_session or ""):match(":(.+)$") or (d.iterm_session or "")
  if d.term_program == "iTerm.app" and uuid ~= "" then
    hs.osascript.applescript(([[
tell application "iTerm2"
  activate
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (unique id of s) is "%s" then
          select w
          select t
          select s
          return
        end if
      end repeat
    end repeat
  end repeat
end tell]]):format(uuid))
  else
    hs.application.launchOrFocus(d.term_program == "Apple_Terminal" and "Terminal" or "iTerm")
  end
end

local function toggleMute(key)
  local d = M.sessions[key]; if not d then return end
  local path = MUTE_DIR .. "/" .. d._fid
  if hs.fs.attributes(path) then os.remove(path)
  else local f = io.open(path, "w"); if f then f:close() end end
end

-- --- static webview shell (loaded ONCE) -----------------------------------
local SHELL = [[
<!doctype html><html><head><meta charset="utf-8"><style>
:root{
  --done:#3ad17f; --wait:#ffb020; --think:#7aa2ff;
  --txt:rgba(255,255,255,.96); --sub:rgba(255,255,255,.44);
  --menuH:37px; --panelH:120px; --sh:40px; --w:380px;
}
*{margin:0;padding:0;box-sizing:border-box;-webkit-user-select:none;user-select:none}
html,body{background:transparent;overflow:hidden;font-family:-apple-system,"SF Pro Text",system-ui,sans-serif}
.panel{
  position:absolute; left:var(--sh); top:0; width:var(--w); height:var(--panelH);
  background:#000; border-radius:0 0 28px 28px;
  border:1px solid rgba(255,255,255,.07); border-top:none;
  box-shadow: inset 0 1px 0 rgba(255,255,255,.06), 0 28px 54px -16px rgba(0,0,0,.8);
  overflow:hidden;
}
.panel.go{animation:drop .34s cubic-bezier(.2,.85,.25,1)}
.panel::before{content:"";position:absolute;inset:0;border-radius:inherit;pointer-events:none;
  background:radial-gradient(130% 70% at 50% -10%, rgba(255,255,255,.07), transparent 55%);}
.panel::after{content:"";position:absolute;left:16px;right:16px;bottom:0;height:1px;pointer-events:none;
  background:linear-gradient(90deg,transparent,rgba(255,255,255,.08),transparent);}
@keyframes drop{from{transform:translateY(-14px);opacity:0}to{transform:translateY(0);opacity:1}}
.head{height:var(--menuH);display:flex;align-items:flex-end;justify-content:center;padding-bottom:3px}
.grip{width:34px;height:4px;border-radius:3px;background:rgba(255,255,255,.16)}
.rows{list-style:none;padding:10px 8px 12px}
.empty{color:var(--sub);text-align:center;font-size:12.5px;padding:14px 0 20px}
.row{position:relative;display:flex;align-items:center;gap:12px;height:50px;
  padding:0 10px;border-radius:16px;cursor:pointer;opacity:1;
  transition:background .16s ease, transform .1s ease;}
.row.enter{animation:enter .42s cubic-bezier(.2,.85,.25,1) both;animation-delay:calc(var(--i) * 40ms + 60ms);}
@keyframes enter{from{opacity:0;transform:translateY(7px)}to{opacity:1;transform:translateY(0)}}
.row:hover{background:rgba(255,255,255,.055)}
.row:active{transform:scale(.985)}
.row.muted .proj,.row.muted .act{opacity:.5}
.dot{width:9px;height:9px;border-radius:50%;flex:none;background:var(--sub)}
.dot.done{background:var(--done);box-shadow:0 0 8px -1px var(--done)}
.dot.thinking{background:var(--think);animation:pulse 1.7s ease-out infinite}
.dot.waiting{background:var(--wait);animation:blink 1.2s ease-in-out infinite}
@keyframes pulse{0%{box-shadow:0 0 0 0 rgba(122,162,255,.5)}70%{box-shadow:0 0 0 8px rgba(122,162,255,0)}100%{box-shadow:0 0 0 0 rgba(122,162,255,0)}}
@keyframes blink{0%,100%{opacity:1}50%{opacity:.35}}
.meta{flex:1;min-width:0}
.proj{font-size:13.5px;font-weight:600;color:var(--txt);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.act{font-size:11px;color:var(--sub);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:1px}
.right{display:flex;align-items:center;gap:6px;flex:none}
.sw{font-size:10px;color:var(--sub);letter-spacing:.02em}
.sw.done{color:var(--done)} .sw.waiting{color:var(--wait)} .sw.thinking{color:var(--think)}
.mute{width:28px;height:28px;border:none;background:transparent;border-radius:9px;color:rgba(255,255,255,.78);
  display:flex;align-items:center;justify-content:center;cursor:pointer;opacity:.4;
  transition:opacity .15s, background .15s, transform .1s, color .15s}
.mute:hover{opacity:1;background:rgba(255,255,255,.09)}
.mute:active{transform:scale(.88)}
.mute.on{opacity:.95;color:var(--wait)}
.mute .slash{opacity:0;transition:opacity .15s} .mute.on .slash{opacity:1}
.mute.on .wave{opacity:0;transition:opacity .15s}
</style></head><body>
<div class="panel"><div class="head"><span class="grip"></span></div><ul class="rows"></ul></div>
<script>
var SVG='<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 5 6 9H3v6h3l5 4z"/><path class="wave" d="M15.5 8.5a5 5 0 0 1 0 7"/><path class="wave" d="M18.5 6a9 9 0 0 1 0 12"/><line class="slash" x1="3.5" y1="20.5" x2="20.5" y2="3.5"/></svg>';
function post(a,k){try{window.webkit.messageHandlers.notch.postMessage({action:a,key:k});}catch(e){}}
document.addEventListener('click',function(e){
  var mb=e.target.closest('.mute');
  if(mb){e.stopPropagation();post('mute',mb.getAttribute('data-key'));return;}
  var row=e.target.closest('.row');
  if(row){post('focus',row.getAttribute('data-key'));}
});
window.render=function(s){
  var r=document.documentElement.style;
  r.setProperty('--menuH',s.menuH+'px'); r.setProperty('--panelH',s.panelH+'px');
  r.setProperty('--sh',s.sh+'px'); r.setProperty('--w',s.w+'px');
  var ul=document.querySelector('.rows');
  if(!s.rows.length){ ul.innerHTML='<div class="empty">no active claude sessions</div>'; return; }
  var empty=ul.querySelector('.empty'); if(empty) empty.remove();
  var seen={};
  s.rows.forEach(function(d,i){
    seen[d.key]=1;
    var li=ul.querySelector('li[data-key="'+d.key+'"]');
    if(!li){                                   /* new session: create + animate in */
      li=document.createElement('li'); li.setAttribute('data-key',d.key); li.className='row';  /* static; cascade only runs on open via replay() */
      li.innerHTML='<span class="dot"></span><div class="meta"><div class="proj"></div><div class="act"></div></div><div class="right"><span class="sw"></span><button class="mute" data-key="'+d.key+'">'+SVG+'</button></div>';
      ul.appendChild(li);
    }                                          /* existing: update in place, no re-animate */
    li.style.setProperty('--i',i+1);
    ['done','thinking','waiting','idle'].forEach(function(c){li.classList.remove(c)});
    li.classList.add(d.status); li.classList.toggle('muted',!!d.muted);
    li.querySelector('.dot').className='dot '+d.status;
    li.querySelector('.proj').textContent=d.project;
    li.querySelector('.act').textContent=d.action;
    var sw=li.querySelector('.sw'); sw.className='sw '+d.status; sw.textContent=d.status;
    var mb=li.querySelector('.mute'); mb.className='mute'+(d.muted?' on':''); mb.title=d.muted?'unmute this session':'mute this session';
  });
  /* reorder ONLY rows that are actually out of place — re-inserting every row each
     render is what was restarting their animation and making the list flicker */
  for(var i=0;i<s.rows.length;i++){ var want=ul.querySelector('li[data-key="'+s.rows[i].key+'"]'); if(want && ul.children[i]!==want){ ul.insertBefore(want, ul.children[i]||null); } }
  Array.prototype.slice.call(ul.querySelectorAll('li[data-key]')).forEach(function(li){
    if(!seen[li.getAttribute('data-key')]) li.remove();
  });
};
window.replay=function(){var p=document.querySelector('.panel'); if(!p)return; p.classList.remove('go'); void p.offsetWidth; p.classList.add('go');};
</script></body></html>]]

-- --- state -> JS ----------------------------------------------------------
local OVER = 6   -- overshoot above the screen top so the black runs behind the bezel (no seam)
local function geomFor(list)
  local full, menuH = screenGeo()
  local shown = math.min(#list, 8)
  local body = (#list > 0) and (shown * ROW_H + PAD_TOP + PAD_BOT) or 56
  local headH = menuH + OVER
  local panelH = headH + body
  local frame = { x = full.x + (full.w - (W + 2 * SH)) / 2, y = full.y - OVER, w = W + 2 * SH, h = panelH + BP }
  return frame, headH, panelH, shown
end

-- prefer the iTerm2 tab name you set; fall back to the folder name
local function cleanName(n)
  if not n or n == "" then return nil end
  n = n:gsub("%s*%b()%s*$", "")                    -- drop trailing job, e.g. " (node)"
  n = n:gsub("^[\194-\244][\128-\191]*%s+", "")    -- drop a leading UTF-8 status glyph + space
  n = n:gsub("^%s+", ""):gsub("%s+$", "")
  if n == "" then return nil end
  return n
end

local function displayName(d)
  local uuid = (d.iterm_session or ""):match(":(.+)$")
  if uuid and M.nameByUuid[uuid] then return M.nameByUuid[uuid] end
  return d.project or "session"
end

local function stateJSON(list, shown, menuH, panelH)
  local rows = {}
  for i = 1, shown do
    local d = list[i]
    rows[i] = {
      key = d._key, project = displayName(d),
      action = d.last_action or d.status or "", status = d.status or "idle",
      muted = d.muted and true or false,
    }
  end
  return hs.json.encode({ rows = rows, menuH = menuH, panelH = panelH, sh = SH, w = W })
end

local function signature(list)
  local t = {}
  for _, d in ipairs(list) do
    t[#t + 1] = (d._key or "") .. "|" .. (d.status or "") .. "|" .. (d.last_action or "") .. "|" .. tostring(d.muted) .. "|" .. displayName(d)
  end
  return table.concat(t, ";")
end

-- push current sessions into the (already loaded) page; never reloads html
local function pushState()
  local list = sortedSessions()
  local frame, menuH, panelH, shown = geomFor(list)
  M.panelFrame = frame
  M.sig = signature(list)
  M.webview:frame(frame)
  M.webview:evaluateJavaScript("window.render && window.render(" .. stateJSON(list, shown, menuH, panelH) .. ")")
end

-- fetch iTerm2 session names asynchronously (non-blocking) and cache them.
-- NOTE: `tab` is a class name inside `tell iTerm2`, so we grab the real tab
-- character OUTSIDE the tell block as a field delimiter.
local NAME_SCRIPT = [[
set d to tab
set lf to linefeed
tell application "iTerm2"
  set out to ""
  repeat with w in windows
    repeat with t in tabs of w
      repeat with sess in sessions of t
        set out to out & (unique id of sess) & d & (name of sess) & lf
      end repeat
    end repeat
  end repeat
  return out
end tell
]]
local function refreshNames()
  hs.task.new("/usr/bin/osascript", function(code, stdout)
    if code ~= 0 or type(stdout) ~= "string" then return end
    local map = {}
    for line in stdout:gmatch("[^\n]+") do
      local uuid, nm = line:match("^([^\t]+)\t(.*)$")
      if uuid then local c = cleanName(nm); if c then map[uuid] = c end end
    end
    M.nameByUuid = map
    if M.visible then pushState() end
  end, { "-e", NAME_SCRIPT }):start()
end

local function showPanel()
  local wasHidden = not M.visible
  pushState()                                   -- always update contents (instant, no animation)
  if wasHidden then                             -- play the appear animation ONLY on closed -> open
    M.webview:show(0); M.visible = true
    M.webview:evaluateJavaScript("window.replay && window.replay()")
  end
end
local function hidePanel()
  if M.visible then M.webview:hide(0); M.visible = false end
end

-- --- menu bar -------------------------------------------------------------
local function isMuted() return hs.fs.attributes(MUTED_FLAG) ~= nil end
local function updateMenubar()
  if not M.menubar then return end
  local t, dn, wt = 0, 0, 0
  for _, d in pairs(M.sessions) do
    if d.status == "thinking" then t = t + 1
    elseif d.status == "done" then dn = dn + 1
    elseif d.status == "waiting" then wt = wt + 1 end
  end
  local p = {}
  if wt > 0 then p[#p + 1] = "!" .. wt end
  if t > 0 then p[#p + 1] = "\u{25D0}" .. t end
  if dn > 0 then p[#p + 1] = "\u{2713}" .. dn end
  M.menubar:setTitle(#p > 0 and table.concat(p, " ") or "\u{25CB}")
end
local function menubarMenu()
  local items, list = {}, sortedSessions()
  if #list == 0 then
    items[#items + 1] = { title = "no active sessions", disabled = true }
  else
    for _, d in ipairs(list) do
      local g = ({ done = "\u{2713}", waiting = "!", thinking = "\u{25D0}" })[d.status] or "\u{25CB}"
      items[#items + 1] = {
        title = string.format("%s  %s%s  \u{2014}  %s", g, d.project or "session",
          d.muted and " (muted)" or "", d.last_action or d.status or ""),
        fn = function() focusSession(d) end,
      }
    end
  end
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = isMuted() and "Unmute all sound" or "Mute all sound",
    fn = function() if isMuted() then os.remove(MUTED_FLAG) else local f = io.open(MUTED_FLAG, "w"); if f then f:close() end end end }
  items[#items + 1] = { title = "Force refresh", fn = function() M.forceRefresh() end }
  return items
end

-- --- refresh + hover ------------------------------------------------------
function M.refresh()
  local prev = 0
  for _, d in pairs(M.sessions) do if d.status == "done" then prev = prev + 1 end end
  loadSessions()
  local now = 0
  for _, d in pairs(M.sessions) do if d.status == "done" then now = now + 1 end end
  updateMenubar()
  if M.visible then
    if signature(sortedSessions()) ~= M.sig then pushState() end
  end
  if now > prev then M.pinnedUntil = hs.timer.secondsSinceEpoch() + 3; showPanel() end  -- auto-drop, 3s
end

local function pointIn(p, f) return f and p.x >= f.x and p.x <= f.x + f.w and p.y >= f.y and p.y <= f.y + f.h end
local function tick()
  local full, menuH = screenGeo()
  local p = hs.mouse.absolutePosition()
  local nowc = hs.timer.secondsSinceEpoch()

  -- OPEN: hovering the notch strip at the top center
  local trig = { x = full.x + (full.w - TRIG_W) / 2, y = full.y, w = TRIG_W, h = menuH + 6 }
  local inTrig = pointIn(p, trig)

  -- KEEP: cursor anywhere within the EXPANDED PANEL itself (its real visible bounds) + small edge pad
  local overPanel = false
  if M.visible and M.panelFrame then
    local pf, pad = M.panelFrame, 14
    local left, right = pf.x + SH - pad, pf.x + SH + W + pad
    local top, bottom = full.y - pad, (pf.y + pf.h - BP) + pad   -- visible panel top..bottom
    overPanel = (p.x >= left and p.x <= right and p.y >= top and p.y <= bottom)
  end

  local inside = inTrig or overPanel
  if inside then M.lastInside = nowc end
  -- open while: hovering the notch, over the panel, within the 3s auto-drop pin, or a brief leave-grace
  local want = inside or (nowc < M.pinnedUntil) or (M.visible and (nowc - M.lastInside) < 0.25)
  if want then if not M.visible then showPanel() end
  else if M.visible then hidePanel() end end
end

-- --- boot -----------------------------------------------------------------
loadSessions()

M.ucc = hs.webview.usercontent.new("notch")
M.ucc:setCallback(function(m)
  local b = (m and m.body) or {}
  local key = b.key
  if not key or not M.sessions[key] then return end
  if b.action == "focus" then
    focusSession(M.sessions[key]); M.pinnedUntil = 0; hidePanel()
  elseif b.action == "mute" then
    toggleMute(key); loadSessions(); updateMenubar(); if M.visible then pushState() end
  end
end)

M.webview = hs.webview.new({ x = 0, y = 0, w = 200, h = 200 }, { developerExtrasEnabled = false }, M.ucc)
pcall(function() M.webview:windowStyle(hs.webview.windowMasks.borderless) end)
pcall(function() M.webview:shadow(false) end)
pcall(function() M.webview:behaviorAsLabels({ "canJoinAllSpaces", "stationary" }) end)
pcall(function() M.webview:level(hs.canvas.windowLevels.popUpMenu) end)
M.webview:transparent(true)
M.webview:allowTextEntry(false)
-- render the moment the shell actually finishes loading (event-driven, not a guessed delay)
M.webview:navigationCallback(function(action)
  if action == "didFinishNavigation" then pushState() end
end)
M.webview:html(SHELL)

-- purge state files for sessions dormant past the display window (keeps the dir clean)
local function purgeStale()
  pcall(function()
    for file in hs.fs.dir(STATE_DIR) do
      if file:sub(-5) == ".json" then
        local path = STATE_DIR .. "/" .. file
        local a = hs.fs.attributes(path)
        if a and a.modification and (os.time() - a.modification) > 1800 then os.remove(path) end
      end
    end
  end)
end

-- POWERFUL REFRESH: guarantees a clean, fully re-fetched state no matter what.
-- Reloads the shell if it ever detached, re-fetches iTerm names, re-reads + purges
-- state, and re-renders. Safe to call anytime (boot, menu, hotkey).
function M.forceRefresh()
  purgeStale()
  refreshNames()
  loadSessions()
  updateMenubar()
  M.webview:evaluateJavaScript("typeof window.render", function(r)
    if r ~= "function" then M.webview:html(SHELL)   -- navigationCallback re-renders on load
    else pushState() end
  end)
end

M.menubar = hs.menubar.new()
if M.menubar then M.menubar:setMenu(menubarMenu) end
updateMenubar()

refreshNames()   -- populate iTerm tab names early
M.watcher = hs.pathwatcher.new(STATE_DIR, function() M.refresh() end):start()
-- pcall-wrap so a single stray error can never permanently kill the hover loop
-- (Hammerspoon stops a timer whose callback throws once)
M.hoverTimer = hs.timer.doEvery(0.12, function() pcall(tick) end):start()
M.sweepTimer = hs.timer.doEvery(4, function()
  if M.hoverTimer and not M.hoverTimer:running() then M.hoverTimer:start() end  -- self-heal the hover loop
  refreshNames()
  purgeStale()
  loadSessions(); updateMenubar()
  -- self-heal: if the webview shell ever detached, reload it (navigationCallback re-renders)
  M.webview:evaluateJavaScript("typeof window.render", function(r)
    if r ~= "function" then M.webview:html(SHELL) end
  end)
  if M.visible and signature(sortedSessions()) ~= M.sig then pushState() end
end):start()

-- belt-and-suspenders: one powerful refresh shortly after boot, in case a reload
-- race left the shell or names unfetched
hs.timer.doAfter(1.0, function() M.forceRefresh() end)

-- manual powerful reload:  ⌃⌥⌘R
pcall(function()
  M.hotkey = hs.hotkey.bind({ "cmd", "alt", "ctrl" }, "R", function()
    M.forceRefresh(); hs.alert.show("\u{1FAB9} Roost refreshed")
  end)
end)

M.show = function() M.pinnedUntil = os.time() + 8; showPanel() end
M.hide = function() M.pinnedUntil = 0; hidePanel() end
_G.ClaudeNotch = M
_G.Roost = M
hs.alert.show("\u{1FAB9} Roost")
