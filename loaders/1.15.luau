-- Cookie Hub universal loader.
-- One client for every game Cookie Hub supports: it sends the current PlaceId to the
-- worker, which decides whether that place is supported and returns its script.
-- This uses executor HTTP/loadstring APIs. Roblox Studio LocalScripts cannot make
-- arbitrary outbound HTTP requests or execute downloaded source; use a server-side
-- bridge for an experience you own instead.
--
-- Published as an immutable loaders/<LOADER_VERSION>.luau in Cookie-Hub-Roblox/Cookie-Hub-Roblox;
-- loader.luau on each branch is a small pointer that runs a chosen version and passes
-- { channel = "production" | "staging" } (roblox-scripts/loader-pointer.luau). Run without
-- arguments, it behaves as production. Staging reads the staging branch's translations and
-- asks the worker for the place's staging menu build.
local LOADER_OPTIONS = ...
local CHANNEL = type(LOADER_OPTIONS) == "table" and LOADER_OPTIONS.channel == "staging" and "staging" or "production"
local LOADER_VERSION = "1.15"
local CLIENT_VERSION = "roblox-gui/" .. LOADER_VERSION .. (CHANNEL == "staging" and "-staging" or "")
local REQUESTED_CHANNEL = CHANNEL == "staging" and "staging" or nil
local REQUEST_ATTEMPTS = 4

assert(getgenv, "This loader needs getgenv to hand the key to the place script.")
local shared = getgenv()
local previous = shared.CookieHubLoaderState
if type(previous) == "table" and (previous.state == "starting" or previous.state == "waiting_key") then
    return -- A launch already owns initialization, including asynchronous startup.
end
local loaderState = { state = "starting" }
shared.CookieHubLoaderState = loaderState
-- Which loader this session runs, kept for the whole session (ScriptAccess is cleared once
-- the place script starts). A menu that teleports the player (99 Nights: the lobby's Start
-- now (solo), Auto Restart After Day 99) queues Url with queue_on_teleport, so the next
-- server reruns this channel's loader. Plain values only; nothing secret.
local PUBLIC_BRANCH_URL = "https://raw.githubusercontent.com/Cookie-Hub-Roblox/Cookie-Hub-Roblox/"
    .. (CHANNEL == "staging" and "staging" or "main") .. "/"
shared.CookieHubLoaderInfo = { Channel = CHANNEL, Version = LOADER_VERSION, Url = PUBLIC_BRANCH_URL .. "loader.luau" }
if type(previous) == "table" and type(previous.retire) == "function" then
    pcall(previous.retire)
end
-- Claim ownership before retiring a stale window: its exit animation can yield.
if type(shared.CookieHubLoaderWindow) == "function" then
    pcall(shared.CookieHubLoaderWindow)
end
local function releaseLoader()
    if shared.CookieHubLoaderState == loaderState then shared.CookieHubLoaderState = nil end
end

