
local AntBMS = require("antbms")
local Fronius = require("fronius")
local SunTime = require("suntime/suntime")
local Switch = require("switch")

local lfs = require("lfs")
local util = require("util")

local BatteryCharge1Switch = Switch:new()
local BatteryCharge2Switch = Switch:new()
local BatteryInverterSwitch = Switch:new()
local GarageInverterSwitch = Switch:new()
local MopedChargeSwitch = Switch:new()
local MopedInverterSwitch = Switch:new()

local config = {
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
    html_main = "/var/www/localhost/htdocs/index.html",
    html_battery = "/var/www/localhost/htdocs/battery.html",

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
    bat_lowest_voltage = 2.9, -- lowest allowed voltage

    deep_discharge_min = 4,
    deep_discharge_max = 8,
    deep_discharge_hysteresis = 4,

    load_full_time = 2, -- hour before sun set

    sleep_time = 30, -- seconds to sleep per iteration

    guard_time = 5 * 60, -- 5 minutes

    charger1 = "battery-charger.lan",
    charger2 = "battery-charger2.lan",
    battery_inverter = "battery-inverter.lan",
    garage_inverter = "192.168.1.30",
    moped_charger = "moped-charger.lan",
    moped_inverter = "moped-inverter.lan",
}

local PVBattery = {
    state = "", -- idle, charge, discharge, error
}

function PVBattery:getCurrentState()
    local state, number, pos1, pos2

    pos1, pos2 = self.state:find("%a+")
    if pos1 and pos2 then
        state = self.state:sub(pos1, pos2)
    else
        state = "error unknown"
    end

    pos1, pos2 = self.state:find("%d+")

    if pos1 and pos2 then
        number = self.state:sub(pos1, pos2)
    else
        number = nil
    end

    return state, number
end

-- Todo honor self.validConfig
function PVBattery:readConfig()
    local file = config.config_file_name or "config.lua"

    local chunk, config_time, err
    config_time, err = lfs.attributes(file, 'modification')

    if err then
        util:log("Error opening config file: " .. config.config_file_name, "Err: " .. err)
        return false
    end

    if config_time == config.config_file_date then
        return true -- no need to reload
    end

    chunk, err = loadfile(file, "t", config)

    if chunk then
        -- get new config values
        chunk()
        config.config_file_date = config_time
        self.validConfig = true
        -- ToDo: print the new config
        return true
    else
        util:log("Error loading config file: " .. config.config_file_name, "Err:" .. err)
        self.validConfig = false
    end
    return false
end

function PVBattery:init()
    self:readConfig()
    util:setLog(config.log_file_name or "config.lua")

    util:log("\n#############################################")
    util:log("PV-Control started.")
    util:log("#############################################")

    local position = config.position
    SunTime:setPosition(position.name, position.latitude, position.longitude, position.timezone, position.height, true)

    SunTime:setDate()
    SunTime:calculateTimes()
    local h, m, s
    h, m, s = util.hourToTime(SunTime.rise)
    util:log("Sun rise at " .. string.format("%02d:%02d:%02d", h, m, s))
    h, m, s = util.hourToTime(SunTime.set)
    util:log("Sun set at " .. string.format("%02d:%02d:%02d", h, m, s))

    BatteryCharge1Switch:init("battery-charger.lan")
    BatteryCharge1Switch:getEnergyTotal()
    util:log("Charger energy today", BatteryCharge1Switch:getEnergyToday(), "kWh")
    util:log("Charger power", BatteryCharge1Switch:getPower(), "W")

    BatteryCharge2Switch:init("battery-charger2.lan")
    BatteryCharge2Switch:getEnergyTotal()
    util:log("Charger2 energy today", BatteryCharge2Switch:getEnergyToday(), "kWh")
    util:log("Charger2 power", BatteryCharge2Switch:getPower(), "W")

    BatteryInverterSwitch:init("battery-inverter.lan")
    --util:log("toggle", BatteryInverterSwitch:toggle("off"))
    BatteryInverterSwitch:getEnergyTotal()
    util:log("Discharger energy today", BatteryInverterSwitch:getEnergyToday(), "kWh")
    util:log("Discharger power", BatteryInverterSwitch:getPower(), "W")

    GarageInverterSwitch:init("192.168.1.30")
    GarageInverterSwitch:getEnergyTotal()
    util:log("Garage inverter energy today", GarageInverterSwitch:getEnergyToday(), "kWh")
    util:log("Garage inverter power", GarageInverterSwitch:getPower(), "W")

    MopedChargeSwitch:init("moped-switch.lan")
    MopedChargeSwitch:getEnergyTotal()
    util:log("Moped energy today", MopedChargeSwitch:getEnergyToday(), "kWh")
    util:log("Moped power", MopedChargeSwitch:getPower(), "W")

    MopedInverterSwitch:init("moped-inverter.lan")
    MopedInverterSwitch:getEnergyTotal()
    util:log("Moped energy today", MopedInverterSwitch:getEnergyToday(), "kWh")
    util:log("Moped power", MopedInverterSwitch:getPower(), "W")

