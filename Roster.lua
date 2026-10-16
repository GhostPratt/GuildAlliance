-------------------------------------------------------------------------------
-- GuildAlliance :: Roster.lua
-- Snapshots the local guild roster and exchanges rosters with allied guilds.
--
-- Messages (see Comm.lua for framing):
--   RH;<guild>;<stamp>;<chunkCount>;<idx>=<rankName>,...     roster header
--   R;<guild>;<stamp>;<seq>;Name.lvl.cls.rank.hrs,...         roster chunk
--   P;<guild>;<stamp>;<seq>;<total>;Name,Name,...             who is online now
--   RQ;<guild>=<stampIHave>,...                               please resend rosters
--
-- One client per guild (the "reporter", see Presence:IsReporter) does the
-- periodic broadcasting so a guild with ten addon users does not send ten
-- copies of the same roster.
-------------------------------------------------------------------------------
local GA = GuildAlliance
local Comm = GA.Comm
local Roster = {}
GA.Roster = Roster

Roster.FULL_INTERVAL     = 30 * 60  -- full roster rebroadcast
Roster.PRESENCE_INTERVAL = 3 * 60   -- online-list broadcast
Roster.GUILDROSTER_POLL  = 120      -- ask the server for a fresh guild roster
Roster.INCOMING_TIMEOUT  = 90       -- commit partial rosters after this long
Roster.OWN_REBROADCAST_SUPPRESS = 10 * 60 -- skip login broadcast if a guildmate sent one this recently

Roster.own = nil              -- latest snapshot of my guild
Roster.incoming = {}          -- [guild..":"..stamp] = partial roster being assembled
Roster.lastBroadcastStamp = 0
Roster.ownGuildBroadcastSeenAt = 0
Roster.lastSnap = 0
Roster.fullPending = false

local CLASS_TO_CODE = {
  WARRIOR = "W", PALADIN = "P", HUNTER = "H", ROGUE = "R", PRIEST = "I",
  DEATHKNIGHT = "K", SHAMAN = "S", MAGE = "M", WARLOCK = "L", DRUID = "D",
}
local CODE_TO_CLASS = {}
for k, v in pairs(CLASS_TO_CODE) do CODE_TO_CLASS[v] = k end
Roster.CODE_TO_CLASS = CODE_TO_CLASS

local localizedToFile
local function ClassFileFromLocalized(localized)
  if not localized then return nil end
  if not localizedToFile then
    localizedToFile = {}
    for _, tbl in ipairs({ LOCALIZED_CLASS_NAMES_MALE, LOCALIZED_CLASS_NAMES_FEMALE }) do
      if type(tbl) == "table" then
        for file, name in pairs(tbl) do localizedToFile[name] = file end
      end
    end
  end
  return localizedToFile[localized]
end

function Roster:ClassCode(classFile, classLocalized)
  return CLASS_TO_CODE[classFile or ""] or CLASS_TO_CODE[ClassFileFromLocalized(classLocalized) or ""] or "?"
end

function Roster:OwnGuildName()
  if not IsInGuild() then return nil end
  return (GetGuildInfo("player"))
end

-------------------------------------------------------------------------------
-- Local snapshot
-------------------------------------------------------------------------------
function Roster:Snapshot()
  local guild = self:OwnGuildName()
  if not guild then
    self.own = nil
    return nil
  end
  -- Toggling the offline filter fires GUILD_ROSTER_UPDATE; OnRosterUpdate debounces on lastSnap.
  self.lastSnap = GetTime()
  local showOffline = GetGuildRosterShowOffline()
  if not showOffline then SetGuildRosterShowOffline(true) end
  local n = GetNumGuildMembers()
  local members, ranks, onlineCount = {}, {}, 0
  for i = 1, n do
    local name, rankName, rankIndex, level, class, _, _, _, online, _, classFile = GetGuildRosterInfo(i)
    if name then
      local hours = 0
      if online then
        onlineCount = onlineCount + 1
      else
        local y, mo, d, h = GetGuildRosterLastOnline(i)
        hours = (y or 0) * 8760 + (mo or 0) * 730 + (d or 0) * 24 + (h or 0)
        if hours == 0 then hours = 1 end -- offline for under an hour; nonzero means offline
      end
      members[name] = {
        level  = level or 0,
        class  = self:ClassCode(classFile, class),
        rank   = rankIndex or 0,
        hours  = hours,
        online = online and true or false,
      }
      if rankIndex and rankName then ranks[rankIndex] = rankName end
    end
  end
  if not showOffline then SetGuildRosterShowOffline(false) end
  self.own = { guild = guild, members = members, ranks = ranks, count = n, online = onlineCount }
  return self.own
