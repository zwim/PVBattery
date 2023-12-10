-- Configuration file for PVBattery.lua

-- Can be used to chain load another config file at startup.
-- But be aware, the last file is the one to be checked continually
-- during PVBattery run.

-- config_file_name = "config.lua"

-- The globals here are locals after ``chunk, err = loadfile(file, "t", configuration)` so:
-- luacheck: ignore 111

-- Times are in seconds if no other extension is used (time_m, time_h ...)

log_file_name = "/var/log/PVBattery.log"

-- html_main = "/var/www/localhost/htdocs/index.html"
html_main = "/tmp/index.html"
--html_battery = "/var/www/localhost/htdocs/battery.html"
html_battery = "/tmp/battery.html"

position = {
    name = "Kirchbichl",
    latitude = 47.5109083,
    longitude = 12.0855866,
    altitude = 520,
    timezone = nil,
}

bat_SOC_min = 18 -- Percent
bat_SOC_max = 100 -- Percent
bat_SOC_min_rescue = 10 -- start rescue charge

bat_hysteresis = 2

bat_lowest_voltage = 2.901 -- lowest allowed voltage
bat_lowest_rescue = 2.801 -- start rescue charge
bat_hightest_voltage = 3.53 -- lowest allowed voltage
max_cell_diff = 0.100 -- maximum allowed cell diff

load_full_time_h = 2.5 -- time before sun set, to load battery at maximum

sleep_time = 15 -- seconds to sleep per iteration

update_interval = 12 -- time to keep old data before an update

guard_time = 1 * 60 -- every minute

FRONIUS_ADR = "192.168.0.49"

Device = {
    { -- Device[1]
        name = "Battery Pack",
        BMS = "battery-bms.lan",
        charger_switches = {
            "battery-charger.lan",
            "battery-charger2.lan",
        },
        inverter_switch = "battery-inverter.lan",
        inverter_control = nil,
        inverter_min_power = 110,
        inverter_skip = false,
    },
    { -- Device[2]
        name = "Garage Inverter",
        BMS = nil,
        charger_switches = {},
        inverter_switch = "192.168.1.30",
        inverter_control = nil,
        inverter_skip = true,
    },
    { -- Device[3]
        name = "Moped",
        BMS = "", -- fehlt noch
        charger_switches = {
            "192.168.1.100",
        },
        inverter_switch = "192.168.1.50",
        inverter_control = "fehltnoch",
        inverter_min_power = 10,
        inverter_skip = false,
    },
}
