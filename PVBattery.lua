
local AntBMS = require("antbms")
local Fronius = require("fronius")
local SunTime = require("suntime/suntime")
local Switch = require("switch")

local lfs = require("lfs")
local util = require("util")

util:setLog("PVBattery.log")

local ChargeSwitch = Switch:new()
ChargeSwitch:init("battery-charger.lan")
ChargeSwitch:getEnergy()
util:log("Charger", ChargeSwitch.Energy.Today)
util:log("Charger", ChargeSwitch:getPower())

local ChargeSwitch2 = Switch:new()
ChargeSwitch2:init("battery-charger2.lan")
ChargeSwitch2:getEnergy()
util:log("Charger2", ChargeSwitch2.Energy.Today)
util:log("Charger2", ChargeSwitch2:getPower())

--util:log("toggle", ChargeSwitch:toggle("off"))

local DischargerSwitch = Switch:new()
DischargerSwitch:init("battery-inverter.lan")
--util:log("toggle", DischargerSwitch:toggle("off"))
DischargerSwitch:getEnergy()
util:log("Discharger", DischargerSwitch.Energy.Today)
util:log("Discharger", DischargerSwitch:getPower())

local PVBattery = {
    state = "", -- idle, charge, discharge, error
}

local config = {
    -- don't touch these
    config_file_name = "config.lua",
    config_file_date = 1689399515, -- 20230715090000
    -- changeable
    position = {
        name = "Kirchbichl",
        latitude = 47.5109083,
        longitude = 12.0855866,
        altitude = 520,
        timezone = nil,
    },

    bat_max_feed_in = -350, -- Watt
    bat_max_feed_in2 = -350, -- Watt
    bat_max_take_out = 160, -- Watt
    exceed_factor = -0.1, -- Shift the bat_max_xxx values by -10%

    bat_SOC_min = 20, -- Percent
    bat_SOC_max = 80, -- Percent

    load_full_time = 1, -- hour before sun set

    sleep_time = 30, -- seconds to sleep per iteration

    guard_time = 5 * 60 -- 5 minutes
    -- add defaults here!
    -- todo
}

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
        -- no need to reload
        return true
    end

    chunk, err = loadfile(file, "t", config)

    if chunk then
        -- save new config values
        chunk()
        config.config_file_date = config_time
        self.validConfig = true
        return true
    else
        util:log("Error loading config file: " .. config.config_file_name, "Err:" .. err)
        self.validConfig = false
    end
    return false
end

function PVBattery:init()
    self:readConfig()

    local position = config.position
    SunTime:setPosition(position.name, position.latitude, position.longitude, position.timezone, position.height, true)

    SunTime:setDate()
    SunTime:calculateTimes()

    util:log("Sun set at " .. SunTime.set)
end

function PVBattery:idle(force)
    if not force and self.state == "idle" then return end
    local ret = DischargerSwitch:toggle("off")
    util:log("discharge", ret)
    util.sleep_time(1)
    if string.lower(ret) ~= "off" then
        DischargerSwitch:toggle("off")
        self.state = "error"
    end
    ret = ChargeSwitch:toggle("off")
    util:log("charge", ret)
    if string.lower(ret) ~= "off" then
        util.sleep_time(1)
        ChargeSwitch:toggle("off")
        self.state = "error"
        return false
    end

    self.state = "idle"
    return true
end

function PVBattery:charge(force)
    if not force and self.state == "charge" then return end
    local ret = DischargerSwitch:toggle("off")
    util:log("discharge", ret)
    if string.lower(ret) ~= "off" then
        self:idle()
        self.state = "error"
        return false
    end
    util.sleep_time(0.5)
    ret = ChargeSwitch:toggle("on")
    util:log("charger", ret)
    if string.lower(ret) ~= "on" then
        self:idle()
        self.state = "error"
        return "error"
    end

    self.state = "charge"
    return true
end

function PVBattery:discharge(force)
    if not force and self.state == "discharge" then return end
    local ret = ChargeSwitch:toggle("off")
    util:log("charger", ret)
    if string.lower(ret) ~= "off" then
        self:idle()
        return "error"
    end
    util.sleep_time(0.5)
    ret = DischargerSwitch:toggle("on")
    util:log("discharge", ret)
    if string.lower(ret) ~= "on" then
        self:idle()
        return "error"
    end

    self.state = "discharge"
    return true
end

