

-- loads the HTTP module and any libraries it requires
local http = require("socket.http")

-- json module
local json = require("dkjson")

local util = require("util")

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
    url = "",
    Data = {},
    Request = {},
    timeOfLastRequiredData = 0, -- no data yet
}

function Fronius:getDataAge()
    return util.getCurrentTime() - self.timeOfLastRequiredData
end

function Fronius:getInverterRealtimeData()
    self.url = string.format("http://%s%s%s%s", host, port, urlPath, GetInverterRealtimeData_cmd)
    --print(url)
    self.body, self.code, self.headers, self.status = http.request(self.url)
    self.Data.GetInverterRealtimeData = json.decode(self.body)
end

function Fronius:getPowerFlowRealtimeData()
    self.url = string.format("http://%s%s%s", host, urlPath, GetPowerFlowRealtimeData_cmd)
    -- print(url)
    self.body, self.code, self.headers, self.status = http.request(self.url)
    -- print(body, code, headers, status)
    if self.body then
        self.Data.GetPowerFlowRealtimeData = json.decode(self.body)
    else
        self.Data.GetPowerFlowRealtimeData = {}
    end
end

function Fronius:getMeterRealtimeData()
    self.url = string.format("http://%s%s%s", host, urlPath, GetMeterRealtimeData_cmd)
    -- print(url)
    self.body, self.code, self.headers, self.status = http.request(self.url)
    -- print(body, code, headers, status)
    if self.body then
        self.Data.GetMeterRealtimeData = json.decode(self.body)
    else
        self.Data.GetMeterRealtimeData = {}
    end
    self.timeOfLastRequiredData = util.getCurrentTime()
end

function Fronius:gotValidRealtimeData()
    return self.Data and self.Data.GetPowerFlowRealtimeData and self.Data.GetPowerFlowRealtimeData.Body
        and self.Data.GetPowerFlowRealtimeData.Body.Data and self.Data.GetPowerFlowRealtimeData.Body.Data.Site
end

-- todo add a getter if neccessary
function Fronius:getGridLoadPV()
    if self:getDataAge() > 1 then -- todo make this configurable
        self:getPowerFlowRealtimeData()
    end
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