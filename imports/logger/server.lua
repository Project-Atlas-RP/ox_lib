--[[
    https://github.com/overextended/ox_lib

    This file is licensed under LGPL-3.0 or higher <https://www.gnu.org/licenses/lgpl-3.0.en.html>

    Copyright © 2025 Linden <https://github.com/thelindat>
]]

local service = GetConvar('ox:logger', 'datadog')

local function removeColorCodes(str)
    -- replace ^[0-9] with nothing
    str = string.gsub(str, "%^%d", "")

    -- replace ^#[0-9A-F]{3,6} with nothing
    str = string.gsub(str, "%^#[%dA-Fa-f]+", "")

    -- replace ~[a-z]~ with nothing
    str = string.gsub(str, "~[%a]~", "")

    return str
end

local hostname = removeColorCodes(GetConvar('ox:logger:hostname', GetConvar('sv_projectName', 'fxserver')))

local function badResponse(endpoint, status, response)
    warn(('unable to submit logs to %s (status: %s)\n%s'):format(endpoint, status, json.encode(response, { indent = true })))
end

local playerData = {}

AddEventHandler('playerDropped', function()
    playerData[source] = nil
end)

local function formatTags(source, tags)
    if type(source) == 'number' and source > 0 then
        local data = playerData[source]

        if not data then
            local _data = {
                ('username:%s'):format(GetPlayerName(source))
            }

            local num = 1

            ---@cast source string
            for i = 0, GetNumPlayerIdentifiers(source) - 1 do
                local identifier = GetPlayerIdentifier(source, i)

                if not identifier:find('ip') then
                    num += 1
                    _data[num] = identifier
                end
            end

            data = table.concat(_data, ',')
            playerData[source] = data
        end

        tags = tags and ('%s,%s'):format(tags, data) or data
    end

    return tags
end

---@class LogContext
---@field hostname string
---@field formatTags fun(source: any, tags: string?): string?

---@class LogProvider
---@field endpoint string
---@field headers table<string, string>
---@field okStatus number
---@field append fun(buffer: table, source: any, event: string, message: string, ...): nil
---@field encode fun(buffer: table): string
---@field parseError fun(status: number, response: any, body: string): any|nil

local KNOWN = { datadog = true, fivemanage = true, loki = true }

-- Atlas: upstream early-returns when no provider is configured; we still need
-- the atlas_logs wrapper below to install, so the provider setup runs in a
-- single-pass repeat block and the early returns become breaks.
repeat
    if not KNOWN[service] then break end

    ---@type fun(ctx: LogContext): LogProvider?
    local providerFactory = lib.require(('imports.logger.providers.%s'):format(service))
    if not providerFactory then break end

    local provider = providerFactory({
        hostname = hostname,
        formatTags = formatTags,
    })
    if not provider then break end

    local buffer

    function lib.logger(source, event, message, ...)
        if not buffer then
            buffer = {}

            SetTimeout(500, function()
                local body = provider.encode(buffer)
                buffer = nil

                PerformHttpRequest(provider.endpoint, function(status, _, _, response)
                    if status == provider.okStatus then return end

                    local err = provider.parseError(status, response, body)
                    if err == nil then return end

                    badResponse(provider.endpoint, status, err)
                end, 'POST', body, provider.headers)
            end)
        end

        provider.append(buffer, source, event, message, ...)
    end
until true

-- ============================================================
-- Atlas patch: route every lib.logger(...) call through atlas_logs.
--
-- Upstream lib.logger only dispatches to datadog/fivemanage/loki (selected
-- by the `ox:logger` convar). atlas_logs is the canonical project sink (web
-- panel), so we wrap whichever upstream function got installed above and
-- mirror the call into atlas_logs.
--
-- If no upstream service is configured (no key set), `lib.logger` is left
-- as `nil` by the upstream code and we install our own stub that just
-- forwards to atlas_logs. Either way, any caller of `lib.logger` gets
-- atlas_logs for free without changing their call site.
-- ============================================================

local upstreamLogger = lib.logger

local function metadataFromArgs(...)
    local meta = {}
    for _, arg in ipairs({ ... }) do
        if type(arg) == 'string' then
            local k, v = string.strsplit(':', arg)
            if k and v then meta[k] = v end
        elseif type(arg) == 'table' then
            for k, v in pairs(arg) do meta[k] = v end
        end
    end
    return meta
end

function lib.logger(source, event, message, ...)
    if upstreamLogger then
        upstreamLogger(source, event, message, ...)
    end

    -- Capture varargs before entering the pcall closure: Lua does not allow
    -- a nested non-vararg function to reference its parent's `...`.
    local extraArgs = { ... }

    pcall(function()
        local invoker = GetInvokingResource() or cache.resource or 'ox_lib'
        local meta = metadataFromArgs(table.unpack(extraArgs))
        meta.invokingResource = meta.invokingResource or invoker
        meta.upstreamService = service
        exports.atlas_logs:log(
            invoker,
            tostring(event or 'log'),
            tostring(message or ''),
            'info',
            (type(source) == 'number' and source > 0) and source or nil,
            meta
        )
    end)
end

return lib.logger
