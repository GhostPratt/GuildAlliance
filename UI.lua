-------------------------------------------------------------------------------
-- GuildAlliance :: UI.lua
-- An "Alliance" tab on the Social frame (FriendsFrame), beside Friends, Who,
-- Guild and Raid. Everything the slash commands do is reachable from here.
--
--   Key / password boxes + Join   join or create an alliance
--   Leave                         leave the alliance
--   Refresh                       ask allies to resend rosters and presence
--   Sync                          broadcast my guild roster now
--   Whisper / Invite / Add Friend act on the selected member
--   Online only                   filter the list
--   Click a row to select it, double click to whisper, right click to invite.
-------------------------------------------------------------------------------
local GA = GuildAlliance
local UI = {}
GA.UI = UI

BINDING_HEADER_GUILDALLIANCE = "Guild Alliance"
BINDING_NAME_GUILDALLIANCE_TOGGLE = "Toggle alliance tab"

UI.TAB_ID = 5
local ROWS, ROW_HEIGHT = 14, 16
local LIST_TOP = -146
local LIST_LEFT = 22
local LIST_WIDTH = 296

local frame, scroll, statusLine1, statusLine2, onlineOnlyCheck, keyBox, pwBox
local whisperBtn, inviteBtn, friendBtn, leaveBtn, syncBtn, tab
local rows = {}
local list = {}
local selected = nil -- { name=, guild= }

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
  if ago then return "|cff808080" .. GA.FormatAgo(ago) .. "|r" end
  return "|cff808080Offline|r"
end

local function isSelected(entry)
  return selected and selected.name == entry.name and selected.guild == entry.guild
end

-------------------------------------------------------------------------------
-- Rendering
-------------------------------------------------------------------------------
function UI:IsActive()
  return frame and frame:IsShown()
end

function UI:UpdateButtons()
  local Comm = GA.Comm
  local c = GA:CharDB()
  local hasAlliance = c.alliance and c.alliance.key
  local hasSel = selected ~= nil
  if hasSel then whisperBtn:Enable() else whisperBtn:Disable() end
  if hasSel then inviteBtn:Enable() else inviteBtn:Disable() end
  if hasSel then friendBtn:Enable() else friendBtn:Disable() end
  if hasAlliance then leaveBtn:Enable() else leaveBtn:Disable() end
  if Comm.joined then syncBtn:Enable() else syncBtn:Disable() end
end

