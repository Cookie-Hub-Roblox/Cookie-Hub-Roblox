-- Cookie Hub loader extension: player analytics.
-- Adds the player's profile to the loader's start report (POST /v1/client/start), which the
-- dashboard's Players tab shows: username, display name, Premium, account age (whole days),
-- avatar torso asset ID and hair accessory asset IDs ("id,id"). The server validates each
-- value and ignores a missing one.
--
-- Loader 1.17+ runs this file from the public repository (extensions/player-analytics.luau
-- on its channel's branch) while extensions/extensions.json lists "player-analytics". Remove it
-- from that list to turn it off. Source: cookie-hub-script-system roblox-scripts/extensions/.
-- Keep it plain ASCII; it is not versioned, so it must keep working with every loader 1.17+.
local Players = game:GetService("Players")
local player = Players.LocalPlayer
local AVATAR_WAIT_SECONDS = 5

-- The saved avatar, fetched in the background as soon as the extension runs. A slow or failed
-- fetch only leaves the torso and hair out.
local avatarDone, avatar = false, nil
task.spawn(function()
    pcall(function() avatar = Players:GetHumanoidDescriptionFromUserId(player.UserId) end)
    avatarDone = true
end)

local function startFields()
    local fields = {}
    pcall(function()
        if type(player.Name) == "string" then fields.username = player.Name end
    end)
    pcall(function()
        if type(player.DisplayName) == "string" then fields.display_name = player.DisplayName end
    end)
    pcall(function()
        fields.premium = player.MembershipType == Enum.MembershipType.Premium
    end)
    pcall(function()
        local age = player.AccountAge
        if type(age) == "number" and age >= 0 and age < 100000 then fields.account_age = math.floor(age) end
    end)
    local deadline = os.clock() + AVATAR_WAIT_SECONDS
    while not avatarDone and os.clock() < deadline do task.wait(0.1) end
    pcall(function()
        local torso = avatar and avatar.Torso
        if type(torso) == "number" and torso >= 0 and torso < 1e15 then fields.torso_id = math.floor(torso) end
    end)
    pcall(function()
        local hair = avatar and avatar.HairAccessory
        if type(hair) == "string" and #hair <= 200 then fields.hair_ids = hair end
    end)
    return fields
end

return { startFields = startFields }
