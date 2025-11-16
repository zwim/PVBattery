
local config = require("configuration")
local json = require("dkjson")
local http = require("socket.http")
local util = require("base/util")

local host = "HW-p1meter-367096.lan"
local port = "80"

local urlPath = "/api/v1/"

local GetP1meterData_cmd   = "data"

local P1meter = {
    host = host,
    port = port,
    urlPath = urlPath,
    socket = nil, -- tcp.socket, will be filled automatically
    url = "",
    Data = {},
    Request = {},
    timeOfLastRequiredData = 0, -- no data yet
    Last = {
        active_power = nil,
        total_power_import_t1_kwh = nil,
        total_power_import_t2_kwh = nil,
        active_voltage_l1_v = nil,
        active_current_l1_a = nil,
        active_current_l2_a = nil,
        active_current_l3_a = nil,
    },
}

function P1meter:new(o)
    o = o or {}   -- create object if user does not provide one
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Vergleichsfunktion: prüft, ob relevante Werte neu sind
function P1meter:is_data_new()
    if not self.Last.active_power and self.Data.power then
        return true
    end

    local is_equal = util.tables_equal_flat(self.Data, self.Last)

    if not is_equal then
        self.Last = self.Data
        return true
    else
        return false
    end
end

function P1meter:getDataAge()
    return util.getCurrentTime() - (self.timeOfLastRequiredData or 0)
end

function P1meter:setDataAge()
    self.timeOfLastRequiredData = util.getCurrentTime()
end

function P1meter:clearDataAge()
    self.timeOfLastRequiredData = 0
end

function P1meter:_get_data(cmd)
    local url = string.format("http://%s:%s%s%s", self.host, self.port, self.urlPath, cmd)
    local body, code = http.request(url)
    code = tonumber(code)
    if code and code >= 200 and code < 300 then
        return body and json.decode(body) or {}
    else
        return {}
    end
end

function P1meter:getData()
    if self:getDataAge(GetP1meterData_cmd) < config.update_interval then
        return
    end
    self.Data = self:_get_data(GetP1meterData_cmd)

    self:setDataAge()
end

function P1meter:gotValidP1meterData()
    return self.Data.active_power_w ~= nil
end

-- todo add a getter if neccessary
function P1meter:getCurrentPower()
    self:getData()
    if self:gotValidP1meterData() then
        return self.Data.active_power_w
    else
        return nil
    end
end

--[[ usage:
P1meter:GetPowerFlowRealtimeData()

print("P_Grid:", P1meter.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_Grid)
print("P_Load:", P1meter.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_Load)
print("P_PV:  ", P1meter.Data.GetPowerFlowRealtimeData.Body.Data.Site.P_PV)
]]

return P1meter
