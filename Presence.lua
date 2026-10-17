-------------------------------------------------------------------------------
-- GuildAlliance :: Presence.lua
-- Who is online, from four sources (strongest first):
--   1. channel membership  - they run the addon and are in the alliance channel
--   2. P reports           - an allied reporter said they were online recently
--   3. /who g-"Guild"      - polled for allied members without the addon
--   4. roster broadcast    - marked online in a recent roster broadcast
-------------------------------------------------------------------------------
local GA = GuildAlliance
local Comm = GA.Comm
local Presence = {}
GA.Presence = Presence

Presence.ONLINE_TTL   = 7 * 60   -- how long a P report / roster "online" flag counts
Presence.LIST_REFRESH = 10 * 60  -- periodic channel member list resync
Presence.channelMembers = {}     -- [name] = true
Presence.users = {}              -- [name] = { guild=, version=, seen= }
Presence.reported = {}           -- [guild] = { stamp=, at=, online={[name]=true} }
Presence.who = {}                -- [guild] = { at=, online={[name]=true} }
Presence.listRequestedAt = -1000
Presence.whoPending = nil
Presence.whoIndex = 0
Presence.lastWhoAt = 0

-------------------------------------------------------------------------------
-- Channel membership
-------------------------------------------------------------------------------
function Presence:ListPending()
  return GetTime() - self.listRequestedAt < 5
end

function Presence:RequestList()
  if not Comm.joined or not Comm.channelName then return end
  self.listRequestedAt = GetTime()
  ListChannelByName(Comm.channelName)
end

-- "Members: Alice*, Bob@, Carol" -> set of names. Markers after a name are dropped.
function Presence:ParseList(text)
  local set = {}
  local body = text
  local colon = body:find(":", 1, true)
  if colon then body = body:sub(colon + 1) end
  for token in body:gmatch("[^,]+") do
    local name = token:match("^%s*([^%s%*@%[%]%(%)]+)")
    if name and name ~= "" then set[name] = true end
  end
  return set
end

function Presence:OnChannelList(text, chanString, chanBase)
  if not (Comm:IsOurChannel(chanString, chanBase) or self:ListPending()) then return end
  if type(text) ~= "string" then return end
  local set = self:ParseList(text)
  set[GA.player] = true
  self.channelMembers = set
  local now = time()
  for name in pairs(set) do
    local u = self.users[name] or {}
    u.seen = now
    self.users[name] = u
  end
  GA:Debug("channel list received")
  GA:Fire("PRESENCE_CHANGED")
end

function Presence:OnChannelJoin(player, chanString, chanBase)
  if not Comm:IsOurChannel(chanString, chanBase) then return end
  if not player or player == "" then return end
  self.channelMembers[player] = true
  local u = self.users[player] or {}
  u.seen = time()
  self.users[player] = u
  GA:Fire("PRESENCE_CHANGED")
end

function Presence:OnChannelLeave(player, chanString, chanBase)
  if not Comm:IsOurChannel(chanString, chanBase) then return end
  if not player or player == "" then return end
  self.channelMembers[player] = nil
  local u = self.users[player]
  if u then
    u.seen = time()
    if u.guild then
      local m = GA.Roster:EnsureMember(u.guild, player)
      if m then m.seen = time() end
    end
  end
  GA:Fire("PRESENCE_CHANGED")
end

-- The alphabetically first channel member from my guild does the broadcasting.
function Presence:IsReporter()
  local own = GA.Roster.own or GA.Roster:Snapshot()
  if not own or not own.members then return false end
  local me = GA.player
  for name in pairs(self.channelMembers) do
    if name ~= me and own.members[name] and name < me then return false end
  end
  return true
end

-------------------------------------------------------------------------------
-- Who polling (for allied members who do not run the addon)
--
-- SetWhoToUI(1) is the only way to get results as data instead of chat text,
-- but the default UI's WHO_LIST_UPDATE handler (WhoList_Update) then calls
-- ShowUIPanel(FriendsFrame) and switches to the Who tab. So while one of our
-- polls is in flight, FriendsFrame is unregistered from that event, and it is
-- re-registered as soon as the result (or a timeout) arrives.
-------------------------------------------------------------------------------
local whoFrameMuted = false

local function muteWhoFrame()
  if whoFrameMuted or not FriendsFrame then return end
  whoFrameMuted = true
  FriendsFrame:UnregisterEvent("WHO_LIST_UPDATE")
end

local function unmuteWhoFrame()
  if not whoFrameMuted then return end
  whoFrameMuted = false
  if FriendsFrame then FriendsFrame:RegisterEvent("WHO_LIST_UPDATE") end
end

function Presence:EndWho()
  self.whoPending = nil
  SetWhoToUI(0)
  unmuteWhoFrame()
end

