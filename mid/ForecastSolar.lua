local Forecast = require("mid/Forecast")
local util = require("base/util")

-- Basis-URL der forecast.solar Public API (kostenlos)
local API = "https://api.forecast.solar/estimate/"

local ForecastSolar = Forecast:extend{
    __name = "ForecastSolar",
}

function ForecastSolar:new(o)
    o = self:extend(o)
    if o.init then o:init() end
    return o
end

function ForecastSolar:init()
    if Forecast.init then Forecast.init(self) end
end

function ForecastSolar:generateURL(plane)
    local url = string.format("%s%f/%f/%d/%d/%f",
        API, plane.latitude, plane.longitude, plane.declination, plane.azimuth, plane.kwp
    )
    return url
end

function ForecastSolar:normalize_data(raw)
    if not raw.result or not raw.result.watts then
        return nil, "Invalid API data"
    end

    local out = {}
    for utc_ts, watts in pairs(raw.result.watts) do
        local lt = util:utc_to_local(utc_ts)
        out[lt] = {
            power_kw = watts / 1000,
        }
    end

    -- kumulativ berechnen
    local arr = {}
    for ts,v in pairs(out) do
        table.insert(arr, {ts=ts, pw=v.power_kw})
    end
    table.sort(arr, function(a,b) return a.ts < b.ts end)

    return out
end

local function example()
    -- Annahme: Dein Standort (Kirchbichl)
    local LAT = 47.5758 -- Beispiel Breitengrad
    local LON = 12.1153 -- Beispiel Längengrad

    local cfg = {
        -- Hier definierst du ALLE deine PV-Flächen.
        planes = {
            {
                name = "Dach",
                latitude = LAT,
                longitude = LON,
                declination = 30,
                azimuth = -45,
                kwp = 7.6,
            },
            {
                name = "Balkon",
                latitude = LAT,
                longitude = LON,
                declination = 85,
                azimuth = 90,
                kwp = 1.6,
            },
            -- Optional: Mehr Flächen hinzufügen
        },
        cachefile = "/tmp/forecast_solar_agg_total.json",
        cachetime = 1 * 3600, -- 1 Stunde
    }

    -- Erster Abruf (echter Fetch)
    local Prognose = ForecastSolar:new{config = cfg}

    local ok, err = Prognose:fetch()
    if not ok then
        print("Kritischer Fehler beim zweiten Fetch:", err)
        return
    end

    Prognose:print_latest()

    print("\n--- Zusammenfassende Werte ---")
    print(string.format("Heutiger Rest-Ertrag (ab jetzt): %.2f kWh",
            Prognose:get_remaining_daily_forecast_yield()))
end

-- Führe die Beispiel-Funktion aus, wenn das Skript direkt gestartet wird
if arg[0]:find("ForecastSolar.lua") then
    example()
end

return ForecastSolar