-- Catch top-level setup failures as well as the explicit request/payload failures.
local loaderOk, loaderErr = pcall(function()

-- Retry transport exceptions/empty transport responses, with bounded backoff.
-- HTTP error responses are returned normally, so rejected keys are not retried.
local function requestWithRetry(send, valid, onRetry)
    for attempt = 1, REQUEST_ATTEMPTS do
        local ok, response = pcall(send)
        if ok and valid(response) then return response end
        if attempt < REQUEST_ATTEMPTS then
            local delay = 2 ^ (attempt - 1)
            if onRetry then onRetry(attempt + 1, delay) end
            task.wait(delay)
        end
    end
    error("HTTP request failed after 4 attempts. Check your connection and try again.", 0)
end

local function validHttpResponse(response)
    return type(response) == "table" and (tonumber(response.StatusCode or response.Status or response.status_code) or 0) > 0
end

local WORKER_ORIGIN = "https://script-access-worker.script-access-worker.workers.dev"
local PLACE_ID = tostring(game.PlaceId) -- the worker picks the script for this place
local DISCORD_URL = "http://dsc.gg/cookie-hub-rblx"

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local PLAYER_ID = tostring(Players.LocalPlayer.UserId)
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local requestFn = request or http_request or (syn and syn.request)
assert(requestFn, "This loader needs an HTTP request API.")
assert(loadstring, "This loader needs loadstring enabled.")
getgenv().CookieHubDebugLog = nil -- discard the previous diagnostic build's buffer

-- ============================================================================
-- Language
-- ============================================================================
-- English is built in. Other languages are plain JSON in the public repository, on the
-- channel's branch (translations/loader/<code>.json, {"strings":{"English":"Translated"}}), keyed
-- by the English text; {1}, {2}... are values filled in at runtime. The choice is shared with
-- the game menus through cookie-hub/language.txt: "auto" (the default) follows the Roblox
-- language setting. A failed download keeps English or the last downloaded copy.
local LANGUAGES = {
    { "en", "English" }, { "ru", "\u{420}\u{443}\u{441}\u{441}\u{43A}\u{438}\u{439}" }, { "pt", "Portugu\u{EA}s" }, { "es", "Espa\u{F1}ol" },
    { "de", "Deutsch" }, { "vi", "Ti\u{1EBF}ng Vi\u{1EC7}t" }, { "id", "Bahasa Indonesia" }, { "th", "\u{E44}\u{E17}\u{E22}" },
    { "fil", "Filipino" },
}
local LANGUAGE_FILE = "cookie-hub/language.txt"
local TRANSLATION_URL = PUBLIC_BRANCH_URL .. "translations/loader/"
local supportedLanguages = {}
for _, language in ipairs(LANGUAGES) do supportedLanguages[language[1]] = language[2] end

local function readText(path)
    if type(readfile) ~= "function" or (type(isfile) == "function" and not isfile(path)) then return nil end
    local ok, value = pcall(readfile, path)
    return ok and type(value) == "string" and value or nil
end
local function writeText(path, text)
    if type(writefile) ~= "function" then return false end
    if type(makefolder) == "function" then
        pcall(makefolder, "cookie-hub")
        if string.find(path, "cookie-hub/translations/", 1, true) == 1 then pcall(makefolder, "cookie-hub/translations") end
    end
    return (pcall(writefile, path, text))
end

-- Roblox's Game Language (LocalPlayer.LocaleId) first; RobloxLocaleId is the app's own language.
local function robloxLanguage()
    local locale
    pcall(function() locale = Players.LocalPlayer.LocaleId end)
    if type(locale) ~= "string" or locale == "" then pcall(function() locale = game:GetService("LocalizationService").RobloxLocaleId end) end
    local code = type(locale) == "string" and string.match(string.lower(locale), "^%s*(%a+)") or "en"
    if code == "tl" then code = "fil" end
    return supportedLanguages[code] and code or "en"
end

-- "auto" or a language code.
local function languagePreference()
    local value = string.match(string.lower(readText(LANGUAGE_FILE) or ""), "^%s*(%a+)")
    return supportedLanguages[value] and value or "auto"
end

local translations, languageCode = nil, "en"
local function T(text, ...)
    local result = translations and translations[text] or text
    local values = table.pack(...)
    if values.n > 0 then
        result = string.gsub(result, "{(%d+)}", function(index)
            local value = values[tonumber(index)]
            return value ~= nil and tostring(value) or ""
        end)
    end
    return result
end

local function decodeTranslations(text)
    if type(text) ~= "string" or text == "" then return nil end
    local ok, data = pcall(HttpService.JSONDecode, HttpService, text)
    local strings = ok and type(data) == "table" and type(data.strings) == "table" and data.strings or nil
    if not strings then return nil end
    local clean = {}
    for source, translated in pairs(strings) do
        if type(source) == "string" and type(translated) == "string" and translated ~= "" then clean[source] = translated end
    end
    return clean
end

-- Switch language. The cached copy applies at once and the download replaces it if newer;
-- the window redraws through languageChanged. Returns a handle whose `done` turns true
-- when the download ends.
local languageRequest, languageChanged = 0, nil
local function onChange()
    if languageChanged then pcall(languageChanged) end
end
local function useLanguage(code)
    languageRequest += 1
    local token, handle = languageRequest, { code = code, done = false }
    local cachePath = "cookie-hub/translations/loader-" .. (CHANNEL == "staging" and "staging-" or "") .. code .. ".json"
    if code == "en" then
        translations, languageCode = nil, "en"
        handle.done, handle.ok = true, true
        onChange()
        return handle
    end
    local cachedText = readText(cachePath)
    local cached = decodeTranslations(cachedText)
    translations, languageCode = cached, cached and code or "en"
    handle.cached = cached ~= nil
    onChange()
    task.spawn(function()
        local ok, response = pcall(requestFn, { Url = TRANSLATION_URL .. code .. ".json", Method = "GET" })
        local status = ok and type(response) == "table" and tonumber(response.StatusCode or response.Status or response.status_code) or 0
        local body = status == 200 and (response.Body or response.body) or nil
        local fresh = decodeTranslations(body)
        if token == languageRequest and fresh then
            handle.ok = true
            if body ~= cachedText then
                writeText(cachePath, body)
                translations, languageCode = fresh, code
                onChange()
            end
        end
        handle.done = true
    end)
    return handle
end

local languageStarted = os.clock()
local function preferredLanguage()
    local preference = languagePreference()
    return preference == "auto" and robloxLanguage() or preference
end
local languageLoad = useLanguage(preferredLanguage())
-- A first download gets up to 3 s (it runs alongside the server check) before text is shown.
local function waitForLanguage()
    while not languageLoad.done and not languageLoad.cached and os.clock() - languageStarted < 3 do task.wait(0.05) end
end

local function installationId()
    -- Keep this stable if your executor exposes a persistent identifier. This sample
    -- intentionally does not claim that Roblox client values are hardware identity.
    return getgenv().ScriptAccessInstallationId or ("roblox-" .. Players.LocalPlayer.UserId)
end

local post
local reportedFailures = {}
local analyticsQueues = {}
local analyticsStopped = {}
local function analyticsAvailable(analytics)
    return type(analytics) == "table" and type(analytics.session_id) == "string" and type(analytics.session_token) == "string" and not analyticsStopped[analytics.session_id]
end
local function reportEvent(analytics, event, text, fields)
    if not analyticsAvailable(analytics) then return end
    local queue = analyticsQueues[analytics.session_id]
    if not queue then
        queue = { events = {}, running = false }
        analyticsQueues[analytics.session_id] = queue
    end
    -- Keep terminal lifecycle events even if a slow connection accumulates
    -- heartbeats. The queue holds at most 32 pending events plus one in flight.
    if #queue.events >= 32 then
        if event == "heartbeat" then return end
        local removeIndex = 1
        for index, pendingEvent in ipairs(queue.events) do
            if pendingEvent.event == "heartbeat" then removeIndex = index; break end
        end
        table.remove(queue.events, removeIndex)
    end
    local item = { id = HttpService:GenerateGUID(false), event = event, text = text }
    if type(fields) == "table" then
        for key, value in pairs(fields) do item[key] = value end
    end
    table.insert(queue.events, item)
    if queue.running then return end
    queue.running = true
    -- One background worker preserves success -> heartbeat -> unload order,
    -- including when a reload happens before the success request completes.
    task.spawn(function()
        while #queue.events > 0 do
            local pendingEvent = table.remove(queue.events, 1)
            local ok, status = pcall(post, "/v1/analytics/events", {
                session_id = analytics.session_id,
                session_token = analytics.session_token,
                events = { pendingEvent },
            })
            -- Expired or revoked telemetry credentials must not send recurring
            -- requests for the rest of an otherwise healthy game session.
            if ok and (status == 401 or status == 403) then
                analyticsStopped[analytics.session_id] = true
                table.clear(queue.events)
                break
            end
        end
        queue.running = false
        analyticsQueues[analytics.session_id] = nil
    end)
end
local function reportLoadFailure(analytics, reason)
    if type(analytics) ~= "table" or type(analytics.session_id) ~= "string" or type(analytics.session_token) ~= "string" then return end
    if reportedFailures[analytics.session_id] then return end
    reportedFailures[analytics.session_id] = true
    reportEvent(analytics, "load_failed", reason)
end

-- The player's avatar, fetched once per launch in the background and shared by the start
-- report and the profile event. A failed or slow fetch only leaves torso and hair out.
local avatarDone, avatarDescription = false, nil
task.spawn(function()
    pcall(function() avatarDescription = Players:GetHumanoidDescriptionFromUserId(Players.LocalPlayer.UserId) end)
    avatarDone = true
end)

-- Account age (days), avatar torso asset ID and hair accessory asset IDs ("id,id").
-- Waits at most `waitSeconds` for the avatar.
local function profileFields(waitSeconds)
    local fields = {}
    pcall(function()
        local age = Players.LocalPlayer.AccountAge
        if type(age) == "number" and age >= 0 and age < 100000 then fields.account_age = math.floor(age) end
    end)
    local deadline = os.clock() + waitSeconds
    while not avatarDone and os.clock() < deadline do task.wait(0.1) end
    local description = avatarDescription
    pcall(function()
        local torso = description and description.Torso
        if type(torso) == "number" and torso >= 0 and torso < 1e15 then fields.torso_id = math.floor(torso) end
    end)
    pcall(function()
        local hair = description and description.HairAccessory
        if type(hair) == "string" and #hair <= 200 then fields.hair_ids = hair end
    end)
    return fields
end

-- Report the player's account age and avatar torso once per launch.
-- Best effort and off the startup path: a failure here costs only these values.
local function reportProfile(analytics)
    if not analyticsAvailable(analytics) then return end
    local fields = profileFields(10)
    fields.hair_ids = nil
    if next(fields) ~= nil then reportEvent(analytics, "profile", nil, fields) end
end

-- Observe asynchronous payload startup without polling or blocking the loader.
-- Keep state in a backing table so every assignment (including ready -> unloaded)
-- reaches the observer, rather than only the first write to a Lua table field.
local function startupTracker(analytics)
    task.spawn(reportProfile, analytics)
    local values = { state = "starting" }
    local observer, failureReported, successReported, unloadReported, retired
    local function retire()
        retired = true
        if successReported and not unloadReported and values.analyticsManaged ~= true then
            unloadReported = true
            reportEvent(analytics, "unload")
        end
    end
    loaderState.retire = retire
    local function heartbeat()
        if retired or values.state ~= "ready" or values.analyticsManaged == true or shared.CookieHubLoaderState ~= loaderState or not analyticsAvailable(analytics) then return end
        reportEvent(analytics, "heartbeat")
        task.delay(60, heartbeat)
    end
    local function changed()
        if values.state == "failed" then
            releaseLoader()
            if not failureReported then
                failureReported = true
                reportLoadFailure(analytics, "initialization_failed")
            end
        elseif values.state == "unloaded" then
            retire()
            releaseLoader()
        elseif values.state == "ready" and shared.CookieHubLoaderState == loaderState then
            loaderState.state = "ready"
            -- New payloads own their telemetry; older places still get CCU and
            -- successful-run counts through this loader lifecycle fallback.
            if not successReported and values.analyticsManaged ~= true and analyticsAvailable(analytics) then
                successReported = true
                reportEvent(analytics, "load_success")
                task.delay(60, heartbeat)
            end
        end
        if observer then observer(values.state, values.reason) end
    end
    local state = setmetatable({}, {
        __index = values,
        __newindex = function(_, key, value)
            values[key] = value
            if key == "state" then changed() end
        end,
    })
    return state, function(callback) observer = callback; changed() end
end

post = function(path, payload, onRetry)
    local encoded = HttpService:JSONEncode(payload)
    local requestId = "loader-" .. HttpService:GenerateGUID(false)
    local response = requestWithRetry(function() return requestFn({
        Url = WORKER_ORIGIN .. path,
        Method = "POST",
        Headers = { ["Content-Type"] = "application/json", ["X-Request-ID"] = requestId },
        -- Executors are inconsistent: Synapse-style APIs use Body, while some
        -- request shims only inspect lowercase body. Supplying both is harmless.
        Body = encoded,
        body = encoded,
    }) end, validHttpResponse, onRetry)
    local statusCode = tonumber(response.StatusCode or response.Status or response.status_code) or 0
    local raw = response.Body or response.body or ""
    local decoded, body = pcall(HttpService.JSONDecode, HttpService, raw)
    if not decoded or type(body) ~= "table" then
        return statusCode, { error = "The service returned an unreadable response." }, raw
    end
    return statusCode, body, raw
end

-- Report once when this loader starts, without delaying the GUI or key checks. This is
-- one execution on the dashboard's Players tab, with the player's names, Premium status,
-- executor, account age and avatar torso/hair.
task.spawn(function()
    local start = { place_id = PLACE_ID, player_id = PLAYER_ID, client_version = CLIENT_VERSION }
    pcall(function()
        local player = Players.LocalPlayer
        start.username = player.Name
        start.display_name = player.DisplayName
        start.premium = player.MembershipType == Enum.MembershipType.Premium
    end)
    pcall(function()
        if type(identifyexecutor) == "function" then
            local name = identifyexecutor()
            if type(name) == "string" then start.executor = name end
        end
    end)
    for key, value in pairs(profileFields(5)) do start[key] = value end
    pcall(post, "/v1/client/start", start)
end)

-- ============================================================================
-- Look & feel
-- ============================================================================
-- Ask the server before constructing any key UI. Only the server's current
-- per-place policy can grant keyless access; a local flag cannot unlock a game.
local probeOk, probeCode, probe = pcall(post, "/v1/scripts/load/" .. HttpService:UrlEncode(PLACE_ID), {
    place_id = PLACE_ID,
    player_id = PLAYER_ID,
    client_version = CLIENT_VERSION,
    build_channel = REQUESTED_CHANNEL,
})
if not probeOk then error(tostring(probeCode), 0) end
if probeCode == 404 and probe.reason == "unsupported_place" then
    waitForLanguage()
    local function create(class, props)
        local object = Instance.new(class)
        local parent = props.Parent
        for key, value in pairs(props) do
            if key ~= "Parent" then object[key] = value end
        end
        object.Parent = parent
        return object
    end
    local screen = create("ScreenGui", {
        Name = "CookieHubUnsupportedGame", ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
    })
    local card = create("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.new(1, -32, 0, 238), BackgroundColor3 = Color3.fromRGB(22, 24, 36),
        BorderSizePixel = 0, Parent = screen,
    })
    create("UISizeConstraint", { MaxSize = Vector2.new(420, 238), Parent = card })
    create("UICorner", { CornerRadius = UDim.new(0, 16), Parent = card })
    create("TextLabel", {
        Position = UDim2.fromOffset(22, 20), Size = UDim2.new(1, -44, 0, 20),
        BackgroundTransparency = 1, Text = "COOKIE HUB", Font = Enum.Font.GothamBold,
        TextSize = 13, TextColor3 = Color3.fromRGB(240, 160, 60), Parent = card,
    })
    create("TextLabel", {
        Position = UDim2.fromOffset(22, 52), Size = UDim2.new(1, -44, 0, 30),
        BackgroundTransparency = 1, Text = T("Unsupported game"), Font = Enum.Font.GothamBold,
        TextSize = 22, TextColor3 = Color3.fromRGB(240, 242, 250), Parent = card,
    })
    create("TextLabel", {
        Position = UDim2.fromOffset(22, 92), Size = UDim2.new(1, -44, 0, 76),
        BackgroundTransparency = 1, TextWrapped = true, Font = Enum.Font.Gotham,
        Text = T("Cookie Hub has no published script for this game yet.") .. "\n" .. T("Place ID: {1}", PLACE_ID),
        TextSize = 15, TextColor3 = Color3.fromRGB(137, 145, 172), Parent = card,
    })
    local dismiss = create("TextButton", {
        Position = UDim2.fromOffset(22, 182), Size = UDim2.new(1, -44, 0, 36),
        BackgroundColor3 = Color3.fromRGB(240, 160, 60), Text = T("Got it"),
        Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = Color3.fromRGB(38, 24, 6), Parent = card,
    })
    create("UICorner", { CornerRadius = UDim.new(0, 8), Parent = dismiss })
    local function closeNotice()
        screen:Destroy()
        if shared.CookieHubLoaderWindow == closeNotice then shared.CookieHubLoaderWindow = nil end
    end
    shared.CookieHubLoaderWindow = closeNotice
    dismiss.MouseButton1Click:Connect(closeNotice)
    releaseLoader()
    return