end

function PVBattery:idle(force)
    if not force and self:getCurrentState() == "idle" then return end
    local ret, ret_1, ret_2
    ret = BatteryInverterSwitch:toggle("off")
    util:log("discharge", ret)
    util.sleep_time(1)
    if string.lower(ret) ~= "off" then
        BatteryInverterSwitch:toggle("off")
        self.state = "error"
    end
    ret_1 = BatteryCharge1Switch:toggle("off")
    util:log("charge1", ret_1)
    ret_2 = BatteryCharge2Switch:toggle("off")
    util:log("charge2", ret_2)
    if string.lower(ret_1) ~= "off" or string.lower(ret_2) ~= "off" then
        util.sleep_time(1)
        -- try again
        BatteryCharge1Switch:toggle("off")
        BatteryCharge2Switch:toggle("off")
        self.state = "error"
        return false
    end

    self.state = "idle"
    return true
end

function PVBattery:charge(direction, force)
    direction = direction or 0

    local state, number = self:getCurrentState()
    number = number or "0"

    if not force and state == "charge" and direction == 0 then
        return
    end

    local ret = BatteryInverterSwitch:toggle("off")
    util:log("discharge", ret)
    if string.lower(ret) ~= "off" then
        self:idle()
        self.state = "error"
        return false
    end

    -- Check if all chargers are running
    if direction == 1 and number == "2" then
        return true
    end

    util.sleep_time(0.5)

    if direction == 1 and number == "0" then -- no charger running
        ret = BatteryCharge1Switch:toggle("on")
        util:log("charger1", ret)
        if string.lower(ret) ~= "on" then
            self:idle()
            self.state = "error"
            return "error"
        end
        self.state = "charge 1"
        return true
    elseif direction == 1 and number == "1" then -- one charger running
        ret = BatteryCharge2Switch:toggle("on")
        util:log("charger2", ret)
        if string.lower(ret) ~= "on" then
            self:idle()
            self.state = "error"
            return "error"
        end
        self.state = "charge 2"
        return true
    elseif direction == -1 and number == "2" then -- two chargers running
        ret = BatteryCharge2Switch:toggle("off")
        util:log("charger2", ret)
        if string.lower(ret) ~= "off" then
            self:idle()
            self.state = "error"
            return "error"
        end
        self.state = "charge 1"
        return true
    elseif direction == -1 and number == "1" then -- one charger running
        ret = BatteryCharge1Switch:toggle("off")
        util:log("charger1", ret)
        if string.lower(ret) ~= "off" then
            self:idle()
            self.state = "error"
            return "error"
        end
        self.state = "idle"
        return true
    end
end

function PVBattery:discharge(force)
    if not force and self:getCurrentState() == "discharge" then return end
    local ret, ret_1, ret_2
    ret_1 = BatteryCharge1Switch:toggle("off")
    util:log("charger1", ret_1)
    ret_2 = BatteryCharge2Switch:toggle("off")
    util:log("charger2", ret_2)

    if string.lower(ret_1) ~= "off" or string.lower(ret_2) ~= "off" then
        self:idle()
        return "error"
    end

    util.sleep_time(0.5)
    ret = BatteryInverterSwitch:toggle("on")
    util:log("discharge", ret)
    if string.lower(ret) ~= "on" then
        self:idle()
        return "error"
    end

    self.state = "discharge"
    return true
