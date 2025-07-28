
local config = require("configuration")
local json = require("dkjson")
local util = require("util")
local http = require("socket.http")

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
    Data = {},
    Request = {},
    timeOfLastRequiredData = {}, -- no data yet
}

function Fronius:new(o)
    o = o or {}   -- create object if user does not provide one
    setmetatable(o, self)
    self.__index = self
    return o
end

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

-- todo add a getter if neccessary
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

--[[ usage:
Fronius:GetPowerFlowRealtimeData()

print("P_Grid:", Fronius.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_Grid)
print("P_Load:", Fronius.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_Load)
print("P_PV:  ", Fronius.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_PV)
]]

return Fronius
