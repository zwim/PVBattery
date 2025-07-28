
local config = require("configuration")
local json = require ("dkjson")
local socket = require("socket")
local util = require("util")

local http = require("socket.http")
http.TIMEOUT=5

local Switch = {
    socket = nil, -- tcp.socket, will be filled automatically
    host = nil,
    port = 80,
    timeOfLastRequiredData = 0, -- no data requiered yet
    max_power = 0,
}

function Switch:extend(subclass_prototype)
    local o = subclass_prototype or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Switch:new(o)
    o = self:extend(o)
    if o.init then
        o:init()
    end
    return o
end

function Switch:init()
    if not self.timeOfLastRequiredData then
        self.timeOfLastRequiredData = 0
    end
    if not self.max_power then
        self.max_power = 0
    end
end

function Switch:getDataAge()
    return util.getCurrentTime() - self.timeOfLastRequiredData
end

function Switch:setDataAge()
    self.timeOfLastRequiredData = util.getCurrentTime()
end

function Switch:clearDataAge()
    self.timeOfLastRequiredData = 0
    self.decoded = nil
end

-- Use this method for receivinge values from one switch
function Switch:_getStatus()
    if not self.host then
        return false
    end

    if self:getDataAge() < config.update_interval and self.decoded then
        return true
    end

    local url = string.format("http://%s/cm?cmnd=status%%200", self.host)
    local body, code = http.request(url)
    code = tonumber(code)
    if not code or code < 200 or code >= 300 then
        self.decoded = nil
        return false
    end
    self.decoded = body and json.decode(body) or {}

    self:setDataAge()
    return true
end

local READ_DATA_SIZE = 2048*2
-- Use this method to collect values from all switches with coroutines
function Switch:_getStatus_coroutine()
    if not self.host or self.host == "" then
        return false
    end
    if self:getDataAge() < config.update_interval and self.decoded then
        return true
    end

    local body, err = util.http_get_coroutine(self, "/cm?cmnd=status0", READ_DATA_SIZE)
    if not body then
        util:log("[Switch:_getStatus_coroutine] Error opening connection to", self.host, ":", err)
        print("[Switch:_getStatus_coroutine] Error opening connection to", self.host, ":", err)
        return false
    end

    self.decoded = json.decode(body) or {}
    self:setDataAge()
    return true
end

function Switch:getEnergyTotal()
    if not self:_getStatus() then
        return (0/0)
    end

    local Energy = self.decoded and self.decoded.StatusSNS and
        self.decoded.StatusSNS.ENERGY and self.decoded.StatusSNS.ENERGY.Total or (0/0)
    return Energy
end

function Switch:getEnergyToday()
    if not self:_getStatus() then
        return (0/0)
    end

    local Energy = self.decoded and self.decoded.StatusSNS and
        self.decoded.StatusSNS.ENERGY and self.decoded.StatusSNS.ENERGY.Today or (0/0)
    return Energy
end

function Switch:getEnergyYesterday()
    if not self:_getStatus() then
        return (0/0)
    end

    local Energy = self.decoded and self.decoded.StatusSNS and
        self.decoded.StatusSNS.ENERGY and self.decoded.StatusSNS.ENERGY.Yesterday or (0/0)
    return Energy
end

function Switch:getPower()
    if not self:_getStatus() then
        return (0/0)
    end

    local Power = self.decoded and self.decoded.StatusSNS and
        self.decoded.StatusSNS.ENERGY and self.decoded.StatusSNS.ENERGY.Power or (0/0)

    if Power and Power > 20 then
        local weight = 0.2
        self.max_power = (1-weight)*self.max_power + weight*Power
    end
    return Power
end

function Switch:getMaxPower()
    return self.max_power
end

function Switch:getPowerState()
    if not self:_getStatus() then
        return ""
    end

    if self:getDataAge() > config.update_interval then
        self:getPower() -- update max_power
    end

    local power_state = self.decoded and self.decoded.Status and self.decoded.Status.Power or ""
    if power_state == 0 or power_state == "0" or power_state:find("^0.") then
        return "off"
    elseif power_state == 1 or power_state == "1" or power_state:find("^1.") then
        return "on"
    else
        return power_state
    end
end

--- toggles switch:
-- on: 0 ... off
-- on: 1 ... on
-- on: 2 ... toggle
function Switch:toggle(on)
    if not self.host then return end

    if not on then
        on = "2"
    end
    local url = string.format("http://%s/cm?cmnd=Power0%%20%s", self.host, tostring(on))
    local _ = http.request(url)
    self:clearDataAge()
--[[
    local body, code = http.request(url)
    code = tonumber(code)
    if not code or code < 200 or code >= 300 then
        return
    end
    local decoded = body and json.decode(body) or {}
    local Result =
    if decoded then
        Result = decoded.power
    end

    self:setDataAge()
    return Result
]]
end

return Switch
