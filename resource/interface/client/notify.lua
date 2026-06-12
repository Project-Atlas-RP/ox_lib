--[[
    https://github.com/overextended/ox_lib

    This file is licensed under LGPL-3.0 or higher <https://www.gnu.org/licenses/lgpl-3.0.en.html>

    Copyright © 2025 Linden <https://github.com/thelindat>
]]

---@alias NotificationPosition 'top' | 'top-right' | 'top-left' | 'bottom' | 'bottom-right' | 'bottom-left' | 'center-right' | 'center-left' | 'custom'
---@alias NotificationType 'info' | 'warning' | 'success' | 'error'
---@alias IconAnimationType 'spin' | 'spinPulse' | 'spinReverse' | 'pulse' | 'beat' | 'fade' | 'beatFade' | 'bounce' | 'shake'

---@class NotifyProps
---@field id? string
---@field title? string
---@field description? string
---@field duration? number
---@field showDuration? boolean
---@field position? NotificationPosition
---@field type? NotificationType
---@field style? { [string]: any }
---@field icon? string | { [1]: IconProp, [2]: string }
---@field iconAnimation? IconAnimationType
---@field iconColor? string
---@field alignIcon? 'top' | 'center'
---@field sound? { bank?: string, set: string, name: string }

local settings = require 'resource.settings'

local customPositionEnabled = false

-- Toggle custom position in NUI with X/Y coordinates
local function setCustomPositionCSS(enabled)
    if customPositionEnabled == enabled then return end
    customPositionEnabled = enabled
    
    SendNUIMessage({
        action = 'setCustomPosition',
        data = {
            enabled = enabled,
            x = settings.notification_custom_x or 18,
            y = settings.notification_custom_y or 78,
            width = settings.notification_custom_width or 300
        }
    })
end

-- Initialize on resource start
CreateThread(function()
    Wait(500)
    if settings.notification_position == 'custom' then
        setCustomPositionCSS(true)
    end
end)

---`client`
---@param data NotifyProps
---@diagnostic disable-next-line: duplicate-set-field
function lib.notify(data)
    local sound = settings.notification_audio and data.sound
    local payload = table.clone(data)
    payload.sound = nil
    payload.position = payload.position or settings.notification_position
    -- Atlas: double the default ox_lib notification duration (3000ms -> 4500ms).
    -- Callers that explicitly pass `duration` are unaffected.
    if payload.duration == nil then payload.duration = 4500 end

    -- If the user selected our custom minimap position, keep it enabled.
    -- react-hot-toast uses the toast position to decide slide-in/out direction.
    -- Using bottom-left here makes the toast slide/fade towards the left.
    local useCustom = settings.notification_position == 'custom'
        and (payload.position == 'custom' or payload.position == 'bottom-right')

    if useCustom then
        setCustomPositionCSS(true)
        payload.position = 'bottom-left'
    else
        setCustomPositionCSS(false)
    end

    SendNUIMessage({
        action = 'notify',
        data = payload
    })

    if not sound then return end

    if sound.bank then lib.requestAudioBank(sound.bank) end

    local soundId = GetSoundId()
    PlaySoundFrontend(soundId, sound.name, sound.set, true)
    ReleaseSoundId(soundId)

    if sound.bank then ReleaseNamedScriptAudioBank(sound.bank) end
end

---@class DefaultNotifyProps
---@field title? string
---@field description? string
---@field duration? number
---@field position? NotificationPosition
---@field status? 'info' | 'warning' | 'success' | 'error'
---@field id? number

---@param data DefaultNotifyProps
function lib.defaultNotify(data)
    -- Backwards compat for v3
    data.type = data.status
    if data.type == 'inform' then data.type = 'info' end
    return lib.notify(data --[[@as NotifyProps]])
end

RegisterNetEvent('ox_lib:notify', lib.notify)
RegisterNetEvent('ox_lib:defaultNotify', lib.defaultNotify)