function UI:Refresh()
  if not self:IsActive() then return end
  self:BuildList()

  -- Drop the selection if it fell out of the list (filter or roster change).
  if selected then
    local still = false
    for _, e in ipairs(list) do
      if isSelected(e) then still = true break end
    end
    if not still then selected = nil end
  end

  FauxScrollFrame_Update(scroll, #list, ROWS, ROW_HEIGHT)
  local offset = FauxScrollFrame_GetOffset(scroll)
  for i = 1, ROWS do
    local row = rows[i]
    local entry = list[i + offset]
    if entry then
      local r, g, b = classColor(entry.m.class)
      if not entry.online then r, g, b = r * 0.55, g * 0.55, b * 0.55 end
      row.name:SetText(entry.name)
      row.name:SetTextColor(r, g, b)
      row.level:SetText(entry.m.level > 0 and tostring(entry.m.level) or "")
      row.guild:SetText(entry.guild)
      row.status:SetText(statusLabel(entry))
      row.entry = entry
      if isSelected(entry) then row.selection:Show() else row.selection:Hide() end
      row:Show()
    else
      row.entry = nil
      row.selection:Hide()
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
  local state = Comm.joined and "|cff40ff40connected|r"
    or (Comm.wantJoined and "|cffffff40joining...|r" or "|cffff4040not connected|r")
  if c.alliance and c.alliance.key then
    local origin = c.allianceFromGuild
      and ("guild, set by " .. tostring(c.allianceSetBy or "?"))
      or "personal"
    statusLine1:SetText("Alliance |cffffffff" .. c.alliance.key .. "|r   " .. state .. "   |cffaaaaaa(" .. origin .. ")|r")
  elseif GA.GuildSync:IAmOfficer() then
    statusLine1:SetText("No alliance. As an officer, the key you join here is shared with your whole guild.")
  else
    statusLine1:SetText("No alliance. Your guild's officers can set one; it arrives automatically at login.")
  end
  statusLine2:SetText(string.format("Allied guilds: %d   Online: %d   Addon users in channel: %d", guilds, online, users))

  self:UpdateButtons()
end

-------------------------------------------------------------------------------
-- Row interaction
-------------------------------------------------------------------------------
local function whisper(name)
  if ChatFrame_SendTell then
    ChatFrame_SendTell(name)
  else
    ChatFrame_OpenChat("/w " .. name .. " ")
  end
end

local function rowOnClick(self, button)
  local e = self.entry
  if not e then return end
  if button == "RightButton" then
    InviteUnit(e.name)
    return
  end
  selected = { name = e.name, guild = e.guild }
  PlaySound("igMainMenuOptionCheckBoxOn")
  UI:Refresh()
end

local function rowOnDoubleClick(self, button)
  local e = self.entry
  if e and button == "LeftButton" then whisper(e.name) end
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
  GameTooltip:AddLine("Click: select   Double click: whisper   Right click: invite", 0.5, 0.5, 0.5)
  GameTooltip:Show()
end

-------------------------------------------------------------------------------
-- Button actions
-------------------------------------------------------------------------------
local function doJoin()
  local key = GA.Trim(keyBox:GetText())
  local pw = GA.Trim(pwBox:GetText())
  if key == "" then
    GA:Print("enter an alliance key first")
    return
  end
  keyBox:ClearFocus()
  pwBox:ClearFocus()
  GA:SetAlliance(key, pw ~= "" and pw or nil)
  UI:Refresh()
end

local function doLeave()
  GA:ClearAlliance()
  keyBox:SetText("")
  pwBox:SetText("")
  UI:Refresh()
end

local function doRefresh()
  if GA.Comm.joined then
    GA.Roster:RequestRosters()
    GA.Presence:RequestList()
  end
  UI:Refresh()
end

local function doSync()
  if not GA.Comm.joined then return end
  GA.Roster:BroadcastFull("manual")
  GA.Roster:BroadcastPresence()
  GA:Print("roster broadcast queued (" .. GA.Comm:QueueLength() .. " messages)")
end

-------------------------------------------------------------------------------
-- Construction
-------------------------------------------------------------------------------
local function makeButton(name, text, width, x, yFromBottom, onClick)
  local b = CreateFrame("Button", name, frame, "UIPanelButtonTemplate")
  b:SetWidth(width)
  b:SetHeight(22)
  b:SetPoint("BOTTOMLEFT", x, yFromBottom)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

-- Tooltip explaining whether Join/Leave affect the whole guild or just this character.
local function scopeTooltip(self, action)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  if not IsInGuild() then
    GameTooltip:AddLine(action .. " for this character.", 1, 1, 1)
  elseif GA.GuildSync:IAmOfficer() then
    GameTooltip:AddLine(action .. " for your whole guild.", 1, 0.82, 0)
    GameTooltip:AddLine("You hold an officer rank, so guildmates running the addon pick this up on login.", 0.8, 0.8, 0.8, true)
  else
    GameTooltip:AddLine(action .. " for this character only.", 1, 1, 1)
    GameTooltip:AddLine(string.format("Only guild ranks 0 to %d can set the alliance for the whole guild.", GA.settings.keyRankMax or 1), 0.8, 0.8, 0.8, true)
  end
  GameTooltip:Show()
end

local function makeEditBox(name, width, x, y, maxLetters)
  local eb = CreateFrame("EditBox", name, frame, "InputBoxTemplate")
  eb:SetWidth(width)
  eb:SetHeight(20)
  eb:SetPoint("TOPLEFT", x, y)
  eb:SetAutoFocus(false)
  eb:SetMaxLetters(maxLetters)
  eb:SetScript("OnEnterPressed", doJoin)
  eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  return eb
end

local function buildPanel()
  frame = CreateFrame("Frame", "GuildAllianceFrame", FriendsFrame)
  frame:SetAllPoints(FriendsFrame)
  frame:Hide()

  statusLine1 = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  statusLine1:SetPoint("TOPLEFT", LIST_LEFT, -78)
  statusLine1:SetWidth(LIST_WIDTH + 24)
  statusLine1:SetJustifyH("LEFT")

  statusLine2 = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  statusLine2:SetPoint("TOPLEFT", LIST_LEFT, -92)
  statusLine2:SetWidth(LIST_WIDTH + 24)
  statusLine2:SetJustifyH("LEFT")

  -- Join row
  local keyLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  keyLabel:SetPoint("TOPLEFT", LIST_LEFT, -113)
  keyLabel:SetText("Key")
  keyBox = makeEditBox("GuildAllianceKeyBox", 104, LIST_LEFT + 30, -109, 24)

  local pwLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  pwLabel:SetPoint("TOPLEFT", LIST_LEFT + 142, -113)
  pwLabel:SetText("Pass")
  pwBox = makeEditBox("GuildAlliancePasswordBox", 70, LIST_LEFT + 178, -109, 16)

  local joinBtn = CreateFrame("Button", "GuildAllianceJoinButton", frame, "UIPanelButtonTemplate")
  joinBtn:SetWidth(60)
  joinBtn:SetHeight(22)
  joinBtn:SetPoint("TOPLEFT", LIST_LEFT + 258, -108)
  joinBtn:SetText("Join")
  joinBtn:SetScript("OnClick", doJoin)
  joinBtn:SetScript("OnEnter", function(self) scopeTooltip(self, "Join an alliance") end)
  joinBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- Column headers
  local function header(text, x, width)
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", LIST_LEFT + x, LIST_TOP + 13)
    fs:SetWidth(width)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
  end
  header("Name", 2, 110)
  header("Lvl", 114, 28)
  header("Guild", 144, 95)
  header("Status", 241, 55)

  -- List
  scroll = CreateFrame("ScrollFrame", "GuildAllianceScrollFrame", frame, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", LIST_LEFT, LIST_TOP)
  scroll:SetWidth(LIST_WIDTH)
  scroll:SetHeight(ROWS * ROW_HEIGHT)
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, function() UI:Refresh() end)
  end)

  for i = 1, ROWS do
    local row = CreateFrame("Button", "GuildAllianceRow" .. i, frame)
    row:SetHeight(ROW_HEIGHT)
    row:SetWidth(LIST_WIDTH)
    row:SetPoint("TOPLEFT", LIST_LEFT, LIST_TOP - (i - 1) * ROW_HEIGHT)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", rowOnClick)
    row:SetScript("OnDoubleClick", rowOnDoubleClick)
    row:SetScript("OnEnter", rowOnEnter)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.selection = row:CreateTexture(nil, "BACKGROUND")
    row.selection:SetAllPoints(row)
    row.selection:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    row.selection:SetBlendMode("ADD")
    row.selection:SetVertexColor(1, 0.8, 0.2, 0.6)
    row.selection:Hide()

    local function col(x, width)
      local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetPoint("LEFT", x, 0)
      fs:SetWidth(width)
      fs:SetHeight(ROW_HEIGHT)
      fs:SetJustifyH("LEFT")
      return fs
    end
    row.name   = col(2, 110)
    row.level  = col(114, 28)
    row.guild  = col(144, 95)
    row.status = col(241, 55)
    row:Hide()
    rows[i] = row
  end

  -- Bottom row B (upper): Refresh, Sync, Leave, Online only
  local refreshBtn = makeButton("GuildAllianceRefreshButton", "Refresh", 70, LIST_LEFT, 108, doRefresh)
  syncBtn  = makeButton("GuildAllianceSyncButton", "Sync", 60, LIST_LEFT + 72, 108, doSync)
  leaveBtn = makeButton("GuildAllianceLeaveButton", "Leave", 60, LIST_LEFT + 134, 108, doLeave)
  leaveBtn:SetScript("OnEnter", function(self) scopeTooltip(self, "Leave the alliance") end)
  leaveBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  onlineOnlyCheck = CreateFrame("CheckButton", "GuildAllianceOnlineOnlyCheck", frame, "UICheckButtonTemplate")
  onlineOnlyCheck:SetWidth(24)
  onlineOnlyCheck:SetHeight(24)
  onlineOnlyCheck:SetPoint("BOTTOMLEFT", LIST_LEFT + 200, 107)
  _G["GuildAllianceOnlineOnlyCheckText"]:SetText("Online only")
  onlineOnlyCheck:SetScript("OnClick", function(self)
    GA.settings.onlineOnly = self:GetChecked() and true or false
    UI:Refresh()
  end)

  -- Bottom row A (lower): act on the selected member
  whisperBtn = makeButton("GuildAllianceWhisperButton", "Whisper", 100, LIST_LEFT, 84, function()
    if selected then whisper(selected.name) end
  end)
  inviteBtn = makeButton("GuildAllianceInviteButton", "Invite", 100, LIST_LEFT + 102, 84, function()
    if selected then InviteUnit(selected.name) end
  end)
  friendBtn = makeButton("GuildAllianceFriendButton", "Add Friend", 100, LIST_LEFT + 204, 84, function()
    if selected then GA:AddFriendSafe(selected.name) end
  end)

  frame:SetScript("OnShow", function()
    local c = GA:CharDB()
    keyBox:SetText(c.alliance and c.alliance.key or "")
    pwBox:SetText(c.alliance and c.alliance.password or "")
    onlineOnlyCheck:SetChecked(GA.settings.onlineOnly)
    UI:Refresh()
  end)
  frame:SetScript("OnHide", function()
    keyBox:ClearFocus()
    pwBox:ClearFocus()
  end)