end
if probeCode == 200 and probe.authorized == true and probe.keyless == true and type(probe.source) == "string" then
    local compiled, payload, compileErr = pcall(loadstring, probe.source, "=CookieHub/Place/" .. PLACE_ID)
    if not compiled or type(payload) ~= "function" then
        reportLoadFailure(probe.analytics, "compile_failed")
        error("Downloaded script could not compile: " .. tostring(compiled and compileErr or payload), 0)
    end
    local startupState = startupTracker(probe.analytics)
    -- A non-secret label supports existing payloads that require a nonempty Key.
    -- Their /v1/validate recheck still uses the server's actual keyless setting.
    getgenv().ScriptAccess = { Key = "keyless", Keyless = true, Fingerprint = installationId(), PlayerId = PLAYER_ID, BuildChannel = probe.build_channel or "production", StartupState = startupState, Analytics = probe.analytics }
    local ran, runErr = pcall(payload)
    getgenv().ScriptAccess = nil
    if not ran then
        reportLoadFailure(probe.analytics, "runtime_failed")
        error("Script failed: " .. tostring(runErr), 0)
    end
    if startupState.state == "failed" then error(startupState.reason or "Place script stopped during initialization.", 0) end
    return
end
if probeCode ~= 403 or probe.reason ~= "key_required" then
    error(tostring(probe.error or probe.reason or "Script was unavailable."), 0)
