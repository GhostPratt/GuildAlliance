-------------------------------------------------------------------------------
-- GuildAlliance :: UI.lua
-- The alliance roster window: allied guild members, online first.
--   Left click   whisper        Right click  invite        Shift click  add friend
-------------------------------------------------------------------------------
local GA = GuildAlliance
local UI = {}
GA.UI = UI

BINDING_HEADER_GUILDALLIANCE = "Guild Alliance"
BINDING_NAME_GUILDALLIANCE_TOGGLE = "Toggle alliance window"

local ROWS, ROW_HEIGHT = 18, 16
local LIST_TOP = -96
local FRAME_WIDTH = 440

local frame, scroll, statusText, onlineOnlyCheck
local rows = {}
local list = {}

local function classColor(code)
  local file = GA.Roster.CODE_TO_CLASS[code]
  local c = file and RAID_CLASS_COLORS and RAID_CLASS_COLORS[file]
  if c then return c.r, c.g, c.b end
  return 0.8, 0.8, 0.8
end

local function classLabel(code)
  local file = GA.Roster.CODE_TO_CLASS[code]
  if file and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[file] then
    return LOCALIZED_CLASS_NAMES_MALE[file]
  end
  return file or "Unknown"
end

-------------------------------------------------------------------------------
-- Data
-------------------------------------------------------------------------------
function UI:BuildList()
  list = {}
  local own = GA.Roster:OwnGuildName()
  local onlineOnly = GA.settings.onlineOnly
  local Presence = GA.Presence
  for guild, g in pairs(GA.realm.guilds) do
    if guild ~= own then
      for name, m in pairs(g.members) do
        local online, source = Presence:Status(guild, name, m)
        if online or not onlineOnly then
          list[#list + 1] = {
            name = name, guild = guild, m = m, online = online, source = source,
            rank = (g.ranks and g.ranks[m.rank]) or "",
          }
        end
      end
    end
  end
  table.sort(list, function(a, b)
    if a.online ~= b.online then return a.online end
    if a.guild ~= b.guild then return a.guild < b.guild end
    return a.name < b.name
  end)
  return list
end

local function statusLabel(entry)
  if entry.online then return "|cff40ff40Online|r" end
  local ago = GA.Presence:LastSeenAgo(entry.guild, entry.m)
  if ago then return "|cff808080" .. GA.FormatAgo(ago) .. " ago|r" end
  return "|cff808080Offline|r"
end