end

-- Fifth tab on the Social frame. FriendsFrame_Update knows nothing about tab 5,
-- so a post-hook paints the frame art, title and shows our panel; registering
-- the panel in FRIENDSFRAME_SUBFRAMES lets Blizzard's code hide it for other tabs.
local function buildTab()
  tab = CreateFrame("Button", "FriendsFrameTab" .. UI.TAB_ID, FriendsFrame, "CharacterFrameTabButtonTemplate")
  tab:SetID(UI.TAB_ID)
  tab:SetText("Alliance")
  tab:SetPoint("LEFT", _G["FriendsFrameTab" .. (UI.TAB_ID - 1)], "RIGHT", -15, 0)
  tab:SetScript("OnClick", function(self)
    PanelTemplates_Tab_OnClick(self, FriendsFrame)
    FriendsFrame_Update()
    PlaySound("igCharacterInfoTab")
  end)
  PanelTemplates_TabResize(tab, 0)
  PanelTemplates_SetNumTabs(FriendsFrame, UI.TAB_ID)
  PanelTemplates_UpdateTabs(FriendsFrame)

  if type(FRIENDSFRAME_SUBFRAMES) == "table" then
    tinsert(FRIENDSFRAME_SUBFRAMES, "GuildAllianceFrame")
  end

  hooksecurefunc("FriendsFrame_Update", function()
    if FriendsFrame.selectedTab ~= UI.TAB_ID then return end
    FriendsFrameTopLeft:SetTexture("Interface\\PaperDollInfoFrame\\UI-Character-General-TopLeft")
    FriendsFrameTopRight:SetTexture("Interface\\PaperDollInfoFrame\\UI-Character-General-TopRight")
    FriendsFrameBottomLeft:SetTexture("Interface\\PaperDollInfoFrame\\UI-Character-General-BottomLeft")
    FriendsFrameBottomRight:SetTexture("Interface\\PaperDollInfoFrame\\UI-Character-General-BottomRight")
    FriendsFrameTitleText:SetText("Guild Alliance")
    if FriendsTabHeader then FriendsTabHeader:Hide() end
    if FriendsFrame_ShowSubFrame then
      FriendsFrame_ShowSubFrame("GuildAllianceFrame")
    else
      frame:Show()
    end
    UI:Refresh()
  end)
