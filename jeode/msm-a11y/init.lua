-- ===========================================================================
-- MSM Accessibility mod - Lua layer (runs under Jeode's sandboxed mod env)
--
-- The native half (a11y.dll) registers these game globals via Jeode's
-- register_global:  a11y_speak(text[,interrupt]), a11y_silence(),
-- a11y_is_active() -> bool, a11y_log(text).
--
-- This file does the game-facing work: read the HUD on demand and announce
-- game notifications/popups, using the *verified* game.* API (see the
-- game-lua-api notes: HUD counter text, playerLevel, getPopUp, etc.).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Resolve the speech function.
--
-- OPEN QUESTION to confirm on first run: native register_global installs into
-- the game's Lua state. This mod's init.lua runs in Jeode's *sandbox* env, so
-- `a11y_speak` may or may not be directly visible here. We probe a few places;
-- if it stays nil, uncomment the queue_lua bridge in jeode_a11y.c (it copies
-- the functions into game _G) and/or expose them via jeode.registerGlobal.
-- ---------------------------------------------------------------------------
local function resolve(name)
    local v = rawget(_G, name)
    if type(v) == "function" then return v end
    -- try the thread's real global table (game state) if reachable
    local ok, genv = pcall(getfenv, 0)
    if ok and type(genv) == "table" and type(genv[name]) == "function" then
        return genv[name]
    end
    return nil
end

local speak         = resolve("a11y_speak")
local silence       = resolve("a11y_silence")
local is_active     = resolve("a11y_is_active")
local a11y_log      = resolve("a11y_log") or function() end
local clickFraction = resolve("a11y_click_fraction")   -- native mouse click
local tutStepFn     = resolve("a11y_tutorial_step")    -- native: returns (step,max)

if not speak then
    a11y_log("init.lua: a11y_speak NOT visible from mod sandbox - see bridge note")
    speak = function() end  -- no-op so the rest of the file is safe to load
else
    a11y_log("init.lua: speech function bound")
end

-- Small helper so accidental nils never raise inside the game loop.
local function say(text, interrupt)
    if text and text ~= "" then speak(tostring(text), interrupt and true or false) end
end

-- ---------------------------------------------------------------------------
-- 2. HUD readers  (verified approach: read the counter widget's text)
--    Ethereal islands use ShardCounter instead of CoinCounter.
-- ---------------------------------------------------------------------------
local LOC = game.getLocalizedText

local function counterText(name)
    local ok, hud = pcall(game.getHUD)
    if not ok or not hud then return nil end
    local widget = hud[name]
    if not widget then return nil end
    local ok2, str = pcall(function() return widget.Text("text"):GetString() end)
    if ok2 then return str end
    return nil
end

local function readCoins()    return counterText("CoinCounter") or counterText("ShardCounter") end
local function readDiamonds() return counterText("DiamondCounter") end
local function readFood()     return counterText("FoodCounter") end

local function readLevel()
    local ok, lvl = pcall(game.playerLevel)
    if ok then return lvl end
    return nil
end

-- Reject anything that isn't a real, speakable name (objects, empty, etc.)
local function humanName(v)
    if v == nil then return nil end
    local s = tostring(v)
    if s == "" then return nil end
    if s:find("userdata") or s:find("table:") or s:find("function:") then return nil end
    return s
end

-- UI stores localization KEYS (e.g. "MAIN_MENU_EXIT", "NO_GOALS_LEFT"); the game
-- localizes them at render time. Speaking the raw key is gibberish, so run any
-- ALL_CAPS_UNDERSCORE key through LOC to get real words. Non-key strings (normal
-- text, numbers like "1,861") pass through unchanged.
local function localize(s)
    if s == nil then return nil end
    s = tostring(s)
    if s == "" then return nil end
    if s:find("^[A-Z0-9_]+$") and s:find("%a") then
        for _, fn in ipairs({ function() return LOC(s) end, function() return game.getLocalizedText(s) end }) do
            local ok, t = pcall(fn)
            if ok and t then
                local h = tostring(t)
                if h ~= "" and h ~= s then return h end
            end
        end
        -- An internal key with no translation ("M_C_LVL_4") is noise, not a
        -- label: drop it so callers fall back to something speakable. Plain
        -- capitalised words ("OPTIONS") are real button text and are kept.
        if s:find("_") then return nil end
    end
    return s
end

-- Strip colour/markup tags (e.g. <c=#6efa05>) and localize bare keys.
local function cleanText(s)
    if not s then return nil end
    s = tostring(s):gsub("<[^>]*>", ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if s == "" then return nil end
    return localize(s)
end

-- Speech joining. Game text often ends in its own punctuation ("...island?"),
-- so add a full stop only where one is missing: no "?." or "..".
local function trimEnd(s) return (tostring(s):gsub("[%s%.,;:]+$", "")) end
local function endsSentence(s) return tostring(s):find("[%.!?]%s*$") ~= nil end
local function joinSentences(parts)
    local out = ""
    for _, p in ipairs(parts) do
        if p and p ~= "" then
            if out ~= "" then out = out .. (endsSentence(out) and " " or ". ") end
            out = out .. p
        end
    end
    return out
end
-- "1. First, 2. Second" style list for screen readers: each item trimmed of
-- trailing punctuation, numbered, and ended with a full stop.
local function numberedList(items)
    local out = {}
    for i, it in ipairs(items) do out[#out + 1] = i .. ". " .. trimEnd(it) .. "." end
    return table.concat(out, " ")
end

local function readIsland()
    -- Strategy 1 (proven on 5.4): island id -> name key -> localized text.
    local ok, r = pcall(function() return LOC(game.islandName(game.currentIsland())) end)
    r = ok and humanName(r) or nil
    if r then return r end

    -- Strategy 2: island type enum -> localized.
    ok, r = pcall(function() return LOC(game.currentIslandType()) end)
    r = ok and humanName(r) or nil
    if r then return r end

    -- Strategy 3: ask the active Island object for its type/name directly.
    ok, r = pcall(function()
        local isl = game.player():getActiveIsland()
        if not isl then return nil end
        for _, m in ipairs({ "getType", "getName", "name", "type" }) do
            if type(isl[m]) == "function" then
                local v = isl[m](isl)
                if v ~= nil then return LOC(v) end
            end
        end
        return nil
    end)
    return ok and humanName(r) or nil
end

-- Full HUD summary, spoken on demand (bind to a hotkey / call from console).
local function announceHud()
    local parts = {}
    local lvl = readLevel();      if lvl then parts[#parts+1] = "Level " .. tostring(lvl) end
    local isl = readIsland();     if isl then parts[#parts+1] = tostring(isl) end
    local coins = readCoins();    if coins then parts[#parts+1] = coins .. " coins" end
    local dia = readDiamonds();   if dia then parts[#parts+1] = dia .. " diamonds" end
    local food = readFood();      if food then parts[#parts+1] = food .. " food" end
    if #parts == 0 then say("HUD not available", true)
    else say(table.concat(parts, ", "), true) end
end

-- ---------------------------------------------------------------------------
-- 3. Automatic announcements
--    game.displayNotification is a verified, real call -> speak toasts.
-- ---------------------------------------------------------------------------
if type(game.displayNotification) == "function" then
    local orig_notify = game.displayNotification
    game.displayNotification = function(msg, ...)
        say(localize(msg), false)
        return orig_notify(msg, ...)
    end
    a11y_log("patched game.displayNotification")
end

-- Confirmation dialogs (yes / no) get their question from the caller. Keep it
-- so the dialog's announcement can read it even when its label isn't readable.
local lastConfirmation = { text = nil, t = -100 }
if type(game.displayConfirmation) == "function" then
    local orig_confirm = game.displayConfirmation
    game.displayConfirmation = function(id, msg, ...)
        pcall(function()
            lastConfirmation.text = cleanText(msg)
            lastConfirmation.t = os.clock()
        end)
        return orig_confirm(id, msg, ...)
    end
    a11y_log("patched game.displayConfirmation")
end

-- ---------------------------------------------------------------------------
-- Popup / menu announcements  (EVENT-DRIVEN, safe)
--
-- The game opens dialogs with game.pushPopUp(id) (verified in decompiled
-- scripts: game.pushPopUp("island_select") etc.). We wrap it and announce
-- INSIDE that call -- the game's own execution context, where the freshly
-- built popup is valid. This is the crash-safe replacement for the old poller
-- that deref'd stale popups during transitions. Everything is pcall-guarded so
-- a weird popup can never crash the game.
-- ---------------------------------------------------------------------------

-- Common MSM popup button element names (from decompiled scripts + M1 probe).
local POPUP_BTN_PROBE = {
    "OkayButton","OKButton","OkButton","ContinueButton","Continue",
    "YesButton","NoButton","CloseButton","CancelButton","ConfirmButton","AcceptButton",
    "DeclineButton","BuyButton","PurchaseButton","CollectButton","CollectAllButton",
    "ClaimButton","SkipButton","WatchButton","ShareButton","RetryButton","NextButton",
    "PrevButton","BackButton","StartButton","PlayButton","DoneButton","SellButton",
    "FeedButton","HatchButton","PlaceButton","UpgradeButton","InfoButton","HelpButton",
    "SettingsButton","ExitButton","QuitButton","GoButton",
}

-- Read a label from a UI element: try elem.Text('text') then elem('text').
local function elementText(e)
    if not e then return nil end
    -- A hidden caption is a leftover (template default "Meebs are cute" on
    -- picture items, "Monster Hunter Joe" on empty friend cards): skip it.
    local hidden = false
    pcall(function() hidden = e.Text("visible"):GetInt() == 0 end)
    if hidden then return nil end
    local ok, t = pcall(function() return e.Text("text"):GetString() end)
    if not (ok and t and #tostring(t) > 0) then
        ok, t = pcall(function() return e("text"):GetString() end)
    end
    -- Context bar buttons (template_barbutton) keep their caption here.
    if not (ok and t and #tostring(t) > 0) then
        ok, t = pcall(function() return e.ButtonLabel("text"):GetString() end)
    end
    if not (ok and t and #tostring(t) > 0) then
        ok, t = pcall(function() return e("ButtonLabelText"):GetString() end)
    end
    if ok and t and #tostring(t) > 0 then
        t = tostring(t):gsub("<[^>]*>", ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
        if t ~= "" then return localize(t) end
    end
    return nil
end

-- Text of an element's visible descendants, for list rows whose label lives in
-- children (bakery food: name, amount and time, price).
local function descendantText(el, depth, parts)
    parts = parts or {}
    if depth > 3 or #parts >= 4 then return parts end
    local kids = nil; pcall(function() kids = el:elements() end)
    if not kids then return parts end
    local n = 0; pcall(function() n = kids:size() end)
    for i = 0, n - 1 do
        if #parts >= 4 then break end
        local c = nil; pcall(function() c = kids[i] end)
        if c then
            local vis = 1; pcall(function() vis = c.Text("visible"):GetInt() end)
            local t = vis ~= 0 and elementText(c) or nil
            if t and not t:find("^[%p%s]*$") then parts[#parts + 1] = t end
            descendantText(c, depth + 1, parts)
        end
    end
    return parts
end

-- Humanize a popup id like "popup_breed_warning" -> "breed warning".
local function popupDisplayName(id)
    if id == nil then return "dialog" end
    local s = tostring(id)
    if s == "social" then return "Friends" end
    local ok, loc = pcall(function() return LOC(s) end)
    local h = ok and humanName(loc) or nil
    if h and h ~= s then return h end
    return (s:gsub("^popup_", ""):gsub("_", " "))
end

-- The popup's heading, if it has one.
-- Find a descendant element by name (breadth-first, a few levels deep).
-- Screens opened from C++ hand us their outer menu root, so the dialog's
-- Title / Notification elements sit a couple of levels below it.
local function findNamed(root, name, maxDepth)
    local level = { root }
    for _ = 0, maxDepth or 4 do
        local nextLevel = {}
        for _, el in ipairs(level) do
            -- Compare child element names: el[name] could also return one of
            -- el's components (every button has a "Text" component).
            local kids = nil; pcall(function() kids = el:elements() end)
            local n = 0; pcall(function() n = kids:size() end)
            for i = 0, n - 1 do
                local c = nil; pcall(function() c = kids[i] end)
                if c then
                    local cn = nil; pcall(function() cn = c:name() end)
                    if cn == name then return c end
                    nextLevel[#nextLevel + 1] = c
                end
            end
        end
        if #nextLevel == 0 then return nil end
        level = nextLevel
    end
    return nil
end

-- Text of a named label, if it is showing (hidden placeholders like the
-- newsflash "TITLE" or a confirmation's "..." are skipped).
local function shownText(root, name)
    local el = findNamed(root, name)
    if not el then return nil end
    local vis = 1
    pcall(function() vis = el.Text("visible"):GetInt() end)
    if vis == 0 then return nil end
    local t = elementText(el)
    if not t or t:find("^[%.%s]*$") then return nil end
    return t
end

local TITLE_NAMES = { "Title", "TitleText", "TitleLabel", "Header" }
-- Left / Center / Right: the numbered steps of "How it works" screens.
local BODY_NAMES = { "Text", "Message", "MessageText", "Body", "Description", "Desc", "Notification", "Notification2",
                     "Left", "Center", "Right" }

local function popupTitle(popup)
    if not popup then return nil end
    for _, nm in ipairs(TITLE_NAMES) do
        local t = shownText(popup, nm)
        if t then return t end
    end
    return nil
end

-- The popup's body / message text (everything that isn't the heading).
local function popupBody(popup)
    if not popup then return nil end
    local parts = {}
    for _, nm in ipairs(BODY_NAMES) do
        local t = shownText(popup, nm)
        if t and t ~= parts[#parts] then parts[#parts + 1] = t end
    end
    if #parts > 0 then return joinSentences(parts) end
    return nil
end

-- Is an element visible / clickable (has a Touch child)?
local function isVisible(el)
    local vis = true
    pcall(function() if el.isVisible == false then vis = false end end)
    -- Buttons hidden with setInvisible: every sprite and the caption off.
    -- (The game can switch such a button's touch back on, as on empty
    -- friend cards, so touch alone doesn't say it is showing.)
    if vis then
        pcall(function()
            if el.UpSprite("visible"):GetInt() == 0 and el.DownSprite("visible"):GetInt() == 0
                and el.Text("visible"):GetInt() == 0 then vis = false end
        end)
    end
    return vis
end
-- Has a Touch component that the game hasn't switched off (hidden context bar
-- buttons and tutorial-blocked controls have Touch "enabled" = 0).
local function isClickable(el)
    local hit = false
    pcall(function() if el.Touch ~= nil then hit = true end end)
    if not hit then return false end
    local en = 1
    pcall(function() en = el.Touch("enabled"):GetInt() end)
    return en ~= 0
end
local function elementName(el)
    local nm = nil
    pcall(function() nm = tostring(el:name()) end)
    return nm
end

-- Friendly names for known island/HUD controls (element name -> spoken label).
-- Counters get their live value appended.
local FRIENDLY = {
    IslandTitleBG = "Island name",
    GoalsButton = "Goals", RankButton = "Rank", ActivityButton = "Activity",
    StickerbookButton = "Sticker book", ViewButton = "Menu", ProfilePic = "Profile",
    EncoreBar = "Encore", Handle = "More counters",
    CoinCounter = "Coins", DiamondCounter = "Diamonds", FoodCounter = "Food",
    MedalCounter = "Medals", WildcardCounter = "Wildcards", KeyCounter = "Keys",
    RelicCounter = "Relics", StarCounter = "Star power",
    BattleButton = "Battle", DailyLoginButton = "Daily login", CalendarButton = "Calendar",
    ShowAll = "Show all", Featured = "Featured",
}
-- Names that are decoration/containers/backgrounds -- never a navigable control.
local function isChrome(name)
    if not name then return true end
    return name:find("BG$") or name:find("Backing") or name:find("Bracket")
        or name:find("^Xp") or name:find("Notification") or name:find("Indicator")
        or name:find("Anim") or name:find("Sprite") or name:find("^debug")
        or name:find("ScrollMarker") or name:find("HelpArrow") or name:find("Faded")
        or name:find("Entries$") or name:find("^Panel") or name:find("^Tray")
        or name:find("^Timer") or name:find("RewardBar") or name:find("EventType")
        or name:find("^Block$") or name:find("Fader")
end

-- Decide if a clickable element is a real, speakable control. Returns its label,
-- or nil to skip. FRIENDLY names always win (chrome check bypassed for those).
-- The bar's currency counters (currency_counter_0/1/2): coins (shards on
-- ethereal islands), diamonds, food.
local function currencyCounterName(name)
    local n = name and name:match("^currency_counter_(%d+)$")
    if not n then return nil end
    if n == "0" then
        local ethereal = false
        pcall(function() ethereal = game.player():getActiveIsland():isEtherealIsland() and true or false end)
        return ethereal and "Shards" or "Coins"
    end
    return ({ ["1"] = "Diamonds", ["2"] = "Food" })[n] or "Currency"
end

-- Friends screen (social.xml, template_social_card, template_topislandsentry_new).
-- Its buttons are icons whose meaning comes from the sprite or the parent.
-- Returns label, true (final: no row context added) or nil.
local controlLabel
do
local SOCIAL_SORT = {
    FilterFavourites = "Show favourites only", FilterTorch = "Show unlit torches only",
    SortAlpha = "Sort by name", SortActivity = "Sort by last login",
    SortLevel = "Sort by level", SortTorches = "Sort by torches",
}
local BOOK_FILTERS = {
    MonsterSingleGeneFilter = "one element", MonsterDoubleGeneFilter = "two elements",
    MonsterTripleGeneFilter = "three elements", MonsterQuadGeneFilter = "four elements",
    MonsterFiveGeneFilter = "five elements", MonsterSpecialFilter = "special monsters",
}
local CARD_ICONS = {
    button_light_torch = "Light torch", button_light_torch_highlight = "Light torch",
    keys = "Send key", button_yes = "Accept request", button_no = "Decline request",
}
local function comp(el, c, var)
    local v = nil
    pcall(function() v = el:C(c)(var or "text"):GetString() end)
    if v then v = cleanText(localize(v) or v) end
    if v == "" then v = nil end
    return v
end
local function parentOf(el)
    local p = nil; pcall(function() p = el:parent() end)
    return p
end
local function cardSummary(card)
    local parts = {}
    local full = nil
    pcall(function() full = card("DisplayNameText"):GetString() end)
    if full == "" then full = nil end
    parts[#parts + 1] = full or elementText(findNamed(card, "DisplayName", 1)) or "Friend"
    local pic = findNamed(card, "ProfilePic", 1)
    local lvl = pic and elementText(findNamed(pic, "Level", 1))
    if lvl then parts[#parts + 1] = "level " .. lvl end
    local act = elementText(findNamed(card, "Activity", 1))
    if act then parts[#parts + 1] = act end
    return table.concat(parts, ", ")
end
local function cardShown(card)
    local vis = 0
    pcall(function() vis = card:C("bg")("visible"):GetInt() end)
    return vis ~= 0
end
-- The open letter in the Inbox (mail.xml CurrentSender / CurrentMessage /
-- AttachmentDetails): text components on plain elements, so no button reads it.
local function mailMessage(el)
    local parts = {}
    local sender = findNamed(el, "CurrentSender", 1)
    local msg = findNamed(el, "CurrentMessage", 1)
    local att = findNamed(el, "AttachmentDetails", 1)
    local function add(e, c, prefix)
        if not e then return end
        local v = 0
        pcall(function() v = e:C(c)("visible"):GetInt() end)
        local t = v ~= 0 and comp(e, c) or nil
        if t then parts[#parts + 1] = (prefix or "") .. t end
    end
    add(sender, "Text", "From ")
    add(msg, "Text")
    add(att, "Name", "Attachment: ")
    add(att, "Expiry")
    if #parts == 0 then return nil end
    return table.concat(parts, ". ")
end
-- A Book of Monsters entry (BOMEntry.lua): only a portrait, so describe it
-- from its MonsterID the way BOMEntry:Refresh decides how to draw it.
local function bookEntry(e)
    local id, shown, filtered = nil, true, false
    pcall(function() id = e.MonsterID end)
    pcall(function() shown = e.visible ~= false end)
    pcall(function() filtered = e.FilteredOut == true end)
    if not id or id == 0 or not shown then return nil end
    local name = nil
    pcall(function() name = cleanText(LOC(game.getMonsterData(id):name())) end)
    local parts = { name or "Unknown monster" }
    pcall(function()
        if game.isSeasonal(id) then parts[#parts + 1] = "seasonal"
        elseif game.isEpic(id) then parts[#parts + 1] = "epic"
        elseif game.isRare(id) then parts[#parts + 1] = "rare" end
    end)
    local owned, avail, unlock, lvl = false, false, nil, nil
    pcall(function() owned = game.hasOrHasEverHadMonsterOnBookOfMonstersIsland(id) == true end)
    pcall(function() avail = game.monsterIsAvail(id, false) or game.monsterIsAvail(id, true) end)
    pcall(function() unlock = game.monsterUnlockLevel(id); lvl = game.playerLevel() end)
    if owned then parts[#parts + 1] = "collected"
    elseif not avail then parts[#parts + 1] = "not collected, not available now"
    elseif unlock and lvl and lvl < unlock then parts[#parts + 1] = "not collected, unlocks at level " .. unlock
    else parts[#parts + 1] = "not collected" end
    if filtered then parts[#parts + 1] = "filtered out" end
    return table.concat(parts, ", ")
end
-- "You received:" (popup_store_bundle_rewards): Contents/entryN/NameFrame.
local function rewardList(root)
    local out = {}
    local contents = root and findNamed(root, "Contents", 5)
    local kids = nil; pcall(function() kids = contents:elements() end)
    local n = 0; pcall(function() n = kids:size() end)
    for i = 0, n - 1 do
        local c = nil; pcall(function() c = kids[i] end)
        local t = c and elementText(findNamed(c, "NameFrame", 1))
        if t then out[#out + 1] = t end
    end
    return out
end
-- Breeding (breeding_v2): two lists, LeftMonsterSelect ("Monster 1") and
-- RightMonsterSelect ("Monster 2"), of List/entryN rows. A picked row's Bg
-- turns yellow (BreedingMonsterListEntry.SetSelected).
local BREED_SIDES = { LeftMonsterSelect = "Monster 1", RightMonsterSelect = "Monster 2" }
local BREED_OTHER = { LeftMonsterSelect = "RightMonsterSelect", RightMonsterSelect = "LeftMonsterSelect" }
local function breedSideOf(el)
    local cur = el
    for _ = 1, 3 do
        cur = parentOf(cur)
        local nm = cur and elementName(cur)
        if nm and BREED_SIDES[nm] then return cur, nm end
    end
    return nil
end
local function breedSelected(entry)
    local s = ""
    pcall(function() s = findNamed(entry, "Bg", 1):C("Sprite")("spriteName"):GetString() end)
    return tostring(s):find("yellow") ~= nil
end
local function breedName(entry)
    return elementText(findNamed(entry, "MonsterName", 1)) or elementText(findNamed(entry, "MonsterSpecies", 1))
end
-- The picked monster's name in one side's list, if any.
local function breedPick(side)
    local list = side and findNamed(side, "List", 1)
    local kids = nil; pcall(function() kids = list:elements() end)
    local n = 0; pcall(function() n = kids:size() end)
    for i = 0, n - 1 do
        local c = nil; pcall(function() c = kids[i] end)
        if c and isVisible(c) and breedSelected(c) then return breedName(c) or "a monster" end
    end
    return nil
end
-- Both picks on the breeding screen: monster 1, monster 2 (either may be nil).
local function breedPicks(root)
    local l, r = findNamed(root, "LeftMonsterSelect", 4), findNamed(root, "RightMonsterSelect", 4)
    return breedPick(l), breedPick(r), findNamed(root, "HeartButton", 4)
end
FRIENDLY.__social = { cardShown = cardShown, cardSummary = cardSummary, mailMessage = mailMessage,
                      bookEntry = bookEntry, rewardList = rewardList, breedPicks = breedPicks,
                      BREED_SIDES = BREED_SIDES }

local function socialLabel(el, name)
    if not name then return nil end
    -- Tabs keep their caption in a "Label" component (Friends, profile editor).
    if name:find("^Tab%u") then
        local t = comp(el, "Label") or elementText(el)
            or name:gsub("^Tab", ""):gsub("(%l)(%u)", "%1 %2")
        return t .. " tab", true
    end
    -- HUD eye button: hides the whole interface to view the island.
    local sprite = name == "ViewButton" and comp(el, "Sprite", "spriteName")
    if sprite == "button_show_hud" then return "Show menus (view mode is on)", true end
    if sprite == "button_hide_hud" then return "Hide menus (view mode)", true end
    local p = parentOf(el)
    local pn = p and elementName(p)
    -- Map: the selected island's arrows and GO; the alert buttons at the top.
    if (name == "LeftButton" or name == "RightButton") and pn == "Main" then
        return name == "LeftButton" and "Previous island" or "Next island", true
    end
    if name == "ActivateButton" and pn == "Main" then
        local island = elementText(findNamed(p, "IslandName", 1))
        return (elementText(el) or "Go") .. (island and (", travel to " .. island) or ""), true
    end
    -- Promo tray (PromoCenterItem_<id>): a picture plus a countdown. Name the
    -- offer from its promo data (PromoCenter.lua's DebugPrintAllPromoInfo fields).
    if name == "Button" and pn and pn:find("^PromoCenterItem_") then
        local parts = {}
        local promo = nil; pcall(function() promo = p.promo end)
        local function field(k)
            local v = nil
            pcall(function() v = promo[k] end)
            if type(v) ~= "string" or v == "" then return nil end
            v = cleanText(localize(v) or v)
            return (v and v ~= "") and v or nil
        end
        local title = field("storeItemTitle") or field("storeItemName")
        if not title then
            -- Offers shown as an ad: the ad's own title.
            pcall(function()
                local ad = game.nativePlacement(promo.placement):getAd(0)
                title = cleanText(ad:getTitle())
            end)
        end
        parts[1] = "Offer" .. (title and title ~= "" and (": " .. title) or "")
        local disc = field("discountText")
        if disc then parts[#parts + 1] = disc end
        local left = elementText(el)
        if left then parts[#parts + 1] = left .. " left" end
        return table.concat(parts, ", "), true
    end
    -- Goal rows (named by goal id): the arrow that shows where to do it. Not
    -- final: the goal's text and rewards are added after.
    if name == "HelpArrow" and pn and pn:find("^%d+$") then return "Show me", false end
    -- HUD Encore button: the event's points and time left.
    if name == "EncoreBar" then
        local parts = { "Encore event" }
        local pts = elementText(findNamed(el, "RewardBar", 1))
        local a, b = (pts or ""):match("(%d+)%s*/%s*(%d+)")
        if a then parts[#parts + 1] = a .. " of " .. b .. " points" elseif pts then parts[#parts + 1] = pts end
        local left = elementText(findNamed(el, "Timer", 1))
        if left then parts[#parts + 1] = left .. " left" end
        return table.concat(parts, ", "), true
    end
    local MAP_ALERTS = { SeasonalAlertButton = "Seasonal event", SaleAlertButton = "Sale",
                         NotificationAlertButton = "Notifications" }
    if MAP_ALERTS[name] then return MAP_ALERTS[name], true end
    -- Hatching fanfare: "The egg is ready! Click it to crack it open!" The egg
    -- needs 7 taps (MonsterHatchFanfare.lua NUM_CRACK_TAPS); Enter taps it
    -- until it opens (nav.crackEgg). In the tutorial there may be no Skip
    -- button, so this is the way on.
    if name == "EggImage" then return "Egg, press Enter to crack it open", true end
    -- The full-screen "Click to continue" area (rewards, card packs, the new
    -- island fanfare), shown only while that caption is showing.
    if (name == "Fade" or name == "TouchBlocker") and p then
        for _, t in ipairs(descendantText(p, 0)) do
            if t:lower():find("continue") then return "Continue", true end
        end
    end
    -- Breeding list rows: name, species, whether picked, and who they'd breed with.
    if name:find("^entry%d+$") and pn == "List" then
        local side, sideName = breedSideOf(el)
        if side then
            local parts = { breedName(el) or "Monster" }
            local species = elementText(findNamed(el, "MonsterSpecies", 1))
            if species and species ~= parts[1] then parts[#parts + 1] = species end
            local feed = findNamed(el, "feed_overlay", 1)
            local need = feed and isVisible(feed) and elementText(feed)
            if need then parts[#parts + 1] = need end
            if breedSelected(el) then
                parts[#parts + 1] = "selected"
            else
                local other = breedPick(findNamed(parentOf(side), BREED_OTHER[sideName], 1))
                if other then parts[#parts + 1] = "breed with " .. other end
            end
            return table.concat(parts, ", "), true
        end
    end
    -- Inbox rows (template_mailentry / template_newsentry): title and sender
    -- live in the row's vars.
    if name == "ViewButton" and pn and pn:find("^mail_%d") then
        local parts = { "View" }
        local function var(n)
            local v = nil; pcall(function() v = p(n):GetString() end)
            v = v and cleanText(v)
            return v
        end
        local title = var("title") or var("shortTitle")
        if title then parts[#parts + 1] = title end
        local sender = var("sender")
        if sender then parts[#parts + 1] = "from " .. sender end
        return table.concat(parts, ", "), true
    end
    -- Profile editor: picture items have no caption, only a sprite.
    if name:find("^item%d+$") and pn == "Panel" then
        local t = elementText(el)
        if not t then
            local s = comp(el, "Sprite", "spriteName")
            s = s and s:match("([^/]+)$")
            if s then
                s = s:gsub("%.%w+$", ""):gsub("^__BUILTIN__WHITE_TEXTURE$", "colour")
                t = s:gsub("_", " "):gsub("(%l)(%u)", "%1 %2")
            end
        end
        local sel = false
        pcall(function() sel = el:C("SelectedSprite")("visible"):GetInt() ~= 0 end)
        return (t or "item") .. (sel and ", selected" or ""), true
    end
    -- Book of Monsters: collected counters and element filters.
    local rarity = name:match("^Collected(%u%l+)$")
    if rarity then
        local t = elementText(el) or ""
        local a, b = t:match("(%d+)%s*/%s*(%d+)")
        return rarity .. (a and (", " .. a .. " of " .. b .. " collected") or (", " .. t)), true
    end
    if name == "FilterButton" and pn and BOOK_FILTERS[pn] then
        local on = false
        pcall(function() on = el.isSelected == true end)
        return "Filter: " .. BOOK_FILTERS[pn] .. (on and ", on" or ", off"), true
    end
    if name == "EditIcon" then return "Edit display name", true end
    if name == "DisplayName" and pn == "Card" then
        return "Display name, " .. (elementText(el) or "") .. ", edit", true
    end
    if name == "FilterButton" and pn and SOCIAL_SORT[pn] then
        return SOCIAL_SORT[pn], true
    end
    if name == "CopyIdButton" then
        local code = p and elementText(p)
        return "Copy friend code" .. (code and (", " .. code) or ""), true
    end
    if pn and pn:find("^cardItem%d") and (name == "SmallLeftButton" or name == "SmallRightButton" or name == "LargeButton") then
        local action = elementText(el)
        if not action then
            local sprite = comp(el, "Overlay", "spriteName")
            action = sprite and CARD_ICONS[sprite] or name:gsub("Button$", "")
        end
        local off = false
        pcall(function() off = el.enabled == false end)
        return action .. ", " .. cardSummary(p) .. (off and ", unavailable" or ""), true
    end
    if name == "FavoriteToggleButton" and pn and pn:find("^cardItem%d") then
        local s = comp(el, "Sprite", "spriteName")
        return (s == "favoritestar" and "Favourite, on" or "Favourite, off") .. ", " .. cardSummary(p), true
    end
    if name == "VisitButton" and pn and pn:find("^topIslandEntry%d") then
        local parts = { "Visit" }
        local rank = comp(p, "Rank")
        if rank then parts[#parts + 1] = "rank " .. rank end
        parts[#parts + 1] = comp(p, "UserName")
        parts[#parts + 1] = comp(p, "IslandName")
        return table.concat(parts, ", "), true
    end
    return nil
end

controlLabel = function(el, name)
    local special, final = socialLabel(el, name)
    if special then return special, final end
    local friendly = name and (FRIENDLY[name] or currencyCounterName(name))
    if friendly then
        local t = elementText(el)           -- append counter value if present
        if t and not friendly:find(t, 1, true) then return friendly .. ", " .. t end
        return friendly
    end
    -- Real visible text makes it a genuine control (popup buttons like "Show All").
    local t = elementText(el)
    if t then return t end
    -- Names ending in Button are controls even without text.
    if name and name:find("Button$") and not isChrome(name) then
        return (localize(name) or name):gsub("Button$", "")
    end
    if isChrome(name) then return nil end
    -- Icon-only context bar buttons: name them after the action they run.
    local fn = nil; pcall(function() fn = el("FunctionName"):GetString() end)
    if fn and fn ~= "" then
        return (fn:gsub("^show_", ""):gsub("_", " "))
    end
    -- List rows: label from their children.
    local parts = descendantText(el, 0)
    if #parts > 0 then return table.concat(parts, ", ") end
    return nil                              -- background / container: skip
end
end -- do (controlLabel)

-- Goal rows (template_goalentry): a bare "Collect" says nothing about which
-- goal it pays out. Name the goal and its rewards, read from the row itself
-- (GoalDesc text, rewardEntry<RewardId> elements with a RewardAmount var).
local REWARD_WORDS = {
    { "RewardCoins", "coins" }, { "RewardDiamonds", "diamonds" }, { "RewardFood", "food" },
    { "RewardXp", "XP" }, { "RewardShards", "shards" }, { "RewardKeys", "keys" },
    { "RewardRelics", "relics" }, { "RewardStarpower", "starpower" }, { "RewardEntity", nil },
}

-- The goal's text: a GoalDesc text component on the row itself (5.7.4), or
-- a GoalDesc child element (older versions).
FRIENDLY.__goalDesc = function(row)
    local v = nil
    pcall(function() v = row:C("GoalDesc")("text"):GetString() end)
    if v and v ~= "" then
        v = cleanText(localize(v) or v)
        if v and v ~= "" then return v end
    end
    local descEl = findNamed(row, "GoalDesc", 1)
    local desc = elementText(descEl)
    if not desc and descEl then
        local parts = descendantText(descEl, 0)
        if #parts > 0 then desc = table.concat(parts, " ") end
    end
    return desc
end

-- The goal row holding el: a child of GoalEntries (rows are named by goal id).
local function goalRow(el)
    local cur = el
    for _ = 1, 4 do
        local p = nil; pcall(function() p = cur:parent() end)
        if not p or p == cur then return nil end
        if elementName(p) == "GoalEntries" then return cur end
        cur = p
        if findNamed(cur, "GoalDesc", 1) then return cur end
    end
    return nil
end

local function goalRewards(row)
    local parts = {}
    for _, r in ipairs(REWARD_WORDS) do
        local e = findNamed(row, "rewardEntry" .. r[1], 6)
        if e then
            local amount = nil; pcall(function() amount = e("RewardAmount"):GetString() end)
            if not amount or amount == "" then amount = elementText(e) end
            if r[2] then
                if amount and amount ~= "" then parts[#parts + 1] = amount .. " " .. r[2] end
            else
                local item = nil
                pcall(function()
                    local q = game.getQuest(row("id"):GetInt())
                    item = cleanText(game.getLocalizedText(game.entityName(q:getRewardEntity())))
                end)
                parts[#parts + 1] = item or "an item"
            end
        end
    end
    return parts
end

local function withGoalContext(el, label)
    local row = goalRow(el)
    if not row then return label end
    local desc = FRIENDLY.__goalDesc(row)
    local out = label
    if desc and not label:find(desc, 1, true) then out = out .. ": " .. desc end
    -- Progress ("2/5") under the Collect spot, while the goal isn't done.
    local prog = findNamed(row, "Progress", 1)
    if prog and isVisible(prog) then
        local t = nil
        pcall(function() t = prog:C("Label")("text"):GetString() end)
        t = t and cleanText(t)
        if t and t ~= "" then out = out .. ". Progress " .. t end
    end
    local rewards = goalRewards(row)
    if #rewards > 0 then out = out .. ". Reward: " .. table.concat(rewards, ", ") end
    return out
end

-- List rows. A row (a monster in the breeding list) is a button with its own
-- text (MonsterName, MonsterSpecies), and may hold buttons of its own (Feed!).
-- Its text, names first: "Fwub, Fwog".
local function rowText(el)
    local names, others = {}, {}
    local kids = nil; pcall(function() kids = el:elements() end)
    local n = 0; pcall(function() n = kids:size() end)
    for i = 0, n - 1 do
        local c = nil; pcall(function() c = kids[i] end)
        if c and isVisible(c) and not isClickable(c) then
            local t = elementText(c)
            if t then
                local nm = elementName(c) or ""
                if nm:find("Name$") then names[#names + 1] = t else others[#others + 1] = t end
            end
        end
    end
    for _, t in ipairs(others) do names[#names + 1] = t end
    return names
end

-- A button inside a row says which row: "Feed! Fwub, Fwog".
local function withRowContext(el, label)
    local cur = el
    for _ = 1, 3 do
        local p = nil; pcall(function() p = cur:parent() end)
        if not p or p == cur then return label end
        cur = p
        if isClickable(cur) then
            local t = rowText(cur)
            if #t > 0 then
                local ctx = table.concat(t, ", ", 1, t[2] and 2 or 1)
                if not label:find(ctx, 1, true) then return label .. " " .. ctx end
                return label
            end
        end
    end
    return label
end

-- Recursively collect navigable controls under `root` into `out` (arrays of
-- {el=, label=}). Depth/count limited; read-only, fully pcall-guarded; runs at a
-- queue_lua frame boundary so it can't race the engine.
-- Does this element contain another clickable element? Then it is a scroller
-- or panel (the breeding menu's monster lists), not a button: naming it from
-- its contents read out the whole list on every Tab.
local function hasClickableDescendant(el, depth)
    if depth > 5 then return false end
    local kids = nil; pcall(function() kids = el:elements() end)
    local n = 0; pcall(function() n = kids:size() end)
    for i = 0, n - 1 do
        local c = nil; pcall(function() c = kids[i] end)
        if c and isVisible(c) and (isClickable(c) or hasClickableDescendant(c, depth + 1)) then return true end
    end
    return false
end

local MAX_NAV_DEPTH = 10
local MAX_NAV_ITEMS = 120
local function collectControls(root, out, depth, group)
    if not root or depth > MAX_NAV_DEPTH or #out >= MAX_NAV_ITEMS then return end
    local kids = nil
    pcall(function() kids = root:elements() end)
    if not kids then return end
    local n = 0
    pcall(function() n = kids:size() end)
    for i = 0, n - 1 do
        if #out >= MAX_NAV_ITEMS then return end
        local child = nil
        pcall(function() child = kids[i] end)
        local cname = child and elementName(child)
        local social = FRIENDLY.__social
        local card = cname and cname:find("^cardItem%d") and social
        if card and not social.cardShown(child) then
            child = nil                              -- empty friend slot
        elseif cname and social and cname:find("^monsterEntry%d") then
            local text = social.bookEntry(child)
            if text then
                local c = child
                out[#out + 1] = { el = { virtual = function() c:touch() end }, label = text }
            end
            child = nil                              -- portraits only below
        elseif cname == "IslandName" and social and elementName(root) == "book_o_monsters" and elementText(child) then
            local text = elementText(child)
            out[#out + 1] = { el = { virtual = function() say(text, true) end }, label = "Page: " .. text }
        elseif cname == "CurrentSender" and social then
            local text = social.mailMessage(root)
            if text then
                out[#out + 1] = { el = { virtual = function() say(text, true) end }, label = "Message: " .. text }
            end
        end
        if card and child then
            -- The card itself opens the friend's profile (SocialCard.OnCardClicked).
            local c = child
            out[#out + 1] = { el = { virtual = function() c:OnCardClicked() end },
                              label = social.cardSummary(c) .. ", open profile" }
        end
        if child and isVisible(child) then
            local isRow = hasClickableDescendant(child, 0) and #rowText(child) > 0
            if isClickable(child) and (isRow or not hasClickableDescendant(child, 0)) then
                local lbl, final = controlLabel(child, cname)
                if final then isRow = false end
                if isRow then
                    -- Its own text plus what its inner buttons say ("Requires Level 4").
                    local parts = rowText(child)
                    local kids = nil; pcall(function() kids = child:elements() end)
                    local n = 0; pcall(function() n = kids:size() end)
                    for i = 0, n - 1 do
                        local c = nil; pcall(function() c = kids[i] end)
                        local t = c and isVisible(c) and isClickable(c) and elementText(c)
                        if t then parts[#parts + 1] = t end
                    end
                    lbl = table.concat(parts, ", ")
                end
                if lbl and not final then
                    local before = lbl
                    lbl = withGoalContext(child, lbl)
                    if lbl == before then lbl = withRowContext(child, lbl) end
                end
                if lbl and lbl:find("%w") then out[#out + 1] = { el = child, label = lbl, group = group } end
            end
            -- Named lists (breeding's Monster 1 / Monster 2): announced on entry,
            -- and [ / ] jump between them.
            local side = social and cname and social.BREED_SIDES[cname]
            collectControls(child, out, depth + 1, side and (side .. " list") or group)   -- recurse into containers too
        end
    end
end

-- Navigable controls under a root: returns parallel {objects}, {labels}.
local function scanClickables(root)
    local out = {}
    if root then collectControls(root, out, 0) end
    local items, labels, groups = {}, {}, {}
    for i, rec in ipairs(out) do items[i] = rec.el; labels[i] = rec.label; groups[i] = rec.group or false end
    return items, labels, groups
end

-- Screens whose message is not in their element tree.
-- newsflash (update alerts, events, offers): the message is an image; the ad
-- behind it carries the title and description (Newsflash.lua: nativePlacement).
local function newsflashText(root)
    local el = nil
    pcall(function() el = root["newsflash"] end)
    el = el or root
    local parts = {}
    pcall(function()
        local placement = game.nativePlacement(el("placement"):GetString())
        local ad = placement:getAd(el("index"):GetInt())
        for _, getter in ipairs({ "getTitle", "getDescription" }) do
            local ok, t = pcall(function() return ad[getter](ad) end)
            t = ok and cleanText(t) or nil
            if t and t ~= parts[#parts] then parts[#parts + 1] = t end
        end
    end)
    if #parts == 0 then return nil end
    return joinSentences(parts)
end

local POPUP_READERS = { newsflash = newsflashText }

local function announcePopup(id, popup)
    -- Prefer the popup's real title; fall back to the humanized id.
    local title = popupTitle(popup)
    local msg = title or popupDisplayName(id)
    local body = popupBody(popup)
    if not body then
        -- Log the dialog's element names (and any text) so missing labels can be added.
        local names, budget = {}, 40
        local function walk(el, depth)
            if depth > 4 or budget <= 0 then return end
            local kids = nil; pcall(function() kids = el:elements() end)
            local n = 0; pcall(function() n = kids:size() end)
            for i = 0, n - 1 do
                local c = nil; pcall(function() c = kids[i] end)
                if c and budget > 0 then
                    budget = budget - 1
                    local cn = "?"; pcall(function() cn = tostring(c:name()) end)
                    local t = elementText(c)
                    names[#names + 1] = cn .. (t and ("='" .. t .. "'") or "")
                    walk(c, depth + 1)
                end
            end
        end
        pcall(walk, popup, 0)
        a11y_log("[announce] no message found for " .. tostring(id) .. ": " .. table.concat(names, " "))
    end
    if not body and lastConfirmation.text then
        local now = 0; pcall(function() now = os.clock() end)
        if now - lastConfirmation.t < 3 then body = lastConfirmation.text end
    end
    lastConfirmation.text = nil
    local reader = POPUP_READERS[tostring(id)]
    if reader then
        local t = nil
        pcall(function() t = reader(popup) end)
        if t then msg, body = t, nil end
    end
    if body and body ~= msg then msg = joinSentences({ msg, body }) end
    local _, labels = scanClickables(popup)
    if #labels > 0 then
        msg = joinSentences({ msg, #labels .. (#labels == 1 and " button: " or " buttons: ") .. table.concat(labels, ", ") })
        msg = msg .. ". Tab to move, Enter to select."
    end
    say(msg, true)
end

-- On-demand: read whatever popup is currently on top (for a future hotkey).
local function announceCurrentPopup()
    local ok, popup = pcall(game.getPopUp)
    if not ok or not popup then say("No dialog open", true) return end
    local ok2, name = pcall(game.getTopPopUpName)
    pcall(announcePopup, ok2 and name or nil, popup)
end

-- Popup object tracking. game.getPopUp() returns an EMPTY wrapper (confirmed by
-- UI dump: "?") -- the real, enumerable popup object is only the return value of
-- game.pushPopUp(). So we keep our own stack of {obj,id}, pushed/popped by
-- hooking both calls, and navigate the top of it.
local popupStack = {}

-- game.getPopUp() returns the top popup's NAME (a string). "MenuReduxElement_Root"
-- is the island base -- i.e. no real popup. This is the check the game's own
-- scripts use (ContextBar.lua). hasPopUp() proved unreliable here.
local function currentPopupName()
    local n = ""
    pcall(function() n = tostring(game.getPopUp()) end)
    return n
end
local function popupOpen()
    local n = currentPopupName()
    return n ~= "" and n ~= "MenuReduxElement_Root" and n ~= "nil"
end

-- MSVC's clock() is wall time since process start, so this is a real timer.
local function clock() local t = 0; pcall(function() t = os.clock() end); return t end

-- Last popup announced, so a menu's own tick doesn't announce it a second time.
local lastAnnounced = { id = nil, t = -100 }

if type(game.pushPopUp) == "function" then
    local orig_push = game.pushPopUp
    game.pushPopUp = function(id, ...)
        local popup = orig_push(id, ...)
        popupStack[#popupStack + 1] = { obj = popup, id = id }
        lastAnnounced.id, lastAnnounced.t = tostring(id), clock()
        pcall(announcePopup, id, popup)
        return popup
    end
    a11y_log("patched game.pushPopUp (event-driven popup announcements)")
else
    a11y_log("game.pushPopUp not found - popup announcements unavailable")
end

for _, fn in ipairs({ "popPopUp", "popTopPopUp" }) do
    if type(game[fn]) == "function" then
        local orig = game[fn]
        game[fn] = function(...)
            local r = orig(...)
            popupStack[#popupStack] = nil          -- top closed
            return r
        end
    end
end

-- ---------------------------------------------------------------------------
-- Live menu registry. Every game menu XML is overridden (generated by
-- scripts/Build-MenuOverrides.ps1) with an invisible A11yHook element whose
-- onTick calls a11y_menuTick(root, file). So any screen the game opens, even
-- from C++ (bakery, context bar, confirmations), hands us a fresh root each
-- frame, and stops the moment it's gone, so we never hold a stale handle.
-- ---------------------------------------------------------------------------
-- Menus that are always on screen (or always ticking) on the island. Anything
-- else that is live is a screen opened on top of the island.
local PERSISTENT_MENUS = { hud = true, contextbar = true, tutorial = true, empty = true, load_fade = true }
local DIALOG_BUTTONS = { "YesButton", "NoButton", "OkayButton", "OkButton", "BuyButton", "ConfirmButton",
                         "CancelButton", "CloseButton", "PurchaseButton" }
local MENU_FRESH_SECONDS = 0.5
local menus = {}   -- file name -> { root, t, frame, rootName, countdown }
-- Which roots are safe to touch. A screen can be freed at any moment (pressing
-- Market swaps the whole island for the store), and touching a freed element
-- crashes the game outright. So a root counts only if its menu ticked after
-- the mod last pressed anything, and hasn't missed its own usual tick: screens
-- don't all tick every frame (the map doesn't), so each one's interval is
-- learned. "Missed" is measured against the newest tick of any menu, not the
-- clock, so one slow frame doesn't hide every screen.
-- (A table, not locals: the main chunk is at Lua's 200-local limit.)
local menuState = { announceFrames = 4, activated = -100, lastTick = -100,
    -- Panels that open alongside placing or a selected decoration (Show Grid,
    -- Decoration Size). Never a screen of their own, and they can linger.
    sidePanels = { showgrid_popup = true, scale_popup = true } }
function menuState.usable(m)
    if m == nil or m.root == nil or m.t <= menuState.activated then return false end
    if clock() - m.t > MENU_FRESH_SECONDS then return false end
    return menuState.lastTick - m.t <= 1.5 * (m.gap or 0.05) + 0.004
end
-- Call right before pressing, selecting or opening anything.
function menuState.touch() menuState.activated = clock() end
-- Did any screen open (or grow a new panel) at or after time t? Used to tell
-- a tap that opened something from a tap on empty ground.
function menuState.openedSince(t)
    for _, m in pairs(menus) do
        if ((m.appeared or -100) >= t or (m.opened or -100) >= t) and clock() - m.t <= MENU_FRESH_SECONDS then
            return true
        end
    end
    return false
end

-- Menus with their own announcer (tutorial hook) or that are always on screen.
local function selfAnnounced(file)
    return file:find("^popup_tutorial") or file == "tutorial" or file == "hud" or file == "contextbar"
        or file == "empty" or file == "load_fade" or file == "store_categoryselect"
        or menuState.sidePanels[file]
end

-- Actions to run a little later on the game thread (after the camera moves,
-- after a selection settles). Driven by menu ticks, which run every frame.
local pending = {}
local function later(seconds, fn)
    pending[#pending + 1] = { t = clock() + seconds, fn = fn }
end
-- An action with p.perRoot runs once for each menu that ticks after its time
-- (it gets that menu's live root) until p.stop; anything else runs once.
local function runPending(now, root)
    if #pending == 0 then return end
    local list = pending
    pending = {}                  -- actions may schedule more via later()
    for _, p in ipairs(list) do
        if now < p.t then
            pending[#pending + 1] = p
        elseif p.perRoot then
            local key = tostring(root)
            if root and not p.done[key] then p.done[key] = true; pcall(p.fn, root) end
            if now < p.stop then pending[#pending + 1] = p end
        else
            pcall(p.fn)
        end
    end
end

-- Set later (placement watcher); runs on every context bar tick.
local contextbarHook = nil
local readyHook = nil      -- set to watchReady further down
local walletHook = nil     -- set to watchWallet further down

local function menuTick(root, file)
    local now = clock()
    runPending(now, root)
    if file == "contextbar" and contextbarHook then pcall(contextbarHook) end
    if file == "hud" and readyHook then pcall(readyHook, now) end
    if walletHook then pcall(walletHook, now) end
    local m = menus[file]
    if not m then
        local rn = "?"; pcall(function() rn = tostring(root:name()) end)
        m = { rootName = rn, t = -100 }
        menus[file] = m
        a11y_log("[menu] live: " .. file .. " (root " .. rn .. ")")
    end
    -- Learn this screen's tick interval: the longest recent gap, slowly
    -- forgotten. (Two copies of one screen can tick in the same frame: ignore
    -- tiny gaps.)
    local gap = now - m.t
    if gap > MENU_FRESH_SECONDS then
        m.gap = nil
    elseif gap > 0.002 then
        m.gap = math.max(gap, (m.gap or gap) * 0.9)
    end
    menuState.lastTick = now
    if now - m.t > MENU_FRESH_SECONDS then                -- (re)appeared
        m.countdown, m.appeared, m.opened, m.panel = menuState.announceFrames, now, now, nil
    end
    -- Some screens stay loaded once used and get reused: the confirmation
    -- popup keeps ticking with nothing in it, and a new "Would you like to
    -- bake...?" is added inside it. Others grow a panel (a buy box) inside a
    -- screen that is already open. Track what is showing: something new after
    -- the screen settled counts as a new screen of its own (announced, and Tab
    -- stays inside it until it goes away); nothing showing means closed.
    if not PERSISTENT_MENUS[file] then
        local shown, newest = {}, nil
        pcall(function()
            local kids = root:elements()
            for i = 0, kids:size() - 1 do
                local inner = kids[i]:elements()
                for j = 0, inner:size() - 1 do
                    local c = inner[j]
                    if isVisible(c) and elementName(c) ~= "A11yHook" then
                        local k = i .. "/" .. j .. "/" .. tostring(elementName(c))
                        shown[k] = c
                        if m.shown and not m.shown[k] then newest = k end
                    end
                end
            end
        end)
        local count = 0
        for _ in pairs(shown) do count = count + 1 end
        -- Only dialogs count (they carry a Yes/No/OK/Buy/Close button): a tab
        -- page or a scroll bar showing up must not trap Tab inside it.
        local function isDialog(k)
            for _, b in ipairs(DIALOG_BUTTONS) do
                if findNamed(shown[k], b, 4) then return true end
            end
            return false
        end
        if newest and now - (m.opened or now) > 1 and isDialog(newest) then
            m.countdown, m.appeared, m.panel = menuState.announceFrames, now, newest
            a11y_log("[menu] new panel in " .. file .. ": " .. newest)
        end
        if m.panel and not shown[m.panel] then m.panel = nil end
        m.panelEl = m.panel and shown[m.panel] or nil
        m.shown, m.content = shown, count
    end
    m.root, m.t = root, now
    if m.countdown then
        m.countdown = m.countdown - 1
        if m.countdown <= 0 then
            m.countdown = nil
            -- Announce popups opened from C++ (Lua pushPopUp already announced its own).
            -- getPopUp() can lag behind for C++-pushed screens (newsflash):
            -- getTopPopUpName() already names them.
            local top = currentPopupName()
            local top2 = ""; pcall(function() top2 = tostring(game.getTopPopUpName()) end)
            -- C++ confirmations report only "MenuReduxElement_Root" as the top
            -- popup, so a popup_* screen that just (re)appeared counts too.
            -- The game can keep naming the screen underneath (the Bakery) while
            -- its confirmation is up, so also accept the newest open screen.
            local newest = true
            for f, o in pairs(menus) do
                if f ~= file and not PERSISTENT_MENUS[f] and not f:find("^popup_tutorial") and not menuState.sidePanels[f]
                    and now - o.t <= MENU_FRESH_SECONDS and o.content ~= 0 and (o.appeared or 0) > (m.appeared or 0) then
                    newest = false
                end
            end
            -- Only real dialogs qualify (popup_* menus or a dialog panel), not
            -- helper screens like load_fade, empty or the store's category bar.
            local dialogLike = file:find("^popup_") or m.panel
            local isTop = top == file or top2 == file or (newest and m.content ~= 0 and dialogLike)
            if not selfAnnounced(file) and isTop
                and not (lastAnnounced.id == file and now - lastAnnounced.t < 2) then
                lastAnnounced.id, lastAnnounced.t = file, now
                pcall(announcePopup, file, m.panelEl or root)
            end
        end
    end
end


-- The most recently opened screen still on screen, if any. Some screens opened
-- from C++ (bakery...) don't always show up as the top popup; without this,
-- Tab would fall back to the island and list the main menu behind them.
local function topOverlay()
    local now, best, bestFile = clock(), nil, nil
    -- Only screens opened after the island loaded: login menus that linger
    -- don't count.
    local since = 0
    for _, f in ipairs({ "hud", "contextbar" }) do
        local m = menus[f]
        if m and m.appeared and m.appeared > since then since = m.appeared end
    end
    for file, m in pairs(menus) do
        -- showgrid_popup (the Show Grid toggle) can linger after placing or
        -- cancelling; it only belongs to placement, never a screen of its own.
        if not PERSISTENT_MENUS[file] and not file:find("^popup_tutorial") and not menuState.sidePanels[file]
            and (m.appeared or 0) >= since
            and m.content ~= 0
            and menuState.usable(m) and (not best or (m.appeared or 0) > (best.appeared or 0)) then
            best, bestFile = m, file
        end
    end
    if best then
        if best.panelEl then return best.panelEl, bestFile .. ":" .. best.panel, bestFile end
        return best.root, bestFile, bestFile
    end
    return nil
end

-- Fresh root for a menu, by file name or by root element name.
local function liveMenu(name)
    local m = menus[name]
    if menuState.usable(m) then return m.root end
    for _, mm in pairs(menus) do
        if mm.rootName == name and menuState.usable(mm) then return mm.root end
    end
    return nil
end

-- Encore event info: name, theme, how points are earned ("15m = 1"), and the
-- progress shown on the HUD's Encore button.
POPUP_READERS.popup_encore_info = function(popup)
    local parts = {}
    local title = shownText(popup, "TitleFrame")
    if title then parts[#parts + 1] = "Encore event: " .. title end
    local theme = shownText(popup, "TopText")
    if theme then parts[#parts + 1] = theme end
    local conv = shownText(popup, "ConversionInfo")
    if conv then
        local n, unit, pts = conv:match("(%d+)%s*([smhd])%s*=%s*(%d+)")
        local UNITS = { s = "seconds", m = "minutes", h = "hours", d = "days" }
        if n then
            local what = theme and theme:match(":%s*(.+)$")
            parts[#parts + 1] = "Every " .. n .. " " .. UNITS[unit] .. (what and (" of " .. what .. " time") or "")
                .. " earns " .. pts .. (pts == "1" and " point" or " points")
        else
            parts[#parts + 1] = conv
        end
    end
    pcall(function()
        local bar = findNamed(game.getHUD(), "EncoreBar", 2)
        local pts = bar and elementText(findNamed(bar, "RewardBar", 1))
        local a, b = (pts or ""):match("(%d+)%s*/%s*(%d+)")
        if a then parts[#parts + 1] = "You have " .. a .. " of " .. b .. " points" end
        local left = bar and elementText(findNamed(bar, "Timer", 1))
        if left then parts[#parts + 1] = left .. " left" end
    end)
    if #parts == 0 then return nil end
    return joinSentences(parts)
end

-- "You received:": read the rewards. They can still be filling in when the
-- popup is pushed; then speak them once they show.
POPUP_READERS.popup_store_bundle_rewards = function(popup)
    local items = FRIENDLY.__social.rewardList(popup)
    if #items > 0 then return "You received: " .. table.concat(items, ", ") end
    later(0.8, function()
        local r = liveMenu("popup_store_bundle_rewards")
        local it = r and FRIENDLY.__social.rewardList(r) or {}
        if #it > 0 then say("You received: " .. table.concat(it, ", ") .. ".", false) end
    end)
    return nil
end

-- ---------------------------------------------------------------------------
-- "Places" menu (Ctrl+Shift+M): a keyboard-openable list of the main
-- destinations. The on-screen market/book/map/options bar lives in a separate
-- menu tree the game exposes no element handle for (dump: topAncestor
-- EntityReduxMenu_Root has only the HUD under it). But those buttons just call
-- game.* entry points -- verified in decompiled ContextBar.lua -- so we invoke
-- them directly. For a screen reader, a direct destination list beats hunting a
-- spatial bar anyway. Every action is pcall-guarded.
-- ---------------------------------------------------------------------------
local function goOptions()
    -- Mirror ContextBar: close a non-root popup first, then open options.
    local cur = ""; pcall(function() cur = tostring(game.getPopUp()) end)
    if cur ~= "options" then
        if cur ~= "" and cur ~= "MenuReduxElement_Root" then pcall(game.popPopUp) end
        pcall(function() game.pushPopUp("options") end)
    end
end
local function goBook()
    pcall(function()
        local isl = game.player():getActiveIsland()
        game.setBookOfMonstersIslandId(isl:id(), isl:islandMode())
    end)
    pcall(function() game.pushPopUp("book_o_monsters") end)
end

local PLACES = {
    { "Market",           function() pcall(game.loadStoreContext) end },
    { "Book of Monsters", goBook },
    { "Map",              function() pcall(function() game.loadMapContext(false) end) end },
    { "Goals",            function() pcall(function() game.pushPopUp("goals") end) end },
    { "Friends",          function() pcall(function() game.checkGamePermission("FRIENDS", "popup_permission_friends") end) end },
    { "Mail",             function() pcall(function() game.pushPopUp("mail") end) end },
    { "Options",          goOptions },
}


-- A virtual list (Places, Objects) driven by Tab / Shift+Tab / Enter.
-- items: array of { label, action }.
local vmenu = { active = false, index = 0, kind = nil, items = {} }

local function openList(kind, title, items, hint)
    if vmenu.active and vmenu.kind == kind then   -- same hotkey again: close
        vmenu.active = false
        say(title .. " closed", true)
        return
    end
    if #items == 0 then say(title .. ": nothing here", true) return end
    vmenu.active, vmenu.index, vmenu.kind, vmenu.items = true, 0, kind, items
    local labels = {}
    for i, d in ipairs(items) do labels[i] = d[1] end
    local list = #items <= 8 and (table.concat(labels, ", ") .. ". ") or (#items .. " items. ")
    say(title .. ". " .. list .. hint, true)
end

local function openPlaces()
    openList("places", "Places", PLACES, "Tab to move, Enter to open, Control Shift M to close.")
end

-- ---------------------------------------------------------------------------
-- Island objects (Ctrl+Shift+O): structures and monsters on the current
-- island, selected the same way the Goals screen's "go" buttons do it
-- (game.getFirstStructureOfType + game.selectStructure, game.selectMonster).
-- Selecting shows the object's context bar, which Tab then navigates.
-- ---------------------------------------------------------------------------
-- getFirstStructureOfType uses the game's structure-type numbers (Goals.lua:
-- 6 = obstacle, 17 = awakener), not SpecificEntityType, so scan the range.
local MAX_STRUCTURE_TYPE = 64

-- The selected object's name, as the game shows it.
local function selectedName()
    local n = nil
    pcall(function() n = game.objectName() end)
    n = n and n ~= "" and cleanText(n) or nil
    -- A selected monster: add its species to the nickname ("Glob, Toe Jammer").
    local isMonster = false
    pcall(function() isMonster = game.selectedObjIsMonster() and true or false end)
    if isMonster then
        local species = nil
        pcall(function() species = cleanText(LOC(game.getMonsterDataFromUniqueId(game.selectedMonsterId()):name())) end)
        if species and (not n or n:lower() ~= species:lower()) then
            return n and (n .. ", " .. species) or species
        end
    end
    return n
end

local sdLogged = false
local function structureLabel(uid)
    local sd = nil
    pcall(function() sd = game.getStructureDataFromUniqueId(uid) end)
    if not sd then return nil end
    if not sdLogged then
        sdLogged = true
        local names = {}
        pcall(function()
            local mt = getmetatable(sd)
            for _, t in ipairs({ mt, rawget(mt, ".fn") }) do
                if type(t) == "table" then for k in pairs(t) do names[#names + 1] = tostring(k) end end
            end
        end)
        a11y_log("[objects] structure data members: " .. table.concat(names, " "))
    end
    for _, m in ipairs({ "name", "getName", "displayName", "entityName", "structureName" }) do
        local ok, v = pcall(function() return sd[m](sd) end)
        if ok and type(v) == "string" and v ~= "" then return cleanText(v) end
    end
    for _, m in ipairs({ "entityId", "getEntityId", "id", "structureId", "type" }) do
        local ok, v = pcall(function() return sd[m](sd) end)
        if ok and type(v) == "number" then
            local ok2, nm = pcall(game.structureTypeName, v)
            if ok2 and type(nm) == "string" and nm ~= "" then return cleanText(nm) end
        end
    end
    return nil
end

-- The species ("Toe Jammer"), from the monster's data.
local function monsterSpecies(uid)
    local sp = nil
    pcall(function() sp = cleanText(LOC(game.getMonsterDataFromUniqueId(uid):name())) end)
    return sp
end

-- Players can rename monsters, and getMonsterName returns that nickname
-- ("Glob"). Say both: "Glob, Toe Jammer"; just the species if they match.
local function monsterLabel(uid)
    local nick = nil
    pcall(function() nick = cleanText(game.getMonsterName(uid)) end)
    local species = monsterSpecies(uid)
    if nick and species and nick:lower() ~= species:lower() then return nick .. ", " .. species end
    return species or nick or "Monster"
end

local TAP_ZOOM, TAP_SECONDS = 0.8, 0.4    -- same zoom FugueSuccess.lua uses
local TAP_FX, TAP_FY = 0.5, 0.47          -- object anchor is at its base: aim just above

local function objectSelected()
    local s = false
    pcall(function() s = game.isObjectSelected() and true or false end)
    return s
end

local function selectedObject()
    local obj = nil
    pcall(function() obj = game.SelectedObject() end)
    if not obj then pcall(function() obj = game:SelectedObject() end) end
    return obj
end

-- What is selected right now, as "m<uid>" / "s<id>" (nil if nothing), so a
-- tap can be checked: did it select our object, or something standing in front?
local function selectionKey()
    if not objectSelected() then return nil end
    local isMonster, key = false, nil
    pcall(function() isMonster = game.selectedObjIsMonster() and true or false end)
    if isMonster then pcall(function() key = "m" .. tostring(game.selectedMonsterId()) end)
    else pcall(function() key = "s" .. tostring(game.selectedStructureId()) end) end
    return key
end

-- Is the current selection our object? By id, or by name in case the id
-- spaces differ. Returns nil when nothing is selected.
local function selectionIs(wantKey, name)
    local got = selectionKey()
    if not got then return nil end
    if wantKey == nil or got == wantKey then return true end
    local n = selectedName()
    if n and name and n:lower() == name:lower() then return true end
    return false
end

-- Points to try on the object, centred by the camera. Its anchor is at its
-- base, so go up first; then sideways, for trees or rocks standing in front.
-- The second point is the centre itself: on a 16:10 screen (1280x800) the
-- tutorial Nursery's egg sits at 0.50 and 0.47 lands on the chain above it.
local TAP_POINTS = {
    { 0.5, 0.47 }, { 0.5, 0.51 }, { 0.5, 0.40 }, { 0.5, 0.33 }, { 0.46, 0.42 }, { 0.54, 0.42 },
}
local TAP_CHECK_SECONDS = 0.45

-- Tap a world object like a finger would: centre the camera on it with the
-- game's zoomCameraToObject, then click. A real tap collects treats and coins,
-- and is what tutorial steps that block direct selection wait for.
-- wantKey: the selectionKey the tap should leave (nil = don't check).
-- reselect: puts our object back after a miss. done(hit): called at the end.
-- untilSomething: also count a click that selected nothing and opened no
-- screen as a miss (it hit empty ground), and try the next point.
local function tapEntity(entity, name, wantKey, reselect, done, untilSomething)
    if not entity then say("Can't find " .. name, true) if done then done(false) end return end
    if type(clickFraction) ~= "function" then say("Click function unavailable", true) return end
    local ok, err = pcall(function() game.worldContext():zoomCameraToObject(entity, TAP_ZOOM, TAP_SECONDS) end)
    if not ok then
        -- Camera didn't move: a click would hit whatever is mid-screen.
        a11y_log("[tap] zoomCameraToObject failed, not clicking: " .. tostring(err))
        if done then done(false) end
        return
    end
    -- The game can ignore every click while its touch input is switched off
    -- (the Book of Monsters turns it off while open) or while it thinks a
    -- controller is in use. Turn touch back on, and log the input state so a
    -- debug zip shows it.
    pcall(function() game.setTouchEnable(true) end)
    local inputState = {}
    for _, f in ipairs({ "getControllerActive", "getControllerType", "getControllerName", "selectedInput" }) do
        local ok, v = pcall(function() return game[f]() end)
        inputState[#inputState + 1] = f .. "=" .. (ok and tostring(v) or "ERR")
    end
    a11y_log("[tap] input: " .. table.concat(inputState, " "))
    local function try(i)
        local pt = TAP_POINTS[i]
        local clickedAt = clock()
        clickFraction(pt[1], pt[2])
        later(TAP_CHECK_SECONDS, function()
            local got = selectionKey()
            -- A miss is something else getting selected (a tree in front),
            -- or, when asked, nothing happening at all.
            local miss = selectionIs(wantKey, name) == false
                or (untilSomething and got == nil and not menuState.openedSince(clickedAt))
            a11y_log("[tap] " .. name .. " point " .. i .. " -> " .. tostring(got) .. (miss and " (miss)" or ""))
            if miss and i < #TAP_POINTS then
                if reselect then pcall(reselect) end
                later(0.2, function() try(i + 1) end)
            elseif done then
                if miss and reselect then pcall(reselect) end
                done(not miss)
            end
        end)
    end
    later(TAP_SECONDS + 0.25, function() try(1) end)
end

local function tapSelected()
    local obj = selectedObject()
    if not obj then say("Nothing selected", true) return end
    local name = selectedName() or "object"
    local key = selectionKey()
    local isMonster = key and key:sub(1, 1) == "m"
    local id = key and tonumber(key:sub(2))
    local function reselect()
        if isMonster then game.selectMonster(id) else game.selectStructure(id) end
    end
    say("Tap " .. name, true)
    -- Selected Nursery with a finished egg: hatch it the game's way first
    -- (see activateObject); click only if that didn't take.
    local ready = false
    if name:lower():find("nursery", 1, true) then
        pcall(function() ready = game.eggReadyToHatch() and true or false end)
    end
    if ready then
        local hok, herr = pcall(function() game.hatchEgg() end)
        if not hok and id and tostring(herr):find("args", 1, true) then
            hok, herr = pcall(function() game.hatchEgg(id) end)
        end
        a11y_log("[hatch] (tap) hatchEgg -> " .. tostring(hok) .. " " .. tostring(herr))
        later(0.8, function()
            local still = false
            pcall(function() still = game.eggReadyToHatch() and true or false end)
            if still then tapEntity(obj, name, nil, nil, function() end) end
        end)
        return
    end
    tapEntity(obj, name, key, id and reselect or nil, function(hit)
        if not hit then say("Something is in front of " .. name .. ". Could not tap it.", true) end
    end)
end

-- Enter on an island object: select it directly (can't hit anything in front
-- of it). Tutorial steps that refuse direct selection get a real tap instead.
local function activateObject(entity, label, select, wantKey)
    say(label, true)
    local ok, err = pcall(select)
    if not ok then a11y_log("[tap] select " .. label .. " failed: " .. tostring(err)) end
    later(0.2, function()
        local got = selectionKey()
        if selectionIs(wantKey, label) then
            -- A Nursery whose egg is done hatches when tapped. The game does
            -- that from C++ through game.hatchEgg (no Lua caller to copy, so
            -- its arguments are unknown): try none, then the structure id. A
            -- wrong argument count is a Lua error, which pcall catches. Only
            -- with the Nursery selected, so the game has a Nursery to use.
            local ready = false
            if label:lower():find("nursery", 1, true) then
                pcall(function() ready = game.eggReadyToHatch() and true or false end)
            end
            if ready then
                local id = wantKey and tonumber(wantKey:match("^s(%d+)$"))
                local hok, herr = pcall(function() game.hatchEgg() end)
                if not hok and id and tostring(herr):find("args", 1, true) then
                    a11y_log("[hatch] hatchEgg(): " .. tostring(herr) .. "; trying with the id")
                    hok, herr = pcall(function() game.hatchEgg(id) end)
                end
                a11y_log("[hatch] hatchEgg -> " .. tostring(hok) .. " " .. tostring(herr))
                later(0.8, function()
                    local still = false
                    pcall(function() still = game.eggReadyToHatch() and true or false end)
                    a11y_log("[hatch] egg still ready afterwards: " .. tostring(still))
                    if not still then return end
                    -- Didn't hatch: tap the Nursery like a finger would.
                    tapEntity(entity, label, nil, nil, function()
                        later(0.6, function()
                            local again = false
                            pcall(function() again = game.eggReadyToHatch() and true or false end)
                            if again then say("Could not hatch the egg. Try Tab, then Tap " .. label .. ".", true) end
                        end)
                    end)
                end)
                return
            end
            say((selectedName() or label) .. " selected. Tab for actions.", true)
            return
        end
        a11y_log("[tap] direct select of " .. label .. " didn't take (" .. tostring(got) .. "), tapping")
        local tapStart = clock()
        tapEntity(entity, label, wantKey, select, function(hit)
            later(0.15, function()
                if hit and menuState.openedSince(tapStart) then
                    -- The tap opened a screen (the hatching fanfare, a notice):
                    -- its own announcement says what happened; don't talk over it.
                    a11y_log("[tap] " .. label .. " opened a screen")
                elseif selectionIs(wantKey, label) then
                    say((selectedName() or label) .. " selected. Tab for actions.", true)
                elseif hit then
                    -- The click selected nothing; that's normal when the tap
                    -- does its own thing (hatch, collect), but say so honestly.
                    say("Clicked on " .. label .. ". If nothing happened, the click missed.", true)
                else
                    say("Could not tap " .. label .. ". Something is in front of it, or nothing answered the click.", true)
                end
            end)
        end, true)                              -- a click on empty ground: try the next spot
    end)
end

-- Structure lookups only answer while the island view is active (not in the
-- Market, Map...), so an empty structure list means "not on the island".
-- ---------------------------------------------------------------------------
-- Object status: what the icons floating over objects show sighted players.
-- Probed in game: secondsUntilActionDone is the time left on a bake, breed,
-- build or clear (0 when idle, negative once done); "done" is told apart from
-- "done long ago" by the island's has*Ready checks. The Nursery's egg calls
-- are not reachable from Lua (the entity comes back as a plain Structure).
-- ---------------------------------------------------------------------------
local function durationText(secs)
    secs = secs - secs % 1
    local h = (secs - secs % 3600) / 3600
    local m = (secs % 3600 - secs % 60) / 60
    local s = secs % 60
    local function unit(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end
    if h > 0 then return m > 0 and (unit(h, "hour") .. " " .. unit(m, "minute")) or unit(h, "hour") end
    if m > 0 then return m >= 10 and unit(m, "minute") or (s > 0 and (unit(m, "minute") .. " " .. unit(s, "second")) or unit(m, "minute")) end
    return unit(s, "second")
end

local function islandReady(check)
    local v = false
    pcall(function() local isl = game.player():getActiveIsland(); v = isl[check](isl) and true or false end)
    return v
end

local function entityIs(ent, method)
    local v = false
    pcall(function() v = ent[method](ent) and true or false end)
    return v
end

local MAX_BUSY_SECONDS = 60 * 60 * 24 * 60     -- larger means "never started" garbage

local function structureStatus(id)
    local ent = nil
    pcall(function() ent = game.GetStructure(id) end)
    if not ent then return nil end
    local secs = 0
    pcall(function() secs = ent:secondsUntilActionDone() or 0 end)
    local busy = secs > 0 and secs < MAX_BUSY_SECONDS
    local upgrading = false
    pcall(function() upgrading = game.isStructureUpgrading(id) and true or false end)
    if entityIs(ent, "isBakery") then
        if busy then return "baking, " .. durationText(secs) .. " left" end
        if islandReady("hasBakeryReady") then return "food ready to collect" end
        return "idle"
    elseif entityIs(ent, "isBreeding") then
        if busy then return "breeding, " .. durationText(secs) .. " left" end
        if islandReady("hasBreedingReady") then return "breeding finished, egg ready" end
        return "empty"
    elseif entityIs(ent, "isNursery") then
        if busy then return "egg hatching, " .. durationText(secs) .. " left" end
        if islandReady("hasNurseryReady") then return "egg ready to hatch" end
        return nil
    elseif entityIs(ent, "isCastle") then
        if busy then return "upgrading, " .. durationText(secs) .. " left" end
        if islandReady("hasCastleUpgradeReady") then return "upgrade finished" end
        return nil
    elseif entityIs(ent, "isObstacle") then
        if busy then return "being removed, " .. durationText(secs) .. " left" end
        -- Finished removals sit at a small negative time; never-started ones
        -- read as a huge negative number.
        if secs < 0 and secs > -MAX_BUSY_SECONDS then return "removal finished, tap it to clear it away" end
        return nil
    end
    if busy then return (upgrading and "upgrading, " or "building, ") .. durationText(secs) .. " left" end
    return nil
end

local function monsterStatus(uid)
    local ent = nil
    pcall(function() ent = game.GetMonster(uid) end)
    local parts = {}
    if ent then
        local lvl, fed, need = nil, nil, 0
        pcall(function() lvl = ent:level() end)
        pcall(function() fed = ent:timesFed() end)
        pcall(function() need = ent:foodRequired() or 0 end)
        if lvl then parts[#parts + 1] = "level " .. tostring(lvl) end
        if fed and need > 0 and lvl and lvl < 20 then parts[#parts + 1] = "fed " .. tostring(fed) .. " of 4" end
    end
    local coins = 0
    pcall(function() coins = game.monsterEarnings(uid) or 0 end)
    if coins > 0 then parts[#parts + 1] = tostring(coins) .. " coins" end
    return #parts > 0 and table.concat(parts, ", ") or nil
end

local function withStatus(label, status)
    return status and (label .. ", " .. status) or label
end

-- Every structure on the island (not just the first of each type: there are
-- usually several Small Trees and Rocks). Falls back to the type scan.
local function islandStructureIds()
    local ids, seen = {}, {}
    pcall(function()
        local ss = game.player():getActiveIsland():structures()
        for i = 0, ss:size() - 1 do
            local id = ss[i]
            if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
        end
    end)
    if #ids == 0 then
        for t = 0, MAX_STRUCTURE_TYPE do
            local id = 0
            pcall(function() id = game.getFirstStructureOfType(t) or 0 end)
            if id ~= 0 and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
        end
    end
    return ids
end

local OBJECT_GROUPS = { [0] = "Buildings", [1] = "Monsters", [2] = "Decorations", [3] = "Trees and rocks" }

local function islandObjects()
    local items = {}
    -- Buildings first, then monsters, decorations, and trees/rocks last.
    -- Repeated names get a number: "Small Tree 2".
    local structs, total, nth = {}, {}, {}
    for _, id in ipairs(islandStructureIds()) do
        local ent = nil
        pcall(function() ent = game.GetStructure(id) end)
        local label = structureLabel(id) or "Structure"
        local rank = entityIs(ent, "isObstacle") and 3 or (entityIs(ent, "isDecoration") and 2 or 0)
        structs[#structs + 1] = { id = id, label = label, rank = rank }
        total[label] = (total[label] or 0) + 1
    end
    for _, st in ipairs(structs) do
        if total[st.label] > 1 then
            nth[st.label] = (nth[st.label] or 0) + 1
            st.label = st.label .. " " .. nth[st.label]
        end
        local id, label = st.id, st.label
        st.item = { withStatus(label, structureStatus(id)), name = label, rank = st.rank,
            live = function() return withStatus(label, structureStatus(id)) end, function()
            vmenu.active = false
            local ent = nil
            pcall(function() ent = game.GetStructure(id) end)
            activateObject(ent, label, function() game.selectStructure(id) end, "s" .. tostring(id))
        end }
    end
    for _, st in ipairs(structs) do if st.rank == 0 then items[#items + 1] = st.item end end
    pcall(function()
        local mons = game.player():getActiveIsland():monsters()
        for i = 0, mons:size() - 1 do
            local uid = mons[i]
            local label = monsterLabel(uid)
            local species = nil
            pcall(function() species = LOC(game.getMonsterDataFromUniqueId(uid):name()) end)
            items[#items + 1] = { withStatus(label, monsterStatus(uid)), name = label,
                species = species and tostring(species) or nil, rank = 1,
                live = function() return withStatus(label, monsterStatus(uid)) end, function()
                vmenu.active = false
                local ent = nil
                pcall(function() ent = game.GetMonster(uid) end)
                if not ent then pcall(function() ent = game.GetMultiMonster(uid) end) end
                activateObject(ent, label, function() game.selectMonster(uid) end, "m" .. tostring(uid))
            end }
        end
    end)
    for rank = 2, 3 do
        for _, st in ipairs(structs) do if st.rank == rank then items[#items + 1] = st.item end end
    end
    return items
end

-- ---------------------------------------------------------------------------
-- Tutorial target. The banner always names what to tap ("Collect the Treats",
-- "Click on the Egg...", "Feed your Noggin..."). Map its words to an island
-- object so one key (or the first Tab entry) taps the right thing.
-- Rules are checked in order, against the game's own tutorial lines (en.utf8):
-- "Click on the Egg to transfer it to the Nursery" is the egg sitting in the
-- Breeding Structure; "Wait for the egg to hatch", "Speed up the hatching of
-- your Mammott egg" and "Monster eggs incubate in the Nursery" are the Nursery,
-- so hatching wins over the bare word "egg".
-- ---------------------------------------------------------------------------
local TUTORIAL_TARGETS = {
    { "transfer it to the nursery", "breeding" },
    { "place the monster", "nursery" },
    { "hatch",             "nursery" },
    { "incubat",           "nursery" },
    { "nursery",           "nursery" },
    { "egg",               "breeding" },
    { "treat",             "bakery" },
    { "cookie",            "bakery" },
    { "bak",               "bakery" },
    { "breed",             "breeding" },
    { "castle",            "castle" },
}

local function tutorialBannerText()
    local active = false
    pcall(function() active = game.tutorialActive() and true or false end)
    if not active then return nil end
    local root = liveMenu("tutorial")
    if not root then return nil end
    local vis, t = 1, nil
    pcall(function() vis = root["primaryText"]["Text"]("visible"):GetInt() end)
    if vis == 0 then return nil end
    pcall(function() t = root["primaryText"]["Text"]("text"):GetString() end)
    return cleanText(t)
end

-- Returns { label, action } for the object the tutorial wants, or nil.
local function tutorialTarget()
    local text = tutorialBannerText()
    if not text then return nil end
    local lower = text:lower()
    -- Buying happens in the Market, not on an island object ("Buy a Noggin
    -- egg" used to match the "egg" rule and point at the Breeding Structure).
    if lower:find("buy", 1, true) or lower:find("market", 1, true) or lower:find("purchase", 1, true) then
        return { "Market", function() pcall(game.loadStoreContext) end, verb = "open" }
    end
    local objs = islandObjects()
    for _, rule in ipairs(TUTORIAL_TARGETS) do
        if lower:find(rule[1], 1, true) then
            for _, o in ipairs(objs) do
                if o[1]:lower():find(rule[2], 1, true) then return o end
            end
        end
    end
    -- A monster named by species ("Feed your Noggin") or nickname.
    for _, o in ipairs(objs) do
        for _, n in ipairs({ o.species, o.name }) do
            if n and #n > 2 and lower:find(n:lower(), 1, true) then return o end
        end
    end
    return nil
end

local function openObjects()
    if popupOpen() or topOverlay() then say("Close the current screen first", true) return end
    local found = false
    for t = 0, MAX_STRUCTURE_TYPE do
        local id = 0
        pcall(function() id = game.getFirstStructureOfType(t) or 0 end)
        if id ~= 0 then found = true break end
    end
    if not found then say("Island objects are only available on the island view", true) return end
    openList("objects", "Island objects", islandObjects(), "Tab to move, Enter to select, Control Shift O to close.")
end

-- ---------------------------------------------------------------------------
-- Selected-object actions that have no on-screen button.
-- Tapping an object in the world does things the context bar can't: collect a
-- finished bakery's treats, collect coins from a monster. We centre the camera
-- on the selection with the game's own zoomCameraToObject, then click the
-- middle of the window.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Placing / moving an object (new monster from the nursery, MOVE button).
-- The game moves objects by dragging. Arrow keys centre the camera on the
-- object and drag it one step that way (native a11y_drag), then say whether
-- the spot is free (game.isSelectedObjectPlaceable). Tab reaches the context
-- bar's confirm / cancel buttons.
-- ---------------------------------------------------------------------------
local dragFn = resolve("a11y_drag")
local MOVE_STEP_X, MOVE_STEP_Y = 0.05, 0.07   -- one arrow press, as a fraction of the window

local function barContext()
    local c = nil
    pcall(function() c = manager:getContext() end)
    return c and tostring(c) or ""
end

local function placing()
    local m = false
    pcall(function() m = game.worldContext():isMovingNewObject() and true or false end)
    if not m then m = barContext():find("MOVE") ~= nil end
    return m
end

-- ---------------------------------------------------------------------------
-- Where the placed object is, relative to the nearest landmark.
-- Every world object keeps its grid tile in the variables pos_x / pos_y (the
-- game's own move code reads them; read here via native a11y_entity_tile). The island is drawn as a diamond: on
-- screen, left/right follows (x + y) and up/down follows (y - x). The signs
-- are learned from the first arrow presses (calibrate) instead of guessed.
-- ---------------------------------------------------------------------------
local function abs(v) return v < 0 and -v or v end

-- Lua can't read an entity's variables; the native a11y_entity_tile calls the
-- game's own pos_x / pos_y getters.
local entityTileFn = resolve("a11y_entity_tile")
local function entityTile(ent)
    if not ent or type(entityTileFn) ~= "function" then return nil end
    local ok, x, y = pcall(entityTileFn, ent)
    if ok then return x, y end
    return nil
end

-- The selected object's tile. While it is being moved, pos_x/pos_y still hold
-- the old spot; the live one is on the WorldContext (native a11y_move_tile,
-- the same fields game.isSelectedObjectPlaceable checks).
local moveTileFn = resolve("a11y_move_tile")
local function selectedTile()
    if placing() and type(moveTileFn) == "function" then
        local ok, x, y = pcall(function() return moveTileFn(game.worldContext()) end)
        if ok and x then return x, y end
    end
    return entityTile(selectedObject())
end

-- Screen direction of grid deltas: sx * (dx + dy) is right, sy * (dy - dx) is down.
local screenSign = { sx = 1, sy = 1, sxKnown = false, syKnown = false }

local function calibrate(dirX, dirY, gx, gy)
    if not gx or (gx == 0 and gy == 0) then return end
    if dirX ~= 0 and not screenSign.sxKnown and gx + gy ~= 0 then
        screenSign.sx = ((gx + gy > 0) == (dirX > 0)) and 1 or -1
        screenSign.sxKnown = true
        a11y_log("[where] calibrated sx=" .. screenSign.sx)
    elseif dirY ~= 0 and not screenSign.syKnown and gy - gx ~= 0 then
        screenSign.sy = ((gy - gx > 0) == (dirY > 0)) and 1 or -1
        screenSign.syKnown = true
        a11y_log("[where] calibrated sy=" .. screenSign.sy)
    end
end

local function directionWords(dx, dy)
    local h = screenSign.sx * (dx + dy)
    local v = screenSign.sy * (dy - dx)
    local hw = h > 0 and "right" or "left"
    local vw = v > 0 and "below" or "above"
    if abs(h) > 2 * abs(v) then return hw end
    if abs(v) > 2 * abs(h) then return vw end
    return vw .. " " .. hw
end

-- Every other structure and monster on the island, with its tile.
local function landmarks()
    -- Skip the object being placed itself (by id, not tile: whatever blocks it
    -- shares its tile and must stay in the list).
    local skip = {}
    pcall(function() skip[game.selectedMonsterId()] = true end)
    pcall(function() skip[game.selectedStructureId()] = true end)
    local out = {}
    pcall(function()
        local isl = game.player():getActiveIsland()
        local ss = isl:structures()
        for i = 0, ss:size() - 1 do
            local id = ss[i]
            local ent = nil; pcall(function() ent = game.GetStructure(id) end)
            local x, y = entityTile(ent)
            if x and not skip[id] then
                local rank = entityIs(ent, "isObstacle") and 3 or (entityIs(ent, "isDecoration") and 2 or 1)
                out[#out + 1] = { x = x, y = y, name = structureLabel(id) or "structure", rank = rank }
            end
        end
        local ms = isl:monsters()
        for i = 0, ms:size() - 1 do
            local uid = ms[i]
            local ent = nil; pcall(function() ent = game.GetMonster(uid) end)
            local x, y = entityTile(ent)
            if x and not skip[uid] then out[#out + 1] = { x = x, y = y, name = monsterLabel(uid), rank = 0 } end
        end
    end)
    return out
end

local whereLogged = false
-- "right of Small Bakery", "2 tiles above Noggy1", "on Small Rock".
local function whereText()
    local x, y = selectedTile()
    local list = x and landmarks() or {}
    a11y_log("[where] tile=" .. tostring(x) .. "," .. tostring(y))
    if not whereLogged then
        whereLogged = true
        a11y_log("[where] selected tile=" .. tostring(x) .. "," .. tostring(y) .. " landmarks=" .. #list
            .. (list[1] and (" first=" .. list[1].name .. "@" .. list[1].x .. "," .. list[1].y) or ""))
    end
    if not x then return nil end
    local best, bestD = nil, nil
    for _, l in ipairs(list) do
        local d = abs(l.x - x); if abs(l.y - y) > d then d = abs(l.y - y) end
        if not bestD or d < bestD then best, bestD = l, d end
    end
    if not best then return nil end
    if bestD == 0 then return "on " .. best.name end
    local dir = directionWords(x - best.x, y - best.y)
    if bestD == 1 then return dir .. " of " .. best.name end
    return bestD .. " tiles " .. dir .. " of " .. best.name
end

local function spotText()
    local ok, p = pcall(function() return game.isSelectedObjectPlaceable() end)
    local status = not ok and "Spot unknown" or (p and "Free spot" or "Blocked")
    local where = nil; pcall(function() where = whereText() end)
    if where then return status .. ", " .. where end
    return status
end

-- Where the object being placed is on screen, relative to the centre the
-- camera was put on. Lets repeated arrow presses drag from the object's
-- current spot without re-centring the camera (which costs ~0.6s) each time.
local placeAt = { x = 0, y = 0, t = -100 }
local PLACE_RECENTRE_SECONDS = 4      -- re-centre after a pause (camera may have moved)
local PLACE_MAX_OFFSET = 0.3          -- or when the object drifts toward the edge
local DRAG_SETTLE_SECONDS = 0.35      -- native drag takes ~0.25s, then the game updates

local function arrow(dx, dy)
    if not placing() then
        a11y_log("[place] arrow ignored, context=" .. barContext())
        return
    end
    if type(dragFn) ~= "function" then say("Drag function unavailable", true) return end
    local now = clock()
    local function drag()
        local x, y = TAP_FX + placeAt.x, TAP_FY + placeAt.y
        local nx, ny = x + dx * MOVE_STEP_X, y + dy * MOVE_STEP_Y
        local bx, by = selectedTile()
        if not dragFn(x, y, nx, ny) then return end        -- previous drag still running
        placeAt.x, placeAt.y, placeAt.t = nx - TAP_FX, ny - TAP_FY, clock()
        later(DRAG_SETTLE_SECONDS, function()
            local ax, ay = selectedTile()
            -- The drag missed the object: later drags would start from the
            -- wrong spot too, so re-centre the camera on it next time.
            if bx and ax and ax == bx and ay == by then
                placeAt.t = -100
                a11y_log("[place] drag did not move the object")
                say("Did not move. " .. spotText(), true)
                return
            end
            if bx and ax then
                calibrate(dx, dy, ax - bx, ay - by)
                if screenSign.learn then screenSign.learn(dx * MOVE_STEP_X, dy * MOVE_STEP_Y, ax - bx, ay - by) end
            end
            say(spotText(), true)
        end)
    end
    local far = placeAt.x > PLACE_MAX_OFFSET or -placeAt.x > PLACE_MAX_OFFSET
        or placeAt.y > PLACE_MAX_OFFSET or -placeAt.y > PLACE_MAX_OFFSET
    if now - placeAt.t > PLACE_RECENTRE_SECONDS or far then
        placeAt.x, placeAt.y, placeAt.t = 0, 0, now
        local obj = selectedObject()
        if obj then pcall(function() game.worldContext():zoomCameraToObject(obj, TAP_ZOOM, TAP_SECONDS) end) end
        later(TAP_SECONDS + 0.2, drag)
    else
        drag()
    end
end

-- Announce entering placement once (checked on the context bar's tick).
local wasPlacing = false
local function watchPlacing()
    local now = placing()
    if now and not wasPlacing then
        a11y_log("[place] placing, context=" .. barContext())
        placeAt.t = -100                 -- new placement: centre the camera on first move
        later(0.3, function()
            say("Placing " .. (selectedName() or "object") .. ". " .. spotText()
                .. ". Arrow keys move it. Tab to Confirm placement.", false)
        end)
    end
    wasPlacing = now
end
contextbarHook = watchPlacing

-- ---------------------------------------------------------------------------
-- Points of interest ([ and ] while placing): jump the object to a free tile
-- next to another object ("place it next to the Noggin").
-- The move is a series of drags. Screen offset per tile is learned from what
-- drags actually do: screen x = A * (dx + dy), screen y = B * (dy - dx), in
-- window fractions. Each drag is followed by reading the live tile, so errors
-- correct themselves on the next drag.
-- ---------------------------------------------------------------------------
local poiStep, spotStep
do
    local MAX_DRAG = 0.3                -- longest single drag from the centre
    local MOVE_TRIES = 6                -- drags allowed to reach one tile
    local NEIGHBOURS = {                -- tried in order until one is free
        { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 }, { 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 },
        { 2, 0 }, { 0, 2 }, { -2, 0 }, { 0, -2 }, { 3, 0 }, { 0, 3 }, { -3, 0 }, { 0, -3 },
    }
    local poi = { list = nil, index = 0, t = -100, gen = 0, target = nil, spots = nil, spot = 0 }
    local setTileFn = resolve("a11y_set_move_tile")
    local SPOT_RADIUS = 4               -- look this many tiles around the object
    local MAX_SPOTS = 12

    -- Is (x, y) free for the object being placed? Writes the live tile, asks
    -- the game's own check, and restores it in the same call (no frame sees it).
    local function freeAt(x, y)
        if type(setTileFn) ~= "function" or type(moveTileFn) ~= "function" then return nil end
        local free = nil
        pcall(function()
            local wc = game.worldContext()
            local ox, oy = moveTileFn(wc)
            if not ox then return end
            setTileFn(wc, x, y)
            local ok, p = pcall(function() return game.isSelectedObjectPlaceable() end)
            setTileFn(wc, ox, oy)
            free = ok and p and true or false
        end)
        return free
    end

    -- Free tiles around the target, nearest rings first. nil = can't probe.
    local function freeSpots(target)
        local out = {}
        for d = 1, SPOT_RADIUS do
            for dx = -d, d do
                for dy = -d, d do
                    if (abs(dx) == d or abs(dy) == d) and #out < MAX_SPOTS then
                        local f = freeAt(target.x + dx, target.y + dy)
                        if f == nil then return nil end
                        if f then out[#out + 1] = { x = target.x + dx, y = target.y + dy } end
                    end
                end
            end
            if #out >= MAX_SPOTS then break end
        end
        return out
    end

    screenSign.learn = function(fx, fy, gx, gy)
        if gx + gy ~= 0 and abs(fx) > 0.02 then
            local a = fx / (gx + gy)
            screenSign.A = screenSign.A and (screenSign.A + a) / 2 or a
            screenSign.sx, screenSign.sxKnown = screenSign.A > 0 and 1 or -1, true
        end
        if gy - gx ~= 0 and abs(fy) > 0.02 then
            local b = fy / (gy - gx)
            screenSign.B = screenSign.B and (screenSign.B + b) / 2 or b
            screenSign.sy, screenSign.syKnown = screenSign.B > 0 and 1 or -1, true
        end
    end

    -- Drag the object by (fx, fy) of the window, re-centring the camera on it
    -- first when the drag would leave the safe middle of the screen.
    local function dragBy(gen, fx, fy, done)
        local function go()
            if gen ~= poi.gen then return end
            local x, y = TAP_FX + placeAt.x, TAP_FY + placeAt.y
            local bx, by = selectedTile()
            if not dragFn(x, y, x + fx, y + fy) then later(0.2, go) return end
            placeAt.x, placeAt.y, placeAt.t = placeAt.x + fx, placeAt.y + fy, clock()
            later(DRAG_SETTLE_SECONDS, function()
                if gen ~= poi.gen then return end
                local ax, ay = selectedTile()
                if bx and ax then screenSign.learn(fx, fy, ax - bx, ay - by) end
                done()
            end)
        end
        local nx, ny = placeAt.x + fx, placeAt.y + fy
        if clock() - placeAt.t > PLACE_RECENTRE_SECONDS or abs(nx) > 0.4 or abs(ny) > 0.35 then
            placeAt.x, placeAt.y, placeAt.t = 0, 0, clock()
            local obj = selectedObject()
            if obj then pcall(function() game.worldContext():zoomCameraToObject(obj, TAP_ZOOM, TAP_SECONDS) end) end
            later(TAP_SECONDS + 0.2, go)
        else
            go()
        end
    end

    -- Drag until the live tile is (tx, ty); done(reached).
    local function moveTo(gen, tx, ty, tries, done)
        if gen ~= poi.gen then return end
        local cx, cy = selectedTile()
        if not cx then done(false) return end
        if cx == tx and cy == ty then done(true) return end
        if tries <= 0 then done(false) return end
        local dx, dy = tx - cx, ty - cy
        local fx, fy
        if screenSign.A and screenSign.B then
            fx, fy = screenSign.A * (dx + dy), screenSign.B * (dy - dx)
        else
            fx, fy = 0.12, 0.12             -- first time: a diagonal drag teaches both axes
        end
        local m = abs(fx) > abs(fy) and abs(fx) or abs(fy)
        if m > MAX_DRAG then fx, fy = fx * MAX_DRAG / m, fy * MAX_DRAG / m end
        dragBy(gen, fx, fy, function() moveTo(gen, tx, ty, tries - 1, done) end)
    end

    local function placeable()
        local ok, p = pcall(function() return game.isSelectedObjectPlaceable() end)
        return ok and p
    end

    local function relation(target)
        local x, y = selectedTile()
        if not x then return "near " .. target.name end
        local dx, dy = x - target.x, y - target.y
        local d = abs(dx); if abs(dy) > d then d = abs(dy) end
        if d == 0 then return "on " .. target.name end
        local dir = directionWords(dx, dy)
        if d == 1 then return dir .. " of " .. target.name end
        return d .. " tiles " .. dir .. " of " .. target.name
    end

    local function goToSpot(gen, target)
        local sp = poi.spots[poi.spot]
        moveTo(gen, sp.x, sp.y, MOVE_TRIES, function(reached)
            if gen ~= poi.gen then return end
            local tail = ", " .. poi.spot .. " of " .. #poi.spots .. (poi.suffix or "")
            poi.suffix = nil
            if reached and placeable() then say("Free spot, " .. relation(target) .. tail, true)
            else say(spotText() .. tail, true) end
        end)
    end

    -- Probe the free tiles around the target, then move to the first. Without
    -- probing, try neighbouring tiles one by one by dragging.
    local function jumpTo(gen, target)
        poi.target, poi.spots, poi.spot = target, freeSpots(target), 1
        if poi.spots then
            if #poi.spots == 0 then
                say("No free spots near " .. target.name, true)
                return
            end
            a11y_log("[poi] " .. #poi.spots .. " free spots near " .. target.name)
            if #poi.spots > 1 then poi.suffix = ". Comma and period for the other free spots" end
            goToSpot(gen, target)
            return
        end
        local i = 0
        local function nextSpot()
            if gen ~= poi.gen then return end
            i = i + 1
            local off = NEIGHBOURS[i]
            if not off then
                say("No free spot found next to " .. target.name .. ". " .. spotText(), true)
                return
            end
            moveTo(gen, target.x + off[1], target.y + off[2], MOVE_TRIES, function(reached)
                if gen ~= poi.gen then return end
                if reached and placeable() then
                    a11y_log("[poi] free at offset " .. off[1] .. "," .. off[2] .. " of " .. target.name)
                    say("Free spot, " .. relation(target), true)
                else
                    nextSpot()
                end
            end)
        end
        nextSpot()
    end

    spotStep = function(dir)
        if not placing() then return end
        if not poi.spots or #poi.spots == 0 or not poi.target then
            say("Press a bracket to pick an object first", true)
            return
        end
        poi.spot = poi.spot + dir
        if poi.spot > #poi.spots then poi.spot = 1 end
        if poi.spot < 1 then poi.spot = #poi.spots end
        poi.gen = poi.gen + 1
        goToSpot(poi.gen, poi.target)
    end

    poiStep = function(dir)
        if not placing() then
            say("Brackets jump between objects while you are placing something", true)
            return
        end
        if type(dragFn) ~= "function" or type(moveTileFn) ~= "function" then
            say("Jumping is unavailable", true)
            return
        end
        if not poi.list or clock() - poi.t > 30 then
            -- Monsters, then buildings, decorations, and trees/rocks last.
            local list = landmarks()
            for i, l in ipairs(list) do l.order = i end
            table.sort(list, function(a, b)
                if a.rank ~= b.rank then return a.rank < b.rank end
                return a.order < b.order
            end)
            poi.list, poi.index = list, 0
        end
        poi.t = clock()
        local n = #poi.list
        if n == 0 then say("No objects to jump to", true) return end
        poi.index = poi.index + dir
        if poi.index > n then poi.index = 1 end
        if poi.index < 1 then poi.index = n end
        poi.gen = poi.gen + 1
        local target = poi.list[poi.index]
        say(target.name .. ", " .. poi.index .. " of " .. n, true)
        local gen = poi.gen
        later(0.05, function() jumpTo(gen, target) end)
    end
end

-- The checkmark / X drawn next to the object being placed are world sprites,
-- not menu buttons. They do what ContextBar.confirm_move / cancel_move do:
-- close the "show grid" popup, then game.moveObjectDone(true/false).
local function closeGridPopup()
    if currentPopupName() == "showgrid_popup" then pcall(game.popPopUp) end
end

local function confirmPlacement()
    local ok, p = pcall(function() return game.isSelectedObjectPlaceable() end)
    if ok and not p then say("Blocked here. Move it with the arrow keys first.", true) return end
    closeGridPopup()
    local done, err = pcall(function() game.moveObjectDone(true) end)
    if not done then a11y_log("[place] moveObjectDone(true) failed: " .. tostring(err)) say("Could not place", true) return end
    say("Placed", true)
end

local function cancelPlacement()
    closeGridPopup()
    pcall(function() game.moveObjectDone(false) end)
    pcall(function() manager:setContext(manager:getDefaultContext()) end)
    say("Placement cancelled", true)
end

local function deselect()
    pcall(function() game.deselectSelectedObject() end)
    pcall(function() manager:setContext(manager:getDefaultContext()) end)
    say("Deselected", true)
end

-- ---------------------------------------------------------------------------
-- Navigation: Tab / Shift+Tab move between controls, Enter activates.
-- Driven by native hotkeys through queue_lua (a safe frame boundary on the game
-- thread). Context: an open list (Places/Objects), else a tutorial popup, else
-- the top popup, else the selected object's actions, else the island (context
-- bar + HUD). Controls are re-scanned on every action, so we never touch a
-- stale object. Virtual entries ({ label, fn }) sit alongside real elements.
-- ---------------------------------------------------------------------------
local nav = { items = {}, labels = {}, index = 0, key = nil, base = nil, remembered = {} }

-- Roots to navigate, a context key for the current screen, and virtual entries.
local function navContext()
    -- Tutorial popups sit on their own layer, not the popup stack, and only
    -- tick while shown.
    for _, n in ipairs({ "popup_tutorial", "popup_tutorial_streamlined" }) do
        local r = liveMenu(n)
        if r then return { r }, "popup:" .. n, {} end
    end
    if placing() then
        -- Confirm / Cancel are world sprites: offer them as entries, plus the
        -- Show Grid toggle that opens alongside.
        local roots = {}
        for f in pairs(menuState.sidePanels) do
            local r = liveMenu(f)
            if r then roots[#roots + 1] = r end
        end
        return roots, "placing", {
            { "Confirm placement", confirmPlacement },
            { "Check spot", function() say(spotText(), true) end },
            { "Cancel placement", cancelPlacement },
        }
    end
    -- After placing or cancelling, the Show Grid toggle can stay reported as the
    -- top popup, and a selected decoration brings its Decoration Size panel.
    -- Outside placement they are not screens: show the island or selection.
    local gridLeftover = menuState.sidePanels[currentPopupName()]
    if not popupOpen() or gridLeftover then
        popupStack = {}
        local ov, ovName = topOverlay()
        if ov then return { ov }, "popup:" .. ovName, {} end
        -- No popup or overlay: navigate the island.
        local cb = liveMenu("contextbar")
        if objectSelected() then
            -- Only the selection's own actions: no HUD bleed-through.
            local name = selectedName() or "object"
            local virtual = {
                { "Tap " .. name, tapSelected },
                { "Deselect " .. name, deselect },
            }
            -- Its bar (Info, Sell, Move...) plus a Decoration Size / Show Grid panel.
            local roots = {}
            if cb then roots[#roots + 1] = cb end
            local sp = liveMenu("scale_popup")
            if sp then roots[#roots + 1] = sp end
            return roots, "selected:" .. name, virtual
        end
        -- Nothing selected: main bar (Market, Options...), the HUD, then the
        -- island's structures and monsters, so Tab alone reaches everything.
        local roots = {}
        if cb then roots[#roots + 1] = cb end
        local ok, hud = pcall(game.getHUD); if ok and hud then roots[#roots + 1] = hud end
        local virtual = {}
        local target = tutorialTarget()
        if target then virtual[1] = { "Tutorial: " .. target[1], target[2], first = true, group = "Tutorial" } end
        for _, o in ipairs(islandObjects()) do virtual[#virtual + 1] = { o[1], o[2], group = OBJECT_GROUPS[o.rank] } end
        return roots, "island", virtual
    end
    -- A real popup is open. Reconcile the stack with the live top name in case a
    -- popup closed via a path we didn't hook (Esc, setContext, etc.).
    local name = currentPopupName()
    while #popupStack > 0 and tostring(popupStack[#popupStack].id) ~= name do
        popupStack[#popupStack] = nil
    end
    -- Prefer live roots from the menus' own ticks (works for popups opened
    -- from C++ too), and of those the newest: the game can keep naming the
    -- Bakery while its "Would you like to bake...?" confirmation is on top.
    local top2 = ""; pcall(function() top2 = tostring(game.getTopPopUpName()) end)
    local best, bestKey, bestT = nil, nil, -1
    local function consider(root, key, file)
        local m = file and menus[file]
        if root and m and (m.appeared or 0) > bestT then best, bestKey, bestT = root, key, m.appeared or 0 end
    end
    consider(liveMenu(name), name, name)
    consider(liveMenu(top2), top2, top2)
    local ov, ovKey, ovFile = topOverlay()
    consider(ov, ovKey, ovFile)
    if best then
        -- Popups pushed from Lua (Options' Screen Size, Language) are built
        -- inside the screen below them, all under one shared root. List only
        -- the popup's own element, or the screen behind leaks in (and pressing
        -- Language there stacks a second popup on top).
        -- (Not for a reused popup whose newest panel topOverlay already picked.)
        local m = menus[bestKey]
        local own = bestKey and not (m and m.panel) and findNamed(best, bestKey, 6)
        if own and isVisible(own) then best = own end
        return { best }, "popup:" .. bestKey, {}
    end
    local top = popupStack[#popupStack]
    if top and top.obj then
        return { top.obj }, "popup:" .. tostring(top.id), {}
    end
    -- No handle at all: stay silent rather than navigate the island behind it.
    return {}, "popup:" .. name, {}
end

local function navEnsure()
    local roots, key, virtual = navContext()
    nav.items, nav.labels, nav.groups = {}, {}, {}
    for _, r in ipairs(roots) do
        local items, labels, groups = scanClickables(r)
        for i = 1, #items do
            nav.items[#nav.items + 1] = items[i]
            nav.labels[#nav.labels + 1] = labels[i]
            nav.groups[#nav.groups + 1] = groups[i] or "Buttons"
        end
    end
    for _, v in ipairs(virtual) do
        if v.first then                          -- e.g. the tutorial target: before everything
            table.insert(nav.items, 1, { virtual = v[2] })
            table.insert(nav.labels, 1, v[1])
            table.insert(nav.groups, 1, v.group or "Actions")
        else
            nav.items[#nav.items + 1] = { virtual = v[2] }
            nav.labels[#nav.labels + 1] = v[1]
            nav.groups[#nav.groups + 1] = v.group or "Actions"
        end
    end
    -- On the island, show one group at a time (Buttons, Buildings, Monsters,
    -- Decorations, Trees and rocks); [ and ] switch groups. The tutorial entry
    -- stays at the top of every group.
    nav.groupOrder = {}
    if key == "island" then
        local seen = {}
        for _, g in ipairs(nav.groups) do
            if g ~= "Tutorial" and not seen[g] then seen[g] = true; nav.groupOrder[#nav.groupOrder + 1] = g end
        end
        if #nav.groupOrder > 1 then
            if not nav.group or not seen[nav.group] then nav.group = nav.groupOrder[1] end
            local items, labels, groups = {}, {}, {}
            for i = 1, #nav.items do
                if nav.groups[i] == nav.group or nav.groups[i] == "Tutorial" then
                    items[#items + 1], labels[#labels + 1], groups[#groups + 1] = nav.items[i], nav.labels[i], nav.groups[i]
                end
            end
            nav.items, nav.labels, nav.groups = items, labels, groups
            key = key .. "@" .. nav.group
        else
            nav.groupOrder = {}
        end
    end
    -- Reset focus when the screen changes. The item count is part of the key
    -- so a context bar that changes buttons resets too.
    -- Remember the place on the screen we leave and restore it on return
    -- (deselecting the Bakery puts you back on the Bakery, not at the top).
    local base = key
    key = key .. "#" .. #nav.items
    if key ~= nav.key then
        if nav.base and nav.base ~= base then nav.remembered[nav.base] = nav.index end
        local saved = nav.base ~= base and nav.remembered[base] or nil
        nav.index = (saved and saved <= #nav.items) and saved or 0
    end
    nav.key, nav.base = key, base
    return #nav.items > 0
end

-- edge: Home/End, jump to the first (dir < 0) or last (dir > 0) item.
local function navMove(dir, edge)
    if vmenu.active then                        -- Places / Objects list takes precedence
        local n = #vmenu.items
        vmenu.index = edge and (dir > 0 and n or 1) or (vmenu.index + dir)
        if vmenu.index > n then vmenu.index = 1 end
        if vmenu.index < 1 then vmenu.index = n end
        local it = vmenu.items[vmenu.index]
        local label = it[1]
        if it.live then pcall(function() label = it.live() or label end) end
        say(label .. ", " .. vmenu.index .. " of " .. n, true)
        return
    end
    local t0 = clock()
    if not navEnsure() then                     -- nothing navigable
        if popupOpen() then say("Nothing to navigate in this dialog", true) end
        return
    end
    local took = clock() - t0                   -- find screens that make Tab feel slow
    if took > 0.03 then a11y_log(string.format("[nav] slow scan %.0f ms, %d items, %s", took * 1000, #nav.items, tostring(nav.key))) end
    local prev = nav.index
    nav.index = edge and (dir > 0 and #nav.items or 1) or (nav.index + dir)
    if nav.index > #nav.items then nav.index = 1 end
    if nav.index < 1 then nav.index = #nav.items end
    -- Entering a named list ("Monster 1 list") says its name first.
    local g = nav.groups[nav.index]
    local prefix = (g and g:find(" list$") and g ~= nav.groups[prev]) and (g .. ". ") or ""
    say(prefix .. (nav.labels[nav.index] or "item") .. ", " .. nav.index .. " of " .. #nav.items, true)
end

-- [ and ] when not placing: jump between groups of the list (buttons,
-- buildings, monsters, decorations, trees and rocks), like headings.
local function groupJump(groups, index, n, dir)
    local starts = {}
    for i = 1, n do
        if i == 1 or groups[i] ~= groups[i - 1] then starts[#starts + 1] = i end
    end
    if #starts < 2 then return nil end
    if dir > 0 then
        for _, st in ipairs(starts) do if st > index then return st end end
        return starts[1]
    end
    for k = #starts, 1, -1 do if starts[k] < index then return starts[k] end end
    return starts[#starts]
end

local function navGroupJump(dir)
    if vmenu.active then
        local groups = {}
        for i, it in ipairs(vmenu.items) do groups[i] = OBJECT_GROUPS[it.rank] or "Items" end
        local n = #vmenu.items
        local to = groupJump(groups, vmenu.index, n, dir)
        if not to then navMove(dir) return end
        vmenu.index = to
        local it = vmenu.items[to]
        local label = it[1]
        if it.live then pcall(function() label = it.live() or label end) end
        say(groups[to] .. ": " .. label .. ", " .. to .. " of " .. n, true)
        return
    end
    if not navEnsure() then return end
    local order = nav.groupOrder or {}
    if #order < 2 then
        local to = groupJump(nav.groups, nav.index, #nav.items, dir)
        if not to then navMove(dir) return end
        nav.index = to
        say(nav.groups[to] .. ": " .. (nav.labels[to] or "item") .. ", " .. to .. " of " .. #nav.items, true)
        return
    end
    local cur = 1
    for i, g in ipairs(order) do if g == nav.group then cur = i end end
    cur = cur + dir
    if cur > #order then cur = 1 end
    if cur < 1 then cur = #order end
    nav.group = order[cur]
    navEnsure()                                 -- refilter; restores this group's place
    local n = #nav.items
    if nav.index < 1 then nav.index = 1 end
    say(nav.group .. ", " .. n .. (n == 1 and " item. " or " items. ")
        .. (nav.labels[nav.index] or "item") .. ", " .. nav.index .. " of " .. n, true)
end

-- Press an element the way the game does. Direct touch calls work for most
-- buttons; list rows like bakery foods only answer the game's own keyboard
-- path (template_barbutton's gotMsgKeyUp), DoStoredScript on the Touch.
local function pressElement(el)
    menuState.touch()                           -- the press may free this screen
    local ok, err = pcall(function()
        el.Touch:onTouchDown(el, 0, 0)
        el.Touch:onTouchUp(el, 0, 0)
    end)
    if ok then return true end
    a11y_log("[nav] direct touch failed (" .. tostring(err) .. "), trying DoStoredScript")
    pcall(function() el["Touch"]:DoStoredScript("onTouchDown") end)
    local ok2, err2 = pcall(function() el["Touch"]:DoStoredScript("onTouchUp") end)
    if not ok2 then a11y_log("[nav] DoStoredScript failed: " .. tostring(err2)) end
    return ok2
end

-- Enter is also the game's own confirm key: buttons mapped to it (Yes, OK)
-- press themselves when Enter is released. So after we press No, the game
-- would press Yes on key up and win. Disarm those buttons for a moment: clear
-- the key they caught and switch their touch off until Enter is released.
--
-- Element handles must never outlive the frame: pressing a button can close
-- the screen (Market, a confirmation), and writing to a freed element crashes
-- the game outright (pcall can't catch it). So mute only on menus that ticked
-- just now, BEFORE the press, and switch back on from inside each menu's own
-- tick (runPending perRoot), matching buttons by identity, not by a kept handle.
do
local MUTE_SECONDS = 0.6
local function eachEnterButton(root, confirmKey, fn)
    local budget = 3000
    local function walk(el, depth)
        if depth > 12 or budget <= 0 then return end
        budget = budget - 1
        pcall(function()
            local tv = el:templateVars()
            if tonumber(tv.buttonMapping) == confirmKey or tonumber(tv.buttonMappingAlt) == confirmKey then fn(el) end
        end)
        local kids = nil; pcall(function() kids = el:elements() end)
        local n = 0; pcall(function() n = kids:size() end)
        for i = 0, n - 1 do
            local c = nil; pcall(function() c = kids[i] end)
            if c then walk(c, depth + 1) end
        end
    end
    pcall(walk, root, 0)
end

function nav.muteGameEnter(skip)
    local confirmKey = nil
    pcall(function() confirmKey = tonumber(game.confirmButton()) end)
    if not confirmKey or confirmKey == 0 then return end
    local now, ids, count = clock(), {}, 0
    local skipId = skip and tostring(skip)
    for _, m in pairs(menus) do
        if menuState.usable(m) then
            eachEnterButton(m.root, confirmKey, function(el)
                if tostring(el) == skipId then return end
                pcall(function() el("buttonDown"):SetInt(0) end)
                local touch = el["Touch"]
                if touch("enabled"):GetInt() ~= 0 then
                    touch("enabled"):SetInt(0)
                    ids[tostring(el)] = true
                    count = count + 1
                end
            end)
        end
    end
    if count == 0 then return end
    a11y_log("[nav] muted " .. count .. " Enter-mapped button(s)")
    local t = now + MUTE_SECONDS
    pending[#pending + 1] = { t = t, stop = t + 1.5, perRoot = true, done = {}, fn = function(root)
        eachEnterButton(root, confirmKey, function(el)
            if ids[tostring(el)] then
                ids[tostring(el)] = nil
                pcall(function() el["Touch"]("enabled"):SetInt(1) end)
            end
        end)
    end }
end
end -- do (Enter muting)

-- After picking a monster on the breeding screen: what is chosen, what next.
function nav.breedingStatus()
    local root = liveMenu("breeding_v2")
    if not root then return end
    local a, b, heart = FRIENDLY.__social.breedPicks(root)
    local h = heart and elementText(heart)
    if a and b then
        say("Breeding " .. a .. " with " .. b .. ". Now press " .. ((h and h ~= "") and h or "the Breed button")
            .. ", near the top of the list.", true)
    elseif a or b then
        say((a or b) .. " picked as " .. (a and "monster 1" or "monster 2") .. ". Now choose "
            .. (a and "monster 2" or "monster 1") .. ".", true)
    else
        say("No monsters picked.", true)
    end
end

-- After picking an island on the Map: its details (Main/IslandName and
-- IslandInfo: collected counts, cost, requirements), then focus on GO.
-- Keep tapping the hatching fanfare's egg until it cracks (7 taps in all).
-- Each tap finds the egg afresh: no handle is kept across frames.
function nav.crackEgg(n)
    later(0.25, function()
        local root = liveMenu("popup_hatch_monster_fanfare")
        local egg = root and findNamed(root, "EggImage", 4)
        if not egg or not isClickable(egg) or n > 9 then
            if n > 1 then say("The egg cracked open. Tab for Continue when it appears.", true) end
            return
        end
        pressElement(egg)
        nav.crackEgg(n + 1)
    end)
end

function nav.mapInfo()
    local root = liveMenu("map_base")
    local main = root and findNamed(root, "Main", 3)
    if not main or not isVisible(main) then return end
    local parts = { elementText(findNamed(main, "IslandName", 1)) or "Island" }
    local budget = 200
    local function walk(el, depth)
        if depth > 4 or budget <= 0 then return end
        local kids = nil; pcall(function() kids = el:elements() end)
        local n = 0; pcall(function() n = kids:size() end)
        for i = 0, n - 1 do
            budget = budget - 1
            local c = nil; pcall(function() c = kids[i] end)
            if c and isVisible(c) then
                local nm = elementName(c) or ""
                local t = elementText(c)
                if t and t ~= "?" and not t:find("^[%p%s]*$") then
                    local rarity = nm:match("^Collected(%u%l+)$")
                    parts[#parts + 1] = rarity and (rarity .. " " .. t) or t
                end
                walk(c, depth + 1)
            end
        end
    end
    walk(findNamed(main, "IslandInfo", 1), 0)
    -- Put focus on GO, so Enter travels there.
    local hint = ""
    if navEnsure() then
        for i, l in ipairs(nav.labels) do
            if elementName(nav.items[i]) == "ActivateButton" then
                nav.index = i
                hint = " " .. l .. " is focused: press Enter to go, or Tab to look around."
                break
            end
        end
    end
    say(table.concat(parts, ", ") .. "." .. hint, true)
end

local function navActivate()
    if vmenu.active then                        -- run the chosen list entry
        if vmenu.index < 1 then say("Press Tab to choose", true) return end
        local dest = vmenu.items[vmenu.index]
        vmenu.active = false
        if vmenu.kind == "places" then say("Opening " .. dest[1], false) end
        pcall(nav.muteGameEnter)                -- before: the action may close screens
        menuState.touch()
        pcall(dest[2])
        return
    end
    if not navEnsure() then return end
    local el = nav.items[nav.index]
    if not el then say("Press Tab to choose", true) return end
    local label = nav.labels[nav.index] or "item"
    if type(el) == "table" and el.virtual then
        pcall(nav.muteGameEnter)
        menuState.touch()
        pcall(el.virtual)
        return
    end
    pcall(nav.muteGameEnter, el)                -- before the press, never after
    -- Decide follow-ups before the press: never touch el after it.
    local breedRow = (nav.groups[nav.index] or ""):find("^Monster %d list$") and (elementName(el) or ""):find("^entry%d")
    local isle = false
    pcall(function() isle = (elementName(el) or ""):find("^entry%d") ~= nil and el:parent():name() == "IslandList" end)
    if elementName(el) == "EggImage" then
        if pressElement(el) then say("Cracking the egg", true); nav.crackEgg(2) end
        return
    end
    if pressElement(el) then say(label, false) else say("Could not activate " .. label, true) end
    if breedRow then later(0.4, nav.breedingStatus) end
    if isle then later(0.5, nav.mapInfo) end
    -- Don't force an index reset here: navContext's key already changes (and
    -- resets focus) if a popup opened or the screen changed. If activation did
    -- nothing to the screen, keep the user's place in the list.
end

-- ---------------------------------------------------------------------------
-- Escape / Backspace: go back. Closes our lists, cancels placement, presses
-- the screen's Close / Back / No / Cancel button, or deselects.
-- The game handles Escape itself on some screens, so we wait a moment and
-- only act if the screen didn't change; otherwise one press would go back twice.
-- ---------------------------------------------------------------------------
local goBack
do
local BACK_NAMES = { CloseButton = true, BackButton = true, NoButton = true, CancelButton = true,
                     ExitButton = true, DismissButton = true, Close = true }
local BACK_WORDS = { "close", "back", "cancel", "no", "not now", "later", "maybe later", "exit", "done" }
local OK_NAMES = { OkayButton = true, OkButton = true }
-- Menus with a text box: Backspace there deletes text, so leave it alone.
local TEXT_ENTRY_MENUS = { "bind_email", "bind_password", "composer_base", "friends_invite", "login_email",
    "login_mfa", "login_register_email", "login_register_password", "popup_delete_account",
    "popup_name_entry", "popup_referral_sending", "popup_text_entry", "tribal" }
local BACK_WAIT_SECONDS = 0.5           -- the game's own Escape gets this long first
local pressEscapeFn = resolve("a11y_press_escape")

local function textEntryOpen()
    for _, f in ipairs(TEXT_ENTRY_MENUS) do
        if liveMenu(f) then return true end
    end
    return false
end

local function screenKey()
    local key = nil
    pcall(function() local _, k = navContext(); key = k end)
    return tostring(key) .. "|" .. tostring(currentPopupName()) .. "|" .. tostring(selectionKey()) .. "|" .. tostring(placing())
end

-- A Close/Back/No button among these controls: el, label.
local function backButtonIn(items, labels)
    local okEl, okLabel, okCount = nil, nil, 0
    for i, el in ipairs(items) do
        if type(el) ~= "table" then
            local nm = elementName(el)
            local label = labels[i] or ""
            if nm and BACK_NAMES[nm] then return el, label end
            local lower = label:lower()
            for _, w in ipairs(BACK_WORDS) do
                -- "Exit" only as the whole label: never "EXIT GAME" on Options.
                if lower == w or (w ~= "exit" and lower:find("^" .. w .. "[%s,%.:]")) then return el, label end
            end
            -- "Continue" (rewards, "Click to continue") is the way out too.
            if (nm and OK_NAMES[nm]) or lower == "continue" then okEl, okLabel, okCount = el, label, okCount + 1 end
        end
    end
    -- A message with only an OK button: OK is the way out.
    if okCount == 1 and #items <= 2 then return okEl, okLabel end
    return nil
end

-- The Close/Back/No button for the current screen. Some screens (the Bakery)
-- keep theirs on the context bar at the bottom, not in their own window.
local function findBackButton()
    if navEnsure() then
        local el, label = backButtonIn(nav.items, nav.labels)
        if el then return el, label end
    end
    -- Context bar buttons run a named function (close_bakery, close_goals,
    -- cancel_scale, cancel_breeding...), reliable even for icon-only buttons.
    local cb = liveMenu("contextbar")
    if cb then
        local items, labels = scanClickables(cb)
        for i, el in ipairs(items) do
            local fn = ""; pcall(function() fn = el("FunctionName"):GetString() or "" end)
            if fn:find("^close") or fn:find("^cancel") or fn:find("^back") then
                return el, (labels[i] and labels[i] ~= "" and labels[i]) or "Close"
            end
        end
        for i, el in ipairs(items) do
            local lower = (labels[i] or ""):lower()
            if lower == "close" or lower == "back" or lower == "done" or lower == "cancel" then return el, labels[i] end
        end
    end
    return nil
end

local function doBack()
    if placing() then cancelPlacement() return end
    if currentPopupName() == "showgrid_popup" then        -- leftover from placing
        closeGridPopup()
        say("Back to the island", true)
        return
    end
    -- A selected decoration's Decoration Size panel: deselect, and close the
    -- panel if the game leaves it behind.
    if currentPopupName() == "scale_popup" then
        if objectSelected() then deselect() else say("Back to the island", true) end
        later(0.3, function()
            if currentPopupName() == "scale_popup" and not objectSelected() and not placing() then
                pcall(game.popPopUp)
            end
        end)
        return
    end
    local onScreen = popupOpen() or topOverlay() ~= nil
    if onScreen or objectSelected() then
        local el, label = findBackButton()
        if el then
            a11y_log("[back] pressing " .. tostring(elementName(el)) .. " (" .. tostring(label) .. ")")
            if pressElement(el) then say(label ~= "" and label or "Back", true) return end
        end
    end
    if objectSelected() then deselect() return end
    if onScreen then
        a11y_log("[back] no close button on " .. tostring(currentPopupName()))
        say("No close button found here", true)
    end
end

function goBack(key)
    if key == "backspace" then
        if textEntryOpen() then return end
        -- Backspace is a real Escape for the game: its own Escape handling runs
        -- first, and the Escape hotkey brings the mod's fallback after it.
        if type(pressEscapeFn) == "function" and not vmenu.active then
            pressEscapeFn()
            return
        end
    end
    if vmenu.active then
        vmenu.active = false
        say("Closed", true)
        return
    end
    local before = screenKey()
    later(BACK_WAIT_SECONDS, function()
        if screenKey() ~= before then
            a11y_log("[back] game handled " .. key)
            return
        end
        doBack()
    end)
end
end

-- ---------------------------------------------------------------------------
-- Tutorial "Continue" (Ctrl+Shift+Enter).
--
-- Tutorial speech popups (e.g. the Bakery/Cookies message) are a separate C++
-- layer: NOT a game.pushPopUp popup, NOT in any reachable element tree, so we
-- can neither read their text nor find their Continue button. The only lever the
-- scripts expose is advancing the tutorial by sending MsgNextTutorialStep to the
-- engine receiver (see IslandPurchaseFanfare.lua). This dismisses/advances the
-- current tutorial step.
-- ---------------------------------------------------------------------------
-- Tutorial dialogs are C++-drawn: no element to click, no dismiss API, and
-- MsgNextTutorialStep does NOT dismiss them. So: press once -> synthesize a real
-- mouse click on the Continue button's on-screen spot (native a11y_click_fraction);
-- press AGAIN quickly (<1.5s, click didn't work) -> skip the whole first-time
-- tutorial via game.endIslandFirstTimeTutorial(). Spacing presses out >1.5s just
-- clicks again (for the next speech step).
-- ---------------------------------------------------------------------------
-- Live tutorial reader. This mod overrides the tutorial menus (data/menus/*.xml,
-- generated by scripts/Build-MenuOverrides.ps1) so their own onTick calls
-- a11y_tutTick(root, menu) every frame. We get a fresh handle while the menu
-- exists and stop getting one the moment it's gone, so we never hold a stale one.
-- ---------------------------------------------------------------------------
local TUT_STABLE_FRAMES = 6      -- text must hold steady this many frames before speaking
local TUT_FRESH_SECONDS = 0.5    -- handle is live if a tick arrived this recently

local tut = { root = nil, menu = nil, lastTick = -100, spoken = "", pending = "", stable = 0, seen = {} }

local function sentence(s)
    if s:find("[%.!?]$") then return s end
    return s .. "."
end


local function tutText(root, elName)
    local visible = 1
    pcall(function() visible = root[elName]["Text"]("visible"):GetInt() end)
    if visible == 0 then return nil end
    local t = nil
    pcall(function() t = root[elName]["Text"]("text"):GetString() end)
    return cleanText(t)
end

-- Tutorial popups are filled from C++, invisible to the Lua "text" property.
-- The native hook on the game's ShowTutorialPopup captures title + text and
-- calls a11y_onTutorialPopup; we keep the message for re-reading.
local popupTextFn = resolve("a11y_tutorial_popup_text")
local tutPopupMsg = nil

local function tutorialPopupMessage()
    if type(popupTextFn) ~= "function" then return nil end
    local ok, title, text = pcall(popupTextFn)
    if not ok then return nil end
    local parts = {}
    for _, s in ipairs({ title, text }) do
        local t = cleanText(s)
        if t then parts[#parts + 1] = sentence(t) end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " ")
end

local function onTutorialPopup()
    tutPopupMsg = tutorialPopupMessage()
    if not tutPopupMsg then return end
    a11y_log("[tut] popup: " .. tutPopupMsg)
    say(tutPopupMsg .. " Control Shift Enter to continue.", true)
end

local function tutMessage(root, menu)
    if menu ~= "tutorial" then return tutPopupMsg end
    local parts = {}
    local names = (menu == "tutorial") and { "primaryText", "SecondaryText" } or { "Title", "Text" }
    for _, nm in ipairs(names) do
        local t = tutText(root, nm)
        if t then parts[#parts + 1] = sentence(t) end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " ")
end

-- The banner menu only advances on click when the game has enabled
-- click-anywhere; otherwise the step wants a real action (place a monster...).
-- Popup menus always have a Continue button.
local function tutCanContinue(root, menu)
    if menu ~= "tutorial" then return true end
    local on = false
    pcall(function() on = root["FadedBG"]["Touch"]("enabled"):GetInt() ~= 0 end)
    return on
end

local function tutHint(root, menu)
    if tutCanContinue(root, menu) then return " Control Shift Enter to continue." end
    local target = nil
    pcall(function() target = tutorialTarget() end)
    if target then return " Control Shift Enter to " .. (target.verb or "tap") .. " " .. target[1] .. "." end
    return ""
end

local function tutLive()
    -- Like menus: ticked recently compared with the other screens, and since
    -- the mod last pressed anything.
    return tut.root ~= nil and (clock() - tut.lastTick) <= TUT_FRESH_SECONDS
        and menuState.lastTick - tut.lastTick <= 0.1 and tut.lastTick > menuState.activated
end

local TUT_DEBUG = false   -- true: log raw tutorial menu state ([tutprobe]/[tuthb]/[tutswig])

-- DIAGNOSTIC: log the raw state of each tutorial menu whenever it changes, so we
-- can see what the game actually puts in these menus during a tutorial step.
local TUT_PROBE = {
    tutorial = { "primaryText", "SecondaryText", "bg", "FadedBG" },
    popup_tutorial = { "Title", "Text", "bg", "OkayButton", "FadedBG" },
    popup_tutorial_streamlined = { "Title", "Text", "bg", "OkayButton", "FadedBG" },
}
local tutRawSig = {}
tut.roots = {}

local function probe(fn)
    local ok, v = pcall(fn)
    if ok then return tostring(v) end
    return "ERR(" .. tostring(v) .. ")"
end

local function tutProbe(root, menu)
    local parts = {}
    parts[#parts + 1] = "rootVisible=" .. probe(function() return root.isVisible end)
    for _, nm in ipairs(TUT_PROBE[menu] or {}) do
        local el = "?"; pcall(function() el = root[nm] end)
        parts[#parts + 1] = nm .. "{el=" .. tostring(el ~= nil)
            .. " elVis=" .. probe(function() return root[nm].isVisible end)
            .. " textVis=" .. probe(function() return root[nm]["Text"]("visible"):GetInt() end)
            .. " spriteVis=" .. probe(function() return root[nm]["Sprite"]("visible"):GetInt() end)
            .. " alpha=" .. probe(function() return root[nm]["Sprite"]("alpha"):GetFloat() end)
            .. " touch=" .. probe(function() return root[nm]["Touch"]("enabled"):GetInt() end)
            .. " text='" .. probe(function() return root[nm]["Text"]("text"):GetString() end) .. "'}"
    end
    local sig = table.concat(parts, " ")
    if sig ~= tutRawSig[menu] then
        tutRawSig[menu] = sig
        a11y_log("[tutprobe] " .. menu .. ": " .. sig)
    end
end

-- DIAGNOSTIC: list the SWIG methods/properties an object exposes (metatable,
-- .fn, .get and __index tables), so we can find a getter for drawn text.
local function swigMembers(obj)
    local names, seen = {}, {}
    local function add(t, prefix)
        if type(t) ~= "table" then return end
        for k, v in pairs(t) do
            local n = prefix .. tostring(k)
            if not seen[n] then seen[n] = true; names[#names + 1] = n .. ":" .. type(v) end
        end
    end
    local ok, mt = pcall(getmetatable, obj)
    if not ok or type(mt) ~= "table" then return "no metatable (" .. tostring(mt) .. ")" end
    add(mt, "")
    add(rawget(mt, ".fn"), ".fn.")
    add(rawget(mt, ".get"), ".get.")
    local idx = rawget(mt, "__index"); if type(idx) == "table" then add(idx, "__index.") end
    table.sort(names)
    return table.concat(names, " ")
end

local TEXT_GETTERS = { "getText", "GetText", "text", "getString", "GetString", "getDisplayText",
    "displayText", "getLocalizedText", "getTextString", "string", "str" }

local tutTextProbed = {}
local function tutProbeTextComponent(root, menu)
    for _, nm in ipairs({ "Title", "Text" }) do
        local comp = nil; pcall(function() comp = root[nm]["Text"] end)
        local key = menu .. "." .. nm
        if comp and not tutTextProbed[key] then
            tutTextProbed[key] = true
            a11y_log("[tutswig] " .. key .. " component members: " .. swigMembers(comp))
            local el = nil; pcall(function() el = root[nm] end)
            a11y_log("[tutswig] " .. key .. " element members: " .. swigMembers(el))
        end
        if comp then
            local res = {}
            for _, g in ipairs(TEXT_GETTERS) do
                res[#res + 1] = g .. "=" .. probe(function() return comp[g](comp) end)
            end
            local sig = table.concat(res, " ")
            if sig ~= tutTextProbed[key .. "#sig"] then
                tutTextProbed[key .. "#sig"] = sig
                a11y_log("[tutswig] " .. key .. " getters: " .. sig)
            end
        end
    end
end

-- DIAGNOSTIC heartbeat: every 2s per menu, log tick count + game tutorial state.
local tutHb = {}
local function tutHeartbeat(menu, now)
    local hb = tutHb[menu] or { n = 0, t = now }
    tutHb[menu] = hb
    hb.n = hb.n + 1
    if now - hb.t < 2 then return end
    local active = probe(function() return game.tutorialActive() end)
    local step = probe(function() local s, m = tutStepFn(); return tostring(s) .. "/" .. tostring(m) end)
    local pop = probe(function() return game.getPopUp() end)
    a11y_log("[tuthb] " .. menu .. " ticks=" .. hb.n .. " tutorialActive=" .. active .. " step=" .. step .. " popup=" .. pop)
    hb.n, hb.t = 0, now
end

local function tutTick(root, menu)
    tut.roots[menu] = root
    if TUT_DEBUG then
        pcall(tutProbe, root, menu)
        pcall(tutHeartbeat, menu, clock())
        if menu ~= "tutorial" then pcall(tutProbeTextComponent, root, menu) end
    end
    -- Popup text is spoken by onTutorialPopup (native hook), not polled here.
    if menu ~= "tutorial" then
        tut.root, tut.menu, tut.lastTick = root, menu, clock()
        return
    end
    local now = clock()
    if now - tut.lastTick > TUT_FRESH_SECONDS then tut.spoken = "" end   -- menu (re)appeared
    tut.root, tut.menu, tut.lastTick = root, menu, now
    if not tut.seen[menu] then tut.seen[menu] = true; a11y_log("[tut] first tick from " .. menu) end

    -- Wait for the text to settle: C++ fills title and body separately after onInit.
    local msg = tutMessage(root, menu) or ""
    if msg ~= tut.pending then tut.pending, tut.stable = msg, 0 return end
    tut.stable = tut.stable + 1
    if tut.stable ~= TUT_STABLE_FRAMES or msg == tut.spoken then return end
    tut.spoken = msg
    if msg == "" then return end
    a11y_log("[tut] " .. menu .. ": " .. msg)
    say(msg .. tutHint(root, menu), false)
end

local function tutGone(menu)
    if tut.menu == menu then
        tut.root, tut.menu, tut.spoken, tut.pending, tut.stable = nil, nil, "", "", 0
    end
end

-- Do exactly what the menu's own Continue button / click-anywhere does.
local function tutContinueLive()
    local root, menu = tut.root, tut.menu
    if not tutCanContinue(root, menu) then
        -- The step wants an action: do it if we know the target.
        local target = nil
        if not popupOpen() and not topOverlay() then target = tutorialTarget() end
        if target then pcall(target[2]) return end
        local what = tut.spoken ~= "" and tut.spoken or "Tab to find it."
        say("This step needs an action. " .. what, true)
        return
    end
    local ok = pcall(function() root:GetReceiver():Send(game.MsgNextTutorialStep()) end)
    if not ok then say("Could not continue", true) return end
    pcall(function() lua_sys.playSoundFx("audio/sfx/menu_click.wav") end)
    tut.spoken, tut.pending, tut.stable = "", "", 0   -- re-read even if text repeats
    say("Continue", true)
end

local CONTINUE_FX, CONTINUE_FY = 0.5, 0.72   -- observed Continue button position
local lastTutClick = -100
-- ---------------------------------------------------------------------------
-- Tutorial step descriptions (Ctrl+Shift+T).
--
-- The tutorial is a fixed, scripted sequence. The game's own message text lives
-- in a complex C++ data structure that isn't cleanly readable, so instead we
-- keep OUR OWN map of step number -> what to do. Keyed by the SPOKEN (1-based)
-- step number, i.e. what "step N of M" announces. Fill in as you play: at each
-- step press Ctrl+Shift+T, note the number and task, and add it here. Unknown
-- steps just announce "step N of M".
-- ---------------------------------------------------------------------------
local TUTORIAL_STEPS = {
    [29] = "Bake cookies in the Bakery",
    -- [n] = "description",
}

local function announceTutorialStep()
    local rawStep, maxStep = -1, 0
    if type(tutStepFn) == "function" then
        local ok, s, m = pcall(tutStepFn)
        if ok then rawStep, maxStep = (s or -1), (m or 0) end
    end
    local live = tutLive() and tutMessage(tut.root, tut.menu) or nil
    if live then
        local step = (rawStep and rawStep >= 0) and (" Step " .. (rawStep + 1) .. " of " .. maxStep .. ".") or ""
        say(live .. step .. tutHint(tut.root, tut.menu), true)
        return
    end
    if not rawStep or rawStep < 0 then say("No tutorial active", true) return end
    local shown = rawStep + 1
    local desc = TUTORIAL_STEPS[shown]
    local msg = (desc and (desc .. ", ") or "") .. "step " .. shown .. " of " .. maxStep
    say(msg, true)
end

-- Press a tutorial popup's own Continue button (same handlers a click runs).
local function pressTutorialPopup(root)
    local ok = pcall(function()
        local b = root["OkayButton"]
        b.Touch:onTouchDown(b, 0, 0)
        b.Touch:onTouchUp(b, 0, 0)
    end)
    if not ok then
        ok = pcall(function() root:GetReceiver():Send(game.MsgNextTutorialStep()) end)
    end
    return ok
end

local function tutorialContinue()
    for _, n in ipairs({ "popup_tutorial", "popup_tutorial_streamlined" }) do
        local r = liveMenu(n)
        if r then
            if pressTutorialPopup(r) then
                tut.spoken, tut.pending, tut.stable = "", "", 0
                say("Continue", true)
            else
                say("Could not continue", true)
            end
            return
        end
    end
    local active = false
    pcall(function() active = game.tutorialActive() end)
    -- Tutorial menus are preloaded and tick even when hidden, so also require
    -- the game to report an active tutorial before sending a step message.
    if active and tutLive() then tutContinueLive() return end
    if not active then lastTutClick = -100; say("No tutorial to continue", true) return end

    local now = 0; pcall(function() now = os.clock() end)

    if (now - lastTutClick) < 1.5 then
        -- Rapid second press: the click didn't dismiss it -> skip the tutorial.
        local ok = pcall(function() game.endIslandFirstTimeTutorial() end)
        lastTutClick = -100
        if ok then say("Skipping tutorial", false) else say("Could not skip tutorial", true) end
    elseif type(clickFraction) == "function" then
        clickFraction(CONTINUE_FX, CONTINUE_FY)
        lastTutClick = now
        say("Continue", false)
    else
        say("Click function unavailable", true)
    end
end

-- ---------------------------------------------------------------------------
-- "What now?" (Ctrl+Shift+W). After the tutorial nothing tells a blind player
-- what to do next: the game shows it as sparkles over buildings and the Goals
-- checklist. Read both: what's ready on this island (Island:has*Ready, the
-- checks behind the game's own indicators), then the current goals with their
-- progress, filled in the way FillQuestDescription.lua does it.
-- ---------------------------------------------------------------------------
local READY_CHECKS = {
    -- Collect All only appears on the bar once the game unlocks it, and it
    -- recharges after use (ContextBar.lua: collectAllUnlocked/Disabled).
    { "hasMonsterCollectReady", function()
        local base = "Monsters have coins to collect"
        local ok, unlocked = pcall(function() return game.collectAllUnlocked() end)
        if ok and unlocked then
            local okd, off = pcall(function() return game.collectAllDisabled() end)
            if okd and off then
                local tt = nil; pcall(function() tt = cleanText(localize(game.collectAllTimerText()) or "") end)
                return base .. ". Collect All on the bar is recharging" .. ((tt and tt ~= "") and (", " .. tt) or "")
            end
            return base .. ". Collect All is on the bar"
        end
        return base .. ". Collect All isn't unlocked yet, so collect from each monster: Control Shift O, pick a monster, press Enter"
    end },
    { "hasBakeryReady",           "Bakery food is ready to collect" },
    { "hasBreedingReady",         "Breeding is finished" },
    { "hasNurseryReady",          "An egg in the Nursery is ready to hatch" },
    { "hasMineReady",             "The Mine is ready" },
    { "hasStructureUpgradeReady", "A structure upgrade is finished" },
    { "hasCastleUpgradeReady",    "The Castle upgrade is finished" },
    { "hasEvolutionReady",        "A monster is ready to evolve" },
    { "hasTrainingReady",         "Monster training is finished" },
    { "hasAttunementReady",       "Attuning is finished" },
    { "hasSynthesisReady",        "Synthesizing is finished" },
    { "hasFuzingReady",           "Fuzing is finished" },
}

local function readyList()
    local out = {}
    local isl = nil
    pcall(function() isl = game.player():getActiveIsland() end)
    if not isl then return out end
    for _, c in ipairs(READY_CHECKS) do
        local ok, v = pcall(function() return isl[c[1]](isl) end)
        if ok and v then
            local text = c[2]
            if type(text) == "function" then
                local okt, t = pcall(text); text = okt and t or "Monsters have coins to collect"
            end
            out[#out + 1] = text
        end
    end
    return out
end

-- Speak when something finishes while you play (the game's "ding"). Polls the
-- island's ready flags and announces only false -> true changes; the first poll
-- on an island just records the baseline. Coins are left out: they fill
-- constantly, and Control Shift W reports them.
do
local FINISHED_TEXT = {
    hasBakeryReady           = "Baking finished. Food is ready to collect at the Bakery",
    hasBreedingReady         = "Breeding finished. The egg is ready",
    hasNurseryReady          = "An egg finished incubating. It is ready to hatch in the Nursery",
    hasMineReady             = "The Mine is ready",
    hasStructureUpgradeReady = "A structure finished building or upgrading",
    hasCastleUpgradeReady    = "The Castle upgrade is finished",
    hasEvolutionReady        = "A monster is ready to evolve",
    hasTrainingReady         = "Monster training is finished",
    hasAttunementReady       = "Attuning is finished",
    hasSynthesisReady        = "Synthesizing is finished",
    hasFuzingReady           = "Fuzing is finished",
}
local READY_POLL_SECONDS = 2
local readyWatch = { t = -100, island = nil, state = {} }

local function watchReady(now)
    if now - readyWatch.t < READY_POLL_SECONDS then return end
    readyWatch.t = now
    local isl, islId = nil, nil
    pcall(function() isl = game.player():getActiveIsland() end)
    if not isl then readyWatch.island = nil return end
    pcall(function() islId = tostring(isl:id()) end)
    local fresh = islId ~= readyWatch.island
    if fresh then readyWatch.island, readyWatch.state = islId, {} end
    local done = {}
    for check, text in pairs(FINISHED_TEXT) do
        local ok, v = pcall(function() return isl[check](isl) and true or false end)
        if ok then
            if v and readyWatch.state[check] == false and not fresh then done[#done + 1] = text end
            readyWatch.state[check] = v
        end
    end
    if #done > 0 then
        a11y_log("[ready] " .. table.concat(done, "; "))
        say(joinSentences(done), false)
    end
end
readyHook = watchReady

-- Speak what you just got or spent ("Got 120 coins", "Spent 40 food"), the
-- way the counters animating at the top tell sighted players. Changes are
-- added up until the balances settle, so a collect that counts up over a few
-- frames is one announcement.
local WALLET = {
    { "playerCoins", "coins" }, { "playerDiamonds", "diamonds" }, { "playerFood", "food" },
    { "playerEtherealCurrency", "shards" }, { "playerKeys", "keys" }, { "playerRelics", "relics" },
    { "playerStarpower", "starpower" }, { "playerCurrentXp", "XP" },
}
local WALLET_POLL_SECONDS = 0.25
local WALLET_SETTLE_SECONDS = 0.8
local wallet = { t = -100, last = nil, level = nil, pending = {}, changed = nil }

local function readWallet()
    local w = {}
    for _, c in ipairs(WALLET) do
        local ok, v = pcall(function() return game[c[1]]() end)
        if ok and type(v) == "number" then w[c[1]] = v end
    end
    return w
end

local function watchWallet(now)
    if now - wallet.t < WALLET_POLL_SECONDS then return end
    wallet.t = now
    -- Balances load in after the game starts: only watch once an island is up,
    -- and start from a fresh baseline whenever there was none.
    local isl = nil
    pcall(function() isl = game.player():getActiveIsland() end)
    if not isl then wallet.last, wallet.pending, wallet.changed = nil, {}, nil return end
    if not wallet.ready then wallet.ready = now end
    if now - wallet.ready < 3 then wallet.last = nil return end
    local w = readWallet()
    local lvl = nil; pcall(function() lvl = game.playerLevel() end)
    if not wallet.last then wallet.last, wallet.level = w, lvl return end
    for _, c in ipairs(WALLET) do
        local k = c[1]
        local a, b = wallet.last[k], w[k]
        if a and b and a ~= b then
            if not (k == "playerCurrentXp" and lvl ~= wallet.level) then
                wallet.pending[k] = (wallet.pending[k] or 0) + (b - a)
            end
            wallet.changed = now
        end
    end
    if lvl and wallet.level and lvl > wallet.level then
        wallet.pending.levelUp = lvl
        wallet.changed = now
    end
    wallet.last, wallet.level = w, lvl or wallet.level
    if not wallet.changed or now - wallet.changed < WALLET_SETTLE_SECONDS then return end
    local got, spent = {}, {}
    for _, c in ipairs(WALLET) do
        local d = wallet.pending[c[1]]
        if d and d > 0 then got[#got + 1] = tostring(d) .. " " .. c[2] end
        if d and d < 0 then spent[#spent + 1] = tostring(-d) .. " " .. c[2] end
    end
    local msg = {}
    if #got > 0 then msg[#msg + 1] = "Got " .. table.concat(got, ", ") end
    if #spent > 0 then msg[#msg + 1] = "Spent " .. table.concat(spent, ", ") end
    if wallet.pending.levelUp then msg[#msg + 1] = "Level up! You are now level " .. tostring(wallet.pending.levelUp) end
    wallet.pending, wallet.changed = {}, nil
    if #msg > 0 then
        a11y_log("[wallet] " .. table.concat(msg, "; "))
        say(joinSentences(msg), false)
    end
end
walletHook = watchWallet
end

-- Goal text with its placeholders filled ({0:object} -> a name, {0:num} -> a number).
local function questText(quest, s)
    s = s and cleanText(s) or nil
    if not s then return nil end
    s = s:gsub("{%s*([0-9]+)%s*:*s*([A-Za-z0-9]+)%s*}", function(index, target)
        local out = nil
        pcall(function()
            local v = quest:getPropertyInt(tonumber(index), target)
            if target == "object" then out = cleanText(game.getLocalizedText(game.entityName(v)))
            else out = tostring(v) end
        end)
        return out or ""
    end)
    return s
end

local MAX_GOALS_SPOKEN = 4

-- The goals the Goals screen's main tab shows (Goals.lua TabMain.filterQuest):
-- visible at the player's level; completed ones, plus up to maxMainQuests open.
-- Their text is the description (the name is an internal id like M_C_LVL_4),
-- falling back to the name only when there is no description, like GoalEntry.
local function goalList()
    local out = {}
    pcall(function()
        local qs = game.quests(2)
        local level = 1; pcall(function() level = game.playerLevel() end)
        local maxOpen = 3; pcall(function() maxOpen = game.maxMainQuests() end)
        -- Same order as the Goals screen (GoalEntries.questCompare, minus its
        -- "can help" check): most complete first, then priority (-1 last), then id.
        local list = {}
        for i = 0, qs:size() - 1 do
            local q = qs[i]
            local e = { q = q, pct = 0, pri = -1, id = 0 }
            pcall(function() e.pct, e.pri, e.id = q:percentComplete(), q:priority(), q:getId() end)
            list[#list + 1] = e
        end
        table.sort(list, function(a, b)
            if a.pct ~= b.pct then return a.pct > b.pct end
            if a.pri ~= b.pri then
                if a.pri == -1 then return false end
                if b.pri == -1 then return true end
                return a.pri < b.pri
            end
            return a.id < b.id
        end)
        local done, open = {}, {}
        for _, e in ipairs(list) do
            local q = e.q
            local visible = false
            pcall(function() visible = q:isVisible(level) and true or false end)
            local complete = false
            pcall(function() complete = q:isComplete() and true or false end)
            if visible and (complete or #open < maxOpen) then
                local raw = nil
                pcall(function() raw = q:getDescription() end)
                if not raw or raw == "" then pcall(function() raw = q:getName() end) end
                local line = questText(q, raw) or "Goal"
                if complete then
                    done[#done + 1] = trimEnd(line) .. ", Done, claim it in Goals"
                else
                    local d, t = nil, nil
                    pcall(function() d, t = q:numProgressMarkersDone(), q:numProgressMarkersTotal() end)
                    if d and t and t > 1 then line = trimEnd(line) .. ", " .. d .. " of " .. t end
                    open[#open + 1] = line
                end
            end
        end
        for _, l in ipairs(done) do out[#out + 1] = l end   -- rewards waiting first
        for _, l in ipairs(open) do out[#out + 1] = l end
    end)
    return out
end

local function whatNow()
    local parts = {}
    local ready = readyList()
    if #ready > 0 then parts[#parts + 1] = "Ready: " .. joinSentences(ready) .. "." end
    local goals = goalList()
    if #goals > 0 then
        local spoken = {}
        for i = 1, MAX_GOALS_SPOKEN do
            if goals[i] then spoken[#spoken + 1] = goals[i] end
        end
        parts[#parts + 1] = "Goals: " .. numberedList(spoken)
        if #goals > #spoken then parts[#parts + 1] = (#goals - #spoken) .. " more in the Goals screen." end
    end
    if #parts == 0 then
        say("Nothing ready and no goals found. Try the Market to buy a monster, or the Goals screen.", true)
        return
    end
    say(table.concat(parts, " "), true)
end

-- ---------------------------------------------------------------------------
-- Diagnostic dump (Ctrl+Shift+D): log the live UI tree to accessibility.log so
-- we can build accurate navigation. For each element: indent, name, [CLICK] if
-- it has a Touch, [hidden] if not visible, and its text/label.
-- ---------------------------------------------------------------------------
local DUMP_MAX_DEPTH = 14
local function dumpElement(el, depth, budget)
    if not el or depth > DUMP_MAX_DEPTH or budget.n <= 0 then return end
    budget.n = budget.n - 1
    local nm = "?"; pcall(function() nm = tostring(el:name()) end)
    local click = isClickable(el) and " [CLICK]" or ""
    local hid = isVisible(el) and "" or " [hidden]"
    local txt = elementText(el)
    local bl = nil; pcall(function() local b = el("ButtonLabelText"):GetString(); if b and #b > 0 then bl = b end end)
    local extra = txt and (" ='" .. txt .. "'") or (bl and (" lbl=" .. bl) or "")
    a11y_log(string.rep("  ", depth) .. nm .. click .. hid .. extra)
    local kids = nil; pcall(function() kids = el:elements() end)
    if not kids then return end
    local n = 0; pcall(function() n = kids:size() end)
    for i = 0, n - 1 do
        if budget.n <= 0 then return end
        local child = nil; pcall(function() child = kids[i] end)
        if child then dumpElement(child, depth + 1, budget) end
    end
end

-- Climb to the topmost ancestor reachable via :parent(), so we can dump sibling
-- menus (market/book/options bar) that aren't under the HUD root.
local function topAncestor(el)
    local cur = el
    for _ = 1, 30 do
        local p = nil
        pcall(function() p = cur:parent() end)
        if not p or p == cur then break end
        cur = p
    end
    return cur
end

-- Probe which per-object status calls work (the icons floating over objects).
local function probeCall(label, fn)
    local ok, v = pcall(fn)
    a11y_log("    " .. label .. " = " .. (ok and tostring(v) or ("ERR " .. tostring(v))))
end

local function probeStatus()
    a11y_log("-- STATUS PROBE --")
    for _, c in ipairs(READY_CHECKS) do
        probeCall("island:" .. c[1], function() local i = game.player():getActiveIsland(); return i[c[1]](i) end)
    end
    for t = 0, MAX_STRUCTURE_TYPE do
        local id = 0
        pcall(function() id = game.getFirstStructureOfType(t) or 0 end)
        if id ~= 0 then
            local ent = nil
            pcall(function() ent = game.GetStructure(id) end)
            a11y_log("  structure type " .. t .. " id " .. tostring(id) .. " " .. tostring(structureLabel(id)) .. " ent=" .. tostring(ent))
            if ent then
                probeCall("secondsUntilActionDone", function() return ent:secondsUntilActionDone() end)
                probeCall("diamondsRequiredToCompleteAction", function() return ent:diamondsRequiredToCompleteAction() end)
                probeCall("isEggHolder", function() return ent:isEggHolder() end)
                probeCall("hasEgg", function() return ent:hasEgg() end)
                probeCall("isEggReadyToHatch", function() return ent:isEggReadyToHatch() end)
                probeCall("secondsUntilHatch", function() return ent:secondsUntilHatch() end)
                probeCall("percentHatched", function() return ent:percentHatched() end)
                probeCall("getMonsterInEgg", function() return ent:getMonsterInEgg() end)
            end
            probeCall("game.timeLeftOnStruct(id)", function() return game.timeLeftOnStruct(id) end)
            probeCall("game.isStructureUpgrading(id)", function() return game.isStructureUpgrading(id) end)
            probeCall("game.timeLeft(id)", function() return game.timeLeft(id) end)
        end
    end
    pcall(function()
        local mons = game.player():getActiveIsland():monsters()
        for i = 0, mons:size() - 1 do
            local uid = mons[i]
            local ent = nil
            pcall(function() ent = game.GetMonster(uid) end)
            a11y_log("  monster " .. tostring(uid) .. " " .. tostring(monsterLabel(uid)) .. " ent=" .. tostring(ent))
            if ent then
                probeCall("level", function() return ent:level() end)
                probeCall("timesFed", function() return ent:timesFed() end)
                probeCall("foodRequired", function() return ent:foodRequired() end)
                probeCall("secondsUntilActionDone", function() return ent:secondsUntilActionDone() end)
            end
            probeCall("game.monsterEarnings(uid)", function() return game.monsterEarnings(uid) end)
            probeCall("game.monsterEarnings()", function() return game.monsterEarnings() end)
        end
    end)
    a11y_log("  selected: " .. tostring(selectionKey()))
    probeCall("context", function() return manager:getContext() end)
    for _, f in ipairs({ "bakeryTime", "timeLeftToBake", "timeLeftToBreed", "timeLeftToHatchEgg", "eggReadyToHatch",
                         "isBreedingFinished", "timeLeftToBuild", "timeLeftToDestoryObstacle", "monsterEarnings" }) do
        probeCall("game." .. f .. "()", function() return game[f]() end)
    end
    a11y_log("-- STATUS PROBE end --")
end

local function dumpUI()
    a11y_log("=== UI DUMP begin ===")
    probeStatus()

    -- What does the game think the top popup is? (getPopUp returns a NAME string.)
    local popName = "?"; pcall(function() popName = tostring(game.getPopUp()) end)
    local hasPop = "?"; pcall(function() hasPop = tostring(game.hasPopUp()) end)
    local topName2 = "?"; pcall(function() topName2 = tostring(game.getTopPopUpName()) end)
    a11y_log("getPopUp()='" .. popName .. "'  hasPopUp()=" .. hasPop .. "  getTopPopUpName()='" .. topName2 .. "'")

    -- Our captured push/pop stack.
    local ids = {}
    for i, e in ipairs(popupStack) do ids[i] = tostring(e.id) end
    a11y_log("popupStack (" .. #popupStack .. "): " .. (table.concat(ids, ", ")))

    -- Dump the stack-top popup object tree, if we captured one.
    local top = popupStack[#popupStack]
    if top and top.obj then
        a11y_log("-- CAPTURED POPUP TREE (id=" .. tostring(top.id) .. ") --")
        dumpElement(top.obj, 0, { n = 600 })
    else
        a11y_log("-- no captured popup object --")
    end

    -- Every menu currently ticking (captured by the XML overrides' A11yHook).
    for file, m in pairs(menus) do
        if clock() - m.t <= 5 then
            a11y_log(string.format("-- menu timing: %s gap=%.3f lag=%.3f age=%.3f usable=%s", file, m.gap or -1,
                menuState.lastTick - m.t, clock() - m.t, tostring(menuState.usable(m))))
        end
        if menuState.usable(m) and file ~= "hud" then
            a11y_log("-- LIVE MENU TREE (" .. file .. ", root " .. tostring(m.rootName) .. ") --")
            dumpElement(m.root, 0, { n = 2000 })
        end
    end

    -- Try to reach the popup element via game.topPopUp() (returns an element in
    -- scripts, unlike getPopUp which returns a name).
    local tp = nil; pcall(function() tp = game.topPopUp() end)
    if tp then
        a11y_log("-- game.topPopUp() TREE --")
        dumpElement(tp, 0, { n = 600 })
    else
        a11y_log("-- game.topPopUp() returned nil/non-element --")
    end

    -- Full HUD tree from top ancestor (island + anything parented under it).
    local ok2, hud = pcall(game.getHUD)
    if ok2 and hud then
        local hudName = "?"; pcall(function() hudName = tostring(hud:name()) end)
        local top2 = topAncestor(hud)
        local topName = "?"; pcall(function() topName = tostring(top2:name()) end)
        a11y_log("HUD name=" .. hudName .. "  topAncestor=" .. topName)
        a11y_log("-- FULL TREE from top ancestor --")
        dumpElement(top2, 0, { n = 2000 })
    else
        a11y_log("no HUD")
    end

    a11y_log("=== UI DUMP end ===")
    say("UI dumped to log", true)
end

-- ---------------------------------------------------------------------------
-- 4. Expose readers for hotkeys / other mods / manual console use.
-- ---------------------------------------------------------------------------
shared.a11y = {
    say        = say,
    silence    = silence,
    is_active  = is_active,
    announceHud= announceHud,
    readCoins  = readCoins,
    readDiamonds = readDiamonds,
    readFood   = readFood,
    readLevel  = readLevel,
    readIsland = readIsland,
    announceCurrentPopup = announceCurrentPopup,
    dumpUI     = dumpUI,
}

-- Expose reader functions into the GAME Lua state (not just the mod sandbox) so
-- native hotkeys, which run via queue_lua in the game state, can reach them.
-- `shared` alone isn't visible there; jeode.registerGlobal is.
if type(jeode) == "table" and type(jeode.registerGlobal) == "function" then
    jeode.registerGlobal("a11y_announceHud", announceHud)
    jeode.registerGlobal("a11y_announcePopup", announceCurrentPopup)
    jeode.registerGlobal("a11y_navNext", function() navMove(1) end)
    jeode.registerGlobal("a11y_navPrev", function() navMove(-1) end)
    jeode.registerGlobal("a11y_navEdge", function(dir) navMove(dir, true) end)
    jeode.registerGlobal("a11y_navActivate", navActivate)
    jeode.registerGlobal("a11y_menu", openPlaces)
    jeode.registerGlobal("a11y_tutorialContinue", tutorialContinue)
    jeode.registerGlobal("a11y_tutorial_announce", announceTutorialStep)
    jeode.registerGlobal("a11y_dump", dumpUI)
    jeode.registerGlobal("a11y_tutTick", tutTick)
    jeode.registerGlobal("a11y_tutGone", tutGone)
    jeode.registerGlobal("a11y_onTutorialPopup", onTutorialPopup)
    jeode.registerGlobal("a11y_menuTick", menuTick)
    jeode.registerGlobal("a11y_objects", openObjects)
    jeode.registerGlobal("a11y_arrow", arrow)
    jeode.registerGlobal("a11y_whatnow", whatNow)
    jeode.registerGlobal("a11y_back", goBack)
    jeode.registerGlobal("a11y_spot", function(dir) spotStep(dir) end)
    -- Control Shift C: the game's own default island view (what it uses after
    -- the island fanfare). Placing re-centres on the object at the next arrow.
    jeode.registerGlobal("a11y_camera", function()
        local ok, err = pcall(function() game.setDefaultCameraSettings() end)
        if not ok then
            a11y_log("[camera] setDefaultCameraSettings failed: " .. tostring(err))
            say("Can't reset the camera here", true)
            return
        end
        placeAt.t = -100
        say("Camera reset to the whole island", true)
    end)
    jeode.registerGlobal("a11y_poi", function(dir)
        if placing() then poiStep(dir) else navGroupJump(dir) end
    end)
    a11y_log("registered a11y_* globals (HUD, popup, nav, menu, dump) via jeode.registerGlobal")
else
    a11y_log("jeode.registerGlobal unavailable - hotkeys will not work")
end

say("Accessibility Lua layer ready", false)
a11y_log("init.lua loaded")
