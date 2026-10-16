-------------------------------------------------------------------------------
-- GuildAlliance :: Comm.lua
-- Transport: a hidden custom chat channel shared by every alliance member.
--
-- Why a chat channel and not SendAddonMessage: AzerothCore only accepts
-- addon-language messages on PARTY/RAID/GUILD/BATTLEGROUND/WHISPER, so there
-- is no cross-guild addon channel. Plain text on a custom channel works, and
-- the client never shows it because the channel is never attached to a chat
-- frame (plus message filters as a safety net).
--
-- Wire format: "GA1;<opcode>;<field>;<field>..."  (max 255 bytes, no '|')
-------------------------------------------------------------------------------
local GA = GuildAlliance
local Comm = {}
GA.Comm = Comm

Comm.MAX_LEN       = 240   -- server caps chat messages at 255 bytes
Comm.SEND_INTERVAL = 0.6   -- seconds between sends (AzerothCore ChatFlood default: 10 msgs/sec)
Comm.JOIN_RETRY    = 15    -- seconds between join attempts
Comm.channelName   = nil
Comm.password      = ""
Comm.joined        = false
Comm.wantJoined    = false
Comm.handlers      = {}

local queue, lastSend = {}, 0
local retryPending = false
local lower = string.lower

-------------------------------------------------------------------------------
-- Channel identity
-------------------------------------------------------------------------------
function Comm:ChannelNameForKey(key)
  local clean = (tostring(key or ""):gsub("[^%w]", ""))
  if clean == "" then return nil end
  return "GA" .. clean:sub(1, 22)
end

function Comm:Configure(key, password)
  self.channelName = self:ChannelNameForKey(key)
  self.password = password or ""
end

-- chanString is arg4 ("5. Name"), chanBase is arg9 ("Name"); either may be missing.
function Comm:IsOurChannel(chanString, chanBase)
  if not self.channelName then return false end
  local want = lower(self.channelName)
  if type(chanBase) == "string" and chanBase ~= "" and lower(chanBase) == want then return true end
  if type(chanString) == "string" and chanString ~= "" then
    local base = chanString:match("^%d+%.%s*(.-)%s*$") or chanString
    if lower(base) == want then return true end
  end
  return false
end

-------------------------------------------------------------------------------
-- Join / leave
-------------------------------------------------------------------------------
function Comm:Join()
  if not self.channelName then return end
  self.wantJoined = true
  local id = GetChannelName(self.channelName)
  if id and id > 0 then
    self:OnJoined()
    return
  end
  GA:Debug("joining channel " .. self.channelName)
  if JoinTemporaryChannel then
    -- Temporary: not written to the client's saved channel list, so it is
    -- never auto-attached to a chat frame on a later login.
    JoinTemporaryChannel(self.channelName, self.password)
  else
    JoinChannelByName(self.channelName, self.password)
  end
  if not retryPending then
    retryPending = true
    GA:After(self.JOIN_RETRY, function()
      retryPending = false
      if self.wantJoined and not self.joined then self:Join() end
    end)
  end
end

function Comm:Leave()
  self.wantJoined = false
  if self.channelName then
    local id = GetChannelName(self.channelName)
    if id and id > 0 then LeaveChannelByName(self.channelName) end
  end
  if self.joined then
    self.joined = false
    GA:Fire("CHANNEL_LEFT")
  end
  queue = {}
end

function Comm:OnJoined()
  if self.joined then return end
  self.joined = true
  GA:Debug("joined " .. self.channelName)
  if self.password ~= "" then
    -- Only succeeds for the channel owner/moderator; the NOT_MODERATOR notice
    -- for everyone else is filtered out.
    SetChannelPassword(self.channelName, self.password)
  end
  GA:Fire("CHANNEL_JOINED")
end

function Comm:OnNotice(notice, chanString, chanBase)
  if not self:IsOurChannel(chanString, chanBase) then return end
  GA:Debug("channel notice " .. tostring(notice))
  if notice == "YOU_JOINED" then
    self:OnJoined()
  elseif notice == "YOU_LEFT" then
    if self.joined then
      self.joined = false
      GA:Fire("CHANNEL_LEFT")
    end
    if self.wantJoined then
      GA:Print("dropped from the alliance channel; rejoining in 30s")
      GA:After(30, function() if self.wantJoined and not self.joined then self:Join() end end)
    end
  elseif notice == "WRONG_PASSWORD" then
    self.wantJoined = false
    GA:Print("wrong alliance password. Use /ga join <key> <password> with the password your allies set.")
  elseif notice == "BANNED" then
    self.wantJoined = false
    GA:Print("you are banned from the alliance channel.")
  end