end

function PVBattery:getStateFromSwitch()
    local charge1_state = BatteryCharge1Switch:getPowerState():lower()
    local charge2_state = BatteryCharge2Switch:getPowerState():lower()
    local discharge_state = BatteryInverterSwitch:getPowerState():lower()

    util:log ("charge state", charge1_state, "charge2 state", charge2_state, "inverter_state", discharge_state)

    if charge1_state == "off" and discharge_state == "off" then
        self.state = "idle"
    elseif charge1_state == "off" and discharge_state == "on" then
        self.state = "discharge"
    elseif charge1_state == "on" and discharge_state == "off" then
        if charge2_state == "off" then
            self.state = "charge 1"
        else
            self.state = "charge 2"
        end
    elseif charge1_state == "on" and discharge_state == "on" then
        self.state = "error"
    end

    return self.state
end

function PVBattery:generateHTML(info)
    local file_descriptor

    local function writeVal(v, nl)
        if type(v) == "string" then
            file_descriptor:write(v)
        elseif type(v) == "table" then
            local text_or_link = v[1]
            if type(v[4]) == "string" then
                text_or_link = string.format('<a href="http://%s">%s</a>', v[4], v[1])
            elseif v[4] ~= nil then
                text_or_link = string.format('<a href="http://%s">%s</a>', v[4].host, v[1])
            end
            if type(v[2]) == "number" then
                file_descriptor:write(string.format("<td align=\"right\">%20s</td> <td>=</td> <td align=\"right\"> % 8.2f %s</td> ",
                        text_or_link, v[2] or "", v[3] or ""))
            else
                file_descriptor:write(string.format(" %20s %s", text_or_link, v[2] or ""))
            end
        end
        if nl then
            file_descriptor:write("\n")
        end
    end

    local header = [[
<!DOCTYPE html>
<html>
  <head>
    <title>Energy Flow</title>
    <meta http-equiv="content-type" content="text/html; charset=utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" user-scalable="yes">
    <meta http-equiv="refresh" content="10">
</head>
<body>
]]
    local footer = "</body></html>"

    -- generate main page
    file_descriptor = io.open(config.html_main, "w")
    file_descriptor:write(header)

    writeVal("<h1>Energy Flow</h1>")

    writeVal(info.time)
    writeVal("<br><br>")

    local h, m, s
    h, m, s = util.hourToTime(SunTime.rise)
    writeVal("Sun rise at " .. string.format("%02d:%02d:%02d", h, m, s))
    writeVal("<br>", true)
    h, m, s = util.hourToTime(SunTime.set)
    writeVal("Sun set at " .. string.format("%02d:%02d:%02d", h, m, s))
    writeVal("<br>", true)

    writeVal("<br><br>")

    if info.grid[2] and info.grid[2] >= 0 then
        file_descriptor:write(string.rep(" ", 10), "optain from ")
        writeVal(info.grid, true)
    end
    writeVal("<br>")

    writeVal("<table>", true)
        writeVal("<tr>")
        writeVal("<td></td> <td></td> <th> Sources </th>")
--        writeVal("<td rowspan=\"3\">Sources</td>")
        writeVal("<td width = 10%></td>")
        writeVal("<td></td> <td></td> <th> Sinks </th>")