end
loaderState.state = "waiting_key"

-- Executor workspace storage, scoped to this Roblox account and place. A saved
-- key still goes through the server's normal verification on every launch.
local KEY_FOLDER = "cookie-hub"
local KEY_FILE = KEY_FOLDER .. "/key-" .. tostring(Players.LocalPlayer.UserId) .. "-" .. PLACE_ID .. ".txt"
local function readSavedKey()
    if type(readfile) ~= "function" then return nil end
    local ok, value = pcall(readfile, KEY_FILE)
    if not ok or type(value) ~= "string" then return nil end
    local key = value:match("^%s*(.-)%s*$")
    return key ~= "" and key or nil
end

local savedKey = readSavedKey()

local function saveKey(key)
    if type(writefile) ~= "function" then return false end
    -- Existing folders may make makefolder throw; the write determines success.
    if type(makefolder) == "function" then pcall(makefolder, KEY_FOLDER) end
    local ok = pcall(writefile, KEY_FILE, key)
    if ok then savedKey = key end
    return ok
end

local function clearSavedKey(key)
    if key ~= savedKey then return end
    savedKey = nil
    if type(delfile) == "function" and pcall(delfile, KEY_FILE) then return end
    -- Some executors expose writefile without delfile. An empty file is ignored.
    if type(writefile) == "function" then pcall(writefile, KEY_FILE, "") end
