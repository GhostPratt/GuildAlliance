-------------------------------------------------------------------------------
-- GuildAlliance :: Core.lua
-- Namespace, saved variables, event dispatch, timers, slash commands.
-- Target: World of Warcraft 3.3.5a (Interface 30300), Lua 5.1.
-------------------------------------------------------------------------------
GuildAlliance = GuildAlliance or {}
local GA = GuildAlliance

GA.VERSION     = "0.1.0"
GA.PROTOCOL    = "GA1"   -- wire protocol tag; bump when the message format changes
GA.MAX_FRIENDS = 50      -- AzerothCore SOCIALMGR_FRIEND_LIMIT (hard server cap)

local DEFAULT_SETTINGS = {
  debug       = false,
  whoPoll     = true,  -- poll /who g-"Guild" so allied members without the addon still show online
  whoInterval = 90,    -- seconds between who polls (one allied guild per poll)
  onlineOnly  = false, -- window filter
}

-------------------------------------------------------------------------------
-- Output
-------------------------------------------------------------------------------
function GA:Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99GuildAlliance|r: " .. tostring(msg))
end

function GA:Debug(msg)
  if self.settings and self.settings.debug then
    DEFAULT_CHAT_FRAME:AddMessage("|cff999999GA debug: " .. tostring(msg) .. "|r")
  end
end

-------------------------------------------------------------------------------
-- Small utilities
-------------------------------------------------------------------------------
-- Split on a literal separator; keeps empty fields.
function GA.Split(str, sep)
  local out = {}
  local esc = (sep:gsub("%p", "%%%0"))
  for field in (tostring(str or "") .. sep):gmatch("(.-)" .. esc) do
    out[#out + 1] = field
  end
  return out
end

function GA.Trim(s)
  return (tostring(s or ""):match("^%s*(.-)%s*$"))
end

function GA.FormatAgo(seconds)
  if not seconds or seconds < 0 then return "?" end
  if seconds < 3600 then return "<1h" end
  if seconds < 86400 then return string.format("%dh", math.floor(seconds / 3600)) end
  return string.format("%dd", math.floor(seconds / 86400))
end

-------------------------------------------------------------------------------
-- Game event dispatch
-------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame", "GuildAllianceEventFrame")
GA.eventFrame = eventFrame
local eventHandlers = {}

function GA:RegisterEvent(event, fn)
  eventHandlers[event] = eventHandlers[event] or {}
  table.insert(eventHandlers[event], fn)
  eventFrame:RegisterEvent(event)
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
  local list = eventHandlers[event]
  if not list then return end
  for i = 1, #list do
    local ok, err = pcall(list[i], event, ...)
    if not ok then GA:Debug(event .. " handler error: " .. tostring(err)) end
  end
end)

-------------------------------------------------------------------------------
-- Internal callback bus (addon-internal events)
-------------------------------------------------------------------------------
local callbacks = {}

function GA:On(name, fn)
  callbacks[name] = callbacks[name] or {}
  table.insert(callbacks[name], fn)
end

function GA:Fire(name, ...)
  local list = callbacks[name]
  if not list then return end
  for i = 1, #list do
    local ok, err = pcall(list[i], ...)
    if not ok then self:Debug(name .. " callback error: " .. tostring(err)) end
  end
end

-------------------------------------------------------------------------------
-- Timers (OnUpdate driven; 3.3.5a has no C_Timer)
-------------------------------------------------------------------------------
local timers = {}