function PVBattery:getStateFromSwitch()
    local charge_state = ChargeSwitch:getPowerState():lower()
    local discharge_state = DischargerSwitch:getPowerState():lower()

    if charge_state == "off" and discharge_state == "off" then
        self.state = "idle"
    elseif charge_state == "off" and discharge_state == "on" then
        self.state = "discharge"
    elseif charge_state == "on" and discharge_state == "off" then
        self.state = "charge"
    elseif charge_state == "off" and discharge_state == "on" then
        self.state = "error"
    end

    util:log ("charge state", charge_state, "inverter_state", discharge_state)
    return self.state
end

PVBattery:init()
util:cleanLogs()

PVBattery:getStateFromSwitch()

util:log("Initial state: ", PVBattery.state)

if PVBattery.state == "error" then
    util:log("ERROR: all switches were on. I have turned all switches off!")
    PVBattery:idle()
end

local last_date, date
date = os.date("*t")
while true do
    -- if config has changed, reload it
    PVBattery:readConfig()

--    AntBMS:readAutoBalance(true)
--    AntBMS:setAutoBalance(true)
--    AntBMS:readAutoBalance(true)

    -- do the sun set and rise calculations if necessary
    last_date = date
    date = os.date("*t")
    if last_date.day ~= date.day or last_date.isdst ~= date.isdst then
        SunTime:setDate()
        SunTime:calculateTimes()
        PVBattery:cleanLogs()
    end

    local current_time = date.hour + date.min / 60 + date.sec / 3600

    util:log("\n#############################################")
    util:log(os.date())

    -- Update BMS, Inverter, Fronius ...
    Fronius:getPowerFlowRealtimeData()
    -- no need to call AntBMS:evaluateParameters() here, as it gets updated on every getter function if neccessary
--    AntBMS:evaluateParameters()

    local P_Grid, P_Load, P_PV = Fronius:getGridLoadPV()
    util:log(P_Grid and string.format("P_Grid = % 8.2f W", P_Grid) or "P_Grid: no valid data")
    util:log(P_Load and string.format("P_Load = % 8.2f W", P_Load) or "P_Load: no valid data")
    util:log(P_PV   and string.format("P_PV   = % 8.2f W", P_PV)   or "P_PV: no valid data")

    util:log("Old state:", PVBattery.state)

    local BMS_SOC = AntBMS:getSOC()
    local BMS_SOC_MIN = math.floor(math.min(BMS_SOC, AntBMS.v.CalculatedSOC) * 100) *.01
    local BMS_SOC_MAX = math.floor(math.max(BMS_SOC, AntBMS.v.CalculatedSOC) * 100) * 0.01
    util:log(BMS_SOC and string.format("Battery SOC = %3d %%", BMS_SOC) or "SOC: no valid data")

    util:setLogNewLine(false)
    util:log("New state:\t")
    util:setLogNewLine(true)

    if P_Grid then
        if P_Grid < config.bat_max_feed_in * (1.00 + config.exceed_factor) then
            if BMS_SOC_MIN <= config.bat_SOC_max then
                util:log("charge")
                PVBattery:charge()
            elseif BMS_SOC_MIN <= 100 and current_time > SunTime.set - config.load_full_time then
                -- Don't obey the max SOC before sun set (Balancing!).
                util:log("charge full")
                PVBattery:charge()
            elseif current_time > SunTime.set_civil then
                util:log("no charge after civil dusk")
                PVBattery:idle()
            else
                util:log("charge stopped as battery SOC=" .. BMS_SOC_MIN .. "% > " .. config.bat_SOC_max .. " %")
                PVBattery:idle()
            end
        elseif PVBattery.state == "charge" and P_Grid > config.bat_max_feed_in * config.exceed_factor then
            util:log("charge stopped")
            PVBattery:idle()
        elseif BMS_SOC_MAX < config.bat_SOC_min then
            util:log("discharge stopped as battery SOC=" .. BMS_SOC_MAX .. "% < " .. config.bat_SOC_min .. " %")
            PVBattery:idle()
        elseif P_Grid > config.bat_max_take_out * (1.00 + config.exceed_factor) then
            if BMS_SOC_MAX >= config.bat_SOC_min then
                util:log("discharge")
                PVBattery:discharge()
            end
        elseif PVBattery.state == "discharge" and P_Grid < config.bat_max_take_out * config.exceed_factor then
            util:log("discharge stopped")
            PVBattery:idle()
        else
            -- keep old state
            util:log("keep " .. PVBattery.state)
        end

        if PVBattery.state == "charge"  and BMS_SOC > 90 then
            if AntBMS.v.Current < 0 and AntBMS.v.Current > -1.0 then
                util:log("turn auto balance on")
                AntBMS:setAutoBalance(true)
            end
        end
    end

    util:log("\n-------- Battery Status:")
    AntBMS:printValues()

    util.sleep_time(config.sleep_time)
end