end

-------------------------------------------------------------------------------
-- Sending
-------------------------------------------------------------------------------
local function cleanField(v)
  if v == nil then return "" end
  return (tostring(v):gsub("[;|\n\r]", ""))
end

-- Queue "GA1;opcode;fields..." for sending. Returns false if it cannot fit.
function Comm:Send(opcode, ...)
  local parts = { GA.PROTOCOL, cleanField(opcode) }
  for i = 1, select("#", ...) do
    parts[#parts + 1] = cleanField((select(i, ...)))
  end
  local msg = table.concat(parts, ";")
  if #msg > 255 then
    GA:Debug("dropping oversize message (" .. #msg .. " bytes)")
    return false
  end
  queue[#queue + 1] = msg
  return true
end

function Comm:QueueLength()
  return #queue
end

function Comm:Pump()
  if not self.joined or #queue == 0 then return end
  local now = GetTime()
  if now - lastSend < self.SEND_INTERVAL then return end
  local id = GetChannelName(self.channelName)
  if not id or id == 0 then
    self.joined = false
    return
  end
  local msg = table.remove(queue, 1)
  lastSend = now
  SendChatMessage(msg, "CHANNEL", nil, id)
end

-------------------------------------------------------------------------------
-- Receiving
-------------------------------------------------------------------------------
function Comm:RegisterHandler(opcode, fn)
  self.handlers[opcode] = fn
end

function Comm:OnChannelMessage(text, sender, chanString, chanBase)
  if not self:IsOurChannel(chanString, chanBase) then return end
  if type(text) ~= "string" then return end
  local fields = GA.Split(text, ";")
  if fields[1] ~= GA.PROTOCOL then return end
  local op = fields[2]
  local handler = self.handlers[op]
  if not handler then
    GA:Debug("unknown opcode '" .. tostring(op) .. "' from " .. tostring(sender))
    return
  end
  local ok, err = pcall(handler, sender, sender == GA.player, fields)
  if not ok then GA:Debug("handler " .. tostring(op) .. " error: " .. tostring(err)) end
end

-------------------------------------------------------------------------------
-- Chat frame filters: hide anything about our channel from every chat frame.
-- 3.3.x passes (frame, event, arg1, ...) to filters; older clients passed
-- (arg1, ...). Detect which and offset accordingly.
-------------------------------------------------------------------------------
local FILTER_EVENTS = {
  "CHAT_MSG_CHANNEL", "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER",
  "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE", "CHAT_MSG_CHANNEL_LIST",
}

local function chatFilter(...)
  local offset, event = 0, nil
  if type((...)) == "table" then
    offset = 2
    event = select(2, ...)
  end
  local chanString = select(4 + offset, ...)
  local chanBase   = select(9 + offset, ...)
  if Comm:IsOurChannel(chanString, chanBase) then return true end
  -- Channel list replies do not always carry the channel name; hide them while
  -- we have a list request in flight.
  if event == "CHAT_MSG_CHANNEL_LIST" and GA.Presence and GA.Presence:ListPending() then
    return true
  end
  return false
end

-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------
function Comm:Init()
  for _, ev in ipairs(FILTER_EVENTS) do
    ChatFrame_AddMessageEventFilter(ev, chatFilter)
  end

  -- CHAT_MSG_CHANNEL args: text, sender, language, "N. Name", target, flags,
  -- zoneChannelID, channelNumber, channelBaseName, ...
  GA:RegisterEvent("CHAT_MSG_CHANNEL", function(event, text, sender, _, chanString, _, _, _, _, chanBase)
    Comm:OnChannelMessage(text, sender, chanString, chanBase)
  end)
  GA:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE", function(event, notice, _, _, chanString, _, _, _, _, chanBase)
    Comm:OnNotice(notice, chanString, chanBase)
  end)

  GA:Every(0.2, function() Comm:Pump() end)
end
