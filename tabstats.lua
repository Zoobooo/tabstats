plugin = {
    name = "tabstats",
    displayName = "Tab Stats",
    prefix = "§dTS",
    version = "1.0.0",
    author = "Zoobo",
    credits = "Zoobo",
    description = "Beta. Tab list stats for Bed Wars, SkyWars, Murder Mystery and Duels: overlay tab list, respawn timers, configurable columns. Needs your own Hypixel API key.",
    dependencies = {
        { name = "hypixel-mod-api", minVersion = "1.0.0" },
        { name = "denicker", optional = true },
        { name = "urchin", optional = true }
    }
}

local HYPIXEL_PLAYER_API = "https://api.hypixel.net/v2/player?uuid="
local MOJANG_PROFILE_API = "https://api.mojang.com/users/profiles/minecraft/"
local CACHE_TTL = 300
local FETCH_RETRIES = 3
local RETRY_BASE_MS = 2000
local REFRESH_MS = 500
local LOADING_TIMEOUT_MS = 10000
local MAX_TRACKED = 32
local PREFIX_PRIORITY = 100

-- 1.8 tab row: [9px head][name][1px][list objective][13px ping]. The header is
-- centred like the rows, so a header exactly one row wide lines up with them.
local HEAD_WIDTH = 9
local PING_WIDTH = 13
local MAX_SINGLE_COLUMN = 20
local LEAD = 8
local GUTTER = 16
local NAME_GAP = 32
local TRAIL = 12
local HEADER_COLOR = "§f"
local LIST_LABEL = "HP"

local active = nil
local duelsKey = nil
local duelsKeyLogged = false
local duelsFallbackLogged = false
local managed = {}
local byUuid = {}
local stats = {}
local fetchCallbacks = {}
local uuidCache = {}
local lastApplied = {}
local tabActive = false
local refreshTimer = nil
local dirty = false
local layoutCache = nil
local lastHeader = nil
local warnedOverlap = false
local warnedNoKey = false
local locationKnown = false
local locationMode = nil
local locationDuelsMode = nil
local lastPregame = nil

local NICKED_STATS = { isNicked = true }

local DEBUG_FILE = (os.getenv("TEMP") or ".") .. "/tabstats-debug.log"

