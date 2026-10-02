--[[
    Rempart — captures d'écran via screenshot-basic (facultatif).
]]

local Screenshot = {}
Rempart.Screenshot = Screenshot

local cooldown = {}  -- src -> ms

function Screenshot.available()
    return GetResourceState('screenshot-basic') == 'started'
end

--- Capture l'écran du joueur. cb(attachment|nil) est appelé exactement une fois.
--- attachment = { name, data (binaire), mime }
function Screenshot.capture(src, cb, force)
    local done = false
    local function finish(att)
        if done then return end
        done = true
        cb(att)
    end

    if not Screenshot.available() then return finish(nil) end
    local now = Rempart.now()
    if not force and cooldown[src] and cooldown[src] > now then return finish(nil) end
    cooldown[src] = now + 20000

    SetTimeout(Config.Punish.screenshotTimeout or 8000, function() finish(nil) end)

    local ok = pcall(function()
        exports['screenshot-basic']:requestClientScreenshot(src, {
            encoding = 'jpg',
            quality = Config.Punish.screenshotQuality or 0.6,
        }, function(err, data)
            if err or type(data) ~= 'string' then return finish(nil) end
            local b64 = data:match('^data:image/%w+;base64,(.+)$')
            if not b64 then return finish(nil) end
            finish({ name = ('rempart_%d_%d.jpg'):format(src, os.time()), data = Utils.base64Decode(b64), mime = 'image/jpeg' })
        end)
    end)
    if not ok then finish(nil) end
end

AddEventHandler('playerDropped', function()
    cooldown[tonumber(source) or -1] = nil
end)
