-- whitelist_live/init.lua
local modname = minetest.get_current_modname()
local storage = minetest.get_mod_storage()

-- state
local WL = {
    enabled = true,
    list = {},                -- set: name->true
    list_array = {},          -- ordered list for listing
    src_file = minetest.get_worldpath() .. "/whitelist.txt",
    file_mtime = nil,
    check_interval = 5.0,
    timer = 0,
}

-- utils
local function normalize(name)
    return (name or ""):lower():gsub("^%s*(.-)%s*$", "%1")
end

local function save_storage()
    local o = { enabled = WL.enabled, list = WL.list_array }
    storage:set_string("whitelist_live:state", minetest.serialize(o))
end

local function load_storage()
    local s = storage:get_string("whitelist_live:state")
    if s and s ~= "" then
        local ok, t = pcall(minetest.deserialize, s)
        if ok and type(t) == "table" then
            WL.enabled = (t.enabled == nil) and true or t.enabled
            WL.list = {}
            WL.list_array = {}
            if type(t.list) == "table" then
                for _,n in ipairs(t.list) do
                    local nn = normalize(n)
                    if nn ~= "" then
                        WL.list[nn] = true
                        table.insert(WL.list_array, nn)
                    end
                end
            end
        end
    end
end

local function set_from_array(arr)
    WL.list = {}
    WL.list_array = {}
    if type(arr) == "table" then
        for _,name in ipairs(arr) do
            local nn = normalize(name)
            if nn ~= "" and not WL.list[nn] then
                WL.list[nn] = true
                table.insert(WL.list_array, nn)
            end
        end
    end
    save_storage()
end

-- file parsing
local function read_whitelist_file(path)
    local fh, err = io.open(path, "r")
    if not fh then return nil, err end
    local arr = {}
    for line in fh:lines() do
        line = line:match("^(.-)%s*$") or ""
        if line:match("^%s*$") then -- skip blank
        elseif line:match("^%s*#") then -- comment
        else
            local nn = normalize(line)
            if nn ~= "" then table.insert(arr, nn) end
        end
    end
    fh:close()
    return arr
end

local function file_mtime(path)
    local attr = nil
    local ok, res = pcall(function() return assert(io.open(path,"r")) end)
    if not ok then return nil end
    -- Use Lua file: seek to end to approximate mtime not available; platform may not provide mtime.
    -- Prefer to use lfs if available:
    if rawget(_G, "lfs") and lfs.attributes then
        local a = lfs.attributes(path)
        if a and a.modification then return a.modification end
    end
    -- fallback: size+time trick (not perfect). We'll return file size + current time hash to force reload on change.
    local fh = io.open(path,"r")
    if not fh then return nil end
    local content = fh:read("*a") or ""
    fh:close()
    return #content
end

