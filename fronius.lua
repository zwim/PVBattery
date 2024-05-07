
local config = require("configuration")
local json = require("dkjson")
local util = require("util")

local http = {}
if config.use_wget then
    function http.request(url)
        return util.httpRequest(url)
    end
else
    -- loads the HTTP module and any libraries it requires
    http = require("socket.http")
end

local host = "192.168.0.49"
local port = ":80"

local inverter_id = 1
local meter_id = 0
-- local version = 1 -- as of Jun 2023

local urlPath = "/solar_api/v1/"

local GetInverterRealtimeData_cmd = "GetInverterRealtimeData.cgi?Scope=Device&DeviceId=" .. inverter_id
    .. "&DataCollection=CommonInverterData"
local GetPowerFlowRealtimeData_cmd = "GetPowerFlowRealtimeData.fcgi?Scope=Device&DeviceId=" .. inverter_id
local GetMeterRealtimeData_cmd = "GetMeterRealtimeData.cgi?Scope=Device&DeviceId=" .. meter_id
    .. "&DataCollection=CommonInverterData"

local Fronius = {
    host = host,
    port = port,
    urlPath = urlPath,
    url = "",
    Data = {},
    Request = {},
    timeOfLastRequiredData = 0, -- no data yet
}

function Fronius:new(o)
    o = o or {}   -- create object if user does not provide one
    setmetatable(o, self)
    self.__index = self
    return o
end

function Fronius:getDataAge()
    return util.getCurrentTime() - self.timeOfLastRequiredData
end

function Fronius:setDataAge()
    self.timeOfLastRequiredData = util.getCurrentTime()
end

function Fronius:_get_RealtimeData(cmd)
    local url = string.format("http://%s%s%s%s", self.host, self.port, self.urlPath, cmd)
    local body, code = http.request(url)
    code = tonumber(code)
    if code and code >= 200 and code < 300 and body then
        return json.decode(body)
    else
        return {}
    end
end

function Fronius:getInverterRealtimeData()
    if self:getDataAge() < config.update_interval then return end

    self.Data.GetInverterRealtimeData = self:_get_RealtimeData(GetInverterRealtimeData_cmd)
    self:setDataAge()
end

function Fronius:getPowerFlowRealtimeData()
    if self:getDataAge() < config.update_interval then return end

    self.Data.GetPowerFlowRealtimeData = self:_get_RealtimeData(GetPowerFlowRealtimeData_cmd)
    self:setDataAge()
end

function Fronius:getMeterRealtimeData()
    if self:getDataAge() < config.update_interval then return end

    self.Data.GetMeterRealtimeData = self:_get_RealtimeData(GetMeterRealtimeData_cmd)
    self:setDataAge()
end

function Fronius:gotValidRealtimeData()
    return self.Data and self.Data.GetPowerFlowRealtimeData and self.Data.GetPowerFlowRealtimeData.Body
        and self.Data.GetPowerFlowRealtimeData.Body.Data and self.Data.GetPowerFlowRealtimeData.Body.Data.Site
end

-- todo add a getter if neccessary
function Fronius:getGridLoadPV()
    self:getPowerFlowRealtimeData()

    if self:gotValidRealtimeData() then
        return Fronius.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_Grid,
               Fronius.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_Load,
               Fronius.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_PV
    else
        return nil, nil, nil
    end
end

--[[ usage:
Fronius:GetPowerFlowRealtimeData()

print("P_Grid:", Fronius.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_Grid)
print("P_Load:", Fronius.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_Load)
print("P_PV:  ", Fronius.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_PV)
]]

return Fronius
