
local lfs = require("lfs")
local util = require("util")


local SCRIPTNAME = "PVBattery.lua"
local SCRIPTNAME_PATTERN = SCRIPTNAME:gsub("%.", "%%%.") -- replace . with %. for search patterns

local config = {
    config_file_name = "config.lua",
    guard_time = 5 * 60,
}

local function readConfig()
    local file = config.config_file_name or "config.lua"

    local chunk, config_time, err
    config_time, err = lfs.attributes(file, 'modification')

    if err then
        util:log("Error opening config file: " .. config.config_file_name, "Err: " .. err)
        return false
    end

    if config_time == config.config_file_date then
        -- no need to reload
        return true
    end

    chunk, err = loadfile(file, "t", config)

    if chunk then
        -- save new config values
        chunk()
        config.config_file_date = config_time
        return true
    else
        util:log("Error loading config file: " .. config.config_file_name, "Err:" .. err)
    end
    return false
end

while true do
    readConfig()
    print(string.format("Check if %s is running every %d s", SCRIPTNAME, config.guard_time))

    local handle = io.popen("ps -ax")
    local output = handle:read("*a")
    handle:close()

    local isScriptRunning = output:find(SCRIPTNAME_PATTERN)
    if not isScriptRunning then
        -- no running PVBattery.lua found, so start it again
        -- os.execute("lua " .. SCRIPTNAME .. ".lua &")
        print(SCRIPTNAME .. " is not running -> restart it")

        -- This will just start it in background, but kills it if this script is stopped
        os.execute("lua PVBattery.lua &")

        -- see https://stackoverflow.com/questions/19233529/run-bash-script-as-daemon
--        os.execute("setsid " .. SCRIPTNAME .. " >/dev/null 2>&1 < /dev/null &")

    else
        print(SCRIPTNAME .. " is running")
    end

    util.sleep_time(config.guard_time or 5*60)
end