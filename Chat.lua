-- Chat: small in-place enhancements to Blizzard's chat frames.

-- Frames Blizzard keeps re-showing are moved under a parent that is never
-- shown. It sits under UIParent so they keep their scale.
local hidden = CreateFrame("Frame", nil, UIParent)
hidden:Hide()

-- Never shown. It measures a row of text, and lends its SetText to lines
-- whose own has been hooked.
local ruler = hidden:CreateFontString()
local setText = ruler.SetText

local HISTORY_LINES = 1000 -- Blizzard keeps 128 per window

local CORNERS = { "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }
local EDIT_BOX_ART = { "Left", "Mid", "Right", "FocusLeft", "FocusMid", "FocusRight" }
local TAB_ART = {
	"Left", "Middle", "Right", "ActiveLeft", "ActiveMiddle", "ActiveRight",
	"HighlightLeft", "HighlightMiddle", "HighlightRight",
}

-- How the sender's name leads the line, per chat event. Events not listed
-- keep Blizzard's own line.
local NAME_FORMAT = {
	CHAT_MSG_WHISPER_INFORM = CHAT_WHISPER_INFORM_GET, -- "To %s: "
	CHAT_MSG_BN_WHISPER_INFORM = CHAT_BN_WHISPER_INFORM_GET, -- "To %s: "
	CHAT_MSG_AFK = CHAT_AFK_GET, -- "%s is Away: "
	CHAT_MSG_DND = CHAT_DND_GET, -- "%s does not wish to be disturbed: "
	CHAT_MSG_RAID_WARNING = CHAT_RAID_WARNING_GET, -- "[Raid Warning] %s: "
}
for _, chatType in ipairs({
	"SAY", "YELL", "WHISPER", "BN_WHISPER", "CHANNEL", "GUILD", "OFFICER", "PARTY",
	"PARTY_LEADER", "RAID", "RAID_LEADER", "INSTANCE_CHAT", "INSTANCE_CHAT_LEADER",
}) do
	NAME_FORMAT["CHAT_MSG_" .. chatType] = "%s: "
end

-- The history holds the original event payload. Blizzard passes the filtered
-- payload to GetDecoratedSenderName just before writing the line. Match that
-- call to the entry by event and line ID; filters can differ by chat window.
local filteredEvent, filteredArgs
hooksecurefunc(ChatFrameUtil, "GetDecoratedSenderName", function(event, ...)
	filteredEvent = event
	filteredArgs = canaccessvalue(event) and NAME_FORMAT[event] and { ... } or nil
end)
-- Blizzard has already resolved the destination, including Battle.net
-- tokens. Keep it with the filtered arguments for this particular window.
hooksecurefunc("FCFManager_ShouldSuppressMessage", function(frame, group, target)
	if filteredArgs then
		filteredArgs.frame, filteredArgs.group, filteredArgs.target = frame, group, target
	end
end)

-- Builds the short form of a player chat line from its history entry:
--   [2. Trade - City] [Name]: hi   ->  [2] Name: hi
--   [Guild] [Name]: hi             ->  Name: hi
--   [Name] says: hi                ->  Name: hi
local function shortLine(chatFrame, entry)
	local extra = entry.extraData -- info id, access id, type id, event, event args
	if type(extra) ~= "table" or not canaccesstable(extra) then return end
	local event = extra[4]
	local nameFormat = canaccessvalue(event) and NAME_FORMAT[event]
	if not nameFormat or not filteredArgs or event ~= filteredEvent or filteredArgs.frame ~= chatFrame then
		return
	end
	local args = filteredArgs
	filteredArgs = nil
	local original = extra[5]
	if type(original) ~= "table" or not canaccesstable(original) then return end
	local text, sender, language, lineID = args[1], args[2], args[3], args[11]
	local group = args.group
	if not canaccessallvalues(text, sender, language, lineID, original[11], original[17],
		group, args.target, args[6], args[7], args[8], args[14])
		or type(text) ~= "string" or type(sender) ~= "string" or type(language) ~= "string"
		or type(lineID) ~= "number" or not group
		or original[11] ~= lineID or C_ChatInfo.IsChatLineCensored(lineID) then
		return
	end
	-- Discord guild messages have their own sender links and attachment text.
	if event == "CHAT_MSG_GUILD" then
		local discord = args[15]
		if not canaccessvalue(discord) then return end
		if discord and (not canaccesstable(discord) or not canaccessvalue(discord.userID)
			or (discord.userID and discord.userID ~= 0)) then return end
	end
	if group == "CHANNEL" and type(args[8]) ~= "number" then return end
	if group == "BN_WHISPER" and (not canaccessvalue(args[13]) or not args[13]) then return end

	text = C_StringUtil.RemoveContiguousSpaces(C_ChatInfo.ReplaceIconAndGroupExpressions(
		text, original[17], not ChatFrameUtil.CanChatGroupPerformExpressionExpansion(group)), 4)
	if args[14] then -- sent from the mobile app
		if not canaccessallvalues(entry.r, entry.g, entry.b) then return end
		text = ChatFrameUtil.GetMobileEmbeddedTexture(entry.r, entry.g, entry.b) .. text
	end
	-- A line in a language other than the reader's own is tagged with it.
	local ownLanguage = chatFrame.defaultLanguage
	if event == "CHAT_MSG_SAY" or event == "CHAT_MSG_YELL" then
		ownLanguage = chatFrame.alternativeDefaultLanguage
	end
	if language ~= "" and language ~= ownLanguage then
		text = "[" .. language .. "] " .. text
	end

	local line = text
	if group ~= "CHANNEL" or sender ~= "" then
		local name = Ambiguate(sender, group == "GUILD" and "guild" or "none")
		local guid = args[12]
		if canaccessvalue(guid) and guid and guid ~= "" then
			local ok, _, class = pcall(GetPlayerInfoByGUID, guid)
			local color = ok and canaccessvalue(class) and class and C_ClassColor.GetClassColor(class)
			if color then name = color:WrapTextInColorCode(name) end
		end
		local link
		if group == "BN_WHISPER" then
			link = GetBNPlayerLink(sender, name, args[13], lineID, group, args.target)
		else
			link = GetPlayerLink(sender, name, lineID, group, args.target)
		end
		line = nameFormat:format(ChatFrameUtil.GetPFlag(args[6], args[7], args[8]) .. link) .. text
	end
	if group == "CHANNEL" then
		line = ("|Hchannel:channel:%d|h[%d]|h "):format(args[8], args[8]) .. line
	end
	local timestamp = ChatFrameUtil.GetTimestampFormat()
	if timestamp then
		line = TimeUtil.BetterDate(timestamp, time()) .. line
	end
	return line
end

-- Blizzard's history is left exactly as Blizzard wrote it. The short form is
-- built once, when a line arrives, and kept here. It is swapped in only on
-- screen, each time Blizzard puts an entry's text on one of the window's
-- lines.
local shortLines = setmetatable({}, { __mode = "k" }) -- entry -> text to show
local hooked = {} -- lines already watched
local function showShortLine(line)
	local text = shortLines[line.messageInfo]
	if text then
		setText(line, text)
	end
end

-- Blizzard scrolls three messages per wheel click.
local function scrollOneMessage(chatFrame, delta)
	chatFrame:ScrollByAmount(delta)
end

-- Character positions are byte offsets into the rendered row's source, which
-- can include a hyperlink target. Strip markup with its tags still paired so
-- a selection that starts or ends inside a link copies only its visible label.
local function plainSpan(text, first, stop)
	if not text:find("|", 1, true) then return text:sub(first, stop - 1) end
	local plain = C_StringUtil.StripHyperlinks(text, false, true)
	if first == 1 and stop == #text + 1 then return plain end
	-- Formatting can split a literal marker across tags in the source.
	local marker = "~COPY!"
	while plain:find(marker, 1, true) do marker = "~" .. marker end
	local marked = text:sub(1, first - 1) .. marker .. text:sub(first, stop - 1) .. marker .. text:sub(stop)
	plain = C_StringUtil.StripHyperlinks(marked, false, true)
	local _, left = plain:find(marker, 1, true)
	local right = left and plain:find(marker, left + 1, true)
	if right then return plain:sub(left + 1, right - 1) end
end

local function readableSelection(frame)
	local start, startRow = frame.selectingCharacterIndex, frame.selectingVisibleLineIndex
	if not canaccessvalue(start) or not canaccessvalue(startRow) or not start or not startRow then return end
	local stop, stopRow = frame:FindCharacterAndLineIndexAtCoordinate(frame:GetScaledCursorPosition())
	if not canaccessvalue(stop) or not canaccessvalue(stopRow) or not stop or not stopRow then return end
	if startRow == stopRow and start == stop then return end

	-- Normalize both ends into reading order. Soft-wrapped rows are already
	-- one font string; only separate chat messages need a newline.
	local step = frame:GetInsertMode() == SCROLLING_MESSAGE_FRAME_INSERT_MODE_TOP and 1 or -1
	if (stopRow - startRow) * step < 0 or (startRow == stopRow and stop < start) then
		startRow, stopRow, start, stop = stopRow, startRow, stop, start
	end
	local parts = {}
	for row = startRow, stopRow, step do
		local text = frame.visibleLines[row]:GetText()
		if not canaccessvalue(text) or type(text) ~= "string" then return end
		local part = plainSpan(text, row == startRow and start or 1, row == stopRow and stop or #text + 1)
		if not part then return end
		parts[#parts + 1] = part
	end
	return table.concat(parts, "\n")
end

local COPY_DIALOG = "CHAT_COPY_TEXT"
local copyEditBoxes = {}
StaticPopupDialogs[COPY_DIALOG] = {
	text = IsMacClient() and "Press Cmd+C to copy." or "Press Ctrl+C to copy.",
	button1 = CLOSE,
	hasEditBox = true,
	editBoxWidth = 350,
	maxLetters = 0,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	EditBoxOnEscapePressed = StaticPopup_StandardEditBoxOnEscapePressed,
	OnShow = function(dialog, data)
		local editBox = dialog:GetEditBox()
		if not copyEditBoxes[editBox] then
			copyEditBoxes[editBox] = true
			-- Static popups share edit boxes. Only act on this dialog's copy key.
			editBox:HookScript("OnKeyDown", function(self, key)
				local owner = self:GetParent()
				if owner.which == COPY_DIALOG and owner:IsShown() and key == "C"
					and (IsControlKeyDown() or IsMacClient() and IsMetaKeyDown()) then
					local request = owner.data
					-- The client handles the real key before the popup is cleared.
					C_Timer.After(0, function() StaticPopup_Hide(COPY_DIALOG, request) end)
				end
			end)
		end
		editBox:SetText(data.text)
		data.text = nil
		editBox:SetFocus()
		editBox:SetCursorPosition(0)
		editBox:HighlightText()
	end,
	OnHide = function(dialog)
		dialog:GetEditBox():ClearFocus()
	end,
}

-- A new press cancels a popup that was queued by an earlier release.
local pressedFrame, pendingCopy
local function beginChatSelection(frame, button)
	if button ~= "LeftButton" then return end
	pressedFrame, pendingCopy = frame, nil
	StaticPopup_Hide(COPY_DIALOG)
end

local function finishChatSelection(frame, button)
	if button ~= "LeftButton" then return end
	local ok, text
	if pressedFrame == frame then
		pressedFrame = nil
		-- Hit testing can fail if a visible line becomes restricted mid-drag.
		ok, text = pcall(readableSelection, frame)
	end
	-- End the highlight before Blizzard's mouse-up handler attempts a copy.
	frame:ResetSelectingText()
	if not ok or not canaccessvalue(text) or not text or text == "" then return end

	local request = { text = text }
	pendingCopy = request
	C_Timer.After(0, function()
		if pendingCopy ~= request then return end
		pendingCopy = nil
		if frame:IsVisible() then StaticPopup_Show(COPY_DIALOG, nil, nil, request) end
	end)
end

local function screenTop(region)
	local top, scale = region:GetTop(), region:GetEffectiveScale()
	if canaccessvalue(top) and canaccessvalue(scale) and top then return top * scale, scale end
end

-- Blizzard snaps using offsets relative to ChatFrame1. Measure the label
-- in screen coordinates since the dock can have a different parent scale.
local selectionTop, selectionPending
local function fitSelectionToTabs()
	if InCombatLockdown() then
		if not selectionPending then
			selectionPending = true
			EventUtil.RegisterOnceFrameEventAndCallback("PLAYER_REGEN_ENABLED", function()
				selectionPending = nil
				fitSelectionToTabs()
			end)
		end
		return
	end

	local frame = ChatFrame1
	local top, scale = screenTop(frame)
	local labelTop = screenTop(ChatFrame1Tab.Text)
	if not top or not labelTop then return end
	local y = (labelTop - top) / scale + 4
	if selectionTop and math.abs(y - selectionTop) < 0.01 then return end

	frame.Selection:SetPoint("TOPLEFT", frame, "TOPLEFT", -8, y)
	-- Keep the fill's side margins and Blizzard's space below for typing.
	if not selectionTop then frame.Selection:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 8, -32) end
	selectionTop = y
	frame:UpdateClampOffsets()
end

local function setup(chatFrame)
	local name = chatFrame:GetName()

	-- Button column (channel, menu, minimize) and scrollbar.
	chatFrame.buttonFrame:SetParent(hidden)
	chatFrame.ScrollBar:SetParent(hidden)

	-- Jump-to-bottom button. It stays shown but empty: Blizzard restarts its
	-- flash animation every frame while it is not playing, and an animation
	-- on a hidden region may never count as playing.
	local jump = chatFrame.ScrollToBottomButton
	jump:EnableMouse(false)
	jump:ClearNormalTexture()
	jump.Flash:SetTexture(nil)

	-- Border edges. Blizzard only fades the ones that are shown. Its
	-- background fill is kept: it darkens while the mouse is over the window.
	for _, suffix in ipairs(CHAT_FRAME_TEXTURES) do
		if suffix ~= "Background" then
			_G[name .. suffix]:Hide()
		end
	end

	-- Edit box border. Blizzard toggles the focus half, so clear the art.
	for _, suffix in ipairs(EDIT_BOX_ART) do
		_G[name .. "EditBox" .. suffix]:SetTexture(nil)
	end

	-- Tab art, leaving the label. Blizzard toggles the selected-tab part, so
	-- clear it rather than hide it.
	local tab = _G[name .. "Tab"]
	for _, key in ipairs(TAB_ART) do
		tab[key]:SetTexture(nil)
	end

	-- Unread glow, which Blizzard shows, pulses and tints to the tab's chat
	-- colour. It is drawn 16 high along the tab's foot, where it runs up into
	-- the label, though only the lower ten rows of its image are lit. Draw
	-- just those, in the gap under the label.
	tab.glow:SetTexCoord(0, 1, 6 / 16, 1)
	tab.glow:SetHeight(6)

	-- Every tab after the first is one cell of a row of equal cells, its
	-- label centred, and Blizzard sizes the cells: it never fits a tab to a
	-- whisper name, which it may not measure. Whisper tabs differ only by an
	-- icon and a label pushed left to make room for it. Drop the icon and
	-- centre the label across the cell, whatever width the cell is given. A
	-- name too long for it ends in an ellipsis.
	if tab.conversationIcon then
		tab.conversationIcon:Hide()
		tab.Text:ClearAllPoints()
		tab.Text:SetPoint("LEFT", 5, -5)
		tab.Text:SetPoint("RIGHT", -5, -5)
		tab.Text:SetJustifyH("CENTER")
	end

	-- Blizzard insets the typed line 15px from the edit box's left edge and
	-- 13px from its right, for that border. Widen the box by the same amounts
	-- so the typed line starts and wraps exactly where the chat text does.
	-- The -2 is Blizzard's own gap below the chat frame.
	chatFrame.editBox:SetPoint("TOPLEFT", chatFrame, "BOTTOMLEFT", -15, -2)
	chatFrame.editBox:SetPoint("RIGHT", chatFrame, "RIGHT", 13, 0)

	-- Blizzard leaves the arrow keys to the game while typing unless Alt is
	-- held. Give them to the typed line: left and right move the cursor, up
	-- and down recall lines sent earlier.
	chatFrame.editBox:SetAltArrowKeyMode(false)

	chatFrame:SetMaxLines(HISTORY_LINES)
	if chatFrame:GetScript("OnMouseWheel") then -- absent if wheel scrolling is off
		chatFrame:SetScript("OnMouseWheel", scrollOneMessage)
	end

	-- Use Blizzard's drag highlight, then pass the selected text to the popup.
	chatFrame:SetTextCopyable(true)
	chatFrame:EnableMouse(true)
	chatFrame:HookScript("OnMouseDown", beginChatSelection)
	chatFrame:HookScript("OnMouseUp", finishChatSelection)

	-- Blizzard's background fill overhangs the text by 2px on the left, 15 on
	-- the right, where the scrollbar was, 3 above and 6 below. Set both sides
	-- to 8, and move the top up 3 and the bottom down 2, which leaves about
	-- 8px clear around the letters on every side. The tabs hang from the
	-- fill's top corners and move with it. The redraw below lowers the top.
	local background = chatFrame.Background
	for _, corner in ipairs(CORNERS) do
		local point, relativeTo, relativePoint, x, y = background:GetPointByName(corner)
		background:SetPoint(point, relativeTo, relativePoint, x < 0 and -8 or 8, y + (y < 0 and -2 or 3))
	end
	local _, _, _, _, fillTop = background:GetPointByName("TOPLEFT")

	local container = chatFrame.FontStringContainer
	local row, spared, trimmed
	-- Blizzard acquires font strings on layout changes, before it writes
	-- their text. Ordinary messages and scrolling reuse the same rows.
	local function watchLines()
		for _, line in ipairs(chatFrame.visibleLines) do
			if not hooked[line] then
				hooked[line] = true
				hooksecurefunc(line, "SetText", showShortLine)
			end
		end
		ruler:SetFontObject(chatFrame:GetFontObject())
		row = ruler:GetLineHeight()
	end
	watchLines()
	hooksecurefunc(chatFrame, "RefreshLayout", watchLines)

	chatFrame:AddOnDisplayRefreshedCallback(function()
		-- Rows stack upward from the bottom, and the window is rarely a whole
		-- number of rows tall. The part of a row left over at the top can
		-- hold no text. Leave it out of the window: end the background fill
		-- below it, which brings the tabs down too, and let clicks there
		-- reach the tabs. The half pixel absorbs rounding.
		local top, fits = chatFrame:GetTop(), chatFrame:GetBottom()
		if not canaccessallvalues(top, fits) or not top or not fits or row <= 0 then
			return
		end
		local spare = math.max((top - fits + 0.5) % row - 0.5, 0)
		if spare ~= spared then
			spared = spare
			background:SetPoint("TOPLEFT", chatFrame, "TOPLEFT", -8, fillTop - spare)
			background:SetPoint("TOPRIGHT", chatFrame, "TOPRIGHT", 8, fillTop - spare)
			chatFrame:SetHitRectInsets(0, 0, spare, 0)
			if chatFrame == FCFDock_GetSelectedWindow(GeneralDockManager) then fitSelectionToTabs() end
		end
		top = top - spare

		-- Rows are not all one height: an icon makes its row taller, and the
		-- topmost message may then still be cut part-way through a row. Find
		-- the top of the last message that fits whole, by measuring. Where a
		-- line's text is hidden its position is a secret value too; the walk
		-- stops there.
		for _, line in ipairs(chatFrame.visibleLines) do
			local lineTop = line:GetTop()
			if not canaccessvalue(lineTop) or not lineTop or lineTop > top + 0.5 then
				break
			end
			fits = lineTop
		end

		-- Above that, keep the whole rows of the next message and trim the
		-- clip region to hide the rest. The eighth of a row hides the tails of
		-- the letters in the row cut away, which hang that far below it.
		local trim = spare + math.max((top - fits + 0.5) % row - 0.5, 0) + row / 8
		if trim ~= trimmed then
			trimmed = trim
			container:ClearAllPoints()
			container:SetPoint("TOPLEFT", 0, -trim)
			container:SetPoint("BOTTOMRIGHT")
		end
	end)

	-- Native drag selection reads the displayed line. The history entry
	-- keeps its original text and metadata for reveal and whisper tabs.
	hooksecurefunc(chatFrame.historyBuffer, "PushFront", function(_, entry)
		shortLines[entry] = shortLine(chatFrame, entry)
	end)
end

-- CHAT_FRAMES only grows, so each window is set up exactly once.
local seen = 0
local function setupNewFrames()
	for i = seen + 1, #CHAT_FRAMES do
		setup(_G[CHAT_FRAMES[i]])
	end
	seen = #CHAT_FRAMES
end

if QuickJoinToastButton then QuickJoinToastButton:SetParent(hidden) end
setupNewFrames()
-- Whisper and pop-out windows are created on demand.
hooksecurefunc("FCF_OpenTemporaryWindow", setupNewFrames)

-- Tabs after the first sit in a scrolling strip, 1px higher than the first.
-- The strip is 31 tall with its bottom on the first tab's, and holds them 1px
-- below the centre of a child frame hung from its top. A tab is 32 tall, so
-- its centre is 16 up: 31 - 28 / 2 - 1.
GeneralDockManager.scrollFrame.child:SetHeight(28)

-- The tab row hangs from the main window's background fill. Hang it from the
-- selected window's instead: each fill ends below its own spare part of a
-- row, which differs with the window's font size.
local function anchorTabRow(dock, chatFrame)
	dock:SetPoint("BOTTOMLEFT", chatFrame.Background, "TOPLEFT")
	dock:SetPoint("BOTTOMRIGHT", chatFrame.Background, "TOPRIGHT")
	if dock == GeneralDockManager then fitSelectionToTabs() end
end
hooksecurefunc("FCFDock_SelectWindow", anchorTabRow)
local selected = FCFDock_GetSelectedWindow(GeneralDockManager)
if selected then anchorTabRow(GeneralDockManager, selected) end
EventRegistry:RegisterFrameEventAndCallback("UI_SCALE_CHANGED", function()
	RunNextFrame(fitSelectionToTabs)
end)

-- Pop-ups (a Battle.net friend coming online, voice chat) stack upward from
-- ChatAlertFrame, which Blizzard hangs above the button column: beside the
-- chat, so off screen when the chat is at the screen's edge. Lay it along the
-- top of the tab row instead. Blizzard starts the stack at its left or right
-- end, and a pop-up (250 wide) is narrower than the narrowest chat (296), so
-- either way it stays within the chat's width. Where the chat is too near the
-- top of the screen, they come down over the tabs rather than leave it.
local TOAST_HEIGHT = 50 -- SocialToastTemplate's
local function placeAlerts()
	local top = GeneralDockManager:GetTop()
	local y = top and math.min(UIParent:GetTop() - top - TOAST_HEIGHT, 0) or 0
	ChatAlertFrame:SetPoint("BOTTOMLEFT", GeneralDockManager, "TOPLEFT", 0, y)
	ChatAlertFrame:SetPoint("BOTTOMRIGHT", GeneralDockManager, "TOPRIGHT", 0, y)
end
-- Blizzard calls this whenever a pop-up shows or hides.
hooksecurefunc(ChatAlertFrame, "UpdateAnchors", placeAlerts)
placeAlerts()

-- A shift-click on a name asks the server who that is. The answer comes back
-- as system messages, which reach only the windows set to show those: unless
-- changed, the main one. Show the answer in the window that was clicked as
-- well.
local whoListener = CreateFrame("Frame")
local whoQuery, whoWindow, whoTarget, whoUntil
local function stopWho()
	if whoWindow then
		whoWindow, whoTarget, whoUntil = nil, nil, nil
		whoListener:UnregisterEvent("CHAT_MSG_SYSTEM")
	end
end

-- A modified click can also fill the Add Friend dialog. Follow the request
-- Blizzard actually sent. A subsequent /who supersedes the previous one.
hooksecurefunc(C_FriendList, "SendWho", function(query, origin)
	stopWho()
	whoQuery = origin == Enum.SocialWhoOrigin.Item and canaccessvalue(query) and query or nil
end)
hooksecurefunc("SetItemRef", function(link, _, _, frame)
	local query = whoQuery
	whoQuery = nil
	if not query or not frame or not frame.messageTypeList or not canaccessvalue(link) then return end
	if not frame.privateMessageList and tContains(frame.messageTypeList, "SYSTEM") then return end
	local name = link:match("^player[^:]*:([^:|]+)")
	local target = name and C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator(name)
	if target and query == WHO_TAG_EXACT .. target then
		whoTarget = Ambiguate(target, "none")
		whoWindow, whoUntil = frame, GetTime() + 10
		whoListener:RegisterEvent("CHAT_MSG_SYSTEM")
	end
end)

whoListener:SetScript("OnEvent", function(_, _, text)
	if not whoWindow then return end
	if GetTime() > whoUntil then return stopWho() end
	if not canaccessvalue(text) then return end
	local name = text:match("^|Hplayer:([^:|]+)")
	local count = not name and text:match("%d+")
	local total = count and WHO_NUM_RESULTS and text == WHO_NUM_RESULTS:format(tonumber(count))
	if total or (name and Ambiguate(C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator(name), "none") == whoTarget) then
		local color = ChatTypeInfo.SYSTEM
		whoWindow:AddMessage(text, color.r, color.g, color.b, color.id)
		if total then stopWho() end
	end
end)
