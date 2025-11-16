local Forecast = require("mid/Forecast")

-- Basis-URL der solarprognose.de Public API (kostenlos, mit Registrierung)
local API = "https://www.solarprognose.de/web/solarprediction/api"

local SolarPrognose = Forecast:extend{
    __name = "SolarPrognose",
}

function SolarPrognose:new(o)
    o = self:extend(o)
    if o.init then o:init() end
    return o
end

function SolarPrognose:init()
    if Forecast.init then Forecast.init(self) end
end

function SolarPrognose:generateURL(plane)
    local url = string.format(
    "%s/v1?access-token=%s&item=module_field&id=%s&type=%s",
        API, plane.token, plane.id, plane.typ
    )
    return url
end

function SolarPrognose:normalize_data(raw)
    if not raw.data then
        return nil, "Invalid API data"
    end
    local normalized = {}
    for epoch, v in pairs(raw.data) do
        local lt = os.date("%Y-%m-%d %H:%M:%S", tonumber(epoch))
        normalized[lt] = {
            power_kw = v[2],
            cumulative_kwh = v[3]
        }
    end
    return normalized
end

------------------------------------------------------------
-- Beispielverwendung
------------------------------------------------------------
local function example()
    local cfg = {
        planes = {
            {
                __name = "Dach (WR1)",
                token = "c2a2da7b09c3c2e2a20651a2223e7fa7",
                id = "14336",
                typ = "hourly",
                cachetime = 1 * 3600,
            },
            {
                __name = "Balkon (WR2)",
                token = "c2a2da7b09c3c2e2a20651a2223e7fa7",
                id = "14337",
                typ = "hourly",
                cachetime = 1*3600,
            },
        },
        cachefile = "/tmp/solarprognose_agg_total.json",
    }

    -- Erstelle den Aggregator und seine internen Solar-Instanzen
    local Prognose = SolarPrognose:new{config = cfg}

    print("Starte Aggregator Fetch (holt Daten für beide Planes)...")

    -- Fetch-Aufruf, der BEIDE API-Abrufe (oder Cache-Lesungen) ausführt und aggregiert
    local err = Prognose:fetch()

    if err then
        print("Kritischer Fehler bei Aggregation:", err)
        return
    end

    Prognose:print_latest()

    print("\n--- Zusammenfassende Werte ---")
    print(string.format("Heutiger Rest-Ertrag (ab jetzt): %.2f kWh",
            Prognose:get_remaining_daily_forecast_yield()))
end

if arg[0]:find("SolarPrognose.lua") then
    example()
end

return SolarPrognose