-- Run fn once after delay seconds.
function GA:After(delay, fn)
  local t = { at = GetTime() + delay, fn = fn }
  timers[#timers + 1] = t
  return t
end

-- Run fn every interval seconds until cancelled.
function GA:Every(interval, fn)
  local t = { at = GetTime() + interval, fn = fn, interval = interval }
  timers[#timers + 1] = t
  return t
end

function GA:Cancel(t)
  if t then t.cancelled = true end
end

eventFrame:SetScript("OnUpdate", function(self, elapsed)
  if #timers == 0 then return end
  local now = GetTime()
  local i = 1
  while i <= #timers do
    local t = timers[i]
    if t.cancelled then
      table.remove(timers, i)
    elseif now >= t.at then
      if t.interval then
        t.at = now + t.interval
        i = i + 1
      else
        table.remove(timers, i)
      end
      local ok, err = pcall(t.fn)
      if not ok then GA:Debug("timer error: " .. tostring(err)) end
    else
      i = i + 1
    end
  end
end)

-------------------------------------------------------------------------------
-- Saved variables
--
-- GuildAllianceDB = {
--   settings = { ... },
--   realms = {
--     [realmName] = {
--       chars  = { [charName] = { alliance = { key=, password= } } },
--       guilds = { [guildName] = { stamp=, at=, source=, own=, ranks={[idx]=name},
--                                  members = { [name] = { level=, class=, rank=, hours=, seen= } } } },
--     },
--   },
-- }
-------------------------------------------------------------------------------
function GA:InitDB()
  if type(GuildAllianceDB) ~= "table" then GuildAllianceDB = {} end
  local db = GuildAllianceDB
  db.settings = db.settings or {}
  for k, v in pairs(DEFAULT_SETTINGS) do
    if db.settings[k] == nil then db.settings[k] = v end
  end
  db.realms = db.realms or {}
  local realmName = GetRealmName() or "Unknown"
  db.realms[realmName] = db.realms[realmName] or {}
  local realm = db.realms[realmName]
  realm.chars  = realm.chars  or {}
  realm.guilds = realm.guilds or {}
  realm.chars[self.player] = realm.chars[self.player] or {}

  self.db        = db
  self.settings  = db.settings
  self.realm     = realm
  self.realmName = realmName
end

function GA:CharDB()
  return self.realm.chars[self.player]
end

-------------------------------------------------------------------------------
-- Alliance configuration
-------------------------------------------------------------------------------
function GA:SetAlliance(key, password)
  local Comm = self.Comm
  local newName = Comm:ChannelNameForKey(key)
  if not newName then
    self:Print("alliance key must contain letters or digits")
    return
  end
  local c = self:CharDB()
  c.alliance = { key = key, password = password }
  if Comm.joined and Comm.channelName == newName then
    Comm:Configure(key, password)
    self:Print("alliance key unchanged; password updated")
    return
  end
  if Comm.wantJoined then Comm:Leave() end
  Comm:Configure(key, password)
  self:After(1.5, function() Comm:Join() end)
  self:Print(string.format("alliance key set to '%s' (channel %s); joining...", key, newName))
end

function GA:ClearAlliance()
  local c = self:CharDB()
  c.alliance = nil
  self.Comm:Leave()
  self:Print("left the alliance channel; this character no longer belongs to an alliance")
end

-------------------------------------------------------------------------------
-- Friends list helper (real friends list; subject to the 50 slot server cap)
-------------------------------------------------------------------------------
function GA:AddFriendSafe(name)
  name = GA.Trim(name)
  if name == "" then
    self:Print("usage: /ga friend <name>")
    return
  end
  local n = GetNumFriends()
  if n >= GA.MAX_FRIENDS then
    self:Print(string.format("friends list is full (%d/%d); the server will refuse more. Remove one first.", n, GA.MAX_FRIENDS))
    return
  end
  AddFriend(name)
  self:Print(string.format("added %s to your friends list (%d/%d slots used)", name, n + 1, GA.MAX_FRIENDS))
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
local HELP = {
  "/ga                      toggle the alliance window",
  "/ga join <key> [pw]      join (or create) an alliance by shared key, optional password",
  "/ga leave                leave the alliance",
  "/ga status               show channel and sync status",
  "/ga guilds               list known guilds and member counts",
  "/ga sync                 broadcast your guild roster now",
  "/ga request              ask allied guilds to resend their rosters",
  "/ga friend <name>        add a player to your real friends list (50 slot cap)",
  "/ga forget <guild>       drop a guild's saved roster",
  "/ga who on|off           toggle /who polling for members without the addon",
  "/ga debug on|off         toggle debug output",
}

function GA:ShowHelp()
  self:Print("v" .. self.VERSION .. " commands:")
  for _, line in ipairs(HELP) do
    DEFAULT_CHAT_FRAME:AddMessage("  " .. line)
  end
end

function GA:ShowStatus()
  local Comm, Presence = self.Comm, self.Presence
  local c = self:CharDB()
  local key = c.alliance and c.alliance.key or "(none)"
  local state = Comm.joined and "joined" or (Comm.wantJoined and "joining" or "not joined")
  self:Print(string.format("alliance key: %s   channel: %s   state: %s", key, tostring(Comm.channelName or "-"), state))
  local users, guilds = 0, 0
  for _ in pairs(Presence.channelMembers) do users = users + 1 end
  for _ in pairs(self.realm.guilds) do guilds = guilds + 1 end
  self:Print(string.format("addon users in channel: %d   known guilds: %d   queued messages: %d   reporter for my guild: %s",
    users, guilds, Comm:QueueLength(), tostring(Presence:IsReporter())))
end

function GA:ShowGuilds()
  local own = self.Roster:OwnGuildName()
  local names = {}
  for g in pairs(self.realm.guilds) do names[#names + 1] = g end
  table.sort(names)
  if #names == 0 then
    self:Print("no guild rosters known yet")
    return
  end
  for _, g in ipairs(names) do
    local data = self.realm.guilds[g]
    local total, online = 0, 0
    for name, m in pairs(data.members) do
      total = total + 1
      if self.Presence:Status(g, name, m) then online = online + 1 end
    end
    self:Print(string.format("%s%s: %d members, %d online, roster age %s",
      g, g == own and " (mine)" or "", total, online, GA.FormatAgo(time() - (data.at or 0))))
  end
end

function GA:HandleSlash(msg)
  local cmd, rest = tostring(msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = (cmd or ""):lower()
  rest = rest or ""
  if cmd == "" or cmd == "show" or cmd == "toggle" then
    self.UI:Toggle()
  elseif cmd == "join" then
    local key, pw = rest:match("^(%S+)%s*(%S*)$")
    if not key then
      self:Print("usage: /ga join <key> [password]")
      return
    end
    self:SetAlliance(key, pw ~= "" and pw or nil)
  elseif cmd == "leave" then
    self:ClearAlliance()
  elseif cmd == "status" then
    self:ShowStatus()
  elseif cmd == "guilds" then
    self:ShowGuilds()
  elseif cmd == "sync" then
    if not self.Comm.joined then
      self:Print("not in an alliance channel")
      return
    end
    self.Roster:BroadcastFull("manual")
    self.Roster:BroadcastPresence()
    self:Print("roster broadcast queued (" .. self.Comm:QueueLength() .. " messages)")
  elseif cmd == "request" then
    if not self.Comm.joined then
      self:Print("not in an alliance channel")
      return
    end
    self.Roster:RequestRosters()
    self.Presence:RequestList()
    self:Print("roster request sent")
  elseif cmd == "friend" then
    self:AddFriendSafe(rest)
  elseif cmd == "forget" then
    if self.realm.guilds[rest] then
      self.realm.guilds[rest] = nil
      self:Print("forgot roster for " .. rest)
      self:Fire("ROSTER_CHANGED", rest)
    else
      self:Print("no roster stored for '" .. rest .. "'")
    end
  elseif cmd == "who" then
    if rest == "on" then
      self.settings.whoPoll = true
    elseif rest == "off" then
      self.settings.whoPoll = false
    end
    self:Print("who polling is " .. (self.settings.whoPoll and "on" or "off"))
  elseif cmd == "debug" then
    if rest == "on" then
      self.settings.debug = true
    elseif rest == "off" then
      self.settings.debug = false
    else
      self.settings.debug = not self.settings.debug
    end
    self:Print("debug output is " .. (self.settings.debug and "on" or "off"))
  else
    self:ShowHelp()
  end
end

SLASH_GUILDALLIANCE1 = "/ga"
SLASH_GUILDALLIANCE2 = "/guildalliance"
SlashCmdList["GUILDALLIANCE"] = function(msg) GA:HandleSlash(msg) end

-------------------------------------------------------------------------------
-- Startup
-------------------------------------------------------------------------------
local enteredWorld = false

GA:RegisterEvent("PLAYER_LOGIN", function()
  GA.player = UnitName("player")
  GA:InitDB()
  GA.Comm:Init()
  GA.Roster:Init()
  GA.Presence:Init()
  GA.UI:Init()
  local c = GA:CharDB()
  if c.alliance and c.alliance.key then
    GA.Comm:Configure(c.alliance.key, c.alliance.password)
  end
  GA:Print("v" .. GA.VERSION .. " loaded. Type /ga for commands.")
end)

GA:RegisterEvent("PLAYER_ENTERING_WORLD", function()
  if enteredWorld then return end
  enteredWorld = true
  -- Channels cannot be joined reliably until a few seconds after entering the world.
  GA:After(6, function()
    local c = GA:CharDB()
    if c.alliance and c.alliance.key then GA.Comm:Join() end
  end)
end)
