local http = require("socket.http")
local ltn12 = require("ltn12")
local url = require("socket.url")

local influx = {
    influx_url,
    api_token,
    headers
    }

function influx:init(url, token, org, bucket)
    if not url or not token or not org or not bucket then
        return
    end

    -- url: http://localhost:8086
    -- InfluxDB 2.x Konfiguration
    self.influx_url = string.format("%s/api/v2/write?org=%s&bucket=%s", url, org, bucket)
    self.api_token = token

    -- HTTP-Header
    self.headers = {
        ["Authorization"] = "Token " .. self.api_token,
        ["Content-Type"] = "text/plain; charset=utf-8",
        ["Accept"] = "application/json"
    }
end

function influx:writeLine(device, datum, value)
    if not self.api_token then
        return
    end
    -- check for nan
    if value ~= value or value == nil then
        return
    end
    if type(value) == "string" then
        value = "\""..value.."\""
    end
    -- create a line like:    "moped-charger,datum=leistung value=12"
    local line_protocol_data = string.format("%s,datum=%s value=%s", device, datum, value)

    local response_body = {}
    local request_body = line_protocol_data

    local _, status_code = http.request{
        url = self.influx_url,
        method = "POST",
        headers = self.headers,
        source = ltn12.source.string(request_body),
        sink = ltn12.sink.table(response_body)
    }

    if status_code ~= 204 then
        -- Antwort ausgeben
        print("Status Code:", status_code)
        print("Response Body:", table.concat(response_body))
    end
end

return influx
