
local config = require("configuration")
local json = require("dkjson")
local util = require("util")
local socket = require("socket")
local http = require("socket.http")

local host = "HW-p1meter-367096.lan"
local port = "80"

local urlPath = "/api/v1/"

local GetP1meterData_cmd   = "data"

local P1meter = {
    host = host,
    port = port,
    urlPath = urlPath,
    url = "",
    Data = {},
    Request = {},
    timeOfLastRequiredData = 0, -- no data yet
}

function P1meter:new(o)
    o = o or {}   -- create object if user does not provide one
    setmetatable(o, self)
    self.__index = self
    return o
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
    if self:getDataAge(GetP1meterData_cmd) < config.update_interval then return true end
    self.Data = self:_get_data(GetP1meterData_cmd)
    self:setDataAge()
    return true
end

local client = nil
function P1meter:_get_data_coroutine(cmd)
    local path = self.urlPath .. cmd
    local err
    if not client then
        client, err = socket.connect(self.host, self.port or 80)
        if not client then
            util:log("Error opening connection to", self.host, ":", err)
            return false
        end
    end
    local x = client:send("GET " .. path .. " HTTP/1.0\r\n\r\n")
    local content = {}
    while true do
        client:settimeout(0)   -- do not block
        local s, status, partial = client:receive(2^15)
        if s then
            s = s:gsub("^.*\r\n\r\n","") -- remove header
            if s ~= "" then
                table.insert(content, s)
            end
        end
        if partial then
            partial = partial:gsub("^.*\r\n\r\n","") -- remove header
            if partial ~= "" then
                table.insert(content, partial)
            end
        end

        if status == "timeout" then
            coroutine.yield(client)
        elseif status == "closed" then
            break
        end
    end
    client:close()
    local body = table.concat(content)

    return body and json.decode(body) or {}
end

function P1meter:getData_coroutine()
    if self:getDataAge() < config.update_interval then return true end
    self.Data = self:_get_data_coroutine(GetP1meterData_cmd)
    self:setDataAge()
    return true
end

function P1meter:gotValidP1meterData()
    return self.Data.active_power_w
end

-- todo add a getter if neccessary
function P1meter:getCurrentPower()

    if self:getData() and self:gotValidP1meterData() then
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
