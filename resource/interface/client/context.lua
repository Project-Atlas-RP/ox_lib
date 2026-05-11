--[[
    https://github.com/overextended/ox_lib

    This file is licensed under LGPL-3.0 or higher <https://www.gnu.org/licenses/lgpl-3.0.en.html>

    Copyright © 2025 Linden <https://github.com/thelindat>
]]

local contextMenus = {}
local openContextMenu = nil
local currentSearchTerm = ''
local searchActive = false
local searchKeysRegistered = false
local pendingRefresh = false

-- Forward declarations
local buildVisibleOptions, sanitizeOption, refreshContextMenu, registerSearchKeys

-- Set state on player so other resources can check if context search is active
-- Other resources should check this state before processing their RegisterKeyMapping handlers:
--   if LocalPlayer.state.contextSearchActive then return end
-- This prevents custom keybinds (like pointing) from triggering while typing in context search
local function setSearchState(active)
    searchActive = active
    LocalPlayer.state:set('contextSearchActive', active, false)
end

-- Export function for other resources to check search state
exports('isContextSearchActive', function()
    return searchActive
end)

-- Control disabler thread while search is active
CreateThread(function()
    while true do
        if searchActive and openContextMenu then
            -- Disable ALL controls - no shooting, punching, jumping, moving
            DisableAllControlActions(0)
            DisableAllControlActions(1)
            DisableAllControlActions(2)
            -- Only allow cursor/mouse movement for NUI interaction
            EnableControlAction(0, 239, true) -- Cursor X
            EnableControlAction(0, 240, true) -- Cursor Y
            EnableControlAction(0, 237, true) -- Cursor scroll down
            EnableControlAction(0, 238, true) -- Cursor scroll up
            EnableControlAction(0, 330, true) -- Mouse left button (for NUI click)
            EnableControlAction(0, 329, true) -- Mouse right button
            Wait(0)
        else
            Wait(200)
        end
    end
end)

local function optionMatches(option, term)
    if not term or term == '' then return true end

    local function matches(value)
        if type(value) ~= 'string' then return false end
        return value:lower():find(term, 1, true) ~= nil
    end

    if matches(option.title) or matches(option.description) or matches(option.icon) or matches(option.metadata) then return true end

    if type(option.metadata) == 'table' then
        for key, value in pairs(option.metadata) do
            if matches(key) or matches(tostring(value)) then return true end
        end
    end

    return false
end

