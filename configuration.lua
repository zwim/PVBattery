
local LOGLEVEL = 3

local lfs = require("lfs")
local util = require("base/util")

local position = {
    name = "Kirchbichl",
    latitude = 47.5109083,
    longitude = 12.0855866,
    altitude = 520,
    timezone = nil, -- will be filled in by SunTimes
}


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
    loglevel = LOGLEVEL,

    host = util.hostname(),

    position = position,

    log_file_name = "/var/log/PVBattery.log",
    html_main = "/var/www/localhost/htdocs/index.html",
    html_json = "/var/www/localhost/htdocs/PVBattery.json",
    html_battery = "/var/www/localhost/htdocs/battery.html",

    bat_SOC_min = 15, -- Percent
    bat_SOC_full = 90, -- Percent
    bat_SOC_max = 100, -- Percent
    bat_SOC_min_rescue = 10, -- start rescue charge
    bat_lowest_voltage = 2.90, -- lowest allowed voltage per cell
    bat_lowest_rescue = 2.801, -- start rescue charge
    bat_highest_voltage = 3.53, -- highest allowed voltage per cell
    bat_high_voltage_hysteresis = 0.050, -- hysteresis on the high side
    max_cell_diff = 0.150,
    cell_cell_diff_hysteresis = 0.020,

    lastFullPeriod = 5*24*3600, -- two days
    min_cell_diff = 0.003,
    min_cell_diff_base = 0.003,
    cell_diff_hysteresis = 0.003,
    min_charge_power = 30,
    charge_finished_current = -0.3,

    bat_SOC_hysteresis = 2,
    bat_voltage_hysteresis = 0.050,

    load_full_time_h = 2, -- time before sun set, to load battery at maximum

    sleep_time = 5, -- seconds to sleep per iteration

    update_interval = 10, -- time to keep old data before an update

    FRONIUS_ADR = "192.168.0.49",

    Device = {
        { -- Device[1]
            name = "P1Meter",
            typ = "smartmeter",
            brand = "homewizard",
            host = "HW-p1meter.lan",
            ip = nil,
        },
        { -- Device[1]
            name = "PV-Dach",
            typ = "inverter",
            brand = "Fronius",
            inverter_switch = "fronius.lan",
        },
        { -- Device[3]
            name = "Battery Pack",
            typ = "battery",
            brand = "custom",
            capacity = 2.300, -- kWh
            BMS = "battery-bms.lan",
            ip = nil,
            charger_switches = {
                "battery-charger.lan",
                "battery-charger2.lan",
            },
            charger_max_power = {
                390,
                340,
            },
            inverter_switch = "battery-inverter.lan",
            inverter_min_power = 150,
            inverter_max_power = 160,
            inverter_time_controlled = nil,
            SOC_min = 25,
            SOC_max = 100,
            leave_mode = "stop",
        },
        { -- Device[4]
            name = "VenusE 1",
            typ = "battery",
            brand = "marstek",
            capacity = 5.120, -- kWh
            host = "Venus-E1-modbus",
            -- ip = "192.168.0.208",
            port = 502,
            slaveId = 1,
            charge_max_power = 2492,
            discharge_max_power = 2492,
            SOC_min = 15,
            SOC_max = 100,
            leave_mode = "auto",
        },
        { -- Device[5]
            name = "VenusE 2",
            typ = "battery",
            brand = "marstek",
            capacity = 5.120, -- kWh
            host = "Venus-E2-modbus",
            -- ip = "192.168.0.161",
            port = 502,
            slaveId = 1,
            charge_max_power = 2492,
            discharge_max_power = 2492,
            SOC_min = 15,
            SOC_max = 100,
            leave_mode = "stop",
        },
        { -- Device[6]
            name = "Balkon Inverter",
            typ = "inverter",
            brand = "Envertech",
            BMS = nil,
            inverter_switch = "balkon-inverter.lan",
            inverter_time_controlled = "sunrise",
        },
        { -- Device[7]
            name = "Garage Inverter",
            typ = "inverter",
            brand = "Envertech",
            BMS = nil,
            inverter_switch = "garage-inverter.lan",
            inverter_time_controlled = "sunrise",
        },
        { -- Device[8]
            typ = "prognose",
            brand = "solarprognose",
            cfg = {
                planes = {
                    {
                        name = "roof",
                        token = "c2a2da7b09c3c2e2a20651a2223e7fa7",
                        project = "7052",
                        item = "module_filed",
                        id = "14336",
                        typ = "hourly",
                        cachefile = "/tmp/solarprognose_dach.json",
                        cachetime = 1*3600,
                    },
                    {
                        name = "balkon",
                        token = "c2a2da7b09c3c2e2a20651a2223e7fa7",
                        project = "7052",
                        item = "module_filed",
                        id = "14337",
                        typ = "hourly",
                        cachefile = "/tmp/solarprognose_balkon.json",
                        cachetime = 1*3600,
                    },
                },
                cachefile = "/tmp/solarprognose_agg_total.json",
            },
        },
        { -- Device[9]
            typ = "prognose",
            brand = "forecast.solar",
            cfg = {
                -- Hier definierst du ALLE deine PV-Flächen.
                planes = {
                    {
                        name = "Dach",
                        latitude = position.latitude,
                        longitude = position.longitude,
                        declination = 30, -- Neigung
                        azimuth = -45,    -- Ausrichtung, Ost=-90, West=90
                        kwp = 4.5,
                    },
                    {
                        name = "Balkon",
                        latitude = position.latitude,
                        longitude = position.longitude,
                        declination = 85, -- Neigung
                        azimuth = 90,     -- Ausrichtung Ost=-90, West=90
                        kwp = 6.9,
                    },
                    -- Optional: Mehr Flächen hinzufügen
                },
                cachefile = "/tmp/forecast_solar_agg.json",
                cachetime = 1 * 3600, -- 1 Stunde
            },
        },
    },

    -- compressor = "bzip2 -6",
    compressor = "zstd -8 --rm -T3",

    mqtt_broker_uri = "battery-control.lan",
    mqtt_client_id = "PVBatteryV",

    -- db_url    = "http://localhost:8086",
    -- db_token  = "ZWyI3Qh2E_LvX3EgifO_8cTbaBwyFktEfLwFxGiLffjX7HGQfDm7x4AzJuK7_1jp2Yfj6CzSat3Ozv4P8efLZQ==",
    db_url    = "http://battery-control:8086",
    db_token  = "Xeq_91oWUcNVCNwE4JsMYJ7-2qT3HybpO5HoqmI40ZEWxZ0Uo6f6GFwg0DamnCPIQBVEXeHcVIy5Or4SbkBkEw==",
    db_org    = "PV",
    db_bucket = "Daten",
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