function Presence:WhoTick()
  if not GA.settings.whoPoll then return end
  local c = GA:CharDB()
  if not (c.alliance and c.alliance.key) then return end
  if self.whoPending then return end
  if GetTime() - self.lastWhoAt < GA.settings.whoInterval then return end
  if FriendsFrame and FriendsFrame:IsVisible() then return end
  local guilds = GA.Roster:AlliedGuildNames()
  if #guilds == 0 then return end
  self.whoIndex = (self.whoIndex % #guilds) + 1
  local guild = guilds[self.whoIndex]
  self.lastWhoAt = GetTime()
  self.whoPending = { guild = guild, at = GetTime() }
  muteWhoFrame()
  SetWhoToUI(1)
  SendWho('g-"' .. guild .. '"')
  GA:Debug("who poll: " .. guild)
  GA:After(6, function()
    local p = Presence.whoPending
    if p and p.guild == guild and GetTime() - p.at >= 6 then
      GA:Debug("who poll timed out: " .. guild)
      Presence:EndWho()
    end
  end)
end

function Presence:OnWhoList()
  local p = self.whoPending
  if not p then return end
  self:EndWho()
  local n = GetNumWhoResults()
  local set = {}
  for i = 1, n do
    local name, guild, level, _, class, _, classFile = GetWhoInfo(i)
    if name and guild == p.guild then
      set[name] = true
      local code = GA.Roster:ClassCode(type(classFile) == "string" and classFile or nil, class)
      local m = GA.Roster:EnsureMember(guild, name, level, code)
      if m then m.seen = time() end
    end
  end
  self.who[p.guild] = { at = time(), online = set }
  GA:Debug(string.format("who poll result for %s: %d online", p.guild, n))
  GA:Fire("PRESENCE_CHANGED")
end

-------------------------------------------------------------------------------
-- Status resolution
-------------------------------------------------------------------------------
-- Returns online(boolean), source(string)
function Presence:Status(guild, name, member)
  if self.channelMembers[name] then return true, "addon" end
  local now = time()
  local r = self.reported[guild]
  if r and now - r.at < self.ONLINE_TTL and r.online[name] then return true, "report" end
  local w = self.who[guild]
  if w and now - w.at < math.max(self.ONLINE_TTL, GA.settings.whoInterval * 2.5) and w.online[name] then
    return true, "who"
  end
  local g = GA.realm.guilds[guild]
  if g and member and member.hours == 0 and g.at and now - g.at < self.ONLINE_TTL then
    return true, "roster"
  end
  return false, nil
end

-- Seconds since the member was last known online, or nil if unknown.
function Presence:LastSeenAgo(guild, member)
  local g = GA.realm.guilds[guild]
  local now = time()
  local best
  if member.seen then best = now - member.seen end
  if g and g.at and member.hours and member.hours > 0 then
    local fromRoster = member.hours * 3600 + (now - g.at)
    if not best or fromRoster < best then best = fromRoster end
  end
  return best
end

-------------------------------------------------------------------------------
-- Protocol handlers
-------------------------------------------------------------------------------
Comm:RegisterHandler("H", function(sender, isSelf, f)
  if isSelf then return end
  local guild, version = f[3], f[4]
  Presence.channelMembers[sender] = true
  Presence.users[sender] = { guild = guild, version = version, seen = time() }
  if guild and guild ~= "" and guild ~= GA.Roster:OwnGuildName() then
    local m = GA.Roster:EnsureMember(guild, sender)
    if m then m.seen = time() end
  end
  GA:Fire("PRESENCE_CHANGED")
end)

Comm:RegisterHandler("P", function(sender, isSelf, f)
  if isSelf then return end
  local guild, stamp, names = f[3], tonumber(f[4]), f[7]
  if not guild or guild == "" or not stamp then return end
  if guild == GA.Roster:OwnGuildName() then return end
  local r = Presence.reported[guild]
  if not r or stamp > r.stamp then
    r = { stamp = stamp, at = time(), online = {} }
    Presence.reported[guild] = r
  end
  if stamp ~= r.stamp then return end
  r.at = time()
  for _, name in ipairs(GA.Split(names or "", ",")) do
    if name ~= "" then
      r.online[name] = true
      local m = GA.Roster:EnsureMember(guild, name)
      if m then m.seen = time() end
    end
  end
  GA:Fire("PRESENCE_CHANGED")
end)

-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------
function Presence:Init()
  -- CHAT_MSG_CHANNEL_JOIN/LEAVE args: "", playerName, language, "N. Name", ..., channelNumber, channelBaseName
  GA:RegisterEvent("CHAT_MSG_CHANNEL_JOIN", function(event, _, player, _, chanString, _, _, _, _, chanBase)
    Presence:OnChannelJoin(player, chanString, chanBase)
  end)
  GA:RegisterEvent("CHAT_MSG_CHANNEL_LEAVE", function(event, _, player, _, chanString, _, _, _, _, chanBase)
    Presence:OnChannelLeave(player, chanString, chanBase)
  end)
  GA:RegisterEvent("CHAT_MSG_CHANNEL_LIST", function(event, text, _, _, chanString, _, _, _, _, chanBase)
    Presence:OnChannelList(text, chanString, chanBase)
  end)
  GA:RegisterEvent("WHO_LIST_UPDATE", function() Presence:OnWhoList() end)

  GA:On("CHANNEL_JOINED", function()
    Presence.channelMembers = { [GA.player] = true }
    GA:After(2, function() Presence:RequestList() end)
  end)
  GA:On("CHANNEL_LEFT", function()
    Presence.channelMembers = {}
    GA:Fire("PRESENCE_CHANGED")
  end)

  GA:Every(15, function() Presence:WhoTick() end)
  GA:Every(self.LIST_REFRESH, function() Presence:RequestList() end)
end