buildVisibleOptions = function(context)
    local options = context.__originalOptions or context.options or {}
    local term = context._searchTerm or ''
    if term == '' then return options, term end

    local filtered = {}
    for i = 1, #options do
        if optionMatches(options[i], term) then
            filtered[#filtered + 1] = options[i]
        end
    end

    return filtered, term
end

sanitizeOption = function(option)
    local sanitized = {}
    for key, value in pairs(option) do
        if type(value) ~= 'function' then
            if key == 'metadata' and type(value) == 'table' then
                local metaCopy = {}
                for mk, mv in pairs(value) do
                    if type(mv) ~= 'function' then metaCopy[mk] = mv end
                end
                sanitized[key] = metaCopy
            else
                sanitized[key] = value
            end
        end
    end
    return sanitized
end

refreshContextMenu = function(contextId)
    local menu = contextMenus[contextId]
    if not menu then return end

    -- Debounce: mark pending and skip if already waiting
    if pendingRefresh then return end
    pendingRefresh = true

    -- Small delay to batch rapid keypresses
    SetTimeout(50, function()
        pendingRefresh = false
        if not openContextMenu or openContextMenu ~= contextId then return end

        local currentMenu = contextMenus[contextId]
        if not currentMenu then return end

        local options
        if currentMenu.search then
            local filteredOptions, term = buildVisibleOptions(currentMenu)

            local title
            if searchActive then
                title = ('🔍 %s|'):format(term)
            else
                title = term ~= '' and ('🔍 ' .. term) or (currentMenu.searchLabel or '🔍 Type to search...')
            end

            local searchButton = {
                title = title,
                description = searchActive and (currentMenu.searchDescriptionActive or 'Type to filter (Backspace to delete)') or (currentMenu.searchDescription or 'Click to start typing'),
                icon = currentMenu.searchIcon or 'fa-solid fa-magnifying-glass',
                _isSearchButton = true
            }
            options = { searchButton }
            for i = 1, #filteredOptions do
                options[#options + 1] = filteredOptions[i]
            end
        else
            options = currentMenu.options
        end

        currentMenu._visibleOptions = options
        local sendOptions = {}
        for i = 1, #options do
            sendOptions[i] = sanitizeOption(options[i])
        end

        SendNuiMessage(json.encode({
            action = 'updateContextOptions',
            data = {
                title = currentMenu.title,
                canClose = currentMenu.canClose,
                menu = currentMenu.menu,
                options = sendOptions
            }
        }, { sort_keys = true }))
    end)
end

registerSearchKeys = function()
    if searchKeysRegistered then return end
    searchKeysRegistered = true

    local function canType()
        if not searchActive or not openContextMenu then return false end
        local menu = contextMenus[openContextMenu]
        return menu and menu.search
    end

    local function updateTerm(newTerm)
        if not openContextMenu then return end
        local menu = contextMenus[openContextMenu]
        if not menu or not menu.search then return end
        currentSearchTerm = newTerm
        menu._searchTerm = currentSearchTerm
        refreshContextMenu(openContextMenu)
    end

    local keys = {
        'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm',
        'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
        '1', '2', '3', '4', '5', '6', '7', '8', '9', '0'
    }

    for _, key in ipairs(keys) do
        RegisterCommand('+ctx_search_' .. key, function()
            if not canType() then return end
            updateTerm(currentSearchTerm .. key)
        end, false)
        RegisterCommand('-ctx_search_' .. key, function() end, false)
        RegisterKeyMapping('+ctx_search_' .. key, 'Context Search: ' .. key:upper(), 'keyboard', key)
    end

    RegisterCommand('+ctx_search_space', function()
        if not canType() then return end
        updateTerm(currentSearchTerm .. ' ')
    end, false)
    RegisterCommand('-ctx_search_space', function() end, false)
    RegisterKeyMapping('+ctx_search_space', 'Context Search: SPACE', 'keyboard', 'SPACE')

    -- Backspace with hold-to-repeat functionality
    local backspaceHeld = false
    RegisterCommand('+ctx_search_backspace', function()
        if not canType() then return end
        if #currentSearchTerm == 0 then return end
        updateTerm(currentSearchTerm:sub(1, -2))
        
        -- Start hold-to-delete loop
        backspaceHeld = true
        SetTimeout(400, function() -- Initial delay before repeat starts
            CreateThread(function()
                while backspaceHeld and canType() and #currentSearchTerm > 0 do
                    Wait(50) -- Speed of repeat deletion
                    if backspaceHeld and #currentSearchTerm > 0 then
                        updateTerm(currentSearchTerm:sub(1, -2))
                    end
                end
            end)
        end)
    end, false)
    RegisterCommand('-ctx_search_backspace', function()
        backspaceHeld = false
    end, false)
    RegisterKeyMapping('+ctx_search_backspace', 'Context Search: BACKSPACE', 'keyboard', 'BACKSPACE')

    -- Exit search mode with Enter or Escape
    -- Returns to normal NUI state (cursor visible, can click buttons, game controls blocked)
    local function exitSearchMode()
        if not searchActive or not openContextMenu then return end
        setSearchState(false)
        -- Restore normal NUI focus: cursor visible, game input blocked (same as when menu first opens)
        -- lib.setNuiFocus(false, false) = SetNuiFocus(true, true) + SetNuiFocusKeepInput(false)
        lib.setNuiFocus(false, false)
        refreshContextMenu(openContextMenu)
    end

    RegisterCommand('+ctx_search_enter', function()
        if not canType() then return end
        exitSearchMode()
    end, false)
    RegisterCommand('-ctx_search_enter', function() end, false)
    RegisterKeyMapping('+ctx_search_enter', 'Context Search: ENTER', 'keyboard', 'RETURN')

    RegisterCommand('+ctx_search_escape', function()
        if not canType() then return end
        exitSearchMode()
    end, false)
    RegisterCommand('-ctx_search_escape', function() end, false)
    RegisterKeyMapping('+ctx_search_escape', 'Context Search: ESCAPE', 'keyboard', 'ESCAPE')
end

---@class ContextMenuItem
---@field title? string
---@field menu? string
---@field icon? string | {[1]: IconProp, [2]: string};
---@field iconColor? string
---@field image? string
---@field progress? number
---@field onSelect? fun(args: any)
---@field arrow? boolean
---@field description? string
---@field metadata? string | { [string]: any } | string[]
---@field disabled? boolean
---@field readOnly? boolean
---@field event? string
---@field serverEvent? string
---@field args? any

---@class ContextMenuArrayItem : ContextMenuItem
---@field title string

---@class ContextMenuProps
---@field id string
---@field title string
---@field menu? string
---@field onExit? fun()
---@field onBack? fun()
---@field canClose? boolean
---@field options { [string]: ContextMenuItem } | ContextMenuArrayItem[]

local function closeContext(_, cb, onExit)
    if cb then cb(1) end

    lib.resetNuiFocus()
    currentSearchTerm = ''
    setSearchState(false)

    if not openContextMenu then return end
    
    -- Reset search term on the menu
    if contextMenus[openContextMenu] and contextMenus[openContextMenu].search then
        contextMenus[openContextMenu]._searchTerm = ''
    end

    if (cb or onExit) and contextMenus[openContextMenu].onExit then contextMenus[openContextMenu].onExit() end

    if not cb then SendNUIMessage({ action = 'hideContext' }) end

    openContextMenu = nil
end

---@param id string
function lib.showContext(id)
    if not contextMenus[id] then error('No context menu of such id found.') end

    local data = contextMenus[id]
    local options

    if data.search then
        registerSearchKeys()
        setSearchState(false)
        currentSearchTerm = data._searchTerm or ''
        local filteredOptions, term = buildVisibleOptions(data)
        local searchButton = {
            title = term ~= '' and ('🔍 ' .. term) or (data.searchLabel or '🔍 Type to search...'),
            description = data.searchDescription or 'Click to start typing',
            icon = data.searchIcon or 'fa-solid fa-magnifying-glass',
            _isSearchButton = true
        }

        options = { searchButton }
        for i = 1, #filteredOptions do
            options[#options + 1] = filteredOptions[i]
        end
    else
        options = data.options
    end

    data._visibleOptions = options
    local sendOptions = {}

    for i = 1, #options do
        sendOptions[i] = sanitizeOption(options[i])
    end
    openContextMenu = id

    -- Enable cursor so the menu (and search row) is clickable.
    lib.setNuiFocus(false, false)

    SendNuiMessage(json.encode({
        action = 'showContext',
        data = {
            title = data.title,
            canClose = data.canClose,
            menu = data.menu,
            options = sendOptions
        }
    }, { sort_keys = true }))
end

---@param context ContextMenuProps | ContextMenuProps[]
function lib.registerContext(context)
    for k, v in pairs(context) do
        if type(k) == 'number' then
            v.__originalOptions = v.options
            contextMenus[v.id] = v
        else
            context.__originalOptions = context.options
            contextMenus[context.id] = context
            break
        end
    end
end

---@return string?
function lib.getOpenContextMenu() return openContextMenu end

---@param onExit boolean?
function lib.hideContext(onExit) closeContext(nil, nil, onExit) end

RegisterNUICallback('openContext', function(data, cb)
    if data.back and contextMenus[openContextMenu] then
        -- Reset search term when going back
        if contextMenus[openContextMenu].search then
            contextMenus[openContextMenu]._searchTerm = ''
        end
        if contextMenus[openContextMenu].onBack then contextMenus[openContextMenu].onBack() end
    end
    currentSearchTerm = ''
    setSearchState(false)
    cb(1)
    lib.showContext(data.id)
end)

RegisterNUICallback('clickContext', function(id, cb)
    cb(1)

    if math.type(tonumber(id)) == 'float' then
        id = math.tointeger(id)
    elseif tonumber(id) then
        id += 1
    end

    local menu = contextMenus[openContextMenu]
    local options = menu and (menu._visibleOptions or menu.options)
    if not options then return end

    local data = options[id]
    if not data then return end

    -- Click-to-arm search typing (no popup)
    if data._isSearchButton then
        if menu and menu.search then
            setSearchState(true)
            currentSearchTerm = menu._searchTerm or ''
            -- Enable NUI focus but allow key input to reach game for RegisterKeyMapping
            -- lib.setNuiFocus(true, false) = SetNuiFocus(true, true) + SetNuiFocusKeepInput(true)
            -- This keeps cursor visible but lets our key mappings receive input
            lib.setNuiFocus(true, false)
            refreshContextMenu(openContextMenu)
        end
        return
    end

    if not data.event and not data.serverEvent and not data.onSelect and not data.menu then return end

    -- If navigating to submenu, reset current search
    if data.menu then
        currentSearchTerm = ''
        if menu and menu.search then
            menu._searchTerm = ''
        end
        return
    end

    openContextMenu = nil
    setSearchState(false)

    SendNUIMessage({ action = 'hideContext' })
    lib.resetNuiFocus()

    if data.onSelect then data.onSelect(data.args) end
    if data.event then TriggerEvent(data.event, data.args) end
    if data.serverEvent then TriggerServerEvent(data.serverEvent, data.args) end
end)

RegisterNUICallback('closeContext', closeContext)