end

-- Persist my own guild into the shared realm store (alts on this realm can see it).
function Roster:StoreOwn(own)
  local g = GA.realm.guilds[own.guild] or { members = {}, ranks = {} }
  local now = time()
  local members = {}
  for name, m in pairs(own.members) do
    local old = g.members[name]
    members[name] = {
      level = m.level, class = m.class, rank = m.rank, hours = m.hours,
      seen = m.online and now or (old and old.seen) or nil,
    }
  end
  g.members = members
  g.ranks = own.ranks
  g.stamp = now
  g.at = now
  g.own = true
  g.source = GA.player
  GA.realm.guilds[own.guild] = g
end

function Roster:OnRosterUpdate()
  local now = GetTime()
  -- SetGuildRosterShowOffline inside Snapshot fires this event again; debounce.
  if now - self.lastSnap < 5 then return end
  self.lastSnap = now
  local prev = self.own
  local own = self:Snapshot()
  if not own then return end
  self:StoreOwn(own)
  if prev and prev.guild == own.guild then
    local changed = false
    for name in pairs(own.members) do
      if not prev.members[name] then changed = true break end
    end
    if not changed then
      for name in pairs(prev.members) do
        if not own.members[name] then changed = true break end
      end
    end
    if changed and Comm.joined and GA.Presence:IsReporter() then
      self:ScheduleFull(30)
    end
  end
  GA:Fire("ROSTER_CHANGED", own.guild)
end