--        writeVal("<td rowspan=\"3\">Sinks</td>")
        writeVal("</tr>", true)

        writeVal("<tr>")
            writeVal(info.roof)
            writeVal("<td>") writeVal("</td>")
        writeVal("</tr>", true)

        writeVal("<tr>")
            writeVal(info.garage_inverter)
            writeVal("<td></td>")
            writeVal(info.battery_switch_1)
        writeVal("</tr>", true)

        writeVal("<tr>")
            writeVal(info.battery_inverter)
            writeVal("<td></td>")
            writeVal(info.battery_switch_2)
        writeVal("</tr>", true)

        writeVal("<tr>")
            writeVal(info.moped_inverter)
            writeVal("<td></td>")
            writeVal(info.moped_charger)
        writeVal("</tr>", true)

        writeVal("<tr>")
            writeVal("<td>") writeVal("<hr></td>")
            writeVal("<td></td>")
            writeVal("<td>") writeVal("<hr></td>")
        writeVal("</tr>", true)

        writeVal("<tr>")
            writeVal(info.sources)
            writeVal("<td></td>")
            writeVal(info.sinks)
        writeVal("</tr>", true)

        writeVal("<tr>")
            writeVal("<td>") writeVal("</td>")
            writeVal("<td></td>")
            writeVal("<td>") writeVal("</td>")
        writeVal("</tr>", true)

    writeVal("</table><br>")
    if info.grid[2] and info.grid[2] <= 0 then
        file_descriptor:write(string.rep(" ", 10), "sell to ")
        info.grid[2] = - info.grid[2] -- just to show positive values
        writeVal(info.grid, true)
        info.grid[2] = - info.grid[2]
    end

    writeVal("<br>")
    writeVal(string.format(" % 34s = % 8.2f W\n","Consumption", info.sources[2] - info.sinks[2] + info.grid[2]))

    writeVal(string.format('<br> <a href="http://%s/battery.html">Battery</a>', config.host))

    file_descriptor:write(footer)
    file_descriptor:close()

    -- Generate battery info
    file_descriptor = io.open(config.html_battery, "w")
    file_descriptor:write(header)

    writeVal("<h1>Battery</h1>")

    writeVal(info.time)
    writeVal("<br><br>")

    if not next(AntBMS.v) then
        writeVal("Communication error. Will retry ...")
        file_descriptor:write(footer)
        file_descriptor:close()
        return
    end

    writeVal("<table>", true)
        writeVal("<tr>")
            writeVal(info.battery_SOC)
        writeVal("</tr>", true)

        writeVal("<tr>")
            writeVal(info.battery_power)
        writeVal("</tr>", true)

        writeVal("<tr>")
            writeVal(info.battery_current)
        writeVal("</tr>", true)

        writeVal("<tr>")
            writeVal("<td>")
            writeVal(info.battery_balancer)
            writeVal("</td>")
        writeVal("</tr>", true)

        writeVal("<tr>")
            writeVal("<td>")
            writeVal(info.battery_balancing)
            writeVal("</td>")
        writeVal("</tr>", true)

        writeVal("<tr>")
        local next_cell = string.format("<td>Cell difference % 6.3f V</td>", AntBMS.v.CellDiff or 0/0)
        writeVal(next_cell)
        writeVal("</tr>", true)

    writeVal("</table>", true)

    writeVal("<br><br>")

    writeVal("<table>")
    local i = 1
    while i <= AntBMS.v.NumberOfBatteries do
        writeVal("<tr>")
        local next_cell
        next_cell = string.format("<td>[%02d] % 6.3f V</td>", i, AntBMS.v.Voltage[i] or 0/0 )
        writeVal(next_cell)
        writeVal("<td></td>")
        i = i + 1
        if i > AntBMS.v.NumberOfBatteries then
            break
        end
        next_cell = string.format("<td>[%02d] % 6.3f V</td>", i, AntBMS.v.Voltage[i] or 0/0 )
        writeVal(next_cell)
        writeVal("</tr>", true)
        i = i + 1
    end
    writeVal("</table>")

    file_descriptor:write(footer)
    file_descriptor:close()
end