local function reload_from_file()
    if not WL.src_file then return false, "no file" end
    local arr, err = read_whitelist_file(WL.src_file)
    if not arr then return false, err end
    set_from_array(arr)
    minetest.log("action", "["..modname.."] whitelist reloaded from file ("..tostring(#arr).." entries)")
    return true
end

-- API
local function add_name(name)
    name = normalize(name)
    if name == "" then return false end
    if WL.list[name] then return false end
    WL.list[name] = true
    table.insert(WL.list_array, name)
    save_storage()
    return true
end

local function remove_name(name)
    name = normalize(name)
    if not WL.list[name] then return false end
    WL.list[name] = nil
    for i,n in ipairs(WL.list_array) do
        if n == name then table.remove(WL.list_array, i); break end
    end
    save_storage()
    return true
end

local function is_whitelisted(name)
    if not name then return false end
    return WL.list[normalize(name)] == true
end

-- load initial storage
load_storage()

-- attempt to load file initially if present
if WL.src_file then
    local ok, _ = pcall(function()
        local fh = io.open(WL.src_file, "r")
        if fh then
            fh:close()
            local mt = file_mtime(WL.src_file)
            WL.file_mtime = mt
            local arr, err = read_whitelist_file(WL.src_file)
            if arr then set_from_array(arr) end
        end
    end)
end

-- privileges
minetest.register_privilege("whitelist_admin", {
    description = "Can manage the whitelist (add/remove/reload/enable/disable)",
    give_to_singleplayer = true,
})
minetest.register_privilege("whitelist_bypass", {
    description = "Bypass the whitelist (allowed to join even when whitelist enabled)",
    give_to_singleplayer = true,
})

-- commands
minetest.register_chatcommand("whitelist", {
    params = "<add|remove|list|reload|enable|disable|status> [name]",
    description = "Manage server whitelist (live-reload from whitelist.txt supported).",
    privs = { whitelist_admin = true },
    func = function(name, param)
        local cmd, arg = param:match("^(%S+)%s*(.*)$")
        if not cmd then
            return false, "usage: /whitelist <add|remove|list|reload|enable|disable|status> [name]"
        end
        cmd = cmd:lower()
        if cmd == "add" then
            if arg == "" then return false, "specify player name" end
            if add_name(arg) then
                return true, "Added "..arg.." to whitelist."
            else
                return false, arg.." already in whitelist or invalid."
            end
        elseif cmd == "remove" then
            if arg == "" then return false, "specify player name" end
            if remove_name(arg) then
                return true, "Removed "..arg.." from whitelist."
            else
                return false, arg.." not in whitelist."
            end
        elseif cmd == "list" then
            if #WL.list_array == 0 then return true, "Whitelist is empty." end
            return true, "Whitelist: "..table.concat(WL.list_array, ", ")
        elseif cmd == "reload" then
            if not WL.src_file then return false, "No whitelist.txt available to reload." end
            local ok, err = reload_from_file()
            if ok then return true, "Whitelist reloaded from file." else return false, "Reload failed: "..tostring(err) end
        elseif cmd == "enable" then
            WL.enabled = true; save_storage()
            return true, "Whitelist enabled."
        elseif cmd == "disable" then
            WL.enabled = false; save_storage()
            return true, "Whitelist disabled."
        elseif cmd == "status" then
            local s = "enabled="..tostring(WL.enabled).."; count="..tostring(#WL.list_array)
            if WL.src_file then s = s .. "; file="..WL.src_file end
            return true, s
        else
            return false, "unknown command"
        end
    end
})

-- prejoin check (deny early)
if minetest.register_on_prejoinplayer then
    minetest.register_on_prejoinplayer(function(name, ip)
        if not WL.enabled then return end
        name = normalize(name)
        -- allow bypass priv if player has it (we can't check privs before join), so check when they attempt to join by name:
        -- there is no player object yet; we must accept here unless name is not whitelisted.
        if WL.list[name] then return end
        return "You are not whitelisted on this server."
    end)
else
    -- fallback: kick on join if not allowed
	minetest.register_on_joinplayer(function(player)
	    local pname = player:get_player_name()

	    -- auto-whitelist singleplayer
	    if minetest.is_singleplayer() then
		if not WL.list[pname] then
		    WL.list[pname] = true
		    table.insert(WL.list_array, pname)
		    save_storage()
		    minetest.log("action", "["..modname.."] auto-whitelisted singleplayer: "..pname)
		end
	    end

	    active_tab[pname] = "inventory" -- existing inventory override
	    update_inventory(player)
	end)
    
end

-- live reload: poll file mtime
minetest.register_globalstep(function(dtime)
    WL.timer = WL.timer + dtime
    if WL.timer < WL.check_interval then return end
    WL.timer = 0
    if not WL.src_file then return end
    local ok, mt = pcall(file_mtime, WL.src_file)
    if not ok then mt = nil end
    if mt and WL.file_mtime ~= mt then
        WL.file_mtime = mt
        local ok2, err = reload_from_file()
        if not ok2 then minetest.log("warning", "["..modname.."] live reload failed: "..tostring(err)) end
    end
end)

