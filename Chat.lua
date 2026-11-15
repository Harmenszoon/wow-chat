-- Chat: small in-place enhancements to Blizzard's chat frames.

-- Frames Blizzard keeps re-showing are moved under a parent that is never
-- shown. It sits under UIParent so they keep their scale, which keeps the
-- toasts anchored to the button column where they were.
local hidden = CreateFrame("Frame", nil, UIParent)
hidden:Hide()

-- Never shown. It measures a row of text, and lends its SetText to lines
-- whose own has been hooked.
local ruler = hidden:CreateFontString()
local setText = ruler.SetText

local HISTORY_LINES = 1000 -- Blizzard keeps 128 per window

local RIGHT_CORNERS = { "TOPRIGHT", "BOTTOMRIGHT" }
local EDIT_BOX_ART = { "Left", "Mid", "Right", "FocusLeft", "FocusMid", "FocusRight" }
local TAB_ART = {
	"Left", "Middle", "Right", "ActiveLeft", "ActiveMiddle", "ActiveRight",
	"HighlightLeft", "HighlightMiddle", "HighlightRight",
}

-- How the sender's name leads the line, per chat event. Events not listed
-- keep Blizzard's own line.
local NAME_FORMAT = {
	CHAT_MSG_WHISPER_INFORM = CHAT_WHISPER_INFORM_GET, -- "To %s: "
	CHAT_MSG_RAID_WARNING = CHAT_RAID_WARNING_GET, -- "[Raid Warning] %s: "
}
for _, chatType in ipairs({
	"SAY", "YELL", "WHISPER", "CHANNEL", "GUILD", "OFFICER", "PARTY", "PARTY_LEADER",
	"RAID", "RAID_LEADER", "INSTANCE_CHAT", "INSTANCE_CHAT_LEADER",
}) do
	NAME_FORMAT["CHAT_MSG_" .. chatType] = "%s: "
end

-- Builds the short form of a player chat line from its history entry:
--   [2. Trade - City] [Name]: hi   ->  [2] Name: hi
--   [Guild] [Name]: hi             ->  Name: hi
--   [Name] says: hi                ->  Name: hi
-- The line is built from the event's own arguments, never by editing
-- Blizzard's finished text, and otherwise as Blizzard builds it. In dungeons,
-- raids and PvP the text, the sender and the sender's GUID are secret values:
-- they may be joined, formatted and passed to the functions used here, but
-- not compared, measured or searched. Keeping to that makes the result the
-- same everywhere.
local function shortLine(chatFrame, entry)
	local extra = entry.extraData -- info id, access id, type id, event, event args
	local event = extra and extra[4]
	local nameFormat = NAME_FORMAT[event]
	if not nameFormat then
		return
	end
	local args = extra[5]
	local text, sender, language, lineID = args[1], args[2], args[3], args[11]
	if C_ChatInfo.IsChatLineCensored(lineID) then
		return
	end
	-- "CHAT_MSG_PARTY_LEADER" -> "PARTY". Blizzard's record of this, kept by
	-- access id, is keyed by sender for whispers and so can itself be secret.
	local group = ChatFrameUtil.GetChatCategory(event:sub(10))

	local name = Ambiguate(sender, group == "GUILD" and "guild" or "none")
	local _, class = GetPlayerInfoByGUID(args[12])
	local color = class and C_ClassColor.GetClassColor(class)
	if color then
		name = color:WrapTextInColorCode(name)
	end

	text = C_StringUtil.RemoveContiguousSpaces(C_ChatInfo.ReplaceIconAndGroupExpressions(
		text, args[17], not ChatFrameUtil.CanChatGroupPerformExpressionExpansion(group)), 4)
	if args[14] then -- sent from the mobile app
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

	-- Blizzard's player link ends in a fourth field, the chat target, which
	-- nothing reads.
	local line = nameFormat:format(ChatFrameUtil.GetPFlag(args[6], args[7], args[8])
		.. ("|Hplayer:%s:%s:%s|h%s|h"):format(sender, lineID, group, name)) .. text
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
-- lines. Anything this addon stored in the history would mark Blizzard's own
-- code as tampered with when it reads it back, and its drag-to-copy would
-- then be refused the clipboard.
local shortLines = setmetatable({}, { __mode = "k" }) -- entry -> short form
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

