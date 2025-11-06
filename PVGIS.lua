-- Benötigte Bibliotheken
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")

-- ######################################################################
-- 🛠️ HILFSFUNKTIONEN
-- ######################################################################

-- Funktion zum Parsen der Kommandozeilen-Argumente
local function parse_args(args)
    local params = {}
    for i = 1, #args do
        -- Sucht nach dem Format --parameter=wert
        local key, value = args[i]:match("^%-%-(.-)=(.+)$")
        if key and value then
            -- Speichert den Wert, konvertiert zu Zahl, wenn möglich
            params[key] = tonumber(value) or value
        end
    end
    return params
end

-- Funktion zur Überprüfung, ob alle notwendigen Parameter vorhanden sind
local function check_params(params)
    local required = {"latitude", "longitude", "angle", "aspect"}
    for _, req in ipairs(required) do
        if params[req] == nil then
            io.stderr:write("❌ FEHLER: Fehlender Parameter --" .. req .. ". Alle Parameter sind notwendig.\n")
            return false
        end
    end
    return true
end

-- ######################################################################
-- ⚙️ KONFIGURATION & STANDARDWERTE
-- ######################################################################

local PVGIS_DEFAULTS = {
    altitude = 0,     -- Höhe über dem Meeresspiegel (PVGIS verwendet automatisch die Gitterzellenhöhe)
    peakpower = 1000, -- Nennleistung für die Berechnung (1 kWp)
    loss = 14,        -- Systemverluste in % (Standardwert)
    raddatabase = "PVGIS-SARAH2" -- Datensatz für Europa
}

-- Die vom Benutzer übergebenen Argumente parsen
local user_args = parse_args({...})

if not check_params(user_args) then
    io.stderr:write("\nNutzung: lua pvgis_cli_download.lua --latitude=... --longitude=... --angle=... --aspect=... [--altitude=...]\n")
    os.exit(1)
end

-- Konfiguration zusammenführen: Benutzer-Input überschreibt Standards
local CONFIG = {}
for k, v in pairs(PVGIS_DEFAULTS) do CONFIG[k] = v end
for k, v in pairs(user_args) do CONFIG[k] = v end

-- ######################################################################
-- 🚀 HAUPT-LOGIK
-- ######################################################################

local base_url = "https://re.jrc.ec.europa.eu/api/v5_2/seriescalc?"
local output_format = "json"

local filename = string.format("solar_%s_%s_%s.json",
    CONFIG.latitude, CONFIG.longitude, os.date("%Y%m%d_%H%M%S"))

print("\n--- PVGIS CLI Downloader ---")
print(string.format("Starte Abruf für: Lat %.3f, Lon %.3f | Neigung %d°, Azimut %d°",
    CONFIG.latitude, CONFIG.longitude, CONFIG.angle, CONFIG.aspect))

-- Die Abfrage-URL zusammenbauen
local query_url = string.format(
    "%slat=%.3f&lon=%.3f&pvcalculation=1&peakpower=%d&pvtech=c-Si&mountingplace=free&loss=%.1f&angle=%d&aspect=%d&outputformat=%s&browser=0&startyear=2005&endyear=2020&raddatabase=%s",
    base_url,
    CONFIG.latitude, CONFIG.longitude,
    CONFIG.peakpower,
    CONFIG.loss,
    CONFIG.angle, CONFIG.aspect,
    output_format,
    CONFIG.raddatabase
)

print("\nURL (gekürzt): " .. string.sub(query_url, 1, 120) .. "...")

-- Daten abrufen (HTTP GET Request)
local body = {}
local res, code, headers, status = http.request{
    url = query_url,
    sink = ltn12.sink.table(body)
}

-- Überprüfung des Download-Erfolgs
if res and code == 200 then
    local content = table.concat(body)

    local file = io.open(filename, "w")
    if file then
        file:write(content)
        file:close()
        print("\n✅ Download erfolgreich!")
        print("Datei gespeichert: " .. filename)

        -- Extrahiere und zeige den Jahresertrag (zur schnellen Validierung)
        local data = json.decode(content)
        if data and data.outputs and data.outputs.totals then
             local annual_sum = data.outputs.totals.fixed.kWh_y
             local specific_yield = annual_sum / (CONFIG.peakpower / 1000)
             print(string.format("   -> Avg. Jahresertrag: %.1f kWh/kWp", specific_yield))
        end
        print("---------------------------------------------------------")
        os.exit(0) -- Erfolg
    else
        io.stderr:write("\n❌ FEHLER: Konnte die Datei nicht speichern. Prüfen Sie die Zugriffsrechte.\n")
        os.exit(1)
    end
else
    io.stderr:write(string.format("\n❌ FEHLER beim API-Aufruf. HTTP-Status: %s\n", tostring(code)))
    io.stderr:write("Stellen Sie sicher, dass die Koordinaten gültig sind und die Verbindung besteht.\n")
    os.exit(1)
end