end

local InvalidKeyReasons = {
    key_not_found = true,
    key_revoked = true,
    key_expired = true,
    fingerprint_mismatch = true,
    fingerprint_already_claimed = true,
}

-- Readable text for the key check's reason codes.
local ReasonText = {
    key_not_found = "That key was not found. Check it or get a new key.",
    key_revoked = "That key was revoked. Get a new key.",
    key_expired = "That key has expired. Get a new key.",
    fingerprint_mismatch = "That key is linked to another Roblox account.",
    fingerprint_already_claimed = "That key is linked to another Roblox account.",
    rate_limited = "Please wait before retrying.",
}

local Theme = {
    Card = Color3.fromRGB(22, 24, 36),
    CardDark = Color3.fromRGB(15, 16, 25),
    Field = Color3.fromRGB(12, 14, 22),
    Button = Color3.fromRGB(31, 35, 52),
    ButtonHover = Color3.fromRGB(42, 47, 69),
    Stroke = Color3.fromRGB(52, 57, 80),
    Accent = Color3.fromRGB(240, 160, 60),
    AccentHover = Color3.fromRGB(252, 182, 96),
    AccentText = Color3.fromRGB(38, 24, 6),
    Text = Color3.fromRGB(240, 242, 250),
    Muted = Color3.fromRGB(137, 145, 172),
    Success = Color3.fromRGB(74, 222, 128),
    Error = Color3.fromRGB(248, 113, 113),
}

local function create(class, props, children)
    local object = Instance.new(class)
    local parent
    for key, value in pairs(props) do
        if key == "Parent" then
            parent = value
        else
            object[key] = value
        end
    end
    for _, child in ipairs(children or {}) do
        child.Parent = object
    end
    object.Parent = parent
    return object
end

-- Text drawn in the current language; redrawn when it changes.
local localized = {}
-- Thai glyphs render small next to Latin text at the same size: labels showing Thai are 1.3x.
local THAI_TEXT_SCALE = 1.3
local baseTextSizes = {}
local function fitThai(object)
    local base = baseTextSizes[object] or object.TextSize
    baseTextSizes[object] = base
    local size = string.find(object.Text, "\224[\184\185]") and math.floor(base * THAI_TEXT_SCALE + 0.5) or base
    if object.TextSize ~= size then object.TextSize = size end
end
local function localize(object, render, property)
    localized[object] = { render, property or "Text" }
    object[property or "Text"] = render()
    if (property or "Text") == "Text" then fitThai(object) end
end
local function setText(object, text, ...)
    local values = table.pack(...)
    localize(object, function() return T(text, table.unpack(values, 1, values.n)) end)
end

local function corner(radius)
    return create("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function stroke(color, transparency)
    return create("UIStroke", {
        Color = color,
        Thickness = 1,
        Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    })
end

local function tween(object, seconds, goal)
    TweenService:Create(object, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal):Play()
end

local busy = false -- true while a verification is in flight

local function hoverable(button, normal, hover, enabled)
    button.MouseEnter:Connect(function()
        if not enabled or enabled() then tween(button, 0.12, { BackgroundColor3 = hover }) end
    end)
    button.MouseLeave:Connect(function()
        if not enabled or enabled() then tween(button, 0.12, { BackgroundColor3 = normal }) end
    end)
end

-- ============================================================================
-- Window
-- ============================================================================
local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
waitForLanguage()

local screen = create("ScreenGui", {
    Name = "ScriptAccess",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    Parent = playerGui,
})

local scale = create("UIScale", { Scale = 0.94 })

local card = create("CanvasGroup", {
    Name = "Card",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(420, 326),
    BackgroundColor3 = Theme.Card,
    GroupTransparency = 1,
    Parent = screen,
}, {
    corner(16),
    stroke(Theme.Stroke, 0.25),
    scale,
})

-- Background gradient lives on its own frame: a UIGradient placed directly on the
-- CanvasGroup would multiply the colour of every child (text, buttons, icons) too.
create("Frame", {
    Name = "Background",
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BorderSizePixel = 0,
    ZIndex = 0,
    Parent = card,
}, {
    create("UIGradient", {
        Rotation = 90,
        Color = ColorSequence.new(Theme.Card, Theme.CardDark),
    }),
})

-- Header (also the drag handle)
local header = create("Frame", {
    Name = "Header",
    Size = UDim2.new(1, 0, 0, 78),
    BackgroundTransparency = 1,
    Active = true,
    Parent = card,
})

create("Frame", {
    Name = "Badge",
    Position = UDim2.fromOffset(20, 17),
    Size = UDim2.fromOffset(46, 46),
    BackgroundColor3 = Theme.Accent,
    BackgroundTransparency = 0.82,
    Parent = header,
}, {
    corner(12),
    stroke(Theme.Accent, 0.6),
    create("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = "\u{1F36A}",
        TextSize = 26,
        Font = Enum.Font.GothamBold,
        TextColor3 = Theme.Text,
    }),
})

create("TextLabel", {
    Position = UDim2.fromOffset(78, 17),
    Size = UDim2.new(1, -190, 0, 26),
    BackgroundTransparency = 1,
    Text = CHANNEL == "staging" and "Cookie Hub (Staging)" or "Cookie Hub",
    TextColor3 = Theme.Text,
    Font = Enum.Font.GothamBold,
    TextSize = 21,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = header,
})

