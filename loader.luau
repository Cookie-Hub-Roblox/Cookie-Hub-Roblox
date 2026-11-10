-- Cookie Hub loader. This file only picks which loader version runs: the loader itself is
-- loaders/<VERSION>.luau next to this file, and a published version never changes.
-- scripts/public-repo.mjs writes the line below for each branch (main = production,
-- staging = staging); keep it the only line that differs between them.
local VERSION, CHANNEL, BRANCH = "1.16", "production", "main"

local url = "https://raw.githubusercontent.com/Cookie-Hub-Roblox/Cookie-Hub-Roblox/" .. BRANCH .. "/loaders/" .. VERSION .. ".luau"
local source
pcall(function() source = game:HttpGet(url) end)
if type(source) ~= "string" or source == "" then
    -- Some executors' game:HttpGet returns nil; their request API still works.
    local requestFn = request or http_request or (syn and syn.request)
    if requestFn then
        local ok, response = pcall(requestFn, { Url = url, Method = "GET" })
        local body = ok and type(response) == "table" and (response.Body or response.body)
        if type(body) == "string" then source = body end
    end
end
if type(source) ~= "string" or source == "" then
    error("Cookie Hub: could not download loader " .. VERSION .. ". Check your connection and try again.", 0)
end
local chunk, failure = loadstring(source, "=CookieHubLoader")
if not chunk then error("Cookie Hub: loader " .. VERSION .. " did not compile: " .. tostring(failure), 0) end
return chunk({ channel = CHANNEL, version = VERSION })