function PVBattery:main()
    local info = {}
    local last_date, date
    -- optain a date in the past
    date = os.date("*t")
    date.year = date.year - 1

    while true do
        local short_sleep = math.huge
        local old_state = self.state
        local _start_time = util.getCurrentTime()

        -- if config has changed, reload it
        self:readConfig()

    --    AntBMS:readAutoBalance(true)
    --    AntBMS:setAutoBalance(true)
    --    AntBMS:readAutoBalance(true)

        last_date = date
        date = os.date("*t")
        util:log("\n#############################################")
        info.time = {string.format("%d/%d/%d-%02d:%02d:%02d", date.year, date.month, date.day, date.hour, date.min, date.sec), ""}
        util:log(info.time[1])

        -- Do the sun set and rise calculations if necessary
        if last_date.day ~= date.day or last_date.isdst ~= date.isdst then
            SunTime:setDate()
            SunTime:calculateTimes()
            util:cleanLogs()
            local h, m, s
            h, m, s = util.hourToTime(SunTime.rise)
            util:log("Sun rise at " .. string.format("%02d:%02d:%02d", h, m, s))
            h, m, s = util.hourToTime(SunTime.set)
            util:log("Sun set at " .. string.format("%02d:%02d:%02d", h, m, s))
            short_sleep = 1
        end

        -- Update Fronius
        util:log("\n-------- Total Overview:")
        Fronius:getPowerFlowRealtimeData()
        local P_Grid, P_Load, P_PV = Fronius:getGridLoadPV()
        local repeat_request = math.min(20, config.sleep_time - 5)
        while not P_Grid or not P_Load or not P_PV and repeat_request > 0 do
            util:log("Communication error: repeat request:", repeat_request)
            repeat_request = repeat_request - 1
            util.sleep_time(1) -- try again in 1 second
            P_Grid, P_Load, P_PV = Fronius:getGridLoadPV()
        end
        info.grid = {"Grid", P_Grid or 0/0, "W", "192.168.0.49"}
        info.load = {"Load", P_Load or 0/0, "W", "192.168.0.49"}
        info.roof = {"Roof", P_PV or 0/0,   "W", "192.168.0.49"}
        util:log(string.format("%8s %8.2f %s", info.grid[1], info.grid[2], info.grid[3]))
        util:log(string.format("%8s %8.2f %s", info.load[1], info.load[2], info.load[3]))
        util:log(string.format("%8s %8.2f %s", info.roof[1], info.roof[2], info.roof[3]))

		-- Update BMS
        AntBMS:evaluateParameters()
        local BMS_SOC = AntBMS:getSOC()
        local BMS_SOC_MIN = math.min(BMS_SOC, AntBMS.v.CalculatedSOC)
        local BMS_SOC_MAX = math.max(BMS_SOC, AntBMS.v.CalculatedSOC)

        info.battery_SOC = {"SOC", AntBMS.v.CalculatedSOC, "%"}
        info.battery_current = {"Current", AntBMS.v.Current, "A"}
        info.battery_power = {"Current power", AntBMS.v.CurrentPower, "W"}
        info.battery_balancer = {"Balancer:", AntBMS.v.BalancedStatusText, ""}
        info.battery_balancing = {"Balancing:", AntBMS.v.ActiveBalancers, ""}

        util:log("\n-------- Battery status:")
        AntBMS:printValues()

        util:log("\n-------- Charger state:")
        util:log("Old state:", self.state)
        util:setLogNewLine(false)
        util:log("New state:\t")
        util:setLogNewLine(true)

        if AntBMS.v.LowestVoltage then
            if AntBMS.v.LowestVoltage < config.bat_lowest_voltage then
                util:log("Undervoltage in one cell, starting emergency charge!")
                self:charge(1)
            elseif BMS_SOC_MIN <= config.deep_discharge_hysteresis then
                config.deep_discharge_hysteresis = config.deep_discharge_max
                util:log("Emergency stop charge")
                self:charge(1)
            elseif config.deep_discharge_hysteresis == config.deep_discharge_max then
                config.deep_discharge_hysteresis = config.deep_discharge_min
                util:log("Stop emergency charge")
                self:idle()
            end
        else
            short_sleep = 1 -- try to read values in 1 sec
        end

        if P_Grid then
            local current_time = date.hour + date.min / 60 + date.sec / 3600

            if P_Grid < config.bat_max_feed_in * (1.00 + config.exceed_factor) then
                if BMS_SOC_MIN <= config.bat_SOC_max then
                    util:log("charge +1")
                    self:charge(1)
                elseif BMS_SOC_MIN <= 100 and current_time > SunTime.set - config.load_full_time then
                    -- Don't obey the max SOC before sun set (Balancing!).
                    util:log("charge full")
                    self:charge()
                elseif current_time > SunTime.set_civil then
                    util:log("no charge after civil dusk")
                    self:idle()
                else
                    util:log(string.format("charge stopped as battery SOC %.2f%% > %2d%%", BMS_SOC_MIN, config.bat_SOC_max))
                    self:idle()
                end
            elseif self:getCurrentState() == "charge" and P_Grid > config.bat_max_feed_in * config.exceed_factor then
                util:log("charge -1")
                self:charge(-1)
            elseif BMS_SOC_MIN < config.bat_SOC_min then
                util:log(string.format("discharge stopped as battery SOC %0.2f%% < %2d%%", BMS_SOC_MIN, config.bat_SOC_min))
                self:idle()
            elseif P_Grid > config.bat_max_take_out * (1.00 + config.exceed_factor) then
                if BMS_SOC_MAX >= config.bat_SOC_min then
                    util:log("discharge")
                    self:discharge()
                end
            elseif self:getCurrentState() == "discharge" and P_Grid < config.bat_max_take_out * config.exceed_factor then
                util:log("discharge stopped")
                self:idle()
            else
                -- keep old state
                util:log("keep " .. self.state)
            end

            if BMS_SOC > 90 then
                if not next(AntBMS.v) then
                    short_sleep = 1
                elseif -1.0 <= AntBMS.v.Current and AntBMS.v.Current <= 0.3 and AntBMS.v.CellDiff > 0.002 then
                    -- -1.0 A < Current < 0.3 A and CellDif > 0.002 V
                    util:log("turn auto balance on")
                    AntBMS:setAutoBalance(true)
                end
            end
        else
            short_sleep = 1 -- try to read values in 1 sec
        end -- if Grid