local function describe(value, depth)
    depth = depth or 0
    if type(value) ~= "table" then return tostring(value) end
    if depth > 2 then return "{...}" end
    local parts = {}
    local ok = pcall(function()
        for k, v in pairs(value) do
            parts[#parts + 1] = tostring(k) .. "=" .. describe(v, depth + 1)
        end
    end)
    if not ok then return "<opaque table>" end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function trace(message)
    starfish.log.debug(message)
    if starfish.config.get("diagnostics.logFile", false) ~= true then return end
    pcall(function()
        local file = io.open(DEBUG_FILE, "a")
        if not file then return end
        file:write(os.date("%H:%M:%S") .. "  " .. message .. "\n")
        file:close()
    end)
end

local function getConfig(key, default)
    local value = starfish.config.get(key, default)
    if value == nil then return default end
    return value
end

local function callPlugin(name, func, ...)
    if not starfish.plugins.has(name) then return nil end
    local ok, result = pcall(starfish.plugins.call, name, func, ...)
    if ok then return result end
    return nil
end

local function getRealName(name)
    return callPlugin("denicker", "getRealName", name)
end

local function isNicked(name)
    return callPlugin("denicker", "isNicked", name) == true
end

local function ratio(pos, neg)
    if neg == 0 then return pos end
    return pos / neg
end

local RAMP = { "f", "a", "e", "6", "c", "4" }

local function ramp(thresholds)
    return function(value)
        local color = "7"
        for index, threshold in ipairs(thresholds) do
            if value >= threshold then color = RAMP[index] end
        end
        return "§" .. color
    end
end

local STAT_COLORS = {
    fkdr   = ramp({ 1, 3, 6, 10, 20, 50 }),
    finals = ramp({ 1000, 2500, 5000, 10000, 25000, 50000 }),
    ws     = ramp({ 1, 5, 10, 25, 50, 100 }),
    kdr    = ramp({ 1, 1.5, 2.5, 4, 6, 10 }),
    wlr    = ramp({ 1, 1.5, 2.5, 4, 6, 10 }),
    wins   = ramp({ 100, 500, 1000, 2500, 5000, 10000 }),
    kills  = ramp({ 250, 1000, 2500, 5000, 10000, 25000 }),
    star   = ramp({ 5, 12, 25, 50, 100, 150 }),
    bwWins = ramp({ 100, 500, 1000, 2500, 5000, 10000 }),
    beds   = ramp({ 500, 1000, 2500, 5000, 10000, 25000 }),
    bblr   = ramp({ 1, 1.5, 2.5, 4, 6, 10 }),
}

-- Default 1.8 font advances (glyph width + 1px spacing).

local SPACE_WIDTH = 4
local BOLD_SPACE_WIDTH = 5
local DEFAULT_CHAR_WIDTH = 6
local CHAR_WIDTH = {
    [" "] = SPACE_WIDTH,
    ["!"] = 2, ['"'] = 4, ["'"] = 2, ["("] = 5, [")"] = 5, ["*"] = 4,
    [","] = 2, ["."] = 2, [":"] = 2, [";"] = 2, ["<"] = 5, [">"] = 5,
    ["@"] = 7, ["["] = 4, ["]"] = 4, ["`"] = 3, ["{"] = 5, ["|"] = 2, ["}"] = 5,
    ["I"] = 4, ["f"] = 5, ["i"] = 2, ["k"] = 5, ["l"] = 3, ["t"] = 4, ["~"] = 7,
    ["✫"] = 8.5, ["✪"] = 8.5, ["⚝"] = 8.5, ["✥"] = 9, ["✭"] = 8.5, ["✩"] = 8.5, ["⋆"] = 8.5,
}

-- Bold adds 1px per glyph; a colour code or §r ends it.
local function textWidth(text)
    local width, bold, code = 0, false, false
    for _, point in utf8.codes(text or "") do
        local char = utf8.char(point)
        if code then
            code = false
            local c = char:lower()
            if c == "l" then
                bold = true
            elseif c:match("^[0-9a-fr]$") then
                bold = false
            end
        elseif char == "§" then
            code = true
        else
            width = width + (CHAR_WIDTH[char] or DEFAULT_CHAR_WIDTH) + (bold and 1 or 0)
        end
    end
    return width
end

-- Spaces are 4px and bold spaces 5px, so any gap of 12px or more fits exactly.
local SMALL_GAPS = { [1] = { 0, 0 }, [2] = { 0, 0 }, [3] = { 1, 0 }, [6] = { 0, 1 }, [7] = { 2, 0 }, [11] = { 0, 2 } }

local function padding(px)
    px = math.floor(px + 0.5)
    if px <= 0 then return "", 0 end

    local normal, bold = nil, nil
    for boldCount = 0, 3 do
        local rest = px - boldCount * BOLD_SPACE_WIDTH
        if rest >= 0 and rest % SPACE_WIDTH == 0 then
            normal, bold = math.floor(rest / SPACE_WIDTH), boldCount
            break
        end
    end
    if not normal then
        normal, bold = SMALL_GAPS[px][1], SMALL_GAPS[px][2]
    end

    local text = "§r" .. (" "):rep(normal)
    if bold > 0 then text = text .. "§l" .. (" "):rep(bold) .. "§r" end
    return text, normal * SPACE_WIDTH + bold * BOLD_SPACE_WIDTH
end

-- Duels stat keys are named after the mode (classic_duel_wins). Some modes have
-- no mode in the location event, so the sidebar's Mode: line is the fallback.

local DUELS_ALIASES = {
    nodebuff = "potion",
    megawalls = "mw",
    mega_walls = "mw",
    skywars = "sw",
    uhc_champions = "uhc",
    the_bridge = "bridge",
}

local function duelsCandidates(raw)
    if not raw or raw == "" then return {} end

    local base = raw:lower()
        :gsub("^duels_", "")
        :gsub("[^%w]+", "_")
        :gsub("^_+", "")
        :gsub("_+$", "")
        :gsub("^the_", "")

    local stem = base:gsub("_duel$", "")
    local alias = DUELS_ALIASES[stem] or DUELS_ALIASES[base]

    local candidates = { base, stem .. "_duel", stem }
    if alias then
        table.insert(candidates, alias .. "_duel")
        table.insert(candidates, alias)
    end

    local seen, unique = {}, {}
    for _, candidate in ipairs(candidates) do
        if candidate ~= "" and not seen[candidate] then
            seen[candidate] = true
            table.insert(unique, candidate)
        end
    end
    return unique
end

local function sidebarTexts()
    local ok, texts = pcall(function()
        local sidebar = starfish.scoreboard.sidebar()
        if not sidebar or not sidebar.lines then return nil end
        local teamOf = {}
        for _, team in ipairs(starfish.scoreboard.teams() or {}) do
            for _, member in ipairs(team.players or {}) do teamOf[member] = team end
        end
        local list = {}
        for _, line in ipairs(sidebar.lines) do
            local name = type(line) == "table" and (line.text or line.name or "") or tostring(line or "")
            local team = teamOf[name]
            local shown = starfish.text.plain(name):find("[\128-\255]") and "" or name
            local text = starfish.text.plain((team and team.prefix or "") .. shown .. (team and team.suffix or ""))
            list[#list + 1] = text:match("^%s*(.-)%s*$")
        end
        return list
    end)
    return ok and texts or nil
end

local function sidebarTitle()
    local ok, title = pcall(function()
        local sidebar = starfish.scoreboard.sidebar()
        if not sidebar then return nil end
        local raw = sidebar.title
        if raw == nil then return nil end
        return starfish.text.plain(raw):upper()
    end)
    if not ok then return nil, tostring(title) end
    return title
end

local function sidebarMode()
    for _, text in ipairs(sidebarTexts() or {}) do
        local mode = text:match("^Mode:%s*(.+)$")
        if mode then return mode end
    end
    return nil
end

local function resolveDuelsKey(locationMode)
    local source = "location:" .. tostring(locationMode)
    local candidates = duelsCandidates(locationMode)
    if #candidates == 0 then
        local scoreboardMode = sidebarMode()
        source = "scoreboard:" .. tostring(scoreboardMode)
        candidates = duelsCandidates(scoreboardMode)
    end
    if #candidates == 0 then return nil end
    trace("Duels mode from " .. source .. " -> trying " .. table.concat(candidates, ", "))
    return candidates
end

local function statsUnavailable(st)
    return st.isNicked or st.fetchError
end

local function group(st, name)
    return (st.raw and st.raw[name]) or {}
end

-- Mode key first (bridge_duel_wins), then the overall Duels total.
local function duelsStat(st, field)
    local duels = st.raw and st.raw.duels
    if not duels then return nil end
    for _, candidate in ipairs(duelsKey or {}) do
        local value = duels[candidate .. "_" .. field]
        if value ~= nil then
            if not duelsKeyLogged then
                duelsKeyLogged = true
                trace("Duels stats key in use: " .. candidate)
            end
            return value
        end
    end
    if not duelsFallbackLogged then
        duelsFallbackLogged = true
        starfish.log.warn("No duels key matched (" .. table.concat(duelsKey or {}, ", ") .. ") - falling back to overall duels totals")
    end
    return duels[field]
end

local function skywarsStar(st)
    local sw = group(st, "skywars")
    local formatted = sw.levelFormatted
    local digits = formatted and starfish.text.plain(formatted):match("%d+")
    local level = tonumber(digits) or tonumber(sw.level) or 0
    local color = (formatted and formatted:match("§(%w)")) or STAT_COLORS.star(level):sub(-1)
    if not color or color == "" then color = "7" end
    return "§" .. color .. "[" .. math.floor(level) .. "✫]"
end

local function bedwarsStar(st)
    return st.bedwarsStar or "§7[0✫]"
end

local NAME_COLUMN = { header = "Name", isName = true }

local function starColumn(getter)
    return {
        header = "Stars",
        value = function(st)
            if not st or st.isLoading then return "§8[-✫]" end
            if statsUnavailable(st) then return "§7[?✫]" end
            return getter(st)
        end
    }
end

local function ratioColumn(header, getter, colorName)
    return {
        header = header,
        value = function(st)
            if not st or st.isLoading then return "§8-" end
            if statsUnavailable(st) then return "§7?" end
            local r = getter(st)
            return STAT_COLORS[colorName](r) .. string.format("%.2f", r)
        end
    }
end

-- The API leaves out the winstreak when a player hides it.
local function countColumn(header, getter, colorName, missingIsHidden)
    return {
        header = header,
        value = function(st)
            if not st or st.isLoading then return "§8-" end
            if statsUnavailable(st) then return "§7?" end
            local value = getter(st)
            if value == nil and missingIsHidden then return "§7?" end
            value = value or 0
            return STAT_COLORS[colorName](value) .. tostring(math.floor(value))
        end
    }
end

local function duelsWinstreak(st)
    local duels = st.raw and st.raw.duels
    if not duels then return nil end
    for _, candidate in ipairs(duelsKey or {}) do
        local value = duels["current_winstreak_mode_" .. candidate]
        if value ~= nil then return value end
    end
    return duels.current_winstreak
end

local BEDWARS_STATS = {
    { id = "stars", text = "Stars", column = starColumn(bedwarsStar) },
    { id = "name", text = "Name", column = NAME_COLUMN },
    { id = "ws", text = "Winstreak", column = countColumn("WS", function(st) return group(st, "bedwars").winstreak end, "ws", true) },
    { id = "fkdr", text = "FKDR", column = ratioColumn("FKDR", function(st)
        local bw = group(st, "bedwars")
        return ratio(bw.final_kills_bedwars or 0, bw.final_deaths_bedwars or 0)
    end, "fkdr") },
    { id = "finals", text = "Finals", column = countColumn("Finals", function(st) return group(st, "bedwars").final_kills_bedwars end, "finals") },
    { id = "kdr", text = "KDR", column = ratioColumn("KDR", function(st)
        local bw = group(st, "bedwars")
        return ratio(bw.kills_bedwars or 0, bw.deaths_bedwars or 0)
    end, "kdr") },
    { id = "wins", text = "Wins", column = countColumn("Wins", function(st) return group(st, "bedwars").wins_bedwars end, "bwWins") },
    { id = "wlr", text = "WLR", column = ratioColumn("WLR", function(st)
        local bw = group(st, "bedwars")
        return ratio(bw.wins_bedwars or 0, bw.losses_bedwars or 0)
    end, "wlr") },
    { id = "beds", text = "Beds", column = countColumn("Beds", function(st) return group(st, "bedwars").beds_broken_bedwars end, "beds") },
    { id = "bblr", text = "BBLR", column = ratioColumn("BBLR", function(st)
        local bw = group(st, "bedwars")
        return ratio(bw.beds_broken_bedwars or 0, bw.beds_lost_bedwars or 0)
    end, "bblr") },
}

local SKYWARS_STATS = {
    { id = "stars", text = "Stars", column = starColumn(skywarsStar) },
    { id = "name", text = "Name", column = NAME_COLUMN },
    { id = "wins", text = "Wins", column = countColumn("Wins", function(st) return group(st, "skywars").wins end, "wins") },
    { id = "kills", text = "Kills", column = countColumn("Kills", function(st) return group(st, "skywars").kills end, "kills") },
    { id = "kdr", text = "KDR", column = ratioColumn("KDR", function(st)
        local sw = group(st, "skywars")
        return ratio(sw.kills or 0, sw.deaths or 0)
    end, "kdr") },
    { id = "wlr", text = "WLR", column = ratioColumn("WLR", function(st)
        local sw = group(st, "skywars")
        return ratio(sw.wins or 0, sw.losses or 0)
    end, "wlr") },
}

local MURDER_STATS = {
    { id = "name", text = "Name", column = NAME_COLUMN },
    { id = "wins", text = "Wins", column = countColumn("Wins", function(st) return group(st, "murder").wins end, "wins") },
    { id = "kills", text = "Kills", column = countColumn("Kills", function(st) return group(st, "murder").kills end, "kills") },
    { id = "kdr", text = "KDR", column = ratioColumn("KDR", function(st)
        local mm = group(st, "murder")
        return ratio(mm.kills or 0, mm.deaths or 0)
    end, "kdr") },
}

local DUELS_STATS = {
    { id = "name", text = "Name", column = NAME_COLUMN },
    { id = "wins", text = "Wins", column = countColumn("Wins", function(st) return duelsStat(st, "wins") end, "wins") },
    { id = "wlr", text = "WLR", column = ratioColumn("WLR", function(st)
        return ratio(duelsStat(st, "wins") or 0, duelsStat(st, "losses") or 0)
    end, "wlr") },
    { id = "kdr", text = "KDR", column = ratioColumn("KDR", function(st)
        return ratio(duelsStat(st, "kills") or 0, duelsStat(st, "deaths") or 0)
    end, "kdr") },
    { id = "ws", text = "Winstreak", column = countColumn("WS", duelsWinstreak, "ws", true) },
    { id = "kills", text = "Kills", column = countColumn("Kills", function(st) return duelsStat(st, "kills") end, "kills") },
}

local MODES = {
    bedwars = { key = "bedwars", label = "Bed Wars", stats = BEDWARS_STATS,
                slots = { "stars", "name", "ws", "fkdr", "finals", "kdr" } },
    skywars = { key = "skywars", label = "SkyWars", stats = SKYWARS_STATS,
                slots = { "stars", "name", "wins", "kills", "kdr" } },
    murder  = { key = "murderMystery", label = "Murder Mystery", stats = MURDER_STATS,
                slots = { "name", "wins", "kills", "kdr" } },
    duels   = { key = "duels", label = "Duels", stats = DUELS_STATS,
                slots = { "name", "wins", "wlr", "kdr" } },
}
local MODE_ORDER = { "bedwars", "skywars", "murder", "duels" }
for _, mode in pairs(MODES) do mode.config = mode.key .. ".enabled" end

local SLOT_OFF = "off"

local function slotKey(mode, index)
    return mode.key .. ".column" .. index
end

-- Same rules as the Bed Wars plugin's column slots: Off is skipped, a second
-- Name collapses, and Name goes last if no slot shows it.
local function columns()
    local mode = active and MODES[active]
    if not mode then return {} end
    local byId = {}
    for _, stat in ipairs(mode.stats) do byId[stat.id] = stat.column end

    local list, hasName = {}, false
    for index, default in ipairs(mode.slots) do
        local column = byId[getConfig(slotKey(mode, index), default)]
        if column and not (column.isName and hasName) then
            hasName = hasName or column.isName == true
            list[#list + 1] = column
        end
    end
    if not hasName then list[#list + 1] = NAME_COLUMN end
    return list
end

local SCALE_VALUES = {}
for _, percent in ipairs({ 50, 60, 70, 75, 80, 85, 90, 95, 100, 110, 125, 150 }) do
    SCALE_VALUES[#SCALE_VALUES + 1] = { text = percent .. "%", value = percent }
end

local function slotValues(mode)
    local values = {}
    for _, stat in ipairs(mode.stats) do values[#values + 1] = { text = stat.text, value = stat.id } end
    values[#values + 1] = { text = "Off", value = SLOT_OFF }
    return values
end

local function registerSchema()
    starfish.schema.section({
        key = "stats",
        label = "Hypixel API",
        description = "Stats come straight from the Hypixel API with your own key (developer.hypixel.net).",
        settings = {
            { key = "stats.apiKey", type = "text", default = "", description = "Your Hypixel API key. Required for any stats to show." },
            { key = "stats.headerLabels", type = "toggle", default = true, description = "Show column labels in the tab list header (Tab list style)." },
        }
    })

    starfish.schema.section({
        key = "tab",
        label = "Tab list",
        description = "How the stats are shown while you hold Tab in a game.",
        settings = {
            { key = "tab.style", type = "cycle", default = "overlay", displayLabel = "Style", description = "Overlay draws its own tab list (stars, heads, stat columns, HP). Tab list writes the stats into the normal tab list instead.", values = {
                { text = "Overlay", value = "overlay" },
                { text = "Tab list", value = "tablist" }
            }},
            { key = "tab.scale", type = "cycle", default = 100, displayLabel = "Size", description = "Overlay size. 100% matches the design screenshot at any resolution.", values = SCALE_VALUES },
            { key = "tab.grayOwnTeam", type = "toggle", default = false, displayLabel = "Gray Own Team", description = "Render your own team's stats in gray to de-emphasize them." },
        }
    })

    starfish.schema.section({
        key = "diagnostics",
        label = "Diagnostics",
        description = "Troubleshooting.",
        settings = {
            { key = "diagnostics.logFile", type = "toggle", default = false, displayLabel = "Debug Log File", description = "Write a debug log to %TEMP%\\tabstats-debug.log." },
        }
    })

    starfish.schema.section({
        key = "respawnTimer",
        label = "Respawn Timer",
        description = "Bed Wars: show a respawn countdown in an extra column on the right while a player is dead.",
        settings = {
            { key = "respawnTimer.enabled", type = "toggle", default = true, description = "Show a respawn countdown while a player is dead." },
            { key = "keepDisconnected.enabled", type = "toggle", default = true, displayLabel = "Keep Disconnected", description = "Keep a disconnected player's tab entry visible, marked DC, until they reconnect." },
        }
    })

    for _, id in ipairs(MODE_ORDER) do
        local mode = MODES[id]
        starfish.schema.section({
            key = mode.key,
            label = mode.label,
            description = "Tab stats in " .. mode.label .. " games.",
            settings = {
                { key = mode.config, type = "toggle", default = true, description = "Show tab stats in " .. mode.label .. "." },
            }
        })
        if starfish.config.get(mode.config, true) ~= false then
            local settings = {}
            for index, default in ipairs(mode.slots) do
                settings[#settings + 1] = { key = slotKey(mode, index), type = "cycle", default = default,
                    displayLabel = "Column " .. index, values = slotValues(mode),
                    description = "What column " .. index .. " shows in " .. mode.label .. "." }
            end
            starfish.schema.section({
                key = mode.key .. "Columns",
                label = mode.label .. " Columns",
                description = "Order and content of the " .. mode.label .. " tab columns.",
                settings = settings
            })
        end
    end
end

registerSchema()

local function modesShownSignature()
    local parts = {}
    for _, id in ipairs(MODE_ORDER) do
        parts[#parts + 1] = tostring(starfish.config.get(MODES[id].config, true) ~= false)
    end
    return table.concat(parts, ",")
end

local schemaModesShown = modesShownSignature()

local function syncSchemaVisibility()
    local signature = modesShownSignature()
    if signature == schemaModesShown then return end
    schemaModesShown = signature
    pcall(starfish.schema.clear)
    registerSchema()
end

local function hypixelApiKey()
    local key = getConfig("stats.apiKey", "")
    if type(key) ~= "string" then return nil end
    key = key:match("^%s*(.-)%s*$")
    if key == "" then return nil end
    return key
end

-- urchin exports the prestige formatter the Bed Wars plugin uses.
local function bedwarsStarText(bw, achievementLevel)
    local level = callPlugin("urchin", "bedwarsLevel", bw and bw.Experience or nil, achievementLevel)
    if type(level) == "table" and type(level.starText) == "string" then
        return level.starText
    end
    return "§7[" .. math.floor(achievementLevel or 0) .. "✫]"
end

local function parsePlayer(player)
    local groups = player.stats or {}
    local achievements = player.achievements or {}
    return {
        raw = {
            bedwars = groups.Bedwars,
            skywars = groups.SkyWars,
            murder = groups.MurderMystery,
            duels = groups.Duels,
        },
        bedwarsStar = bedwarsStarText(groups.Bedwars, achievements.bedwars_level),
        displayName = player.displayname,
        timestamp = os.time()
    }
end

local function notifyFetched(key)
    local callbacks = fetchCallbacks[key]
    fetchCallbacks[key] = nil
    if callbacks then
        for _, callback in ipairs(callbacks) do
            callback(stats[key])
        end
    end
    dirty = true
end

-- Tab-list UUIDs are real (v4); anything else goes through Mojang, and a name
-- Mojang doesn't know is a nick.
local function resolveUuid(query, callback)
    local cacheKey = query:lower()
    local cached = uuidCache[cacheKey]
    if cached == false then
        callback(nil, true)
        return
    elseif cached then
        callback(cached)
        return
    end

    local player = starfish.players.byName(query)
    if player and player.uuid and player.uuid:sub(15, 15) == "4" then
        uuidCache[cacheKey] = player.uuid
        callback(player.uuid)
        return
    end

    starfish.http.get(MOJANG_PROFILE_API .. starfish.http.encodeUri(query), function(res)
        local id = res.success and res.data and res.data.id or nil
        if id then
            uuidCache[cacheKey] = id
            callback(id)
        elseif res.status == 404 or res.status == 204 then
            uuidCache[cacheKey] = false
            callback(nil, true)
        else
            callback(nil, false)
        end
    end)
end

local function describeError(res)
    if res.status == 403 then return "invalid Hypixel API key" end
    if res.status == 429 then return "Hypixel API rate limit" end
    local cause = type(res.data) == "table" and res.data.cause or nil
    return cause or res.error or ("HTTP " .. tostring(res.status or "?"))
end

local function fetchStats(key, query, attempt)
    local cached = stats[key]
    if cached and not cached.isLoading and cached.timestamp and os.time() - cached.timestamp < CACHE_TTL then
        notifyFetched(key)
        return
    end
    if cached and cached.isLoading and (attempt or 1) == 1
        and starfish.time.monotonic() - cached.startedAt < LOADING_TIMEOUT_MS then
        return
    end

    local apiKey = hypixelApiKey()
    if not apiKey then
        if not warnedNoKey then
            warnedNoKey = true
            starfish.log.warn("No Hypixel API key set - stats stay hidden until one is added in the Tab Stats settings")
        end
        stats[key] = { fetchError = "no Hypixel API key set" }
        notifyFetched(key)
        return
    end

    stats[key] = { isLoading = true, startedAt = starfish.time.monotonic() }

    local function retryOrFail(message)
        local tries = attempt or 1
        if tries < FETCH_RETRIES then
            starfish.timers.delay(math.floor(RETRY_BASE_MS * 2 ^ (tries - 1)), function()
                fetchStats(key, query, tries + 1)
            end)
        else
            starfish.log.warn("Stats for " .. query .. " failed: " .. message)
            stats[key] = { fetchError = message }
            notifyFetched(key)
        end
    end

    resolveUuid(query, function(uuid, notFound)
        if notFound then
            stats[key] = { isNicked = true, timestamp = os.time() }
            notifyFetched(key)
            return
        end
        if not uuid then
            retryOrFail("UUID lookup failed")
            return
        end

        starfish.http.request({
            url = HYPIXEL_PLAYER_API .. uuid,
            method = "GET",
            headers = { ["API-Key"] = apiKey }
        }, function(res)
            local data = type(res.data) == "table" and res.data or nil
            if res.success and data and data.player then
                stats[key] = parsePlayer(data.player)
                notifyFetched(key)
            elseif res.success and data and data.player == nil then
                stats[key] = { isNicked = true, timestamp = os.time() }
                notifyFetched(key)
            elseif res.status == 403 then
                starfish.log.warn("Stats for " .. query .. " failed: " .. describeError(res))
                stats[key] = { fetchError = describeError(res) }
                notifyFetched(key)
            else
                retryOrFail(describeError(res))
            end
        end)
    end)
end

local function requestStats(name, callback)
    local realName = getRealName(name)
    if not realName and isNicked(name) then
        if callback then callback(NICKED_STATS) end
        return
    end

    local query = realName or name
    local key = query:lower()
    if callback then
        fetchCallbacks[key] = fetchCallbacks[key] or {}
        table.insert(fetchCallbacks[key], callback)
    end

    fetchStats(key, query)
end

local function statsFor(name)
    local realName = getRealName(name)
    if not realName and isNicked(name) then return NICKED_STATS end
    return stats[(realName or name):lower()]
end

local function displayNameOf(name)
    local player = starfish.players.byName(name)
    return (player and player.displayName) or name
end

-- The client draws the prefix of the name's scoreboard team, and
-- players.byName().team can be empty for dead players.
local function scoreboardTeamOf(name)
    local ok, team = pcall(function()
        for _, candidate in ipairs(starfish.scoreboard.teams() or {}) do
            for _, member in ipairs(candidate.players or {}) do
                if member == name then return candidate end
            end
        end
        return nil
    end)
    return ok and team or nil
end

local function teamPrefixOf(name)
    local team = scoreboardTeamOf(name)
    if team then return team.prefix or "" end
    local ok, prefix = pcall(function()
        local player = starfish.players.byName(name)
        local playerTeam = player and player.team
        return playerTeam and playerTeam.prefix or ""
    end)
    return (ok and prefix) or ""
end

-- Bed Wars and Duels pre-game lobbies list placeholder entries with v2 UUIDs
-- (real players are v4, nicks v1); some stay listed after the game starts.
local function isPlaceholderUuid(uuid)
    return type(uuid) == "string" and uuid:sub(15, 15) == "2"
end

local function isObfuscatedEntry(name)
    local player = starfish.players.byName(name)
    if player and isPlaceholderUuid(player.uuid) then return true end
    local shown = teamPrefixOf(name) .. ((player and player.displayName) or "")
    return shown:find("§k", 1, true) ~= nil
end

local function teamPrefixWidth(name)
    return textWidth(teamPrefixOf(name))
end

local function computeMaxTeamPrefixWidth()
    local maxWidth = 0
    for name in pairs(managed) do
        local width = teamPrefixWidth(name)
        if width > maxWidth then maxWidth = width end
    end
    return maxWidth
end

local function nameColumnWidth(name, uuid)
    return textWidth(displayNameOf(name))
        + textWidth(starfish.display.othersPrefix(uuid))
        + textWidth(starfish.display.othersSuffix(uuid))
end

local function computeMaxNameColumnWidth()
    local maxWidth = textWidth("Name")
    for name, entry in pairs(managed) do
        local width = nameColumnWidth(name, entry.uuid)
        if width > maxWidth then maxWidth = width end
    end
    return maxWidth
end

local function maxColumnWidth(column)
    if column.isName then return computeMaxNameColumnWidth() end
    local maxWidth = textWidth(column.header)
    for name in pairs(managed) do
        local width = textWidth(column.value(statsFor(name)))
        if width > maxWidth then maxWidth = width end
    end
    return maxWidth
end

-- Our padding resets formatting, so the team colour is restated.
local function teamColorOf(name)
    local color = nil
    for code in teamPrefixOf(name):gmatch("§([0-9a-fA-F])") do
        color = code
    end
    return color and ("§" .. color) or "§r"
end

-- ghosts: team members already offline when the game started (no tab entry).
local game = { started = false, respawns = {}, disconnected = {}, eliminated = {}, ghosts = {} }

local function stopRespawnTimers()
    for _, respawn in pairs(game.respawns) do respawn.timer:off() end
    game.respawns = {}
end

local function resetGame()
    stopRespawnTimers()
    game.started = false
    game.startedAt = nil
    game.disconnected = {}
    game.eliminated = {}
    game.ghosts = {}
end

local function statusText(name)
    if active ~= "bedwars" then return nil end
    if game.disconnected[name] then
        return getConfig("keepDisconnected.enabled", true) and "§cDC" or nil
    end
    local respawn = game.respawns[name]
    if respawn and getConfig("respawnTimer.enabled", true) then
        return "§c" .. math.max(0, respawn.remaining) .. "s"
    end
    return nil
end

local function myTeamColor()
    local ok, me = pcall(starfish.players.me)
    local color = ok and me and me.name and teamColorOf(me.name)
    if not color or color == "§r" then return nil end
    return color
end

local function isGrayed(name, ownTeamColor)
    return ownTeamColor ~= nil and getConfig("tab.grayOwnTeam", false) == true and teamColorOf(name) == ownTeamColor
end

local function grayText(text)
    return "§8" .. starfish.text.plain(text)
end

local function computeLayout()
    local cols = columns()
    local teamPrefixPad = computeMaxTeamPrefixWidth()
    local widths, starts = {}, {}
    local x = teamPrefixPad
    for index, column in ipairs(cols) do
        widths[index] = maxColumnWidth(column)
        if index > 1 then
            x = x + (column.isName and NAME_GAP or GUTTER)
        elseif not column.isName then
            x = x + LEAD
        end
        starts[index] = x
        x = x + widths[index]
    end

    local statusWidth = 0
    for name in pairs(managed) do
        local text = statusText(name)
        if text then statusWidth = math.max(statusWidth, textWidth(text)) end
    end
    local status = nil
    if statusWidth > 0 then
        x = x + GUTTER
        status = { start = x, width = statusWidth }
        x = x + statusWidth
    end

    return {
        columns = cols,
        widths = widths,
        starts = starts,
        teamPrefixPad = teamPrefixPad,
        status = status,
        ownTeam = myTeamColor(),
        rowEnd = x + TRAIL
    }
end

local function buildRow(name, uuid, layout)
    local prefix, suffix = {}, {}
    local parts = prefix
    local x = teamPrefixWidth(name)

    local function padTo(target)
        local pad, width = padding(target - x)
        table.insert(parts, pad)
        x = x + width
    end

    local st = statsFor(name)
    for index, column in ipairs(layout.columns) do
        local start = layout.starts[index]
        if column.isName then
            padTo(start)
            table.insert(parts, teamColorOf(name))
            parts = suffix
            x = x + nameColumnWidth(name, uuid)
        else
            local text = column.value(st)
            if isGrayed(name, layout.ownTeam) then text = grayText(text) end
            local width = textWidth(text)
            padTo(start + math.floor((layout.widths[index] - width) / 2))
            table.insert(parts, text)
            x = x + width
        end
    end
    local status = layout.status and statusText(name)
    if status then
        local width = textWidth(status)
        padTo(layout.status.start + math.floor((layout.status.width - width) / 2))
        table.insert(parts, status)
        x = x + width
    end
    padTo(layout.rowEnd)

    return table.concat(prefix), table.concat(suffix)
end

-- Width the client reserves for the list objective: the widest " <score>",
-- or 90px for hearts.
local function listObjectiveWidth(players)
    local ok, objective = pcall(starfish.scoreboard.displayed, "list")
    if not ok or not objective or not objective.name then return 0, false end
    if tostring(objective.type or ""):lower():find("heart") then return 90, false end

    local widest = 0
    for _, player in ipairs(players) do
        local okScore, score = pcall(starfish.scoreboard.score, objective.name, player.name)
        local value = (okScore and tonumber(score)) or 0
        widest = math.max(widest, textWidth(" " .. math.floor(value)))
    end
    return widest, widest > 5
end

local function headerLabelsLine(layout, players)
    local parts, x = {}, 0

    local function put(target, label)
        local pad, width = padding(target - x)
        table.insert(parts, pad)
        table.insert(parts, HEADER_COLOR .. label)
        x = x + width + textWidth(label)
    end

    for index, column in ipairs(layout.columns) do
        local labelWidth = textWidth(column.header)
        put(HEAD_WIDTH + layout.starts[index] + math.floor((layout.widths[index] - labelWidth) / 2), column.header)
    end

    local rowWidth = math.floor(layout.rowEnd)
    local listWidth, showsValues = listObjectiveWidth(players)
    if showsValues then
        put(HEAD_WIDTH + rowWidth + 1 + listWidth - textWidth(LIST_LABEL), LIST_LABEL)
    end

    local pad = padding(HEAD_WIDTH + rowWidth + listWidth + PING_WIDTH - x)
    table.insert(parts, pad)
    return table.concat(parts)
end

local skinUrlOf, headTexture
do
    -- Skins are PNGs; the zlib stream is inflated here (a port of zlib's puff.c).

    local LENGTH_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
    local LENGTH_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
    local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
    local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
    local CODE_LENGTH_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

    local function inflate(data)
        local pos = 3
        local bitBuffer, bitCount = 0, 0
        local out, outCount = {}, 0

        local function bits(count)
            while bitCount < count do
                local byte = data:byte(pos)
                if not byte then error("inflate: data ended early") end
                pos = pos + 1
                bitBuffer = bitBuffer | (byte << bitCount)
                bitCount = bitCount + 8
            end
            local value = bitBuffer & ((1 << count) - 1)
            bitBuffer = bitBuffer >> count
            bitCount = bitCount - count
            return value
        end

        local function huffman(lengths, first, count)
            local counts, offsets, symbols = {}, {}, {}
            for len = 0, 15 do counts[len] = 0 end
            for i = 0, count - 1 do
                local len = lengths[first + i] or 0
                counts[len] = counts[len] + 1
            end
            counts[0] = 0
            offsets[1] = 0
            for len = 1, 14 do offsets[len + 1] = offsets[len] + counts[len] end
            for i = 0, count - 1 do
                local len = lengths[first + i] or 0
                if len ~= 0 then
                    symbols[offsets[len]] = i
                    offsets[len] = offsets[len] + 1
                end
            end
            return { counts = counts, symbols = symbols }
        end

        local function decode(table)
            local code, first, index = 0, 0, 0
            for len = 1, 15 do
                code = code | bits(1)
                local count = table.counts[len]
                if code - count < first then
                    return table.symbols[index + (code - first)]
                end
                index = index + count
                first = (first + count) << 1
                code = code << 1
            end
            error("inflate: invalid code")
        end

        local fixedLengths, fixedDistances
        local function fixedTables()
            if not fixedLengths then
                local lengths = {}
                for i = 0, 143 do lengths[i] = 8 end
                for i = 144, 255 do lengths[i] = 9 end
                for i = 256, 279 do lengths[i] = 7 end
                for i = 280, 287 do lengths[i] = 8 end
                fixedLengths = huffman(lengths, 0, 288)
                local distances = {}
                for i = 0, 29 do distances[i] = 5 end
                fixedDistances = huffman(distances, 0, 30)
            end
            return fixedLengths, fixedDistances
        end

        local function dynamicTables()
            local literalCount = bits(5) + 257
            local distanceCount = bits(5) + 1
            local codeCount = bits(4) + 4
            local lengths = {}
            for i = 1, codeCount do lengths[CODE_LENGTH_ORDER[i]] = bits(3) end
            local codeTable = huffman(lengths, 0, 19)

            lengths = {}
            local index = 0
            while index < literalCount + distanceCount do
                local symbol = decode(codeTable)
                if symbol < 16 then
                    lengths[index] = symbol
                    index = index + 1
                else
                    local length, repeatCount = 0, 0
                    if symbol == 16 then
                        length = lengths[index - 1]
                        repeatCount = 3 + bits(2)
                    elseif symbol == 17 then
                        repeatCount = 3 + bits(3)
                    else
                        repeatCount = 11 + bits(7)
                    end
                    for _ = 1, repeatCount do
                        lengths[index] = length
                        index = index + 1
                    end
                end
            end
            return huffman(lengths, 0, literalCount), huffman(lengths, literalCount, distanceCount)
        end

        repeat
            local final = bits(1)
            local blockType = bits(2)
            if blockType == 0 then
                bitBuffer, bitCount = 0, 0
                local length = data:byte(pos) | (data:byte(pos + 1) << 8)
                pos = pos + 4
                for i = 0, length - 1 do
                    outCount = outCount + 1
                    out[outCount] = data:byte(pos + i)
                end
                pos = pos + length
            else
                local literals, distances
                if blockType == 1 then
                    literals, distances = fixedTables()
                elseif blockType == 2 then
                    literals, distances = dynamicTables()
                else
                    error("inflate: invalid block type")
                end
                while true do
                    local symbol = decode(literals)
                    if symbol < 256 then
                        outCount = outCount + 1
                        out[outCount] = symbol
                    elseif symbol == 256 then
                        break
                    else
                        symbol = symbol - 256
                        local length = LENGTH_BASE[symbol] + bits(LENGTH_EXTRA[symbol])
                        local distanceSymbol = decode(distances) + 1
                        local distance = DIST_BASE[distanceSymbol] + bits(DIST_EXTRA[distanceSymbol])
                        for _ = 1, length do
                            outCount = outCount + 1
                            out[outCount] = out[outCount - distance]
                        end
                    end
                end
            end
        until final == 1

        return out
    end

    local PNG_SIGNATURE = "\137PNG\r\n\26\n"
    local PNG_CHANNELS = { [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 }

    local function decodePng(bytes)
        if type(bytes) ~= "string" or bytes:sub(1, 8) ~= PNG_SIGNATURE then return nil, "not a PNG" end

        local pos, chunks = 9, {}
        local width, height, depth, colorType, compression, filterMethod, interlace, palette, transparency
        while pos + 7 <= #bytes do
            local length = string.unpack(">I4", bytes, pos)
            local kind = bytes:sub(pos + 4, pos + 7)
            local body = bytes:sub(pos + 8, pos + 7 + length)
            if kind == "IHDR" then
                width, height, depth, colorType, compression, filterMethod, interlace = string.unpack(">I4I4BBBBB", body)
            elseif kind == "PLTE" then
                palette = body
            elseif kind == "tRNS" then
                transparency = body
            elseif kind == "IDAT" then
                chunks[#chunks + 1] = body
            elseif kind == "IEND" then
                break
            end
            pos = pos + 12 + length
        end

        local channels = colorType and PNG_CHANNELS[colorType]
        if not width or depth ~= 8 or interlace ~= 0 or compression ~= 0 or filterMethod ~= 0 or not channels then
            return nil, "unsupported PNG"
        end

        local raw = inflate(table.concat(chunks))
        local stride = width * channels
        local rows, previous, index = {}, {}, 1
        for y = 0, height - 1 do
            local filter = raw[index]
            index = index + 1
            local line = {}
            for x = 1, stride do
                local value = raw[index] or 0
                index = index + 1
                local left = x > channels and line[x - channels] or 0
                local up = previous[x] or 0
                if filter == 1 then
                    value = value + left
                elseif filter == 2 then
                    value = value + up
                elseif filter == 3 then
                    value = value + ((left + up) >> 1)
                elseif filter == 4 then
                    local upLeft = x > channels and (previous[x - channels] or 0) or 0
                    local estimate = left + up - upLeft
                    local toLeft, toUp, toUpLeft = math.abs(estimate - left), math.abs(estimate - up), math.abs(estimate - upLeft)
                    if toLeft <= toUp and toLeft <= toUpLeft then
                        value = value + left
                    elseif toUp <= toUpLeft then
                        value = value + up
                    else
                        value = value + upLeft
                    end
                end
                line[x] = value & 255
            end
            rows[y] = line
            previous = line
        end

        local function pixel(x, y)
            local line = rows[y]
            if not line or x < 0 or x >= width then return 0, 0, 0, 0 end
            local at = x * channels + 1
            if colorType == 6 then
                return line[at], line[at + 1], line[at + 2], line[at + 3]
            elseif colorType == 2 then
                return line[at], line[at + 1], line[at + 2], 255
            elseif colorType == 3 then
                local entry = line[at]
                local r, g, b = palette:byte(entry * 3 + 1, entry * 3 + 3)
                local a = transparency and transparency:byte(entry + 1) or 255
                return r or 0, g or 0, b or 0, a
            elseif colorType == 4 then
                return line[at], line[at], line[at], line[at + 1]
            end
            return line[at], line[at], line[at], 255
        end

        return width, height, pixel
    end

    -- Face (8,8) with the hat layer (40,8) on top, scaled up 8x so texture
    -- filtering keeps the pixels sharp.
    local HEAD_TEXTURE_SIZE = 64

    local function headPixels(pngBytes)
        local width, _, pixel = decodePng(pngBytes)
        if not width then return nil end
        local scale = HEAD_TEXTURE_SIZE // 8
        local faceRows = {}
        for y = 0, 7 do
            local row = {}
            for x = 0, 7 do
                local r, g, b = pixel(8 + x, 8 + y)
                local hr, hg, hb, ha = pixel(40 + x, 8 + y)
                if ha and ha > 0 then
                    local t = ha / 255
                    r = math.floor(hr * t + r * (1 - t) + 0.5)
                    g = math.floor(hg * t + g * (1 - t) + 0.5)
                    b = math.floor(hb * t + b * (1 - t) + 0.5)
                end
                row[x] = string.char(r, g, b, 255):rep(scale)
            end
            local line = table.concat(row, "", 0, 7)
            faceRows[y] = line:rep(scale)
        end
        return table.concat(faceRows, "", 0, 7)
    end

    function skinUrlOf(player)
        local ok, url = pcall(function()
            local properties = player and player.properties
            if not properties then return nil end
            local textures = properties.textures
            if not textures then
                for _, property in ipairs(properties) do
                    if property.name == "textures" then textures = property end
                end
            end
            if not textures or not textures.value then return nil end
            local decoded = starfish.base64.decode(textures.value)
            return decoded and decoded:match('"SKIN"%s*:%s*{%s*"url"%s*:%s*"([^"]+)"')
        end)
        return ok and url or nil
    end

    local heads = { textures = {}, pending = {}, requested = {} }

    local function requestHead(url)
        if heads.requested[url] then return end
        heads.requested[url] = true
        starfish.http.getBinary(url, function(res)
            local bytes = res and res.binary
            if not res or not res.success or not bytes then
                trace("skin download failed: " .. tostring(res and (res.error or res.status)))
                return
            end
            local ok, pixels = pcall(headPixels, bytes)
            if ok and pixels then
                heads.pending[url] = pixels
                pcall(starfish.overlay.invalidate)
            else
                trace("skin decode failed: " .. tostring(pixels))
            end
        end)
    end

    function headTexture(url)
        if not url then return nil end
        local texture = heads.textures[url]
        if texture then return texture end
        local pixels = heads.pending[url]
        if pixels then
            heads.pending[url] = nil
            local ok, id = pcall(starfish.overlay.loadTexture, { data = pixels, width = HEAD_TEXTURE_SIZE, height = HEAD_TEXTURE_SIZE })
            if ok and id then
                heads.textures[url] = id
                return id
            end
            trace("loadTexture failed: " .. tostring(id))
            return nil
        end
        requestHead(url)
        return nil
    end
end

-- Overlay sizes are GUI pixels (u), measured from the reference design.

local TAB_KEY = "TAB"
local REFERENCE_UNITS_PER_HEIGHT = 440 -- the reference is 1057px tall at 2.4px per u
local TEXT_SIZE_PER_UNIT = 12          -- mctext draws one Minecraft pixel as size/12
local GLYPH_TOP = 2                    -- and a capital's top 2u below the text y

local LAYOUT = {
    top = 10,
    pad = 8,
    gap = 17,
    nameGap = 32,
    head = 8,
    headGap = 8,
    nameTail = 2,    -- the reference font draws names ~2u wider than mctext
    row = 35 / 3,    -- label band and player rows (28px at the reference's 2.4px/u)
    rowText = 2,
    line = 15,
    lineText = 2.5,
}

local PANEL_COLOR = { r = 0, g = 0, b = 0, a = 128 }
local LABEL_BAND_COLOR = { r = 255, g = 255, b = 255, a = 16 }
local ROWS_COLOR = { r = 255, g = 255, b = 255, a = 8 }
local MISSING_HEAD_COLOR = { r = 60, g = 60, b = 60, a = 255 }
local TEXT_BASE_COLOR = { r = 255, g = 255, b = 255, a = 255 } -- textColored requires one; § codes override it

local overlay = { bound = false, held = false, header = nil, footer = nil, loggedHeaderFooter = false, measured = {} }
local markOverlayBroken

local function overlayStyle()
    return getConfig("tab.style", "overlay") == "overlay"
end

-- After some injects the renderer isn't attached (supported() false, 0x0
-- viewport). Tab must not be taken then, or there is no tab list at all.
local overlayUsableLogged = nil

local function overlayUsable()
    local okSupported, supported = pcall(starfish.overlay.supported)
    local okViewport, width, height = pcall(starfish.overlay.getViewport)
    local usable = okSupported and supported == true and okViewport
        and (tonumber(width) or 0) > 0 and (tonumber(height) or 0) > 0
    if usable ~= overlayUsableLogged then
        overlayUsableLogged = usable
        trace(usable and "overlay renderer attached - Tab shows the overlay"
            or ("overlay renderer not attached (supported: " .. tostring(okSupported and supported)
                .. ", viewport: " .. tostring(width) .. "x" .. tostring(height) .. ") - stats go into the normal tab list"))
    end
    return usable
end

local function useOverlay()
    return not overlay.broken and overlayStyle() and overlayUsable()
end

local function overlayScale(viewportHeight)
    local percent = tonumber(getConfig("tab.scale", 100)) or 100
    return viewportHeight / REFERENCE_UNITS_PER_HEIGHT * percent / 100
end

local function toLegacy(value)
    if value == nil then return nil end
    if type(value) ~= "string" then
        local ok, text = pcall(starfish.text.legacy, value)
        return ok and text or nil
    end
    local first = value:match("^%s*(.)")
    if first == "{" or first == "[" or first == '"' then
        local ok, text = pcall(function() return starfish.text.legacy(starfish.text.fromJson(value)) end)
        if ok and text then return text end
    end
    return value
end

local function splitLines(text)
    local lines = {}
    if not text or text == "" then return lines end
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    while #lines > 0 and starfish.text.plain(lines[#lines]):match("^%s*$") do
        lines[#lines] = nil
    end
    return lines
end

starfish.events.on("player:listHeaderFooter", function(event)
    if not overlay.loggedHeaderFooter then
        overlay.loggedHeaderFooter = true
        trace("tab header/footer event: " .. describe(event))
    end
    overlay.header = toLegacy(event.header)
    overlay.footer = toLegacy(event.footer)
    pcall(starfish.overlay.invalidate)
end)

local function isSpectator(player)
    local mode = player.gamemode
    return mode == 3 or (type(mode) == "string" and mode:lower():find("spectator") ~= nil)
end

-- Same order as the client: spectators last, then team name, then name.
local function overlayPlayers()
    local ok, players = pcall(starfish.players.all)
    if not ok or not players then return {} end

    local list = {}
    for _, player in ipairs(players) do
        if player.name and player.uuid and not isPlaceholderUuid(player.uuid) then
            local team = scoreboardTeamOf(player.name)
            list[#list + 1] = {
                name = player.name,
                uuid = player.uuid,
                player = player,
                teamName = team and team.name or "",
                prefix = team and team.prefix or teamPrefixOf(player.name),
                suffix = team and team.suffix or "",
                spectator = isSpectator(player),
            }
        end
    end
    -- Hypixel removes dead players from the tab until they respawn, so anyone
    -- with a countdown or DC is drawn from their last snapshot.
    local present = {}
    for _, entry in ipairs(list) do present[entry.name] = true end
    for name, entry in pairs(managed) do
        local snapshot = entry.snapshot
        if not present[name] and snapshot and statusText(name) then
            local team = scoreboardTeamOf(name)
            list[#list + 1] = {
                name = name,
                uuid = entry.uuid,
                player = snapshot,
                teamName = team and team.name or "",
                prefix = team and team.prefix or teamPrefixOf(name),
                suffix = team and team.suffix or "",
                spectator = false,
            }
        end
    end
    for name, ghost in pairs(game.ghosts) do
        if not present[name] and statusText(name) then
            list[#list + 1] = {
                name = name,
                player = nil,
                teamName = ghost.team.name or "",
                prefix = ghost.team.prefix or "",
                suffix = ghost.team.suffix or "",
                spectator = false,
            }
        end
    end
    table.sort(list, function(a, b)
        if a.spectator ~= b.spectator then return not a.spectator end
        if a.teamName ~= b.teamName then return a.teamName < b.teamName end
        return a.name < b.name
    end)
    return list
end

local function listScores(list)
    local ok, objective = pcall(starfish.scoreboard.displayed, "list")
    if not ok or not objective or not objective.name then return nil end
    local scores = {}
    for _, entry in ipairs(list) do
        local okScore, score = pcall(starfish.scoreboard.score, objective.name, entry.name)
        scores[entry.name] = (okScore and tonumber(score)) or 0
    end
    return scores
end

local function hpText(score)
    return "§a" .. math.floor(score)
end

local function nameText(entry)
    local others = entry.uuid and (starfish.display.othersSuffix(entry.uuid) or "") or ""
    return (entry.prefix or "") .. entry.name .. (entry.suffix or "") .. others
end

local function overlayLayout(measure)
    local list = overlayPlayers()
    local scores = listScores(list)
    local cols = columns()

    local ownTeam = myTeamColor()
    local anyStatus = false
    local cells = {}
    for index, entry in ipairs(list) do
        local st = statsFor(entry.name)
        local grayed = isGrayed(entry.name, ownTeam)
        local row = {}
        for colIndex, column in ipairs(cols) do
            if column.isName then
                row[colIndex] = nameText(entry)
            else
                local value = column.value(st)
                row[colIndex] = grayed and grayText(value) or value
            end
        end
        if scores then row.hp = hpText(scores[entry.name] or 0) end
        row.status = statusText(entry.name)
        anyStatus = anyStatus or row.status ~= nil
        cells[index] = row
    end

    local x = LAYOUT.pad
    local placed = {}
    for colIndex, column in ipairs(cols) do
        local width = measure(column.header)
        if column.isName then
            local widest = 0
            for _, row in ipairs(cells) do widest = math.max(widest, measure(row[colIndex])) end
            width = math.max(width, LAYOUT.head + LAYOUT.headGap + widest + LAYOUT.nameTail)
            if colIndex > 1 then x = x + LAYOUT.nameGap end
        else
            for _, row in ipairs(cells) do width = math.max(width, measure(row[colIndex])) end
            if colIndex > 1 then x = x + LAYOUT.gap end
        end
        placed[colIndex] = { x = x, w = width, column = column }
        x = x + width
    end

    local hp = nil
    if scores then
        local width = measure(LIST_LABEL)
        for _, row in ipairs(cells) do width = math.max(width, measure(row.hp)) end
        x = x + LAYOUT.gap
        hp = { x = x, w = width }
        x = x + width
    end
    local status = nil
    if anyStatus then
        local width = 0
        for _, row in ipairs(cells) do
            if row.status then width = math.max(width, measure(row.status)) end
        end
        x = x + LAYOUT.gap
        status = { x = x, w = width }
        x = x + width
    end
    local tableWidth = x + LAYOUT.pad

    local headerLines, footerLines = splitLines(overlay.header), splitLines(overlay.footer)
    local width = tableWidth
    for _, line in ipairs(headerLines) do width = math.max(width, measure(line) + 2 * LAYOUT.pad) end
    for _, line in ipairs(footerLines) do width = math.max(width, measure(line) + 2 * LAYOUT.pad) end

    local labelsY = #headerLines * LAYOUT.line
    local rowsY = labelsY + LAYOUT.row
    local footerY = rowsY + #list * LAYOUT.row

    return {
        list = list,
        cells = cells,
        placed = placed,
        hp = hp,
        status = status,
        width = width,
        tableX = (width - tableWidth) / 2,
        headerLines = headerLines,
        footerLines = footerLines,
        labelsY = labelsY,
        rowsY = rowsY,
        footerY = footerY,
        height = footerY + #footerLines * LAYOUT.line,
    }
end

local function drawOverlay()
    if not overlay.held or not tabActive or not useOverlay() then return end

    local viewportWidth, viewportHeight = starfish.overlay.getViewport()
    local scale = overlayScale(viewportHeight)
    local size = TEXT_SIZE_PER_UNIT * scale
    local TOP_LEFT = starfish.overlay.Anchor.TOP_LEFT

    if overlay.measuredScale ~= scale then
        overlay.measured = {}
        overlay.measuredScale = scale
    end
    local function measure(text)
        local plain = starfish.text.plain(text or "")
        local cached = overlay.measured[plain]
        if not cached then
            cached = (starfish.overlay.measureText(plain, size)) / scale
            overlay.measured[plain] = cached
        end
        return cached
    end

    local layout = overlayLayout(measure)
    if not overlay.loggedDraw then
        overlay.loggedDraw = true
        trace(string.format("overlay drawn: %d rows, %.0fx%.0f viewport, %.2f px/u", #layout.list, viewportWidth, viewportHeight, scale))
    end
    local originX = math.floor((viewportWidth - layout.width * scale) / 2 + 0.5)
    local originY = LAYOUT.top * scale

    local function rect(x, y, w, h, color)
        starfish.overlay.rect({ anchor = TOP_LEFT, x = originX + x * scale, y = originY + y * scale, w = w * scale, h = h * scale, color = color })
    end
    local function text(value, x, capTop)
        starfish.overlay.textColored({ anchor = TOP_LEFT, x = originX + x * scale, y = originY + (capTop - GLYPH_TOP) * scale, text = value, size = size, color = TEXT_BASE_COLOR })
    end
    local function centered(value, x, w, capTop)
        text(value, x + (w - measure(value)) / 2, capTop)
    end

    rect(0, 0, layout.width, layout.height, PANEL_COLOR)
    rect(0, layout.labelsY, layout.width, LAYOUT.row, LABEL_BAND_COLOR)
    rect(0, layout.rowsY, layout.width, #layout.list * LAYOUT.row, ROWS_COLOR)

    for index, line in ipairs(layout.headerLines) do
        centered(line, 0, layout.width, (index - 1) * LAYOUT.line + LAYOUT.lineText)
    end

    local tableX = layout.tableX
    for _, cell in ipairs(layout.placed) do
        centered(HEADER_COLOR .. cell.column.header, tableX + cell.x, cell.w, layout.labelsY + LAYOUT.rowText)
    end
    if layout.hp then
        centered(HEADER_COLOR .. LIST_LABEL, tableX + layout.hp.x, layout.hp.w, layout.labelsY + LAYOUT.rowText)
    end
    if layout.status and (overlay.statusTraces or 0) < 5 then
        overlay.statusTraces = (overlay.statusTraces or 0) + 1
        local shown = {}
        for index, entry in ipairs(layout.list) do
            local status = layout.cells[index].status
            if status then shown[#shown + 1] = entry.name .. "=" .. starfish.text.plain(status) end
        end
        trace("overlay drew status column: " .. table.concat(shown, ", "))
    end

    for index, entry in ipairs(layout.list) do
        local rowTop = layout.rowsY + (index - 1) * LAYOUT.row
        local capTop = rowTop + LAYOUT.rowText
        local row = layout.cells[index]
        for colIndex, cell in ipairs(layout.placed) do
            local x = tableX + cell.x
            if cell.column.isName then
                local texture = headTexture(skinUrlOf(entry.player))
                if texture then
                    starfish.overlay.texture({ anchor = TOP_LEFT, x = originX + x * scale, y = originY + capTop * scale,
                        w = LAYOUT.head * scale, h = LAYOUT.head * scale, texture = texture })
                else
                    rect(x, capTop, LAYOUT.head, LAYOUT.head, MISSING_HEAD_COLOR)
                end
                text(row[colIndex], x + LAYOUT.head + LAYOUT.headGap, capTop)
            else
                centered(row[colIndex], x, cell.w, capTop)
            end
        end
        if layout.hp then
            centered(row.hp, tableX + layout.hp.x, layout.hp.w, capTop)
        end
        if layout.status and row.status then
            centered(row.status, tableX + layout.status.x, layout.status.w, capTop)
        end
    end

    for index, line in ipairs(layout.footerLines) do
        centered(line, 0, layout.width, layout.footerY + (index - 1) * LAYOUT.line + LAYOUT.lineText)
    end
    overlay.drawnAt = starfish.time.monotonic()
end

starfish.overlay.onRender(function()
    if not overlay.loggedRender then
        overlay.loggedRender = true
        trace("overlay render callback running")
    end
    local ok, err = pcall(drawOverlay)
    if not ok then markOverlayBroken("draw error: " .. tostring(err)) end
end)

local keyTraces = 0

local function setTabHeld(held, source)
    if overlay.held == held then return end
    overlay.held = held
    if held then overlay.pressedAt = starfish.time.monotonic() end
    if keyTraces < 6 then
        keyTraces = keyTraces + 1
        trace("Tab " .. (held and "down" or "up") .. " (" .. source .. ")")
    end
    pcall(starfish.overlay.invalidate)
end

local function bindTab()
    if overlay.bound then return end
    -- Binds without activeInMenu never fire under Lunar.
    local ok, err = pcall(starfish.input.bind, TAB_KEY, {
        onPress = function()
            overlay.forcedClosed = false
            setTabHeld(true, "bind")
        end,
        onRelease = function() setTabHeld(false, "bind") end,
        activeInMenu = true,
    })
    overlay.bound = ok
    if ok and overlay.bindLogged then return end
    overlay.bindLogged = ok
    local okInput, inputSupported = pcall(starfish.input.supported)
    local okOverlay, overlaySupported = pcall(starfish.overlay.supported)
    trace((ok and "tab overlay bound to Tab" or ("tab bind failed: " .. tostring(err)))
        .. " (input supported: " .. tostring(okInput and inputSupported)
        .. ", overlay supported: " .. tostring(okOverlay and overlaySupported) .. ")")
end

local function unbindTab()
    if not overlay.bound then return end
    pcall(starfish.input.unbind, TAB_KEY)
    overlay.bound = false
    setTabHeld(false, "unbind")
end

-- If the overlay can't draw, Tab goes back to the game for the session.
markOverlayBroken = function(reason)
    if overlay.broken then return end
    overlay.broken = true
    trace("overlay disabled for this session (" .. tostring(reason) .. ") - Tab is back to normal, stats go into the tab list")
    unbindTab()
    dirty = true
    layoutCache = nil
end

local DRAW_DEADLINE_MS = 400

-- Starfish has no chat-open state (isCursorVisible only covers its own
-- cursor), so the chat keys are polled, never bound.
local CHAT_OPEN_KEYS = { "T", "SLASH" }
-- After Alt+Tab the game never sees Tab released and isHeld stays true.
local FOCUS_KEYS = { "LALT", "RALT" }
local CHAT_CLOSE_KEYS = { "RETURN", "NUMPADENTER", "ESCAPE" }
local keyWasHeld = {}
local chatOpen = false
local cursorFree = false
local chatTraces = 0

local function pressedNow(key)
    local ok, held = pcall(starfish.input.isHeld, key)
    held = ok and held == true
    local edge = held and not keyWasHeld[key]
    keyWasHeld[key] = held
    return edge
end

local function anyPressed(keys)
    local pressed = nil
    for _, key in ipairs(keys) do
        if pressedNow(key) and not pressed then pressed = key end
    end
    return pressed
end

local function tabBlocked()
    return chatOpen or cursorFree
end

local function setChatOpen(open, key)
    if chatOpen == open then return end
    chatOpen = open
    if tabActive and chatTraces < 12 then
        chatTraces = chatTraces + 1
        trace(open and ("chat opened (" .. key .. ") - Tab goes to chat")
            or ("chat closed (" .. key .. ") - Tab shows the overlay"))
    end
end

starfish.timers.interval(16, function()
    local opened = anyPressed(CHAT_OPEN_KEYS)
    local closed = anyPressed(CHAT_CLOSE_KEYS)
    local switched = anyPressed(FOCUS_KEYS)
    if overlay.held and (switched or closed == "ESCAPE") then
        overlay.forcedClosed = true
        setTabHeld(false, switched and "alt" or "escape")
    end
    if not chatOpen and opened and not overlay.held then
        setChatOpen(true, opened)
    elseif chatOpen and closed then
        setChatOpen(false, closed)
    end

    local okCursor, free = pcall(starfish.overlay.isCursorVisible)
    cursorFree = okCursor and free == true

    if tabBlocked() then
        unbindTab()
    elseif tabActive and useOverlay() and not overlay.bound then
        bindTab()
    end
end)

starfish.timers.interval(50, function()
    if overlay.held and overlay.pressedAt and (overlay.drawnAt or -1) < overlay.pressedAt
        and starfish.time.monotonic() - overlay.pressedAt > DRAW_DEADLINE_MS then
        markOverlayBroken("no overlay frame within " .. DRAW_DEADLINE_MS .. "ms of pressing Tab")
    end
    if not overlay.bound then return end
    local ok, held = pcall(starfish.input.isHeld, TAB_KEY)
    if not ok or held == nil then return end
    if overlay.forcedClosed then
        if held ~= true then overlay.forcedClosed = false end
        return
    end
    if (held == true) ~= overlay.held then
        setTabHeld(held == true, "poll")
    end
end)

starfish.timers.interval(250, function()
    if overlay.held then pcall(starfish.overlay.invalidate) end
end)

local function forget(name)
    local entry = managed[name]
    if not entry then return end
    if entry.held then pcall(starfish.display.releaseRemoval, entry.uuid) end
    starfish.display.clearPrefix(entry.uuid)
    starfish.display.clearSuffix(entry.uuid)
    lastApplied[entry.uuid] = nil
    byUuid[entry.uuid] = nil
    managed[name] = nil
end

local function clearDecorations()
    for _, entry in pairs(managed) do
        starfish.display.clearPrefix(entry.uuid)
        starfish.display.clearSuffix(entry.uuid)
        if entry.held then pcall(starfish.display.releaseRemoval, entry.uuid) end
    end
    starfish.display.clearTabHeaderAppend()
    managed = {}
    byUuid = {}
    lastApplied = {}
    layoutCache = nil
    lastHeader = nil
end

local function clearRowDecorations()
    for _, entry in pairs(managed) do
        starfish.display.clearPrefix(entry.uuid)
        starfish.display.clearSuffix(entry.uuid)
    end
    starfish.display.clearTabHeaderAppend()
    lastApplied = {}
    lastHeader = nil
    layoutCache = nil
end

local function deactivate()
    unbindTab()
    resetGame()
    overlay.bindLogged = false
    overlay.loggedDraw = false
    overlay.statusTraces = 0
    keyTraces = 0
    chatTraces = 0
    if not tabActive then return end
    tabActive = false
    if refreshTimer then
        refreshTimer:off()
        refreshTimer = nil
    end
    clearDecorations()
end

local shouldProtect, syncRemovalHolds, detectMissingTeamMembers
do
    -- Bed Wars chat events, with the Bed Wars plugin's messages and timings.

    local RESPAWN_SECONDS = 5
    local RECONNECT_RESPAWN_SECONDS = 10
    local RESPAWN_CONFIRM_GRACE_MS = 500
    local TEAM_COLORS = {
        Red = "§c", Blue = "§9", Green = "§a", Yellow = "§e",
        Aqua = "§b", White = "§f", Pink = "§d", Gray = "§8",
    }
    local REJOIN_MESSAGES = {
        ["You will respawn in 10 seconds!"] = "respawn",
        ["Your bed was destroyed so you are a spectator!"] = "spectator",
    }
    local DEATH_PHRASES = {
        " was ", "fell into the void", "hit the ground too hard",
        "burned to death", "drowned", "went up in flames", " died",
    }

    -- Living players' entries are held so a disconnect stays listed.
    function shouldProtect(name)
        if active ~= "bedwars" or not game.started or not managed[name] then return false end
        if game.disconnected[name] then return getConfig("keepDisconnected.enabled", true) == true end
        if game.eliminated[name] then return false end
        return true
    end

    function syncRemovalHolds()
        for name, entry in pairs(managed) do
            local protect = shouldProtect(name)
            if protect ~= (entry.held == true) then
                entry.held = protect
                pcall(protect and starfish.display.holdRemoval or starfish.display.releaseRemoval, entry.uuid)
            end
            local okPlayer, player = pcall(starfish.players.byName, name)
            if okPlayer and player then entry.snapshot = player end
        end
    end

    local function known(name)
        return managed[name] ~= nil or game.ghosts[name] ~= nil
    end

    local function markEliminated(name)
        game.ghosts[name] = nil
        local respawn = game.respawns[name]
        if respawn then respawn.timer:off() end
        game.respawns[name] = nil
        game.eliminated[name] = true
        game.disconnected[name] = nil
        trace("eliminated: " .. name)
        forget(name)
        dirty = true
    end

    local function markDisconnected(name)
        if game.disconnected[name] then return end
        game.disconnected[name] = true
        trace("disconnected: " .. name)
        dirty = true
    end

    local function clearDisconnected(name)
        if not game.disconnected[name] then return end
        game.disconnected[name] = nil
        dirty = true
    end

    local function markTeamEliminated(teamColor)
        local names = {}
        for name in pairs(managed) do names[#names + 1] = name end
        for name in pairs(game.ghosts) do names[#names + 1] = name end
        for _, name in ipairs(names) do
            if teamColorOf(name) == teamColor then markEliminated(name) end
        end
    end

    -- Hypixel keeps players who left before the start on their team, so right
    -- after the start, team members missing from the tab are shown as DC.
    local GHOST_WINDOW_MS = 20000

    function detectMissingTeamMembers()
        if active ~= "bedwars" or not game.started or not game.startedAt then return end
        if starfish.time.monotonic() - game.startedAt > GHOST_WINDOW_MS then return end
        local okTeams, teams = pcall(starfish.scoreboard.teams)
        local okPlayers, players = pcall(starfish.players.all)
        if not okTeams or not teams or not okPlayers or not players then return end
        local present = {}
        for _, player in ipairs(players) do
            if player.name then present[player.name] = true end
        end
        for _, team in ipairs(teams) do
            -- Bed Wars team prefixes are a bold team letter, e.g. "§c§lR §r§c".
            if starfish.text.plain(team.prefix or ""):match("^%u%s+$") then
                for _, member in ipairs(team.players or {}) do
                    if type(member) == "string" and member:match("^[%w_]+$") and #member <= 16
                        and not present[member] and not known(member) and not game.eliminated[member] then
                        game.ghosts[member] = { team = team }
                        game.disconnected[member] = true
                        trace("offline at game start: " .. member .. " (team " .. tostring(team.name) .. ") - shown as DC")
                        requestStats(member)
                        dirty = true
                    end
                end
            end
        end
    end

    local function confirmRespawned(name)
        if game.respawns[name] or not known(name) then return end
        if not starfish.players.byName(name) then markDisconnected(name) end
    end

    local function trackRespawn(name, seconds)
        if game.eliminated[name] then return end
        clearDisconnected(name)
        local existing = game.respawns[name]
        if existing then existing.timer:off() end

        local respawn = { remaining = seconds }
        game.respawns[name] = respawn
        respawn.timer = starfish.timers.interval(1000, function()
            respawn.remaining = respawn.remaining - 1
            dirty = true
            if respawn.remaining <= 0 then
                respawn.timer:off()
                if game.respawns[name] == respawn then game.respawns[name] = nil end
                starfish.timers.delay(RESPAWN_CONFIRM_GRACE_MS, function() confirmRespawned(name) end)
            end
        end)
        trace("respawning: " .. name .. " (" .. seconds .. "s)")
        dirty = true
    end

    local function onRejoin(kind)
        game.started = true
        local ok, me = pcall(starfish.players.me)
        if not ok or not me or not me.name then return end
        if kind == "spectator" then
            markEliminated(me.name)
        else
            trackRespawn(me.name, RECONNECT_RESPAWN_SECONDS)
        end
    end

    local function isDeathMessage(message)
        if message:sub(-1) ~= "." then return false end
        for _, phrase in ipairs(DEATH_PHRASES) do
            if message:find(phrase, 1, true) then return true end
        end
        return false
    end

    -- Player chat always contains ":".
    local function handleGameChat(message)
        if message:find(":", 1, true) then return end

        local eliminatedTeam = message:match("^TEAM ELIMINATED > (%a+) Team")
        if eliminatedTeam and TEAM_COLORS[eliminatedTeam] then
            markTeamEliminated(TEAM_COLORS[eliminatedTeam])
            return
        end

        local reconnected = message:match("^([%w_]+) reconnected%.$")
        if reconnected and known(reconnected) then
            trackRespawn(reconnected, RECONNECT_RESPAWN_SECONDS)
            return
        end

        local disconnected = message:match("^([%w_]+) disconnected%.")
        if disconnected and known(disconnected) then
            markDisconnected(disconnected)
            if message:sub(-11) == "FINAL KILL!" then markEliminated(disconnected) end
            return
        end

        local subject = message:match("^([%w_]+) ")
        if not subject or not known(subject) then return end
        if message:sub(-11) == "FINAL KILL!" then
            markEliminated(subject)
        elseif isDeathMessage(message) then
            trackRespawn(subject, RESPAWN_SECONDS)
        end
    end

    starfish.events.on("chat:receive", function(event)
        if active ~= "bedwars" or not tabActive then return end
        if event.kind == "actionBar" then return end
        local ok, err = pcall(function()
            local message = starfish.text.plain(event.message or "")
            if REJOIN_MESSAGES[message] then
                onRejoin(REJOIN_MESSAGES[message])
            else
                handleGameChat(message)
            end
        end)
        if not ok then trace("chat handler error: " .. tostring(err)) end
    end)
end

local function warnIfOverlapping()
    if warnedOverlap or active ~= "bedwars" then return end
    for _, entry in pairs(managed) do
        local others = (starfish.display.othersPrefix(entry.uuid) or "") .. (starfish.display.othersSuffix(entry.uuid) or "")
        if others:find("✫", 1, true) then
            warnedOverlap = true
            starfish.chat.warning("Tab Stats: turn off Tab Stats in the Bed Wars plugin settings, both are drawing the tab.")
            trace("overlap with another plugin's tab stats: " .. others)
            return
        end
    end
end

local function refresh()
    if not tabActive then return end
    if not active or not getConfig(MODES[active].config, true) then
        deactivate()
        return
    end

    syncRemovalHolds()
    detectMissingTeamMembers()

    -- The sidebar can load after the location event.
    if active == "duels" and not duelsKey then
        duelsKey = resolveDuelsKey(nil)
        if duelsKey then
            duelsKeyLogged = false
            duelsFallbackLogged = false
            dirty = true
        end
    end

    if useOverlay() then
        if next(lastApplied) or lastHeader then clearRowDecorations() end
        if not tabBlocked() then bindTab() end
        return
    end
    if overlay.bound then
        unbindTab()
        dirty = true
    end

    if dirty or not layoutCache then
        dirty = false
        layoutCache = computeLayout()
        for name, entry in pairs(managed) do
            local teamPrefix = teamPrefixOf(name)
            if entry.teamPrefix ~= nil and entry.teamPrefix ~= teamPrefix then
                trace(name .. ": team prefix " .. describe(entry.teamPrefix) .. " -> " .. describe(teamPrefix))
            end
            entry.teamPrefix = teamPrefix
            local prefix, suffix = buildRow(name, entry.uuid, layoutCache)
            local combined = prefix .. "\0" .. suffix
            if lastApplied[entry.uuid] ~= combined then
                lastApplied[entry.uuid] = combined
                starfish.display.setPrefix(entry.uuid, prefix, { priority = PREFIX_PRIORITY })
                starfish.display.setSuffix(entry.uuid, suffix, { priority = PREFIX_PRIORITY })
            end
        end
    end

    local okPlayers, players = pcall(starfish.players.all)
    players = (okPlayers and players) or {}
    local header = nil
    if getConfig("stats.headerLabels", true) and #players <= MAX_SINGLE_COLUMN then
        header = headerLabelsLine(layoutCache, players)
    end
    if header ~= lastHeader then
        lastHeader = header
        if header then
            starfish.display.setTabHeaderAppend(header)
        else
            starfish.display.clearTabHeaderAppend()
        end
    end

    warnIfOverlapping()
end

local function manage(name, uuid)
    if managed[name] then return end
    if isObfuscatedEntry(name) then return end
    trace("tracking " .. name .. " (uuid v" .. tostring(uuid):sub(15, 15)
        .. ", team prefix " .. describe(teamPrefixOf(name)) .. ")")
    managed[name] = { uuid = uuid }
    byUuid[uuid] = name
    game.ghosts[name] = nil
    requestStats(name)
    dirty = true
end

local lastTrackedCount = nil

local function trackTabList()
    local players = starfish.players.all()
    if #players ~= lastTrackedCount then
        lastTrackedCount = #players
        trace("tab list: " .. #players .. " players"
            .. (#players > MAX_TRACKED and " (too many, treating as a lobby)" or ""))
    end
    if #players > MAX_TRACKED then return end
    for _, player in ipairs(players) do
        if player.name and player.uuid then
            manage(player.name, player.uuid)
        end
    end
end

local function activate()
    if not active or not getConfig(MODES[active].config, true) then return end
    tabActive = true
    dirty = true
    resetGame()
    game.started = active == "bedwars"
    game.startedAt = game.started and starfish.time.monotonic() or nil
    trace("Tab stats active: " .. MODES[active].label
        .. (duelsKey and (" (" .. table.concat(duelsKey, ", ") .. ")") or ""))
    trackTabList()
    if not refreshTimer then
        refreshTimer = starfish.timers.interval(REFRESH_MS, refresh)
    end
end

local function modeFor(serverType)
    if serverType == "BEDWARS" then return "bedwars" end
    if serverType == "SKYWARS" then return "skywars" end
    if serverType == "MURDER_MYSTERY" then return "murder" end
    if serverType == "DUELS" then return "duels" end
    return nil
end

local function applyLocation(loc)
    local mode = modeFor(loc.serverType)
    locationKnown = true
    -- Some modes send no mode string, so any non-lobby server counts.
    local inGame = loc.lobbyName == nil
    local nextMode = inGame and mode or nil

    trace("location " .. describe(loc) .. " -> " .. tostring(nextMode))

    locationMode = nextMode
    locationDuelsMode = loc.mode

    if nextMode ~= active then
        deactivate()
        active = nil
        duelsKey = nil
    else
        dirty = true
    end
end

starfish.events.on("hypixel:location", function(event)
    trace("location event: " .. describe(event))
    if not event.success then return end
    applyLocation(event.location)
end)

local TITLE_MODES = {
    ["BED WARS"] = "bedwars",
    ["SKYWARS"] = "skywars",
    ["SKY WARS"] = "skywars",
    ["MURDER MYSTERY"] = "murder",
    ["DUELS"] = "duels",
}

local lastTitle = nil

-- In-game sidebars have a Map: or Mode: line; lobby sidebars don't.
local function inGameByScoreboard()
    for _, text in ipairs(sidebarTexts() or {}) do
        if text:match("^Map:") or text:match("^Mode:") then return true end
    end
    return false
end

local function detectFromScoreboard()
    local title = sidebarTitle()
    if title ~= lastTitle then
        lastTitle = title
        trace("scoreboard title: " .. tostring(title) .. " inGame=" .. tostring(inGameByScoreboard()))
    end
    if not title or not inGameByScoreboard() then return nil end

    for needle, mode in pairs(TITLE_MODES) do
        if title:find(needle, 1, true) then return mode end
    end
    return nil
end

local function detectedMode()
    if locationKnown then return locationMode end
    return detectFromScoreboard()
end

-- Pre-game sidebars (Bed Wars, Duels) show Players: n/m and Waiting... or
-- Starting in.
local OBFUSCATED_PREGAME = { bedwars = true, duels = true }

local loggedSidebar = false

-- The sidebar arrives shortly after joining; wait for it, up to SIDEBAR_WAIT_MS.
local SIDEBAR_WAIT_MS = 15000
local sidebarMissingSince = nil

local function inPregameLobby()
    local texts = sidebarTexts()
    if not texts or #texts == 0 then
        local now = starfish.time.monotonic()
        sidebarMissingSince = sidebarMissingSince or now
        return now - sidebarMissingSince < SIDEBAR_WAIT_MS
    end
    sidebarMissingSince = nil
    if not loggedSidebar and #texts > 0 then
        loggedSidebar = true
        trace("sidebar at game detection: " .. table.concat(texts, " | "))
    end
    for _, text in ipairs(texts) do
        if text:match("^Players:%s*%d+%s*/%s*%d+") or text:match("^Waiting") or text:match("^Starting in") then
            return true
        end
    end
    return false
end

local function detectTickBody()
    local detected = detectedMode()

    if detected and OBFUSCATED_PREGAME[detected] then
        local pregame = inPregameLobby()
        if pregame ~= lastPregame then
            lastPregame = pregame
            trace(detected .. (pregame and ": pre-game lobby, names are obfuscated - waiting for the game to start"
                or ": game started"))
        end
        if pregame then detected = nil end
    else
        lastPregame = nil
    end

    if detected ~= active then
        deactivate()
        active = detected
        if active == "duels" then
            duelsKey = resolveDuelsKey(locationDuelsMode)
            duelsKeyLogged = false
            duelsFallbackLogged = false
        else
            duelsKey = nil
        end
        if active then
            trace("detected mode: " .. active)
            activate()
        end
    elseif active and not tabActive then
        activate()
    elseif active and tabActive and next(managed) == nil then
        trackTabList()
    end
end

local function detectTick()
    local ok, err = pcall(detectTickBody)
    if not ok then trace("tick error: " .. tostring(err)) end
end

starfish.timers.interval(1000, detectTick)

starfish.events.on("session:join", function()
    deactivate()
    active = nil
    duelsKey = nil
    locationMode = nil
    locationDuelsMode = nil
    chatOpen = false
end)

starfish.events.on("player:join", function(event)
    if not tabActive or not event.name or not event.uuid then return end
    manage(event.name, event.uuid)
end)

starfish.events.on("team:update", function()
    if tabActive then dirty = true end
end)

starfish.events.on("player:listUpdate", function(event)
    if not tabActive or event.action ~= "remove" then return end
    for _, entry in ipairs(event.players or {}) do
        local name = entry.uuid and byUuid[entry.uuid]
        if name and not shouldProtect(name) then forget(name) end
    end
end)

starfish.config.onChangeAny(function()
    syncSchemaVisibility()
    dirty = true
    if active and not getConfig(MODES[active].config, true) then
        deactivate()
    elseif active and not tabActive then
        activate()
    end
end)

plugin.onDisable = function()
    deactivate()
    unbindTab()
end

starfish.commands.register("stats", {
    description = "Show a player's stats for the mode you are in",
    arguments = {
        { name = "player", type = "string", optional = true, description = "Player name to look up" }
    }
}, function(ctx)
    local name = ctx.args and ctx.args.player
    if not name or name == "" then
        starfish.chat.error("Usage: /tabstats stats <player>")
        return
    end
    if not active then
        starfish.chat.error("Not in a Bed Wars, SkyWars, Murder Mystery or Duels game.")
        return
    end

    requestStats(name, function(st)
        if not st or statsUnavailable(st) then
            starfish.chat.error(name .. " - stats unavailable")
            return
        end
        local parts = {}
        for _, column in ipairs(columns()) do
            if not column.isName then
                table.insert(parts, "§7" .. column.header .. " " .. column.value(st))
            end
        end
        starfish.chat.info("§f" .. name .. " §8- §r" .. table.concat(parts, "  "))
    end)
end)

local restored = callPlugin("hypixel-mod-api", "getLocation")
trace("plugin loaded, restored location: " .. describe(restored))
if restored and restored.serverType then
    applyLocation(restored)
end