-- A line an addon prints is stored marked as that addon's, and Blizzard's
-- drag-to-copy is refused the clipboard while one is on screen. Of Blizzard's
-- ways to store a line, only BackFillMessage leaves it unmarked (tested in
-- game), and it adds at the oldest end. So the whole history is put back
-- through it, newest line first.
local function restoreUnmarked(chatFrame)
	local buffer = chatFrame.historyBuffer
	local offset = chatFrame:GetScrollOffset()
	local entries = {}
	for i = 1, chatFrame:GetNumMessages() do
		entries[i] = buffer:GetEntryAtIndex(i) -- 1 is the newest
	end
	chatFrame:Clear()
	for _, entry in ipairs(entries) do
		local extra = entry.extraData
		if extra then
			chatFrame:BackFillMessage(entry.message, entry.r, entry.g, entry.b, unpack(extra, 1, extra.n))
		else
			chatFrame:BackFillMessage(entry.message, entry.r, entry.g, entry.b)
		end
	end
	-- The history now holds new entries in the same order. Carry each short
	-- form over to the entry that replaced its own.
	for i, entry in ipairs(entries) do
		shortLines[buffer:GetEntryAtIndex(i)] = shortLines[entry]
	end
	chatFrame:SetScrollOffset(offset)
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

	chatFrame:SetMaxLines(HISTORY_LINES)
	if chatFrame:GetScript("OnMouseWheel") then -- absent if wheel scrolling is off
		chatFrame:SetScript("OnMouseWheel", scrollOneMessage)
	end

	-- Blizzard's own drag-to-copy, which chat windows leave switched off.
	-- It needs the window to take mouse clicks, so clicks on the chat area
	-- no longer pass through to the world.
	chatFrame:SetTextCopyable(true)
	chatFrame:EnableMouse(true)

	-- Blizzard's background fill overhangs the text by 2px on the left and by
	-- 15 on the right, where the scrollbar was. Match the left.
	local background = chatFrame.Background
	for _, corner in ipairs(RIGHT_CORNERS) do
		local point, relativeTo, relativePoint, _, y = background:GetPointByName(corner)
		background:SetPoint(point, relativeTo, relativePoint, 2, y)
	end

	-- Blizzard redraws after every new line, scroll, resize and font change.
	local container = chatFrame.FontStringContainer
	local trimmed
	chatFrame:AddOnDisplayRefreshedCallback(function()
		-- Lines are created as the window needs them. Watch each new one, and
		-- show its short form now, since this redraw has already filled it.
		for _, line in ipairs(chatFrame.visibleLines) do
			if not hooked[line] then
				hooked[line] = true
				hooksecurefunc(line, "SetText", showShortLine)
				showShortLine(line)
			end
		end

		-- Messages stack upward from the bottom and are cut off at the
		-- window's top edge, usually part-way through a row. Find the top of
		-- the last message that fits whole. This is measured, because rows
		-- are not all one height: an icon makes its row taller. In instances
		-- a line's position can be a secret value; the walk stops there.
		local top, fits = chatFrame:GetTop(), chatFrame:GetBottom()
		if not top then
			return
		end
		for _, line in ipairs(chatFrame.visibleLines) do
			local lineTop = line:GetTop()
			if not canaccessvalue(lineTop) or not lineTop or lineTop > top + 0.5 then
				break
			end
			fits = lineTop
		end

		-- Above that, keep the whole rows of the next message and trim the
		-- clip region to hide the rest. The half pixel absorbs rounding. The
		-- eighth of a row hides the tails of the letters in the row cut away,
		-- which hang that far below it.
		ruler:SetFontObject(chatFrame:GetFontObject())
		local row = ruler:GetLineHeight()
		local trim = math.max((top - fits + 0.5) % row - 0.5, 0) + row / 8
		if trim ~= trimmed then
			trimmed = trim
			container:ClearAllPoints()
			container:SetPoint("TOPLEFT", 0, -trim)
			container:SetPoint("BOTTOMRIGHT")
		end
	end)

	-- As each line arrives, build its short form, and note whether an addon
	-- wrote it. The history is put right just before a selection starts, on
	-- the left button: a window's own mouse-down script runs ahead of
	-- Blizzard's. Lines from before this addon loaded are unknown, so the
	-- first click always does it.
	local marked = true
	hooksecurefunc(chatFrame.historyBuffer, "PushFront", function(_, entry)
		marked = marked or not issecurevariable(entry, "message")
		shortLines[entry] = shortLine(chatFrame, entry)
	end)
	chatFrame:HookScript("OnMouseDown", function(_, button)
		if marked and button == "LeftButton" then
			marked = false
			restoreUnmarked(chatFrame)
		end
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

QuickJoinToastButton:SetParent(hidden)
setupNewFrames()
-- Whisper and pop-out windows are created on demand.
hooksecurefunc("FCF_OpenTemporaryWindow", setupNewFrames)

-- Tabs after the first sit in a scrolling strip, 1px higher than the first.
-- The strip is 31 tall with its bottom on the first tab's, and holds them 1px
-- below the centre of a child frame hung from its top. A tab is 32 tall, so
-- its centre is 16 up: 31 - 28 / 2 - 1.
GeneralDockManager.scrollFrame.child:SetHeight(28)

-- Edit Mode pads the main chat frame's selection box for the button column
-- and scrollbar, and clamps the frame to the screen by it. With those gone,
-- pull the sides in close to the text. The 60 and -32 are Blizzard's own
-- margins for the tabs and edit box; SetPoint replaces the whole anchor.
ChatFrame1.Selection:SetPoint("TOPLEFT", -5, 60)
ChatFrame1.Selection:SetPoint("BOTTOMRIGHT", 5, -32)
