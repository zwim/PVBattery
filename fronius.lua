
-- loads the HTTP module and any libraries it requires
local http = require("socket.http")

-- json module
local json = require ("dkjson")

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
}

function Fronius:GetInverterRealtimeData()
    self.url = string.format("http://%s%s%s%s", host, port, urlPath, GetInverterRealtimeData_cmd)
    --print(url)
    self.body, self.code, self.headers, self.status = http.request(self.url)
    self.Data.GetInverterRealtimeData = json.decode(self.body)
end

function Fronius:GetPowerFlowRealtimeData()
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

function Fronius:GetMeterRealtimeData()
    self.url = string.format("http://%s%s%s", host, urlPath, GetMeterRealtimeData_cmd)
    -- print(url)
    self.body, self.code, self.headers, self.status = http.request(self.url)
    -- print(body, code, headers, status)
    if self.body then
        self.Data.GetMeterRealtimeData = json.decode(self.body)
    else
        self.Data.GetMeterRealtimeData = {}
    end
end

--[[ usage:
Fronius:GetPowerFlowRealtimeData()

print("P_Grid:", Fronius.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_Grid)
print("P_Load:", Fronius.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_Load)
print("P_PV:  ", Fronius.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_PV)
]]

return Fronius