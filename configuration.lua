
local lfs = require("lfs")
local util = require("util")

local configuration = {
    -- Don't change this in a config file.
    -- Use a config file only if it is younger than ---v
    config_file_date = 1689399515,             -- 20230715090000

    -- add defaults here!
    -- will be overwritten and extended by config.lua's content

    -- Can be used to chain load another config file at startup.
    -- But be aware, the last file is the one to be checked continually
    -- during PVBattery run.
    config_file_name = "config.lua", -- load this file

    host = "battery-control.lan",

    position = {
        name = "Kirchbichl",
        latitude = 47.5109083,
        longitude = 12.0855866,
        altitude = 520,
        timezone = nil,
    },

    log_file_name = "/var/log/PVBattery.log",
    html_main = "/var/www/localhost/htdocs/index.html",
    html_battery = "/var/www/localhost/htdocs/battery.html",

    bat_max_feed_in = -350, -- Watt
    bat_max_feed_in2 = -350, -- Watt
    bat_max_take_out = 160, -- Watt
    exceed_factor = -0.15, -- Shift the bat_max_xxx values by -10%

    bat_SOC_min = 20, -- Percent
    bat_SOC_max = 90, -- Percent
    bat_lowest_voltage = 2.90, -- lowest allowed voltage per cell
    bat_highest_voltage = 3.53, -- highest allowed voltage per cell

    bat_hysteresis = 2,

    load_full_time = 2, -- hour before sun set

    sleep_time = 5, -- seconds to sleep per iteration

    guard_time = 5 * 60, -- 5 minutes

    FRONIUS_ADR = "192.168.0.49",

    Device = {
        { -- Device[1]
            name = "Battery Pack",
            charger_switch = {
                "battery-charger.lan",
                "battery-charger2.lan",
            },
            inverter_switch = "battery-inverter.lan",
            inverter_control = nil,
            inverter_min_power = 110,
            inverter_skip = false,
            BMS = "batter-bms.ln",
        },
        { -- Device[2]
            name = "Garage Inverter",
            charger_switch = {},
            inverter_switch = "192.168.1.30",
            inverter_control = nil,
            inverter_skip = true,
            BMS = nil,
        },
        { -- Device[3]
            name = "Moped",
            charger_switch = {
                "moped-charger",
            },
            inverter_switch = "moped-inverter",
            inverter_control = "192.168.0.13",
            inverter_min_power = 10,
            inverter_skip = false,
            BMS = "192.168.0.13",
        },
    }
}

-- Todo honor self.validConfig
function configuration:read()
    local file = configuration.config_file_name or "config.lua"

    local chunk, config_time, err
    config_time, err = lfs.attributes(file, 'modification')

    if err then
        util:log("Error opening config file: " .. configuration.config_file_name, "Err: " .. err)
        return false
    end

    if config_time == configuration.config_file_date then
        return nil -- no need to reload
    end

    chunk, err = loadfile(file, "t", configuration)

    if chunk then
        -- get new config values
        chunk()
        configuration.config_file_date = config_time
        self.validConfig = true
        -- ToDo: print the new config
        return nil
    else
        util:log("Error loading config file: " .. configuration.config_file_name, "Err:" .. err)
        self.validConfig = false
    end
    return false
end

return configuration
