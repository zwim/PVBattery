
local lfs = require("lfs")
local util = require("util")

local configuration = {
    -- Don't change this in a config file.
    -- Use a config file only if it is younger than
    config_file_date = 1689399515,             -- 20230715090000

    -- add defaults here!
    -- will be overwritten and extended by config.lua's content

    -- Can be used to chain load another config file at startup.
    -- But be aware, the last file is the one to be checked continually
    -- during PVBattery run.
    config_file_name = "config.lua", -- the config file

    command_file_name = "/tmp/PVCommands", -- a file containing commands for PVBattery

    use_wget = false,

    host = util.hostname(),

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

    bat_SOC_min = 15, -- Percent
    bat_SOC_full = 90, -- Percent
    bat_SOC_max = 101, -- Percent
    bat_SOC_min_rescue = 10, -- start rescue charge
    bat_lowest_voltage = 2.90, -- lowest allowed voltage per cell
    bat_lowest_rescue = 2.801, -- start rescue charge
    bat_highest_voltage = 3.53, -- highest allowed voltage per cell
    bat_high_voltage_hysteresis = 0.050, -- hysteresis on the high side
    max_cell_diff = 0.105,
    batt_cell_diff_hysteresis = 0.020,

    lastFullPeriod = 5*24*3600, -- two days
    minCellDiff = 0.003,
    CellDiffHysteresis = 0.003,
    minPower = 30,

    bat_SOC_hysteresis = 2,
    bat_voltage_hysteresis = 0.050,

    load_full_time_h = 2, -- time before sun set, to load battery at maximum

    sleep_time = 5, -- seconds to sleep per iteration

    update_interval = 10, -- time to keep old data before an update

    FRONIUS_ADR = "192.168.0.49",

    Device = {
        { -- Device[1]
            name = "Battery Pack",
            BMS = "battery-bms.lan",
            charger_switches = {
                "battery-charger.lan",
                "battery-charger2.lan",
                "battery-charger3.lan",
            },
            charger_max_power = {
                350,
                300,
                200,
            },
            inverter_switch = "battery-inverter.lan",
            inverter_control = nil,
            inverter_min_power = 110,
            inverter_time_controlled = nil,
        },
        { -- Device[2]
            name = "Garage Inverter",
            BMS = nil,
            charger_switches = {},
            inverter_switch = "192.168.1.30",
            inverter_control = nil,
            inverter_time_controlled = {off = nil, on = nil},
        },
        { -- Device[3]
            name = "Moped",
            BMS = "192.168.0.13",
            charger_switches = {
                "moped-charger",
            },
            charger_max_power = {
                500,
            },
            inverter_switch = "moped-inverter",
            inverter_control = "192.168.0.13",
            inverter_min_power = 10,
            inverter_time_controlled = nil,
        },
    },

    -- compressor = "bzip2 -6",
    compressor = "zstd -8 --rm -T3",
}

function configuration:needUpdate()
    local file = self.config_file_name or "config.lua"

    local config_time, err
    config_time, err = lfs.attributes(file, "modification")

    if err then
        util:log("Error opening config file: " .. self.config_file_name, "Err: " .. err)
        return false
    end

    if config_time == self.config_file_date then
        return false -- no need to reload
    end
    return true, config_time
end

-- Todo honor self.validConfig
function configuration:read(force)
    local needs_update, config_time = self:needUpdate()
    if force and not needs_update then
        return false
    end
    local file = configuration.config_file_name or "config.lua"

    local chunk, err
    chunk, err = loadfile(file, "t", configuration)

    if chunk then
        -- get new config values
        chunk()
        configuration.config_file_date = config_time
        self.validConfig = true
        -- ToDo: print the new config
        return true
    else
        util:log("Error loading config file: " .. configuration.config_file_name, "Err:" .. err)
        self.validConfig = false
        return false
    end
end

return configuration
