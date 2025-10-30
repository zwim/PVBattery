
local config = require("configuration")
local json = require("dkjson")
local util = require("util")
local http = require("socket.http")
local modbus = require("modbus")

local host = "192.168.0.49"
local port = "80"

local inverter_id = 1
local meter_id = 0
-- local version = 1 -- as of Jun 2023

local urlPath = "/solar_api/v1/"

local GetInverterRealtimeData_cmd = "GetInverterRealtimeData.cgi?Scope=Device&DeviceId=" .. inverter_id
    .. "&DataCollection=CommonInverterData"
local GetPowerFlowRealtimeData_cmd = "GetPowerFlowRealtimeData.fcgi?Scope=Device&DeviceId=" .. inverter_id
local GetMeterRealtimeData_cmd   = "GetMeterRealtimeData.cgi?Scope=Device&DeviceId=" .. meter_id
    .. "&DataCollection=CommonInverterData"

local Fronius = {
    host = host,
    port = port,
    urlPath = urlPath,
    url = "",
    socket = nil, -- tcp.socket, will be filled automatically
    Data = {},
    Request = {},
    timeOfLastRequiredData = {}, -- no data yet
}

function Fronius:extend(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Fronius:new(o)
    o = self:extend(o)
    if o.host then
        o.host = o.host:lower()
    end
    if o.init then
        o:init()
    end
    return o
end

function Fronius:init()
    -- Verbindung zu Fronius-Wechselrichter (nicht direkt zum Smart Meter!)
    self.modbus_port = self.modbus_port or 502
    self.slave_id = self.modbus_slave_id or 200  -- Standardadresse des Fronius Smart Meter
    self.ModbusInstance = modbus:new{ip = self.ip, port = self.modbus_port, slave_id = self.slave_id}
end


local registers = {}
-- registers.         = {adr = , typ = "", gain = , unit = ""}

registers.readACPower     = {adr = 40097, typ = "f32", gain = 1, unit = "W"} -- Bezug positiv, Einspeisung negativ


function Fronius:getDataAge(source)
    return util.getCurrentTime() - (self.timeOfLastRequiredData[source] or 0)
end

function Fronius:setDataAge(source)
    self.timeOfLastRequiredData[source] = util.getCurrentTime()
end

function Fronius:clearDataAge(source)
    if source then
        self.timeOfLastRequiredData[source] = 0
    else
        self.timeOfLastRequiredData = {}
    end
end

function Fronius:_get_RealtimeData(cmd)
    local url = string.format("http://%s:%s%s%s", self.host, self.port, self.urlPath, cmd)
    local body, code = http.request(url)
    code = tonumber(code)
    if code and code >= 200 and code < 300 then
        return body and json.decode(body) or {}
    else
        return {}
    end
end

function Fronius:getPowerFlowRealtimeData()
    if self:getDataAge(GetPowerFlowRealtimeData_cmd) < config.update_interval then return true end
    self.Data.GetPowerFlowRealtimeData = self:_get_RealtimeData(GetPowerFlowRealtimeData_cmd)
    self:setDataAge(GetPowerFlowRealtimeData_cmd)
    return true
end

function Fronius:getInverterRealtimeData()
    if self:getDataAge(GetInverterRealtimeData_cmd) < config.update_interval then return true end
    self.Data.GetInverterRealtimeData = self:_get_RealtimeData(GetInverterRealtimeData_cmd)
    self:setDataAge(GetInverterRealtimeData_cmd)
    return true
end

function Fronius:getMeterRealtimeData()
    if self:getDataAge(GetMeterRealtimeData_cmd) < config.update_interval then return true end
    self.Data.GetMeterRealtimeData = self:_get_RealtimeData(GetMeterRealtimeData_cmd)
    self:setDataAge(GetMeterRealtimeData_cmd)
    return true
end

function Fronius:_get_RealtimeData_coroutine(cmd)
    if not self.host or self.host == "" then
        return false
    end

    local path = self.urlPath .. cmd
    local body, err = util.http_get_coroutine(self, path, nil)
    if not body then
        util:log("[Fronius:_get_RealtimeData_coroutine] Error getting data from", self.host, ":", err)
        return false
    end
    return json.decode(body) or {}
end

function Fronius:getPowerFlowRealtimeData_coroutine()
    if self:getDataAge(GetPowerFlowRealtimeData_cmd) < config.update_interval then
        return true
    end
    self.Data.GetPowerFlowRealtimeData = self:_get_RealtimeData_coroutine(GetPowerFlowRealtimeData_cmd)
    self:setDataAge(GetPowerFlowRealtimeData_cmd)
    return true
end

function Fronius:getInverterRealtimeData_coroutine()
    if self:getDataAge(GetInverterRealtimeData_cmd) < config.update_interval then return true end
    self.Data.GetInverterRealtimeData = self:_get_RealtimeData_coroutine(GetInverterRealtimeData_cmd)
    self:setDataAge(GetInverterRealtimeData_cmd)
    return true
end

function Fronius:getMeterRealtimeData_coroutine()
    if self:getDataAge(GetMeterRealtimeData_cmd) < config.update_interval then return true end
    self.Data.GetMeterRealtimeData = self:_get_RealtimeData_coroutine(GetMeterRealtimeData_cmd)
    self:setDataAge(GetMeterRealtimeData_cmd)
    return true
end

function Fronius:gotValidPowerFlowRealtimeData()
    return self.Data and self.Data.GetPowerFlowRealtimeData and self.Data.GetPowerFlowRealtimeData.Body
        and self.Data.GetPowerFlowRealtimeData.Body.Data and self.Data.GetPowerFlowRealtimeData.Body.Data.Site
end

function Fronius:gotValidInverterRealtimeData()
    return self.Data and self.Data.GetInverterRealtimeData and self.Data.GetInverterRealtimeData.Body
        and self.Data.GetInverterRealtimeData.Body.Data.PAC
end

function Fronius:getGridLoadPV()

    if self:getPowerFlowRealtimeData() and self:gotValidPowerFlowRealtimeData() and
       self:getInverterRealtimeData() and self:gotValidInverterRealtimeData() then

        return self.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_Grid,
               self.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_Load,
               self.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_PV,
               self.Data.GetInverterRealtimeData.Body.Data.PAC.Value
    else
        return nil, nil, nil, nil
    end
end

function Fronius:getPowerModbus()
    return self.ModbusInstance:readHoldingRegisters(1, registers.readACPower),
        "Battery Power", registers.readACPower.unit
end

function Fronius:getPower()
    if self:gotValidInverterRealtimeData() then
        return self.Data.GetInverterRealtimeData.Body.Data.PAC.Value
    else
        return nil
    end
end

local function example()
    local SmartMeter = Fronius:new{ip = "192.168.0.49"}

    for i = 1, 100 do
        local power = SmartMeter:getPowerModbus()
        print("power", power)
    end

end

if arg[0]:find("fronius.lua") then
    example()
end

return Fronius