-------------------------------------------------------------------------------
-- Broadcasting
-------------------------------------------------------------------------------
local function chunkList(items, room)
  local chunks, cur = {}, nil
  for _, item in ipairs(items) do
    if cur and #cur + 1 + #item > room then
      chunks[#chunks + 1] = cur
      cur = nil
    end
    cur = cur and (cur .. "," .. item) or item
  end
  if cur then chunks[#chunks + 1] = cur end
  return chunks
end

function Roster:ScheduleFull(delay)
  if self.fullPending then return end
  self.fullPending = true
  GA:After(delay, function()
    Roster.fullPending = false
    if Comm.joined then Roster:BroadcastFull("scheduled") end
  end)
end

function Roster:BroadcastFull(reason)
  local own = self:Snapshot()
  if not own then return end
  self:StoreOwn(own)
  local stamp = time()
  if stamp <= self.lastBroadcastStamp then stamp = self.lastBroadcastStamp + 1 end
  self.lastBroadcastStamp = stamp

  local entries = {}
  for name, m in pairs(own.members) do
    entries[#entries + 1] = table.concat({ name, m.level, m.class, m.rank, m.hours }, ".")
  end
  table.sort(entries)
  local headerLen = #(GA.PROTOCOL .. ";R;" .. own.guild .. ";" .. stamp .. ";999;")
  local chunks = chunkList(entries, Comm.MAX_LEN - headerLen)

  local ranks = {}
  for idx, rname in pairs(own.ranks) do
    ranks[#ranks + 1] = idx .. "=" .. (tostring(rname):gsub("[,=]", ""):sub(1, 20))
  end
  table.sort(ranks)

  Comm:Send("RH", own.guild, stamp, #chunks, table.concat(ranks, ","))
  for i, chunk in ipairs(chunks) do
    Comm:Send("R", own.guild, stamp, i, chunk)
  end
  GA:Debug(string.format("broadcast roster (%s): %d members in %d chunks", tostring(reason), #entries, #chunks))
end

function Roster:BroadcastPresence()
  local own = self.own or self:Snapshot()
  if not own then return end
  local names = {}
  for name, m in pairs(own.members) do
    if m.online then names[#names + 1] = name end
  end
  table.sort(names)
  local stamp = time()
  local headerLen = #(GA.PROTOCOL .. ";P;" .. own.guild .. ";" .. stamp .. ";99;99;")
  local chunks = chunkList(names, Comm.MAX_LEN - headerLen)
  if #chunks == 0 then chunks[1] = "" end
  for i, chunk in ipairs(chunks) do
    Comm:Send("P", own.guild, stamp, i, #chunks, chunk)
  end
end

function Roster:RequestRosters()
  local own = self:OwnGuildName()
  local pairsList = {}
  for guild, g in pairs(GA.realm.guilds) do
    if guild ~= own then
      pairsList[#pairsList + 1] = (guild:gsub("[,=]", "")) .. "=" .. tostring(g.stamp or 0)
    end
  end
  table.sort(pairsList)
  local s = table.concat(pairsList, ",")
  if #s > 200 then
    s = s:sub(1, 200)
    s = (s:gsub(",[^,]*$", ""))
  end
  Comm:Send("RQ", s)
end

function Roster:AlliedGuildNames()
  local own = self:OwnGuildName()
  local out = {}
  for guild in pairs(GA.realm.guilds) do
    if guild ~= own then out[#out + 1] = guild end
  end
  table.sort(out)
  return out
end

-- Make sure a guild/member exists in the store (seeded from who results or presence).
function Roster:EnsureMember(guild, name, level, classCode)
  if not guild or guild == "" or not name or name == "" then return nil end
  local g = GA.realm.guilds[guild]
  if not g then
    g = { members = {}, ranks = {}, at = 0, stamp = 0 }
    GA.realm.guilds[guild] = g
  end
  local m = g.members[name]
  if not m then
    m = { level = 0, class = "?", rank = 0, hours = 1 }
    g.members[name] = m
  end
  if level and level > 0 then m.level = level end
  if classCode and classCode ~= "?" then m.class = classCode end
  return m
end

-------------------------------------------------------------------------------
-- Receiving rosters
-------------------------------------------------------------------------------
function Roster:TryCommit(key, force)
  local inc = self.incoming[key]
  if not inc then return end
  if not force and (not inc.total or inc.got < inc.total) then return end

  local g = GA.realm.guilds[inc.guild] or { members = {}, ranks = {} }
  if g.stamp and inc.stamp < g.stamp and not g.own then
    self.incoming[key] = nil
    return
  end
  local now = time()
  local newMembers = {}
  for _, chunk in pairs(inc.chunks) do
    for _, e in ipairs(GA.Split(chunk, ",")) do
      if e ~= "" then
        local p = GA.Split(e, ".")
        local name = p[1]
        if name and name ~= "" then
          local old = g.members[name]
          local hours = tonumber(p[5]) or 0
          newMembers[name] = {
            level = tonumber(p[2]) or 0,
            class = p[3] or "?",
            rank  = tonumber(p[4]) or 0,
            hours = hours,
            seen  = (hours == 0) and now or (old and old.seen) or nil,
          }
        end
      end
    end
  end
  if force then
    -- Partial roster: keep members we did not hear about rather than dropping them.
    for name, m in pairs(g.members) do
      if not newMembers[name] then newMembers[name] = m end
    end
  end
  g.members = newMembers
  g.stamp = inc.stamp
  g.at = now
  g.source = inc.sender
  g.own = nil
  if inc.ranks then
    g.ranks = {}
    for _, pair in ipairs(GA.Split(inc.ranks, ",")) do
      local idx, rname = pair:match("^(%d+)=(.*)$")
      if idx then g.ranks[tonumber(idx)] = rname end
    end
  end
  GA.realm.guilds[inc.guild] = g
  self.incoming[key] = nil
  GA:Debug(string.format("stored roster for %s from %s (%s)", inc.guild, tostring(inc.sender), force and "partial" or "complete"))
  GA:Fire("ROSTER_CHANGED", inc.guild)
end

function Roster:SweepIncoming()
  local now = GetTime()
  for key, inc in pairs(self.incoming) do
    if now - (inc.at or 0) > self.INCOMING_TIMEOUT then
      if inc.got > 0 then
        self:TryCommit(key, true)
      else
        self.incoming[key] = nil
      end
    end
  end
end

local function incomingFor(guild, stamp, sender)
  local key = guild .. ":" .. stamp
  local inc = Roster.incoming[key]
  if not inc then
    inc = { chunks = {}, got = 0, guild = guild, stamp = stamp, sender = sender }
    Roster.incoming[key] = inc
  end
  inc.at = GetTime()
  return key, inc
end

Comm:RegisterHandler("RH", function(sender, isSelf, f)
  if isSelf then return end
  local guild, stamp, total, ranks = f[3], tonumber(f[4]), tonumber(f[5]), f[6]
  if not guild or guild == "" or not stamp or not total then return end
  if guild == Roster:OwnGuildName() then
    Roster.ownGuildBroadcastSeenAt = time()
    return
  end
  local key, inc = incomingFor(guild, stamp, sender)
  inc.total = total
  inc.ranks = ranks
  Roster:TryCommit(key)
end)

Comm:RegisterHandler("R", function(sender, isSelf, f)
  if isSelf then return end
  local guild, stamp, seq, entries = f[3], tonumber(f[4]), tonumber(f[5]), f[6]
  if not guild or guild == "" or not stamp or not seq then return end
  if guild == Roster:OwnGuildName() then return end
  local key, inc = incomingFor(guild, stamp, sender)
  if not inc.chunks[seq] then
    inc.chunks[seq] = entries or ""
    inc.got = inc.got + 1
  end
  Roster:TryCommit(key)
end)

Comm:RegisterHandler("RQ", function(sender, isSelf, f)
  if isSelf then return end
  local own = Roster:OwnGuildName()
  if not own then return end
  if not GA.Presence:IsReporter() then return end
  local have = 0
  for _, pair in ipairs(GA.Split(f[3] or "", ",")) do
    local g, s = pair:match("^(.-)=(%d+)$")
    if g == (own:gsub("[,=]", "")) then have = tonumber(s) or 0 end
  end
  if Roster.lastBroadcastStamp > 0 and have >= Roster.lastBroadcastStamp then
    Roster:BroadcastPresence()
  else
    Roster:ScheduleFull(2 + math.random() * 4)
  end
end)

-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------
function Roster:OnChannelJoined()
  GA:After(3, function() Comm:Send("H", Roster:OwnGuildName() or "", GA.VERSION) end)
  GA:After(5, function() Roster:RequestRosters() end)
  GA:After(12, function()
    if not Comm.joined then return end
    if GA.Presence:IsReporter() and time() - Roster.ownGuildBroadcastSeenAt > Roster.OWN_REBROADCAST_SUPPRESS then
      Roster:BroadcastFull("login")
    end
    Roster:BroadcastPresence()
  end)
end

function Roster:Init()
  GA:RegisterEvent("GUILD_ROSTER_UPDATE", function() Roster:OnRosterUpdate() end)
  GA:RegisterEvent("PLAYER_GUILD_UPDATE", function(event, unit)
    if unit == "player" and IsInGuild() then GuildRoster() end
  end)
  GA:On("CHANNEL_JOINED", function() Roster:OnChannelJoined() end)

  GA:After(5, function() if IsInGuild() then GuildRoster() end end)
  GA:Every(self.GUILDROSTER_POLL, function() if IsInGuild() then GuildRoster() end end)
  GA:Every(self.PRESENCE_INTERVAL, function()
    if Comm.joined and GA.Presence:IsReporter() then Roster:BroadcastPresence() end
  end)
  GA:Every(self.FULL_INTERVAL, function()
    if Comm.joined and GA.Presence:IsReporter() then Roster:BroadcastFull("periodic") end
  end)
  GA:Every(30, function() Roster:SweepIncoming() end)
end