local subtitle = create("TextLabel", {
    Position = UDim2.fromOffset(78, 43),
    Size = UDim2.new(1, -190, 0, 18),
    BackgroundTransparency = 1,
    Text = "",
    TextColor3 = Theme.Muted,
    Font = Enum.Font.Gotham,
    TextSize = 13,
    TextTruncate = Enum.TextTruncate.AtEnd,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = header,
})
setText(subtitle, "Place {1}", PLACE_ID)

-- Show the name of the game we are in (falls back to the place id if the lookup fails)
task.spawn(function()
    local ok, info = pcall(function()
        return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
    end)
    if ok and type(info) == "table" and type(info.Name) == "string" and info.Name ~= "" and subtitle.Parent then
        localized[subtitle] = nil
        subtitle.Text = info.Name
    end
end)

local closeButton = create("TextButton", {
    Name = "Close",
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -16, 0, 20),
    Size = UDim2.fromOffset(28, 28),
    BackgroundColor3 = Theme.Button,
    BackgroundTransparency = 1,
    AutoButtonColor = false,
    Text = "X",
    TextColor3 = Theme.Muted,
    Font = Enum.Font.GothamBold,
    TextSize = 14,
    Parent = header,
}, { corner(8) })

closeButton.MouseEnter:Connect(function()
    tween(closeButton, 0.12, { BackgroundTransparency = 0, TextColor3 = Theme.Error })
end)
closeButton.MouseLeave:Connect(function()
    tween(closeButton, 0.12, { BackgroundTransparency = 1, TextColor3 = Theme.Muted })
end)

-- Language picker: "Same as Roblox" (default) or a language, shared with the game menus.
local languageButton = create("TextButton", {
    Name = "Language",
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -50, 0, 20),
    Size = UDim2.fromOffset(60, 28),
    BackgroundColor3 = Theme.Button,
    BackgroundTransparency = 1,
    AutoButtonColor = false,
    Text = "",
    TextColor3 = Theme.Muted,
    Font = Enum.Font.GothamBold,
    TextSize = 12,
    Parent = header,
}, { corner(8) })
localize(languageButton, function() return "\u{1F310} " .. string.upper(languageCode) end)
languageButton.MouseEnter:Connect(function()
    tween(languageButton, 0.12, { BackgroundTransparency = 0, TextColor3 = Theme.Text })
end)
languageButton.MouseLeave:Connect(function()
    tween(languageButton, 0.12, { BackgroundTransparency = 1, TextColor3 = Theme.Muted })
end)