--[[
        BatteryCharge1Switch:getPowerState()
        BatteryCharge2Switch:getPowerState()
        BatteryInverterSwitch:getPowerState()
        GarageInverterSwitch:getPowerState()
        MopedChargeSwitch:getPowerState()
        MopedInverterSwitch:getPowerState()
]]

        info.battery_switch_1 = {"Battery Charger1", BatteryCharge1Switch:getPower(), "W", BatteryCharge1Switch}
        info.battery_switch_2 = {"Battery Charger2", BatteryCharge2Switch:getPower(), "W", BatteryCharge2Switch}
        info.battery_inverter = {"Battery Inverter", BatteryInverterSwitch:getPower(), "W", BatteryInverterSwitch}

        info.garage_inverter = {"Garage Inverter", GarageInverterSwitch:getPower(), "W", GarageInverterSwitch}

        info.moped_charger = {"Moped Switch", MopedChargeSwitch:getPower(), "W", MopedChargeSwitch}
        info.moped_inverter = {"Moped Inverter", MopedInverterSwitch:getPower(), "W", MopedInverterSwitch}

        local function _add(a, b)
            if b and b == b  then
                return a + b
            else
                return a
            end
        end
        info.sources = {"Total Source", 0, "W"}
        info.sources[2] = _add(info.sources[2], info.roof[2])
        info.sources[2] = _add(info.sources[2], info.battery_inverter[2])
        info.sources[2] = _add(info.sources[2], info.garage_inverter[2])
        info.sources[2] = _add(info.sources[2], info.moped_inverter[2])

        info.sinks = {"Total Sink", 0, "W"}
        info.sinks[2] = _add(info.sinks[2], info.battery_switch_1[2])
        info.sinks[2] = _add(info.sinks[2], info.battery_switch_2[2])
        info.sinks[2] = _add(info.sinks[2], info.moped_charger[2])


        self:generateHTML(info)

        util:log("\n. . . . . . . . . sleep . . . . . . . . . . . .")

        if old_state ~= self.state then
            util.sleep_time(5 - (util.getCurrentTime() - _start_time)) -- sleep only 5 seconds after a change
        else
            util.sleep_time(math.min(config.sleep_time - (util.getCurrentTime() - _start_time), short_sleep))
        end
    end -- end of inner loop
end

-------------------------------------------------------------------------------

if #arg > 2 then
    if arg[1] and arg[1] == "-c" then
        if arg[2] then
            config.config_file_name = arg[2]
        end
    end
end

PVBattery:init()
util:cleanLogs()

PVBattery:getStateFromSwitch()

util:log("Initial state:", PVBattery.state)

if PVBattery:getCurrentState() == "error" then
    util:log("ERROR: all switches were on. I have turned all switches off!")
    PVBattery:idle()
end

while true do
    PVBattery:main()
end
