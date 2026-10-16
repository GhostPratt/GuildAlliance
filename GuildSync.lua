-------------------------------------------------------------------------------
-- GuildAlliance :: GuildSync.lua
-- Distributes the alliance key inside a guild so members pick it up on login.
--
-- Transport: SendAddonMessage on GUILD (and WHISPER replies). AzerothCore
-- allows addon messages there, and the client cannot show them.
--
-- Trust model: a key is accepted as "the guild's alliance" only when the sender
-- holds an officer rank (rank index <= settings.keyRankMax, default 1 = guild
-- master and the next rank). Rank is read from our own guild roster, which the
-- server provides, never from the message. Regular members may relay the
-- officer-set key to newcomers; relays are held briefly in case an officer
-- answers, then accepted.
--
-- Messages (prefix "GuildAlly"):
--   REQ;<stampIHave>                       who has a newer key than mine?
--   KEY;<stamp>;<setBy>;<key>;<password>   the guild's key; empty key = cleared
-------------------------------------------------------------------------------
local GA = GuildAlliance
local GuildSync = {}
GA.GuildSync = GuildSync

GuildSync.PREFIX = "GuildAlly"
GuildSync.MEMBER_RELAY_HOLD = 5   -- seconds to wait for an officer before trusting a member relay
GuildSync.pendingRelay = nil

-------------------------------------------------------------------------------
-- Ranks
-------------------------------------------------------------------------------
function GuildSync:MyRank()
  if not IsInGuild() then return nil end
  local _, _, rankIndex = GetGuildInfo("player")
  return rankIndex
end

function GuildSync:IsOfficerRank(rankIndex)
  return rankIndex ~= nil and rankIndex <= (GA.settings.keyRankMax or 1)
end

function GuildSync:IAmOfficer()
  return self:IsOfficerRank(self:MyRank())
end

-- Rank of a guildmate from our own roster snapshot; nil if not a known member.
function GuildSync:RankOf(name)
  local own = GA.Roster.own or GA.Roster:Snapshot()
  local m = own and own.members and own.members[name]
  return m and m.rank or nil
end

-------------------------------------------------------------------------------
-- Sending
-------------------------------------------------------------------------------
local function send(msg, target)
  if not IsInGuild() then return end
  if target then
    SendAddonMessage(GuildSync.PREFIX, msg, "WHISPER", target)
  else
    SendAddonMessage(GuildSync.PREFIX, msg, "GUILD")
  end
end

local function clean(v)
  return (tostring(v == nil and "" or v):gsub("[;|\n\r]", ""))
end

function GuildSync:KeyMessage()
  local c = GA:CharDB()
  local a = c.alliance
  return table.concat({
    "KEY",
    tostring(c.allianceStamp or 0),
    clean(c.allianceSetBy or GA.player),
    clean(a and a.key or ""),
    clean(a and a.password or ""),
  }, ";")
end

-- Tell the whole guild the current key (or that it was cleared).
function GuildSync:BroadcastKey()
  local c = GA:CharDB()
  if not c.allianceFromGuild then return end
  send(self:KeyMessage())
  GA:Debug("broadcast guild key to guild")
end

-- Ask guildmates for a newer key than the one we hold.
function GuildSync:Request()
  local c = GA:CharDB()
  send("REQ;" .. tostring(c.allianceStamp or 0))
  GA:Debug("requested guild key")
end

-------------------------------------------------------------------------------
-- Receiving
-------------------------------------------------------------------------------
function GuildSync:Apply(stamp, setBy, key, pw, sender, verified)
  local c = GA:CharDB()
  if stamp <= (c.allianceStamp or 0) then return end
  if verified then self.pendingRelay = nil end
  local meta = { stamp = stamp, setBy = (setBy ~= "" and setBy) or sender, fromGuild = true }
  if key == "" then
    if c.alliance then
      GA:ClearAlliance(meta)
      GA:Print("the guild's alliance was cleared by " .. meta.setBy)
    else
      c.allianceStamp = stamp
      c.allianceSetBy = meta.setBy
      c.allianceFromGuild = true
    end
    return
  end
  local password = (pw ~= "" and pw) or nil
  if c.alliance and c.alliance.key == key and (c.alliance.password or "") == (password or "") then
    -- Same alliance; just adopt the guild's ownership of it.
    c.allianceStamp = stamp
    c.allianceSetBy = meta.setBy
    c.allianceFromGuild = true
    GA:Fire("ALLIANCE_CHANGED")
    return
  end
  GA:SetAlliance(key, password, meta)
  GA:Print(string.format("alliance key '%s' received from your guild (set by %s)", key, meta.setBy))
end

function GuildSync:OnMessage(msg, channel, sender, retried)
  if sender == GA.player then return end
  if channel ~= "GUILD" and channel ~= "WHISPER" then return end
  local senderRank = self:RankOf(sender)
  if not senderRank then
    -- Roster may not be loaded yet right after login; try once more.
    if not retried then
      GA:After(5, function() GuildSync:OnMessage(msg, channel, sender, true) end)
    end
    return
  end
  local f = GA.Split(msg, ";")
  if f[1] == "REQ" then
    local theirStamp = tonumber(f[2]) or 0
    local c = GA:CharDB()
    if not c.allianceFromGuild then return end
    if (c.allianceStamp or 0) <= theirStamp then return end
    -- Officers answer fast; members relay later so an officer's answer wins.
    local delay = self:IAmOfficer() and (0.5 + math.random()) or (3 + math.random() * 2)
    GA:After(delay, function() send(GuildSync:KeyMessage(), sender) end)
  elseif f[1] == "KEY" then
    local stamp = tonumber(f[2]) or 0
    local setBy, key, pw = f[3] or "", f[4] or "", f[5] or ""
    if self:IsOfficerRank(senderRank) then
      self:Apply(stamp, setBy, key, pw, sender, true)
    else
      local p = self.pendingRelay
      if not p or stamp > p.stamp then
        self.pendingRelay = { stamp = stamp, setBy = setBy, key = key, pw = pw, sender = sender }
        GA:After(self.MEMBER_RELAY_HOLD, function()
          local held = GuildSync.pendingRelay
          if held then
            GuildSync.pendingRelay = nil
            GuildSync:Apply(held.stamp, held.setBy, held.key, held.pw, held.sender, false)
          end
        end)
      end
    end
  end
end

-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------
function GuildSync:Init()
  GA:RegisterEvent("CHAT_MSG_ADDON", function(event, prefix, msg, channel, sender)
    if prefix ~= GuildSync.PREFIX then return end
    GuildSync:OnMessage(msg, channel, sender)
  end)

  GA:On("ENTERED_WORLD", function()
    -- Wait for the guild roster (requested at +5s) so ranks can be verified.
    GA:After(10, function()
      if not IsInGuild() then return end
      GuildSync:Request()
      local c = GA:CharDB()
      if c.allianceFromGuild and GuildSync:IAmOfficer() then
        -- Officers announce at login so members who logged in earlier catch up.
        GA:After(2, function() GuildSync:BroadcastKey() end)
      end
    end)
  end)
end