local languageMenu = create("Frame", {
    Name = "Languages",
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -16, 0, 52),
    Size = UDim2.fromOffset(200, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundColor3 = Theme.CardDark,
    Visible = false,
    ZIndex = 20,
    Parent = card,
}, {
    corner(10),
    stroke(Theme.Stroke, 0.1),
    create("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }),
    create("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }),
})
local languageChoices = { { "auto" } }
for _, language in ipairs(LANGUAGES) do table.insert(languageChoices, language) end
local chooseLanguage
for order, choice in ipairs(languageChoices) do
    local item = create("TextButton", {
        LayoutOrder = order,
        Size = UDim2.new(1, 0, 0, 24),
        BackgroundColor3 = Theme.ButtonHover,
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = "",
        TextColor3 = Theme.Text,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 21,
        Parent = languageMenu,
    }, { corner(6), create("UIPadding", { PaddingLeft = UDim.new(0, 8) }) })
    localize(item, function()
        local mark = languagePreference() == choice[1] and "\u{2713}  " or "     "
        -- "Same as Roblox (Espanol)", spelled in that language: the detected Game Language in its own name.
        return mark .. (choice[2] or T("Same as Roblox") .. " (" .. supportedLanguages[robloxLanguage()] .. ")")
    end)
    item.MouseEnter:Connect(function() item.BackgroundTransparency = 0 end)
    item.MouseLeave:Connect(function() item.BackgroundTransparency = 1 end)
    item.MouseButton1Click:Connect(function() chooseLanguage(choice[1]) end)
end
languageButton.MouseButton1Click:Connect(function()
    languageMenu.Visible = not languageMenu.Visible
end)

create("Frame", {
    Position = UDim2.fromOffset(20, 78),
    Size = UDim2.new(1, -40, 0, 1),
    BackgroundColor3 = Theme.Stroke,
    BackgroundTransparency = 0.4,
    BorderSizePixel = 0,
    Parent = card,
})

-- Key field
local keyHeading = create("TextLabel", {
    Position = UDim2.fromOffset(22, 96),
    Size = UDim2.new(1, -44, 0, 14),
    BackgroundTransparency = 1,
    Text = "",
    TextColor3 = Theme.Muted,
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = card,
})
setText(keyHeading, "ACCESS KEY")

local keyStroke = stroke(Theme.Stroke, 0.2)
local keyBox = create("TextBox", {
    Name = "Key",
    Position = UDim2.fromOffset(20, 116),
    Size = UDim2.new(1, -40, 0, 44),
    BackgroundColor3 = Theme.Field,
    PlaceholderText = "",
    PlaceholderColor3 = Color3.fromRGB(92, 100, 128),
    Text = savedKey or "",
    TextColor3 = Theme.Text,
    Font = Enum.Font.GothamMedium,
    TextSize = 14,
    TextXAlignment = Enum.TextXAlignment.Left,
    ClearTextOnFocus = false,
    Parent = card,
}, {
    corner(10),
    keyStroke,
    create("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }),
})

localize(keyBox, function() return T("Paste your access key") end, "PlaceholderText")

keyBox.Focused:Connect(function()
    tween(keyStroke, 0.15, { Color = Theme.Accent })
end)

-- Buttons
local function makeButton(text, position, size, background, textColor)
    return create("TextButton", {
        Position = position,
        Size = size,
        BackgroundColor3 = background,
        AutoButtonColor = false,
        Text = text,
        TextColor3 = textColor,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        Parent = card,
    }, { corner(10) })
end

local getKey = makeButton("", UDim2.fromOffset(20, 174), UDim2.fromOffset(122, 44), Theme.Button, Theme.Text)
setText(getKey, "Get key")
create("UIStroke", { Color = Theme.Stroke, Thickness = 1, Transparency = 0.25, Parent = getKey })
hoverable(getKey, Theme.Button, Theme.ButtonHover)

local verify = makeButton("", UDim2.fromOffset(154, 174), UDim2.new(1, -174, 0, 44), Theme.Accent, Theme.AccentText)
setText(verify, "Verify & load")
hoverable(verify, Theme.Accent, Theme.AccentHover, function() return not busy end)

-- Status line
local statusDot = create("Frame", {
    Position = UDim2.fromOffset(22, 245),
    Size = UDim2.fromOffset(8, 8),
    BackgroundColor3 = Theme.Muted,
    BorderSizePixel = 0,
    Parent = card,
}, { corner(4) })

local statusLabel = create("TextLabel", {
    Position = UDim2.fromOffset(38, 234),
    Size = UDim2.new(1, -60, 0, 32),
    BackgroundTransparency = 1,
    Text = "",
    TextColor3 = Theme.Muted,
    Font = Enum.Font.Gotham,
    TextSize = 13,
    TextWrapped = true,
    TextTruncate = Enum.TextTruncate.AtEnd,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Center,
    Parent = card,
})

languageChanged = function()
    for object, entry in pairs(localized) do
        if object.Parent then
            object[entry[2]] = entry[1]()
            if entry[2] == "Text" then fitThai(object) end
        end
    end
end

local StatusColors = {
    info = Theme.Muted,
    working = Theme.Accent,
    ok = Theme.Success,
    error = Theme.Error,
}

-- `text` is English with {1}, {2}... for the values that follow `kind`; server messages
-- without a translation show as sent.
local function setStatus(text, kind, ...)
    local color = StatusColors[kind or "info"]
    setText(statusLabel, text, ...)
    statusLabel.TextColor3 = (kind == "info" or kind == nil) and Theme.Muted or color
    tween(statusDot, 0.15, { BackgroundColor3 = color })
end
setStatus("Enter your key to continue.", "info")

chooseLanguage = function(preference)
    languageMenu.Visible = false
    writeText(LANGUAGE_FILE, preference)
    local code = preference == "auto" and robloxLanguage() or preference
    local handle = useLanguage(code)
    task.spawn(function()
        while not handle.done do task.wait(0.1) end
        if screen.Parent and code ~= "en" and not handle.ok and not handle.cached then
            setStatus("Could not download the {1} translation. Showing English for now.", "error", supportedLanguages[code])
        end
    end)
end

-- Footer: Discord invite (click to copy)
create("Frame", {
    Position = UDim2.fromOffset(20, 276),
    Size = UDim2.new(1, -40, 0, 1),
    BackgroundColor3 = Theme.Stroke,
    BackgroundTransparency = 0.4,
    BorderSizePixel = 0,
    Parent = card,
})

local discordButton = create("TextButton", {
    Name = "Discord",
    Position = UDim2.fromOffset(20, 284),
    Size = UDim2.new(1, -40, 0, 30),
    BackgroundColor3 = Theme.Button,
    BackgroundTransparency = 1,
    AutoButtonColor = false,
    Text = "",
    TextColor3 = Theme.Muted,
    Font = Enum.Font.GothamMedium,
    TextSize = 12,
    Parent = card,
}, { corner(8) })

localize(discordButton, function() return "\u{1F4AC}  " .. T("Join our Discord") .. "  \u{B7}  dsc.gg/cookie-hub-rblx" end)

discordButton.MouseEnter:Connect(function()
    tween(discordButton, 0.12, { BackgroundTransparency = 0, TextColor3 = Theme.Text })
end)
discordButton.MouseLeave:Connect(function()
    tween(discordButton, 0.12, { BackgroundTransparency = 1, TextColor3 = Theme.Muted })
end)

-- ============================================================================
-- Behaviour
-- ============================================================================
local connections = {}

local function closeWindow(preserveStartup)
    if not preserveStartup then
        loaderState.cancelled = true
        releaseLoader()
    end
    if shared.CookieHubLoaderWindow == closeWindow then shared.CookieHubLoaderWindow = nil end
    languageChanged = nil
    if not screen.Parent then return end
    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end
    table.clear(connections)
    tween(card, 0.18, { GroupTransparency = 1 })
    tween(scale, 0.18, { Scale = 0.94 })
    task.wait(0.2)
    screen:Destroy()
end

shared.CookieHubLoaderWindow = closeWindow
closeButton.MouseButton1Click:Connect(function() closeWindow() end)

-- Drag the card by its header (mouse and touch)
do
    local dragging, dragStart, startPosition = false, nil, nil

    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPosition = card.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    table.insert(connections, UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            card.Position = UDim2.new(
                startPosition.X.Scale, startPosition.X.Offset + delta.X,
                startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
        end
    end))
end

discordButton.MouseButton1Click:Connect(function()
    if setclipboard and pcall(setclipboard, DISCORD_URL) then
        setStatus("Discord invite copied. Paste it into your browser to join.", "ok")
    else
        setStatus("Clipboard unavailable. Join here: {1}", "info", DISCORD_URL)
    end
end)

getKey.MouseButton1Click:Connect(function()
    local target = WORKER_ORIGIN .. "/games/" .. HttpService:UrlEncode(PLACE_ID)
    if setclipboard and pcall(setclipboard, target) then
        setStatus("Key link copied. Open it in your browser to get your key.", "ok")
    else
        setStatus("Clipboard unavailable. Open this link: {1}", "info", target)
    end
end)

local function setBusy(state)
    busy = state
    if not state then releaseLoader() end
    setText(verify, state and "Checking\u{2026}" or "Verify & load")
    tween(verify, 0.12, { BackgroundColor3 = state and Theme.ButtonHover or Theme.Accent })
    verify.TextColor3 = state and Theme.Muted or Theme.AccentText
end

local function verifyAndLoad()
    if busy or not screen.Parent then return end
    local active = shared.CookieHubLoaderState
    if active and active ~= loaderState and (active.state == "starting" or active.state == "waiting_key") then return end

    local key = keyBox.Text:match("^%s*(.-)%s*$")
    if key == "" then
        setStatus("Enter your access key first.", "error")
        return
    end

    shared.CookieHubLoaderState = loaderState
    loaderState.state = "starting"
    loaderState.cancelled = false
    setBusy(true)
    setStatus("Checking key\u{2026}", "working")

    local ok, code, tokenResult = pcall(post, "/v1/token", {
        key = key,
        fingerprint = installationId(),
        place_id = PLACE_ID,
        player_id = PLAYER_ID,
        client_version = CLIENT_VERSION,
    }, function(attempt)
        setStatus("Connection interrupted. Retrying verification ({1}/4)\u{2026}", "working", attempt)
    end)
    if loaderState.cancelled or not screen.Parent then return end
    if not ok or type(tokenResult) ~= "table" or code ~= 200 or not tokenResult.authorized or type(tokenResult.token) ~= "string" then
        if ok and code == 403 and type(tokenResult) == "table" and InvalidKeyReasons[tokenResult.reason] then
            clearSavedKey(key)
            if keyBox.Text:match("^%s*(.-)%s*$") == key then keyBox.Text = "" end
        end
        local reason = type(tokenResult) == "table" and (ReasonText[tokenResult.reason] or tokenResult.error or tokenResult.reason) or nil
        setStatus(tostring(reason or (ok and "Key was not accepted.") or code), "error")
        setBusy(false)
        return
    end

    -- Save only after acceptance, even if the subsequent script download fails.
    local saved = saveKey(key)
    setStatus(saved and "Key accepted. Downloading script\u{2026}" or "Key accepted. Saving unavailable; downloading\u{2026}", "working")

    -- Send the short-lived token in JSON: this executor drops Body when Authorization is set.
    local loadedRequest, loadCode, result = pcall(post, "/v1/scripts/load/" .. HttpService:UrlEncode(PLACE_ID), { token = tokenResult.token, player_id = PLAYER_ID, client_version = CLIENT_VERSION, build_channel = REQUESTED_CHANNEL }, function(attempt)
        setStatus("Connection interrupted. Retrying script download ({1}/4)\u{2026}", "working", attempt)
    end)
    if loaderState.cancelled or not screen.Parent then return end
    if not loadedRequest or type(result) ~= "table" or loadCode ~= 200 or not result.authorized or type(result.source) ~= "string" then
        local reason = loadedRequest and type(result) == "table" and (result.error or result.reason or "Script was unavailable.") or tostring(loadCode)
        setStatus(tostring(reason), "error")
        setBusy(false)
        return
    end

    local compiled, payload, compileErr = pcall(loadstring, result.source, "=CookieHub/Place/" .. PLACE_ID)
    if not compiled or type(payload) ~= "function" then
        reportLoadFailure(result.analytics, "compile_failed")
        setStatus("Downloaded script could not compile: {1}", "error", tostring(compiled and compileErr or payload))
        setBusy(false)
        return
    end

    setStatus("Verified. Loading Cookie Hub\u{2026}", "ok")

    -- One-time handoff: the payload reads and clears this immediately, then
    -- re-validates the key itself. We clear it again afterwards in case it never ran.
    local startupState, observeStartup = startupTracker(result.analytics)
    getgenv().ScriptAccess = { Key = key, Fingerprint = installationId(), PlayerId = PLAYER_ID, BuildChannel = result.build_channel or "production", StartupState = startupState, Analytics = result.analytics }
    local ran, runErr = pcall(payload)
    getgenv().ScriptAccess = nil

    if not ran then
        reportLoadFailure(result.analytics, "runtime_failed")
        setStatus("Script failed: {1}", "error", tostring(runErr))
        setBusy(false)
        return
    end

    observeStartup(function(state, reason)
        if loaderState.cancelled or not screen.Parent then return end
        if state == "failed" or state == "unloaded" then
            setStatus(reason or "Place script stopped during initialization.", "error")
            setBusy(false)
        elseif state == "ready" then
            closeWindow(true)
        end
    end)
end

local function tryVerifyAndLoad()
    local ok, failure = pcall(verifyAndLoad)
    if not ok then
        shared.ScriptAccess = nil
        releaseLoader()
        if screen.Parent then
            setStatus("Loader failed: {1}", "error", tostring(failure))
            setBusy(false)
        end
    end
end

verify.MouseButton1Click:Connect(tryVerifyAndLoad)
keyBox.FocusLost:Connect(function(enterPressed)
    tween(keyStroke, 0.15, { Color = Theme.Stroke })
    if enterPressed then
        tryVerifyAndLoad()
    end
end)

-- Intro animation
tween(card, 0.25, { GroupTransparency = 0 })
tween(scale, 0.25, { Scale = 1 })

if savedKey then
    setStatus("Checking saved key\u{2026}", "working")
    task.spawn(tryVerifyAndLoad)
elseif type(readfile) ~= "function" or type(writefile) ~= "function" then
    setStatus("Enter your key. This executor cannot save keys between sessions.", "info")
end
end)
if not loaderOk then
    releaseLoader()
    shared.ScriptAccess = nil
    error(loaderErr, 0)
end