end

-------------------------------------------------------------------------------
-- Public
-------------------------------------------------------------------------------
function UI:Toggle()
  if not frame then return end
  if FriendsFrame:IsShown() and FriendsFrame.selectedTab == UI.TAB_ID then
    HideUIPanel(FriendsFrame)
    return
  end
  if ToggleFriendsFrame then
    ToggleFriendsFrame(UI.TAB_ID)
  else
    PanelTemplates_SetTab(FriendsFrame, UI.TAB_ID)
    ShowUIPanel(FriendsFrame)
  end
  if FriendsFrame:IsShown() then FriendsFrame_Update() end
end

function UI:Init()
  if not frame then
    buildPanel()
    buildTab()
  end
  GA:On("PRESENCE_CHANGED", function() UI:Refresh() end)
  GA:On("ROSTER_CHANGED", function() UI:Refresh() end)
  GA:On("CHANNEL_JOINED", function() UI:Refresh() end)
  GA:On("CHANNEL_LEFT", function() UI:Refresh() end)
  GA:On("ALLIANCE_CHANGED", function()
    if UI:IsActive() then
      local c = GA:CharDB()
      keyBox:SetText(c.alliance and c.alliance.key or "")
      pwBox:SetText(c.alliance and c.alliance.password or "")
      UI:Refresh()
    end
  end)
  GA:Every(30, function() UI:Refresh() end)
end