-------------------------------------------------------------------------------
-- Rendering
-------------------------------------------------------------------------------
function UI:Refresh()
  if not frame or not frame:IsShown() then return end
  self:BuildList()
  FauxScrollFrame_Update(scroll, #list, ROWS, ROW_HEIGHT)
  local offset = FauxScrollFrame_GetOffset(scroll)
  for i = 1, ROWS do
    local row = rows[i]
    local entry = list[i + offset]
    if entry then
      local r, g, b = classColor(entry.m.class)
      row.name:SetText(entry.name)
      row.name:SetTextColor(r, g, b)
      row.level:SetText(entry.m.level > 0 and tostring(entry.m.level) or "")
      row.guild:SetText(entry.guild)
      row.status:SetText(statusLabel(entry))
      if not entry.online then
        row.name:SetTextColor(r * 0.55, g * 0.55, b * 0.55)
      end
      row.entry = entry
      row:Show()
    else
      row.entry = nil
      row:Hide()
    end
  end

  local Comm, Presence = GA.Comm, GA.Presence
  local c = GA:CharDB()
  local users, guilds, online = 0, 0, 0
  for _ in pairs(Presence.channelMembers) do users = users + 1 end
  local own = GA.Roster:OwnGuildName()
  for guild in pairs(GA.realm.guilds) do if guild ~= own then guilds = guilds + 1 end end
  for _, e in ipairs(list) do if e.online then online = online + 1 end end
  local state = Comm.joined and "|cff40ff40connected|r" or (Comm.wantJoined and "|cffffff40joining|r" or "|cffff4040not joined|r")
  statusText:SetText(string.format("Alliance: %s   %s   Allied guilds: %d   Online: %d   Addon users: %d",
    c.alliance and c.alliance.key or "none", state, guilds, online, users))
end

local function rowOnEnter(self)
  local e = self.entry
  if not e then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  local r, g, b = classColor(e.m.class)
  GameTooltip:AddLine(e.name, r, g, b)
  GameTooltip:AddLine(e.guild .. (e.rank ~= "" and (" - " .. e.rank) or ""), 1, 1, 1)
  if e.m.level > 0 then
    GameTooltip:AddLine("Level " .. e.m.level .. " " .. classLabel(e.m.class), 0.8, 0.8, 0.8)
  end
  if e.online then
    local why = { addon = "in alliance channel", report = "reported by allied guild", who = "seen via /who", roster = "online in last roster sync" }
    GameTooltip:AddLine("Online (" .. (why[e.source] or "?") .. ")", 0.4, 1, 0.4)
  else
    local ago = GA.Presence:LastSeenAgo(e.guild, e.m)
    GameTooltip:AddLine(ago and ("Last seen " .. GA.FormatAgo(ago) .. " ago") or "Offline", 0.6, 0.6, 0.6)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Left click: whisper   Right click: invite   Shift click: add friend", 0.5, 0.5, 0.5)
  GameTooltip:Show()
end

local function rowOnClick(self, button)
  local e = self.entry
  if not e then return end
  if IsShiftKeyDown() then
    GA:AddFriendSafe(e.name)
  elseif button == "RightButton" then
    InviteUnit(e.name)
  else
    if ChatFrame_SendTell then
      ChatFrame_SendTell(e.name)
    else
      ChatFrame_OpenChat("/w " .. e.name .. " ")
    end
  end
end

-------------------------------------------------------------------------------
-- Construction
-------------------------------------------------------------------------------
local function buildFrame()
  frame = CreateFrame("Frame", "GuildAllianceFrame", UIParent)
  frame:SetWidth(FRAME_WIDTH)
  frame:SetHeight(ROWS * ROW_HEIGHT + 118)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("HIGH")
  frame:SetToplevel(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  frame:Hide()
  tinsert(UISpecialFrames, "GuildAllianceFrame")

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", 0, -16)
  title:SetText("Guild Alliance")

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)

  statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  statusText:SetPoint("TOPLEFT", 20, -38)
  statusText:SetWidth(FRAME_WIDTH - 40)
  statusText:SetJustifyH("LEFT")

  onlineOnlyCheck = CreateFrame("CheckButton", "GuildAllianceOnlineOnlyCheck", frame, "UICheckButtonTemplate")
  onlineOnlyCheck:SetWidth(24)
  onlineOnlyCheck:SetHeight(24)
  onlineOnlyCheck:SetPoint("TOPLEFT", 16, -54)
  _G["GuildAllianceOnlineOnlyCheckText"]:SetText("Online only")
  onlineOnlyCheck:SetScript("OnClick", function(self)
    GA.settings.onlineOnly = self:GetChecked() and true or false
    UI:Refresh()
  end)

  local syncBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  syncBtn:SetWidth(80)
  syncBtn:SetHeight(20)
  syncBtn:SetPoint("TOPRIGHT", -30, -56)
  syncBtn:SetText("Refresh")
  syncBtn:SetScript("OnClick", function()
    if GA.Comm.joined then
      GA.Roster:RequestRosters()
      GA.Presence:RequestList()
    end
    UI:Refresh()
  end)

  local function header(text, x, width)
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", x, LIST_TOP + 14)
    fs:SetWidth(width)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return fs
  end
  header("Name", 22, 120)
  header("Lvl", 146, 30)
  header("Guild", 180, 140)
  header("Status", 324, 80)

  scroll = CreateFrame("ScrollFrame", "GuildAllianceScrollFrame", frame, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 16, LIST_TOP)
  scroll:SetWidth(FRAME_WIDTH - 56)
  scroll:SetHeight(ROWS * ROW_HEIGHT)
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, function() UI:Refresh() end)
  end)

  for i = 1, ROWS do
    local row = CreateFrame("Button", "GuildAllianceRow" .. i, frame)
    row:SetHeight(ROW_HEIGHT)
    row:SetWidth(FRAME_WIDTH - 60)
    row:SetPoint("TOPLEFT", 20, LIST_TOP - (i - 1) * ROW_HEIGHT)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", rowOnClick)
    row:SetScript("OnEnter", rowOnEnter)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local function col(x, width, justify)
      local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetPoint("LEFT", x, 0)
      fs:SetWidth(width)
      fs:SetHeight(ROW_HEIGHT)
      fs:SetJustifyH(justify or "LEFT")
      return fs
    end
    row.name   = col(2, 120)
    row.level  = col(126, 30)
    row.guild  = col(160, 140)
    row.status = col(304, 80)
    row:Hide()
    rows[i] = row
  end

  frame:SetScript("OnShow", function()
    onlineOnlyCheck:SetChecked(GA.settings.onlineOnly)
    UI:Refresh()
  end)
end

function UI:Toggle()
  if not frame then return end
  if frame:IsShown() then
    frame:Hide()
  else
    frame:Show()
  end
end

function UI:Init()
  if not frame then buildFrame() end
  GA:On("PRESENCE_CHANGED", function() UI:Refresh() end)
  GA:On("ROSTER_CHANGED", function() UI:Refresh() end)
  GA:On("CHANNEL_JOINED", function() UI:Refresh() end)
  GA:On("CHANNEL_LEFT", function() UI:Refresh() end)
  GA:Every(30, function() UI:Refresh() end)
end
