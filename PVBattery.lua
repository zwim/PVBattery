
local AntBms = require("antbms")
local Fronius = require("fronius")
local SunTime = require("suntime/suntime")
local Switch = require("switch")

local lfs = require("lfs")
local util = require("util")

util:setLog("PVBattery.log")

local ChargeSwitch = Switch:new()
ChargeSwitch:init("battery-charger.lan")

ChargeSwitch:getEnergy()
util:log(ChargeSwitch.Energy.Today)
util:log(ChargeSwitch:getPower())
--util:log("toggle", ChargeSwitch:toggle("off"))

local DischargeSwitch = Switch:new()
DischargeSwitch:init("battery-inverter.lan")
--util:log("toggle", DischargeSwitch:toggle("off"))


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

    bat_max_feed_in = -320, -- Watt
    bat_max_take_out = 160, -- Watt
    exceed_factor = 0.1, -- 10%

    bat_soc_min = 20, -- Percent
    bat_soc_max = 80, -- Percent

    load_full_time = 1, -- hour before sun set

    sleep_time = 30, -- seconds to sleep per iteration

    -- add defaults here!
    -- todo
}



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
        return true
    else
        util:log("Error loading config file: " .. config.config_file_name, "Err:" .. err)
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
    local ret = DischargeSwitch:toggle("off")
    util:log("discharge", ret)
    util.sleep_time(1)
    if string.lower(ret) ~= "off" then
        DischargeSwitch:toggle("off")
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
    local ret = DischargeSwitch:toggle("off")
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
    ret = DischargeSwitch:toggle("on")
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
    local discharge_state = DischargeSwitch:getPowerState():lower()

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

    -- do the sun set and rise calculations if necessary
    last_date = date
    date = os.date("*t")
    if last_date.day ~= date.day or last_date.isdst ~= date.isdst then
        SunTime:setDate()
        SunTime:calculateTimes()
    end

    local current_time = date.hour + date.min / 60 + date.sec / 3600

    util:log("----------------------------------------------")
    util:log(os.date())

    util:log("Current state: ", PVBattery.state)
    Fronius:GetPowerFlowRealtimeData()

    local P_Grid
    if Fronius and Fronius.Data and Fronius.Data.GetPowerFlowRealtimeData and Fronius.Data.GetPowerFlowRealtimeData.Body
        and Fronius.Data.GetPowerFlowRealtimeData.Body.Data and Fronius.Data.GetPowerFlowRealtimeData.Body.Data.Site
        then

        P_Grid = Fronius.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_Grid

        util:log(string.format("P_Grid = % 8.2f W", Fronius.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_Grid))
        util:log(string.format("P_Load = % 8.2f W", Fronius.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_Load))
        util:log(string.format("P_PV   = % 8.2f W", Fronius.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_PV))

    else
        util:log("ERROR P_GRID")
        P_Grid = nil
    end

    AntBms:evaluateParameters()
    AntBms:printValues()

    local Bms_Soc = AntBms:getSoc()

    if P_Grid then
        if P_Grid < config.bat_max_feed_in  then
            if Bms_Soc <= config.bat_soc_max then
                util:log("charge")
                PVBattery:charge()
            elseif Bms_Soc <= 100 and current_time > SunTime.set - config.load_full_time then
                -- Don't obey the max soc one hour before sun set.
                util:log("charge full")
                PVBattery:charge()
            elseif current_time > SunTime.set_civil then
                util:log("no charge after civil dusk")
                PVBattery:idle()
            else
                util:log("charge stopped as battery SOC=" .. Bms_Soc .. "%")
                PVBattery:idle()
            end
        elseif PVBattery.state == "charge" and P_Grid >  0 then
            util:log("charge stopped")
            PVBattery:idle()
        elseif P_Grid > config.bat_max_take_out  then
            if Bms_Soc >= config.bat_soc_min then
                util:log("discharge")
                PVBattery:discharge()
            else
                util:log("discharge stopped as battery SOC=" .. Bms_Soc .. "%")
                PVBattery:idle()
            end
        elseif PVBattery.state == "discharge" and P_Grid < 0 then
            util:log("discharge stopped")
            PVBattery:idle()
        else
            -- keep old state
            util:log("stay")
        end
    end

    util.sleep_time(config.sleep_time)
end
