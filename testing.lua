module("L_PhilipsHue2", package.seeall)

local dkjson = require("dkjson")
local socket = require("socket")
local http = require("socket.http")
local ltn12 = require("ltn12")
local log = luup.log
local params = {
    mode = "client",
	protocol = "tlsv1",
    verify = {"none"},
	options = {"no_compression"},
	ciphers = "ALL",
}

-- Flags
local DEBUG_MODE = false
local FAILED_STATUS_REPORT = true
local FLAGS = {
	LAMPS = false,
	BRIDGE = false,
	HANDLE_GROUPS = false
}

-- Constants
local DEVICE_FILES = {
	MOTION_SENSOR      = "D_MotionSensor1.xml"
}

local DEVICE_TYPES = {
	BINARY_LIGHT       = "urn:schemas-upnp-org:device:BinaryLight:1",
}

local SID = {
	HUE    		= "urn:micasaverde-com:serviceId:PhilipsHue1",
	SWP 		= "urn:upnp-org:serviceId:SwitchPower1",
	DIM			= "urn:upnp-org:serviceId:Dimming1"
}

local TASK = {
	ERROR       = 2,
	ERROR_ALARM = -2,
	ERROR_STOP  = -4,
	SUCCESS     = 4,
	BUSY        = 1
}
-- LastUpdate
local DISPLAY_SECONDS = 20
local POLLING_RATE = 7 -- 30 --"PollFrequency"

-- Globals
local lug_device = nil
local g_appendPtr -- The pointer passed to luup.chdev.append
local g_taskHandle = -1
local g_lastTask = os.time() -- The time when the status message was last updated.
local g_ipAddress = ""
local g_UUID = nil
local g_hueURL = ""
local g_username  = "testuser"
local g_lastState = ""
local g_lampNumber = 0
local g_groupNumber = 0
local g_sceneNumber = 0
local g_lamps = {

}
local g_groups = {
	-- .id
	-- .name
	-- ... 
}
local g_scenes = {
	-- .id
	-- .name
	-- ... 
}

local LANGUAGE_TOKENS = {
	["fr"] = {
		["Please press the link button on the Bridge and hit the Pair button again!"] = "Veuillez appuyer sur le bouton lien localisé sur le pont et cliquez a nouveau sur le bouton 'associer avec le pont'!",
		["Philips Hue Connected!"] = "Philips Hue est connecté!",
		["Philips Hue Disconnected!"] = "Philips Hue est déconnecté!",
		["Connection with the Bridge could not be established! Check IP or the wired connection!"] = "La connexion de pont n'a pas été établie! Veuillez vérifier l'adresse IP ou la connexion par câble!",
		["IP address could not be automatically set! Please add it in IP field, save and reload the engine!"] = "L'adresse IP ne peut pas être initialisée automatiquement! Veuillez l'ajouter dans le champ IP et appuyer sur le bouton 'sauvegarder le numéro d'IP'!",
		["Startup successful!"] = "Démarrage réussi",
		["Startup ERROR : Connection with the Bridge could not be established!"] = "Luup ERROR : La connexion de pont n'a pas été établie!",
		["Philips Hue Bridge has been discovered!"] = "Philips Hue a été découvert!",
		["Philips Hue Bridge could not be found!"] = "Philips Hue n'a pas été trouvé!",
		["Linking ERROR occurred: "] = "Une erreur de liaison est survenue:",
		["Starting up..."] = "Démarrage ..."
	},
	["en"] = {
		["Please press the link button on the Bridge and hit the Pair button again!"] = "Please press the link button on the Bridge and hit the Pair button again!",
		["Philips Hue Connected!"] = "Philips Hue Connected!",
		["Philips Hue Disconnected!"] = "Philips Hue Disconnected!",
		["Connection with the Bridge could not be established! Check IP or the wired connection!"] = "Connection with the Bridge could not be established! Check IP or the wired connection!",
		["IP address could not be automatically set! Please add it in IP field, save and reload the engine!"] = "IP address could not be automatically set! Please add it in IP field and click on 'Save' button!",
		["Startup successful!"] = "Startup successful!",
		["Startup ERROR : Connection with the Bridge could not be established!"] = "Startup ERROR : Connection with the Bridge could not be established!",
		["Philips Hue Bridge has been discovered!"] = "Philips Hue Bridge has been discovered!",
		["Philips Hue Bridge could not be found!"] = "Philips Hue Bridge could not be found!",
		["Linking ERROR occurred: "] = "Linking ERROR occurred: ",
		["Starting up..."] = "Starting up..."
	}
	
}
local lug_language
---------------------------------------------------------
-----------------Generic Utils---------------------------
---------------------------------------------------------
local function debug (text)
--	if (DEBUG_MODE == true) then
		log(text)
--	end
end

function clearTask()
	if (os.time() - g_lastTask >= DISPLAY_SECONDS) then
		if lug_language == "fr" then
			luup.task("Effancer...", TASK.SUCCESS, "Philips Hue", g_taskHandle)
		else
			luup.task("Clearing...", TASK.SUCCESS, "Philips Hue", g_taskHandle)
		end
	end
	debug("(Hue2 Plugin)::(clearTask) : Clearing task... ")
end

local function displayMessage (text, mode)
	if LANGUAGE_TOKENS[lug_language] and LANGUAGE_TOKENS[lug_language][text] then
		text = LANGUAGE_TOKENS[lug_language][text]
	end
	
	if mode == TASK.ERROR_ALARM or mode == TASK.ERROR_STOP then
		luup.task(text, TASK.ERROR, "Philips Hue", g_taskHandle)
		if mode == TASK.ERROR_STOP then
			luup.set_failure(1, lug_device)
		end
		return
	end
	luup.task(text, mode, "Philips Hue", g_taskHandle)
	-- Set message timeout.
	g_lastTask = os.time()
	luup.call_delay("clearTask", DISPLAY_SECONDS)
end

local function GetLanguage()
	local file = io.open("/etc/cmh/language")
	if file then
		local language = file:read("*a")
		file:close()
		language = language:match("%a+")
		debug("(Hue2 Plugin)::(GetLanguage) : Got language: ".. language)
		return language
	else
		debug("(Hue2 Plugin)::(GetLanguage) : Cannot open /etc/cmh/language, returning default language!")
		return "en"
	end
end

local function UrlEncode (s)
	s = s:gsub("\n", "\r\n")
	s = s:gsub("([^%w])", function (c)
							  return string.format("%%%02X", string.byte(c))
						  end)
	return s
end

local function DEC_HEX(IN)
	return string.format("%02X",IN) or "00"
end

function round(x)
	return math.floor(x+0.5)
end

local function clamp(x,min,max)
	if x < min then
        return round(min)
	end
	if x > max then
		return round(max)
	end
	return round(x)
end

local function mirekToKelvin(value)
	local mirek = 6500-(value-153)*12.9682997118
	return mirek
end

local function convertColorTemperatureToHex(colortemperature)
	local kelvin = 6500 - (colortemperature - 153) * 12.9682997118
	local temp = kelvin / 100
    local red, green, blue
	if temp <= 66 then
		red = 255
		green = temp
		green = 99.4708025861 * math.log(green) - 161.1195681661
		if temp <= 19 then
			blue = 0
		else
			blue = temp - 10
			blue = 138.5177312231 * math.log(blue) - 305.0447927307
		end
    else
		red = temp - 60
		red = 329.698727446 * math.pow(red, -0.1332047592)
		green = temp - 60
		green = 288.1221695283 * math.pow(green, -0.0755148492)
		blue = 255
    end
	return "#" .. DEC_HEX(clamp(red, 0, 255)) .. DEC_HEX(clamp(green, 0, 255)) .. DEC_HEX(clamp(blue, 0, 255))
end

local function HueToRgb(p,q,t)
	if t < 0 then
		t = t + 1
	elseif t > 1 then
		t = t - 1
	end
	if t < 1/6 then
		return p + (q - p) * 6 * t
	elseif t < 1/2 then
		return q;
	elseif t < 2/3 then
		return p + (q - p) * (2/3 - t) * 6
	end
	return p
end

local function convertHslToHex(h,s)
	local l = 0.7 - (s - 200 ) * 0.0036363636363
	local r,g,b
	h = h/65535
	s = s/255
	if s == 0 then
		r = 1
		g = 1
		b = 1
	else
		local q
		if l < 0.5 then
			q = l * (1 + s)
		else
			q = l + s - l * s
		end

		local p = 2 * l - q
		r = HueToRgb(p, q, h + 1/3)
		g = HueToRgb(p, q, h)
		b = HueToRgb(p, q, h - 1/3)
	end
	return "#" .. DEC_HEX(clamp(round(r * 255),0,255)) .. DEC_HEX(clamp(round(g * 255),0,255)) .. DEC_HEX(clamp(round(b * 255),0,255))
end
---------------------------------------------------------
---------------Action Implementations--------------------
---------------------------------------------------------
function bridgeConnect(lul_device)
	log("(Hue2 Plugin)::(bridgeConnect) : Linking with the Bridge device - lug_device = "..(lug_device or "NIL"))
	local deviceType = "Vera" .. luup.pk_accesspoint 
	local jsondata = { devicetype = deviceType}
    local postdata = dkjson.encode(jsondata)
    local body, status, headers = http.request(g_hueURL, postdata)
    local json_response = dkjson.decode(body)
	
	local linkError = false
    local otherError = false
    local errorDescription = ""
	
	for key, value in pairs(json_response) do
		if value.error ~= nil then
			if value.error.type == 101 then 
				linkError = true
				break
			else
				otherError = true
				errorDescription = value.error.description
				break
			end
		end
		if value.success then
			local username = value.success.username
			luup.attr_set("username", username, lug_device)
			break
		end
    end
	 	
	if linkError then
		luup.variable_set(SID.HUE, "Status", LANGUAGE_TOKENS[lug_language]["Please press the link button on the Bridge and hit the Pair button again!"], lug_device)
		luup.variable_set(SID.HUE, "BridgeLink", "0", lug_device)
		displayMessage("Please press the link button on the Bridge and hit the Pair button again!", TASK.BUSY)
		log( "(Hue2 Plugin)::(bridgeConnect) : Please press the link button on the Bridge and hit the Pair button again!" )
	elseif otherError then
		luup.variable_set(SID.HUE, "Status", LANGUAGE_TOKENS[lug_language]["Linking ERROR occurred: "] .. errorDescription , lug_device)
		log( "(Hue2 Plugin)::(bridgeConnect) : Linking ERROR occurred: " .. errorDescription )
	else
		local bridgeLink = luup.variable_get(SID.HUE, "BridgeLink", lug_device) or ""
		if bridgeLink == "0" then
			luup.variable_set(SID.HUE, "BridgeLink", "1", lug_device)
			luup.reload()
		end
		luup.variable_set(SID.HUE, "Status",LANGUAGE_TOKENS[lug_language]["Philips Hue Connected!"], lug_device)
		displayMessage("Philips Hue Connected!", TASK.BUSY)
		log( "(Hue2 Plugin)::(bridgeConnect) : Philips Hue Connected!" )
	end
end

local function getIconVal(colormode, value)
	if colormode == "hs" or colormode == "xy" then
		if value >= 0 and value <= 3900 then
			return "R"
		elseif value > 3900 and value <= 8500 then
			return "O"
		elseif value > 8500 and value <= 13700 then
			return "Y"
		elseif value > 13700 and value <= 29500 then
			return "G"
		elseif value > 29500 and value <= 34700 then
			return "C"
		elseif value > 34700 and value <= 47500 then
			return "B"
		elseif value > 47500 and value <= 49100 then
			return "V"
		elseif value > 49100 and value <= 62250 then
			return "M"
		elseif value > 62250 and value <= 65535 then
			return "R"
		else
			return "W"
		end
	elseif colormode == "ct" then
		if value > 0 and value <= 300 then
			return "ABB"
		elseif value > 300 and value <= 350 then
			return "ABW"
		elseif value >350 and value <= 500 then
			return "ABY"
		else
			return "ABW"
		end
	else
		return "ABW"
	end
end

function setLoadLevelTarget(lul_settings, device)
	local newLoadlevelTarget
	if lul_settings.newTargetValue then
		if tonumber(lul_settings.newTargetValue) > 0 then
			newLoadlevelTarget = "100"
		else
			newLoadlevelTarget = "0"
		end
	elseif lul_settings.newLoadlevelTarget then
		newLoadlevelTarget = lul_settings.newLoadlevelTarget
	else
		debug("(Hue2 Plugin)::(setLoadLevelTarget) : We shouldn't be here!!!")
		return false
	end
	-- Philips Hue Color Temperatures
	local colors = {
		energize = {hue = 34495, sat = 232, ct = 155, name = 'Energize'},
		concentrate = {hue = 33849, sat = 44, ct = 234, name = 'Concentrate'},
		reading = {hue = 15331, sat = 121, ct = 343, name = 'Reading'},
		warm = {hue = 14563, sat = 160, ct = 385, name = 'Warm'},
		natural = {hue = 15223, sat = 127, ct = 349, name = 'Natural'},
		relax = {hue = 13198, sat = 209, ct = 463, name = 'Relax'},
	}
	-- Check for UI7 All On/Off Command
	if lul_settings.Category then
		local isGroupOnOff = false
			for k,v in pairs(g_groups) do
				if tonumber(v.veraid) == device then
				isGroupOnOff = true
			end
		end
		if tonumber(lul_settings.Category) == 999 and isGroupOnOff == false then
			if tonumber(lul_settings.newTargetValue) > 0 then
				newLoadlevelTarget = 50
				--setColorTemperature(colors.relax.ct, device)
			else
				newLoadlevelTarget = 0
			end
		else
			debug("(Hue2 Plugin)::(setLoadLevelTarget) : Group is not affected by All On/Off command, returning ...")
			return false
		end
	end
	
	luup.variable_set(SID.DIM, "LoadLevelStatus", newLoadlevelTarget, device)
	luup.variable_set(SID.DIM, "LoadLevelTarget", newLoadlevelTarget, device)
	if tonumber(newLoadlevelTarget) > 0 then
		luup.variable_set(SID.SWP, "Status", "1", device)
	else
		luup.variable_set(SID.SWP, "Status", "0", device)
	end
	local brightness = math.floor(tonumber(newLoadlevelTarget) * 254 / 100 + 0.5)
	
	local lampID = ""
	local isGroup = false
	for key, val in pairs(g_lamps) do
		if tonumber(val.veraid) == device then
			lampID = val.hueid
		end
	end
	
	if lampID == "" then
		for key, val in pairs(g_groups) do
			if tonumber(val.veraid) == device then
				lampID = val.hueid
				isGroup = true
			end
		end
	end	
	if tostring(newLoadlevelTarget) == "0" then
		if isGroup then
			if setLampValues(lampID, "group", "on", false, "bri", brightness) then
				return true
			else
				return false
			end
		else
			if setLampValues(lampID, "light", "on", false, "bri", brightness) then 
				return true
			else
				return false
			end
		end
	else
		if isGroup then
			if setLampValues(lampID, "group", "on", true, "bri", brightness) then
				return true
			else 
				return false
			end
		else
			if setLampValues(lampID, "light", "on", true, "bri", brightness) then
				return true
			else
				return false
			end
		end
	end
end

function turnOffLamp(lamp)
	setLampValues(lamp, "light", "on", false)
end

function setStateForAll(state, device)
	local data = {}
	if state == "0" then
		data["on"] = false
	elseif state == "1" then
		data["on"] = true
	else
		debug("(Hue2 Plugin)::(setStateForAll) : We shouldn't be here!")
		return false
	end
	local senddata = dkjson.encode(data)
	local body = putToHue(senddata, 0, "group")
	local json = dkjson.decode(body)
	local flagError = false
	for key, value in pairs(json) do
		if (value.error ~= nil) then
			debug( "(Hue2 Plugin)::(setStateForAll) : Setting state for all bulbs ERROR occurred : " .. value.error.type .. " with description : " .. value.error.description)
			flagError = true
		end
    end
	
	if flagError == false then
		debug("(Hue2 Plugin)::(setStateForAll) : Successfully changed state for all hue bulbs!")
		luup.variable_set(SID.HUE, "StateForAll", state, device)
		return true
	else
		log("(Hue2 Plugin)::(setStateForAll) : Please check error/s above!")
		return false
	end
end
function setHueAndSaturation(hue, saturation, device)
	debug("(Hue2 Plugin)::(setHueAndSaturation) : Starting...")
	local lampID = ""
	local on_val
	local isGroup = false
	for key, val in pairs(g_lamps) do
		if tonumber(val.veraid) == device then
			lampID = val.hueid
			on_val = val.on
		end
	end
	if lampID == "" then
		for key, val in pairs(g_groups) do
			if tonumber(val.veraid) == device then
				lampID = val.hueid
				on_val = val.on
				isGroup = true
			end
		end
	end
	local value = "hue:".. hue .. ";sat:" .. saturation
	luup.variable_set(SID.HUE, "LampValues", value, device)
	luup.variable_set(SID.HUE, "LampHexValue", convertHslToHex(hue,saturation), device)
	
	debug("(Hue2 Plugin)::(setHueAndSaturation) : on_val = ".. tostring(on_val))
	if on_val then
		if isGroup then
			if setLampValues(lampID, "group", "hue", tonumber(hue), "sat", tonumber(saturation)) then
				return true
			else
				return false
			end
		else
			if setLampValues(lampID, "light", "hue", tonumber(hue), "sat", tonumber(saturation)) then
				return true
			else
				return false
			end
		end
	else
		if isGroup then
			if setLampValues(lampID, "group", "on", true, "hue", tonumber(hue), "sat", tonumber(saturation)) then 
				return true
			else
				return false
			end
		else
			if setLampValues(lampID, "light", "on", true, "hue", tonumber(hue), "sat", tonumber(saturation)) then
				return true
			else
				return false
			end
		end
		--luup.call_delay( "turnOffLamp", 5, lampID)
	end
end

function setColorTemperature(colortemperature, device)
	debug("(Hue2 Plugin)::(setColorTemperature) : CT = " .. colortemperature)
	local lampID = ""
	local on_val
	local isGroup = false
	for key, val in pairs(g_lamps) do
		if tonumber(val.veraid) == device then
			lampID = val.hueid
			on_val = val.on
		end
	end
	if lampID == "" then
		for key, val in pairs(g_groups) do
			if tonumber(val.veraid) == device then
				lampID = val.hueid
				on_val = val.on
				isGroup = true
			end
		end
	end
 	luup.variable_set(SID.HUE, "LampValues", "ct:" .. colortemperature, device)
	luup.variable_set(SID.HUE, "LampHexValue", convertColorTemperatureToHex(colortemperature), device)
	debug("(Hue2 Plugin)::(setColorTemperature) : on_val = ".. tostring(on_val))
	if on_val then
		if isGroup then
			if setLampValues(lampID, "group", "ct", tonumber(colortemperature)) then 
				return true
			else
				return false
			end
		else
			if setLampValues(lampID, "light", "ct", tonumber(colortemperature)) then
				return true
			else
				return false
			end
		end
	else
		if isGroup then
			if setLampValues(lampID, "group", "on", true, "ct", tonumber(colortemperature)) then
				return true
			else
				return false
			end
		else
			if setLampValues(lampID, "light", "on", true, "ct", tonumber(colortemperature)) then
				return true
			else
				return false
			end	
		end
		--luup.call_delay( "turnOffLamp", 5, lampID)
	end
end

function putToHue(data, hueid, hueStructure)
    debug("Hue2 Plugin)::(putToHue):data=" .. data)
    local len = string.len(data)
	local URL = ""
	if hueStructure == "group" then 
		URL = g_hueURL .. "/" .. g_username .. "/groups/" .. hueid .. "/action"
	elseif hueStructure == "light" then
		URL = g_hueURL .. "/" .. g_username .. "/lights/" .. hueid .. "/state"
	elseif hueStructure == "scene" then
		URL = g_hueURL .. "/" .. g_username .. "/scenes/" .. hueid
	elseif hueStructure == "Mscene" then
		local sceneName = hueid:match("^(.*),")
		local lightID = hueid:match(",(.*)$")
		URL = g_hueURL .. "/" .. g_username .. "/scenes/" .. sceneName .. "/lights/" .. lightID .. "/state"
	end
	
    local bodyparts = { }
    local x, status, headers = http.request {
      url = URL,
      headers = {["content-length"] = len},
      source = ltn12.source.string(data),
      sink = ltn12.sink.table(bodyparts),
      method = "PUT"
    }
    local body = table.concat(bodyparts)
    return body
end

function setLampValues(light_id, hueStructure, ...)
	local lampID = tonumber(light_id, 10)
	local deviceID
	local arg = {...}
	if #arg % 2 ~= 0 then 
		log( "(Hue2 Plugin)::(setLampValues) : ERROR : Wrong number of arguments!")
		return false
	end
	local data = {}
	for i = 1,#arg,2  do
		data[arg[i]] = arg[i+1]
	end

	if hueStructure == "group" then
		deviceID = g_groups[lampID].veraid
	else
		deviceID = g_lamps[lampID].veraid
	end
	
	for key,val in pairs(data) do
		if key == "bri" then
			if val == 0 then
				data[key] = 1
				if hueStructure == "group" then
					g_groups[lampID].bri = 1
				elseif hueStructure == "light" then
					g_lamps[lampID].bri = 1
				end
			end
		end
		if key == "hue" then
			local iconVal = getIconVal("hs", val)
			if hueStructure == "group" then
				luup.variable_set(SID.HUE, "IconValue", iconVal, g_groups[lampID].veraid)
			else
				luup.variable_set(SID.HUE, "IconValue", iconVal, g_lamps[lampID].veraid)
			end
		end
		if key == "ct" then
			local iconVal = getIconVal("ct", val)
			if hueStructure == "group" then
				luup.variable_set(SID.HUE, "IconValue", iconVal, g_groups[lampID].veraid)
			else
				luup.variable_set(SID.HUE, "IconValue", iconVal, g_lamps[lampID].veraid)
			end
		end
	end
	
    local senddata = dkjson.encode(data)
	local body = putToHue(senddata, light_id, hueStructure)
	local json = dkjson.decode(body)
	
	local flagError = false
	
	for key, value in pairs(json) do
		if (value.error ~= nil) then
			log( "(Hue2 Plugin)::(setLampValues) : Changing lamp/group status ERROR occurred : " .. value.error.type .. " with description : " .. value.error.description)
			flagError = true
		end
    end
	
	if flagError == false then
		debug("(Hue2 Plugin)::(setLampValues) : Successfully changed lamp/group status for device " .. deviceID .. " !")
		return true
	else
		log("(Hue2 Plugin)::(setLampValues) : Please check error/s above!")
		return false
	end
end

local function getLightName(light_id)
	for k,v in pairs(g_lamps) do
		if tostring(v.hueid) == tostring(light_id) then
			return v.name .. "," .. v.veraid
		end
	end
end

local function getGroupLights(group_hue_id)
	local groupLights = ""
	for key,val in pairs(g_groups) do
		if val.hueid == group_hue_id then
			for k,v in pairs(val.lights) do
				groupLights = groupLights .. v .. "," .. getLightName(v) .. ";"
			end
		end
	end
	return groupLights:sub(1,#groupLights - 1)
end

local function appendLamps()
	debug("(Hue2 Plugin)::(appendLamps) : Verifying... ")
	local count = 0
	for i, v in pairs(g_lamps) do
		debug("(Hue2 Plugin)::(appendLamps) : Appending Lamp ".. i ..".")
luup.log("appendLamps: processing type["..(v.huetype or "NIL").."] manufacturer ["..(v.manufacturer or "NIL").."] model ["..(v.modelid or "NIL").."]")
		if v.manufacturer == 'philips' then
			if v.huetype == "Dimmable light" then
				luup.chdev.append(lug_device, g_appendPtr, "hueLamp_"..v.hueid, "HueLux ".. v.hueid ..": ".. v.name, "urn:schemas-micasaverde-com:device:PhilipsHueLuxLamp:1", "D_PhilipsHueLuxLamp2.xml", nil, "urn:micasaverde-com:serviceId:PhilipsHue1,BulbModelID=" .. v.modelid .. "\nurn:upnp-org:serviceId:Dimming1,TurnOnBeforeDim=0", false)
				count = count + 1
			else
				luup.chdev.append(lug_device, g_appendPtr, "hueLamp_"..v.hueid, "HueLamp ".. v.hueid ..": ".. v.name, "urn:schemas-micasaverde-com:device:PhilipsHueLamp:1", "D_PhilipsHueLamp2.xml", nil, "urn:micasaverde-com:serviceId:PhilipsHue1,BulbModelID=" .. v.modelid .. "\nurn:upnp-org:serviceId:Dimming1,TurnOnBeforeDim=0", false)
				count = count + 1
			end
		elseif v.manufacturer == 'cree' then
			if v.modelid == "Connected" then
				luup.chdev.append(lug_device, g_appendPtr, "hueLamp_"..v.hueid, "CreeConnected ".. v.hueid ..": ".. v.name, "urn:schemas-micasaverde-com:device:PhilipsHueLuxLamp:1", "D_PhilipsHueLuxLamp2.xml", nil, "urn:micasaverde-com:serviceId:PhilipsHue1,BulbModelID=" .. v.modelid .. "\nurn:upnp-org:serviceId:Dimming1,TurnOnBeforeDim=0", false)
				count = count + 1
			end
		end
		
		if count > 80 then
			debug("(Hue2 Plugin)::(appendLamps) : Possible error in generating lamps function, more then 80 devices were generated!!!")
			return
		end
	end
end

local function appendGroups()
	debug("(Hue2 Plugin)::(appendGroups) : Verifying... ")
	if #g_groups > 0 then
		local count = 0
		for i, v in pairs(g_groups) do
			if v.huetype == "LightGroup" then
				debug("(Hue2 Plugin)::(appendGroups) : Appending Group ".. i ..".")
				groupType = "NLG"
				luup.chdev.append(lug_device, g_appendPtr, "hueGroup_".. v.hueid, "HueGroup ".. v.hueid ..": ".. v.name, "urn:schemas-micasaverde-com:device:PhilipsHueMultisourceLuminaireLamp:1", "D_PhilipsHueMultisourceLuminaireLamp2.xml", nil, "urn:micasaverde-com:serviceId:PhilipsHue1,GroupType=NLG\nurn:upnp-org:serviceId:Dimming1,TurnOnBeforeDim=0", false)
				count = count + 1
--				debug("(Hue2 Plugin)::(appendGroups) : Not handled!")
			elseif v.huetype == "Luminaire" then
				debug("(Hue2 Plugin)::(appendGroups) : Appending Luminaire Group ".. i ..".")
				local GroupType = ""
				if v.modelid == "HML001" or v.modelid == "HML002" or v.modelid == "HML003" or v.modelid == "HML007" then 
					GroupType = "CTM"
				else
					GroupType = "CLM"
				end
				local services = "urn:micasaverde-com:serviceId:PhilipsHue1,GroupType=" .. GroupType .. "\nurn:micasaverde-com:serviceId:PhilipsHue1,BulbModelID=" .. v.modelid  .. "\nurn:upnp-org:serviceId:Dimming1,TurnOnBeforeDim=0"
				luup.chdev.append(lug_device, g_appendPtr, "hueGroup_".. v.hueid, "HueLuminaire ".. v.hueid ..": ".. v.name, "urn:schemas-micasaverde-com:device:PhilipsHueMultisourceLuminaireLamp:1", "D_PhilipsHueMultisourceLuminaireLamp2.xml", nil, services, false)
				count = count + 1
			end
			if count > 50 then
				debug("(Hue2 Plugin)::(appendGroups) : Possible error in generating lamps function, more then 50 devices were generated!!!")
				return
			end
		end
	else
		debug("(Hue2 Plugin)::(appendGroups) : No supported groups found!")
	end
end
---------------------------------------------------------
---------------Initialization Functions------------------
---------------------------------------------------------
local function getChildDevices(device)
	for dev, attr in pairs(luup.devices) do
		if (attr.device_num_parent == device) then
			local LampNo = attr.id:match("^hueLamp_(%d+)")
			if LampNo then
				for k,v in pairs(g_lamps) do
					if LampNo == tostring(v.hueid) then
						g_lamps[tonumber(v.hueid)].veraid = dev
					end
				end
			end
			local GroupNo = attr.id:match("^hueGroup_(%d+)")
			if GroupNo then
				for k,v in pairs(g_groups) do
					if GroupNo == tostring(v.hueid) then
						g_groups[tonumber(v.hueid)].veraid = dev
					end
				end
			end
		end
	end
end

local function findBridge()
	-- Try to get the bridge IP via nupnp
	log("(Hue2 Plugin)::(findBridge) : Trying to get IP via NUPNP...")
	local https = require("ssl.https")
	local content, status = https.request("https://www.meethue.com/api/nupnp")
--	local status, content = luup.inet.wget("https://www.meethue.com/api/nupnp")
	if content then
		uuid = content:match("\"id\":\"(.-)\"")
		ipAddress = content:match("\"internalipaddress\":\"(.-)\"")
		if ipAddress then
			log("(Hue2 Plugin)::(findBridge) : (NUPNP) : Philips Hue Bridge found with IP address: " .. ipAddress)
			g_ipAddress = ipAddress
			g_UUID = uuid
			luup.variable_set(SID.HUE, "UUID", g_UUID, lug_device)
			luup.attr_set("ip", g_ipAddress, lug_device)
			luup.variable_set(SID.HUE, "Status", LANGUAGE_TOKENS[lug_language]["Philips Hue Bridge has been discovered!"], lug_device)
			FLAGS.BRIDGE = true
			return true
		else
			log("(Hue2 Plugin)::(findBridge) : (NUPNP) : Philips Hue Bridge could not be found!")
			luup.variable_set(SID.HUE, "Status", LANGUAGE_TOKENS[lug_language]["Philips Hue Bridge could not be found!"], lug_device)
			FLAGS.BRIDGE = false
			return false
		end
	else
		log("(Hue2 Plugin)::(findBridge) : Philips Hue Bridge could not be found!")
		luup.variable_set(SID.HUE, "Status", LANGUAGE_TOKENS[lug_language]["Philips Hue Bridge could not be found!"], lug_device)
		FLAGS.BRIDGE = false
		return false
	end
end

local function getLength(var)
	local i = 0
	for k,v in pairs(var) do
		i = i + 1
	end
	return i
end

local function getDevices(json)
	local length = 0
	-- Get LampS Info
	if json.lights then
		length = getLength(json.lights)
		if length > 0 then
			g_lampNumber = length
			for key, val in pairs(json.lights) do
				local k = tonumber(key)
				local manufacturer = "philips"
				if val.manufacturername then
					local manufacturer = string.gsub(string.lower(val.manufacturername), '%s+', '')
				end
				if manufacturer == "philips" then
					if val.type == "Dimmable light" then
						g_lamps[k] = {}
						g_lamps[k].manufacturer = manufacturer
						g_lamps[k].hueid = key
						g_lamps[k].on = val.state.on
						g_lamps[k].bri = val.state.bri or 0
						g_lamps[k].huetype = val.type
						g_lamps[k].name = val.name
						g_lamps[k].modelid = val.modelid
						g_lamps[k].reachable = val.state.reachable or false
					else
						g_lamps[k] = {}
						g_lamps[k].manufacturer = manufacturer
						g_lamps[k].hueid = key
						g_lamps[k].on = val.state.on
						g_lamps[k].bri = val.state.bri or 0
						if val.state.hue then g_lamps[k].hue = val.state.hue or 0 end
						if val.state.sat then g_lamps[k].sat = val.state.sat or 0 end
						if val.state.xy[1] then g_lamps[k].x = val.state.xy[1] or 0 end
						if val.state.xy[2] then g_lamps[k].y = val.state.xy[2] or 0 end
						if val.state.ct then g_lamps[k].ct = val.state.ct or 0 end
						if val.state.colormode then g_lamps[k].colormode = val.state.colormode or "hs" end
						g_lamps[k].huetype = val.type
						g_lamps[k].name = val.name
						g_lamps[k].modelid = val.modelid
						g_lamps[k].uniqueid = val.uniqueid
						g_lamps[k].swversion = val.swversion
					end
				elseif manufacturer == "cree" or manufacturer == "ge_appliances" then
					if val.type == "Dimmable light" then
						g_lamps[k] = {}
						g_lamps[k].manufacturer = manufacturer
						g_lamps[k].hueid = key
						g_lamps[k].on = val.state.on
						g_lamps[k].bri = val.state.bri or 0
						g_lamps[k].huetype = val.type
						g_lamps[k].name = val.name
						g_lamps[k].modelid = val.modelid
						g_lamps[k].reachable = val.state.reachable or false
					else
						g_lamps[k] = {}
						g_lamps[k].manufacturer = manufacturer
						g_lamps[k].hueid = key
						g_lamps[k].on = val.state.on
						g_lamps[k].bri = val.state.bri or 0
						if val.state.hue then g_lamps[k].hue = val.state.hue or 0 end
						if val.state.sat then g_lamps[k].sat = val.state.sat or 0 end
						if val.state.xy[1] then g_lamps[k].x = val.state.xy[1] or 0 end
						if val.state.xy[2] then g_lamps[k].y = val.state.xy[2] or 0 end
						if val.state.ct then g_lamps[k].ct = val.state.ct or 0 end
						if val.state.colormode then g_lamps[k].colormode = val.state.colormode or "hs" end
						g_lamps[k].huetype = val.type
						g_lamps[k].name = val.name
						g_lamps[k].modelid = val.modelid
						g_lamps[k].uniqueid = val.uniqueid
						g_lamps[k].swversion = val.swversion
					end
				end
			end
			debug("(Hue2 Plugin)::(getDevices) : Lights values saved!")
		else
			debug("(Hue2 Plugin)::(getDevices) : There are no lights set on the Bridge!")
		end
	else
		debug("(Hue2 Plugin)::(getDevices) : Possible error, 'lights' tag is not there!")
	end
	-- Get Groups Info
	length = 0
	if json.groups then
		length = getLength(json.groups)
		if length > 0 then
			g_groupNumber = length
			for key, val in pairs(json.groups) do
				if val.type and ((val.type == "Luminaire") or (val.type == "LightGroup")) then
					local k = tonumber(key) 
					g_groups[k] = {}
					g_groups[k].lights = {}
					g_groups[k].hueid = key
					g_groups[k].name = val.name
					for i = 1,getLength(val.lights) do
						g_groups[k].lights[i] = val.lights[i]
					end
					g_groups[k].huetype = val.type
					if val.modelid then g_groups[k].modelid = val.modelid end
					g_groups[k].on = val.action.on
					g_groups[k].bri = val.action.bri or 0
					if val.action.hue then g_groups[k].hue = val.action.hue or 0 end
					if val.action.sat then g_groups[k].sat = val.action.sat or 0 end
					if val.action.xy then g_groups[k].x = val.action.xy[1] end
					if val.action.xy then g_groups[k].y = val.action.xy[2] end
					if val.action.effect then g_groups[k].effect = val.action.effect end
					if val.action.ct then g_groups[k].ct = val.action.ct or 0 end
					if val.action.alert then g_groups[k].alert = val.action.alert or "none" end
					if val.action.colormode then g_groups[k].colormode = val.action.colormode or "hs" end
				end
			end
			if #g_groups > 0 then
				debug("(Hue2 Plugin)::(getDevices) : Groups values saved!")
			end
		else
			debug("(Hue2 Plugin)::(getDevices) : There are no groups set on the Bridge!")
		end
	else
		debug("(Hue2 Plugin)::(getDevices) : Possible error, 'groups' tag is not there!")
	end
	-- Get Scenes Info
	local bridgeScenes = {}
	length = 0
	if json.scenes then
		length = getLength(json.scenes)
		if length > 0 then
			g_sceneNumber = length
			for key, val in pairs(json.scenes) do
				local k = key
				g_scenes[k] = {}
				g_scenes[k].sceneID = key
				g_scenes[k].lights = {}
				g_scenes[k].name = val.name
				for i = 1,getLength(val.lights) do
					g_scenes[k].lights[i] = val.lights[i]
				end
				g_scenes[k].active = val.active
				-- update scenes json for web and mobile
				bridgeScenes[k] = {}
				bridgeScenes[k].name = val.name:match("(.+)%s+o[nf]+ %d*") or val.name:match("(.+)")
				bridgeScenes[k].lights = {}
				for i = 1,getLength(val.lights) do
					bridgeScenes[k].lights[i] = val.lights[i]
				end
				bridgeScenes[k].active = val.active				
			end
			debug("(Hue2 Plugin)::(getDevices) : Scenes values saved!")
		else
			debug("(Hue2 Plugin)::(getDevices) : There are no Scenes set on the Bridge!")
		end
	else
		debug("(Hue2 Plugin)::(getDevices) : Possible error, 'scenes' tag is not there!")
	end
	local scenejson = dkjson.encode(bridgeScenes)
	luup.variable_set(SID.HUE, "BridgeScenes", scenejson, lug_device)
end

function pollHueDevice(pollType)
	local onLightsNumber = 0 
	if pollType == "true" then
		debug("(Hue2 Plugin)::(pollHueDevice) : Action poll performed!")
	else
		debug("(Hue2 Plugin)::(pollHueDevice) : Normal poll performed!")
	end
	local length = 0
	local url = g_hueURL .. "/" .. g_username
	local body, status, headers = http.request(url)
	if status == 200 then
		if FAILED_STATUS_REPORT then
			local getFailedStatus = luup.variable_get("urn:micasaverde-com:serviceId:HaDevice1", "CommFailure", lug_device) or ""
			if getFailedStatus == "1" then
				luup.set_failure(0, lug_device)
				luup.variable_set(SID.HUE, "Status",LANGUAGE_TOKENS[lug_language]["Philips Hue Connected!"] , lug_device)
				luup.variable_set(SID.HUE, "BridgeLink", "1" , lug_device)
				displayMessage("Philips Hue Connected!", TASK.BUSY)
				for k,v in pairs(g_lamps) do
					if v.veraid then
						luup.set_failure(0, v.veraid)
					end
				end
				for k,v in pairs(g_groups) do
					if v.veraid then
						luup.set_failure(0, v.veraid)
					end
				end
				--luup.reload()
			end
		end
		local thisStatus = {}
		local json = dkjson.decode(body)
		
		if json.lights then
			length = getLength(json.lights)
			if length > 0 then
				if g_lampNumber ~= length then
					debug("(Hue2 Plugin)::(pollHueDevice) : Lights number have been changed, reloading engine in order to apply the changes!")
					luup.reload()
				end
				for key, val in pairs(json.lights) do
					local k = tonumber(key)
					thisStatus[k] = {}
					thisStatus[k].hueid = key
					thisStatus[k].on = val.state.on
					thisStatus[k].bri = val.state.bri
					thisStatus[k].reachable = val.state.reachable
					if val.type ~= "Dimmable light" then
						thisStatus[k].hue = val.state.hue
						thisStatus[k].sat = val.state.sat
						thisStatus[k].x = val.state.xy[1]
						thisStatus[k].y = val.state.xy[2]
						if val.state.ct then thisStatus[k].ct = val.state.ct or 0 end
						thisStatus[k].colormode = val.state.colormode
					end
				end
			else
				luup.variable_set(SID.HUE, "BridgeFavoriteScenes", "", lug_device)
				luup.variable_set(SID.HUE, "ActionListScenes", "", lug_device)
				luup.variable_set(SID.HUE, "BridgeLights", "", lug_device)
				g_lampNumber = 0
				debug("(Hue2 Plugin)::(pollHueDevice) : Polling the Bridge Device : There are no lights set on the Bridge!")
			end
		else
			debug("(Hue2 Plugin)::(pollHueDevice) : Polling the Bridge Device : Possible error, 'lights' tag is not there!")
		end
		
		for key, val in pairs(thisStatus) do
			if val.hueid == g_lamps[key].hueid then
				if val.type == "Dimmable light" then
					if val.on ~= g_lamps[key].on or val.bri ~= g_lamps[key].bri then
						g_lamps[key].on = val.on
						g_lamps[key].bri = val.bri
					end
				else
					if val.on ~= g_lamps[key].on or val.bri ~= g_lamps[key].bri or val.hue ~= g_lamps[key].hue or val.sat ~= g_lamps[key].sat or val.x ~= g_lamps[key].x or val.y ~= g_lamps[key].y or val.colormode ~= g_lamps[key].colormode or val.reachable ~= g_lamps[key].reachable then	
						g_lamps[key].on = val.on
						g_lamps[key].bri = val.bri
						g_lamps[key].hue = val.hue
						g_lamps[key].sat = val.sat
						g_lamps[key].x = val.x
						g_lamps[key].y = val.y
						g_lamps[key].colormode = val.colormode
						g_lamps[key].reachable = val.reachable
					end
					if val.type ~= "Color light" then
						if val.ct ~= g_lamps[key].ct then
							g_lamps[key].ct = val.ct
						end
					end
				end
			end
		end
		for key, value in pairs(g_lamps) do
			local lampDimStatus = luup.variable_get(SID.DIM, "LoadLevelStatus", tonumber(value.veraid)) or ""
			if value.on then
				onLightsNumber = onLightsNumber + 1
				if lampDimStatus ~= "" then
					local updateVal = math.floor(value.bri / 254 * 100 + 0.5)
					if value.bri == 1 then 
						updateVal = 1
					end
					if updateVal ~= tonumber(lampDimStatus) then
						luup.variable_set(SID.DIM, "LoadLevelStatus", updateVal, tonumber(value.veraid))
						luup.variable_set(SID.DIM, "LoadLevelTarget", updateVal, tonumber(value.veraid))
						luup.variable_set(SID.SWP, "Status", "1", tonumber(value.veraid))
						debug("(Hue2 Plugin)::(pollHueDevice) : Lamp[" .. value.hueid .. "] ON - UI Updated!")
					else
						debug("(Hue2 Plugin)::(pollHueDevice) : Lamp[" .. value.hueid .. "] ON - No UI update needed!")
					end
				else
					local updateVal = math.floor(value.bri / 254 * 100 + 0.5)
					if value.bri == 1 then 
						updateVal = 1
					end
					luup.variable_set(SID.DIM, "LoadLevelStatus", updateVal, tonumber(value.veraid))
					luup.variable_set(SID.DIM, "LoadLevelTarget", updateVal, tonumber(value.veraid))
					luup.variable_set(SID.SWP, "Status", "1", tonumber(value.veraid))
					debug("(Hue2 Plugin)::(pollHueDevice) : Lamp[" .. value.hueid .. "] ON - UI Updated!")
				end
			else
				if lampDimStatus == "" then
					luup.variable_set(SID.DIM, "LoadLevelStatus", "0", tonumber(value.veraid))
					luup.variable_set(SID.DIM, "LoadLevelTarget", "0", tonumber(value.veraid))
					luup.variable_set(SID.SWP, "Status", "0", tonumber(value.veraid))
					debug("(Hue2 Plugin)::(pollHueDevice) : Lamp[" .. value.hueid .. "] OFF - UI Updated!")
				elseif lampDimStatus ~= "0" then
					debug("(Hue2 Plugin)::(pollHueDevice) : Lamp[" .. value.hueid .. "] OFF - Value set to 0!")
					luup.variable_set(SID.DIM, "LoadLevelStatus", "0", tonumber(value.veraid))
					luup.variable_set(SID.DIM, "LoadLevelTarget", "0", tonumber(value.veraid))
					luup.variable_set(SID.SWP, "Status", "0", tonumber(value.veraid))
					debug("(Hue2 Plugin)::(pollHueDevice) : Lamp[" .. value.hueid .. "] OFF - UI Updated!")
				else
					debug("(Hue2 Plugin)::(pollHueDevice) : Lamp[" .. value.hueid .. "] OFF - No UI update needed!")
				end
			end
			-- update AllOn/Off button status
			local stateAll = luup.variable_get(SID.HUE, "StateForAll", lug_device) or "0"
			if onLightsNumber > 0 then 
				if stateAll == "0" then
					luup.variable_set(SID.HUE, "StateForAll", "1", lug_device)
				end
			else
				if stateAll == "1" then
					luup.variable_set(SID.HUE, "StateForAll", "0", lug_device)
				end
			end
			if value.huetype ~= "Dimmable light" then
				local iconColorOnLamp = luup.variable_get(SID.HUE, "IconValue", value.veraid) or ""
				local LampValuesOnLamp = luup.variable_get(SID.HUE, "LampValues", value.veraid) or ""
				local iconNow
				local hue,sat,ct
				local LampValuesNow
				local LampHexValueNow
				if value.colormode == "hs" or value.colormode == "xy" then
					iconNow = getIconVal(value.colormode, value.hue)
					LampValuesNow = "hue:".. value.hue .. ";sat:" .. value.sat
					LampHexValueNow = convertHslToHex(value.hue,value.sat)
				else
					iconNow = getIconVal(value.colormode, value.ct)
					LampValuesNow = "ct:" .. value.ct
					LampHexValueNow = convertColorTemperatureToHex(value.ct)
				end
				if iconColorOnLamp ~= iconNow then
					luup.variable_set(SID.HUE, "IconValue", iconNow, value.veraid)
				end
				if LampValuesOnLamp ~= LampValuesNow then
					luup.variable_set(SID.HUE, "LampValues", LampValuesNow, value.veraid)
					luup.variable_set(SID.HUE, "LampHexValue", LampHexValueNow, value.veraid)
				end
			end
			-- update lamp failure
			if FAILED_STATUS_REPORT then	
				local getLampFailedStatus = luup.variable_get("urn:micasaverde-com:serviceId:HaDevice1", "CommFailure", value.veraid) or ""
				if value.reachable then
					if getLampFailedStatus ~= "0" then
						luup.set_failure(0, value.veraid)
					end
				else
					if getLampFailedStatus ~= "1" then
						luup.set_failure(1, value.veraid)
					end
				end
			end
		end
		
		if #g_groups > 0 then
			thisStatus = {}
			if json.groups then
				if getLength(json.groups) > 0 then
					for key, val in pairs(json.groups) do
						local k = tonumber(key)
						thisStatus[k] = {}
						thisStatus[k].lights = {}
						thisStatus[k].hueid = key
						thisStatus[k].name = val.name
						for i = 1,getLength(val.lights) do
							thisStatus[k].lights[i] = val.lights[i]
						end
						thisStatus[k].huetype = val.type
						thisStatus[k].on = val.action.on
						thisStatus[k].bri = val.action.bri or 0
						thisStatus[k].hue = val.action.hue or 0 
						thisStatus[k].sat = val.action.sat or 0
						if val.action.xy then thisStatus[k].x = val.action.xy[1] end
						if val.action.xy then thisStatus[k].y = val.action.xy[2] end
						thisStatus[k].ct = val.action.ct or 0
						thisStatus[k].alert = val.action.alert or "none"
						thisStatus[k].colormode = val.action.colormode or "hs"
					end
				else
					debug("(Hue2 Plugin)::(pollHueDevice) : Polling the Bridge Device : There are no groups set on the Bridge!")
				end
			else
				debug("(Hue2 Plugin)::(pollHueDevice) : Polling the Bridge Device : Possible error, 'groups' tag is not there!")
			end
			
			for key, val in pairs(thisStatus) do
				if g_groups[key] and (val.hueid == g_groups[key].hueid) then
					if val.on ~= g_groups[key].on or val.bri ~= g_groups[key].bri or val.hue ~= g_groups[key].hue or val.sat ~= g_groups[key].sat or val.x ~= g_groups[key].x or val.y ~= g_groups[key].y or val.ct ~= g_groups[key].ct or val.colormode ~= g_groups[key].colormode then	
						g_groups[key].on = val.on
						g_groups[key].bri = val.bri
						g_groups[key].hue = val.hue
						g_groups[key].sat = val.sat
						g_groups[key].x = val.x
						g_groups[key].y = val.y
						g_groups[key].ct = val.ct
						g_groups[key].colormode = val.colormode
					end
				end
			end
			
			for key, value in pairs(g_groups) do
				local lampDimStatus = luup.variable_get(SID.DIM, "LoadLevelStatus", tonumber(value.veraid)) or ""
				if value.on then
					if lampDimStatus ~= "" then
						local updateVal = math.floor(value.bri / 254 * 100 + 0.5)
						if value.bri == 1 then 
							updateVal = 1
						end
						if updateVal ~= tonumber(lampDimStatus) then
							luup.variable_set(SID.DIM, "LoadLevelStatus", updateVal, tonumber(value.veraid))
							luup.variable_set(SID.DIM, "LoadLevelTarget", updateVal, tonumber(value.veraid))
							luup.variable_set(SID.SWP, "Status", "1", tonumber(value.veraid))
						else
							debug("(Hue2 Plugin)::(pollHueDevice) : Group[" .. value.hueid .. "] ON - No UI update needed!")
						end
					else
						local updateVal = math.floor(value.bri / 254 * 100 + 0.5)
						if value.bri == 1 then 
							updateVal = 1
						end
						luup.variable_set(SID.DIM, "LoadLevelStatus", updateVal, tonumber(value.veraid))
						luup.variable_set(SID.DIM, "LoadLevelTarget", updateVal, tonumber(value.veraid))
						luup.variable_set(SID.SWP, "Status", "1", tonumber(value.veraid))
					end
				else
					if lampDimStatus == "" then
						luup.variable_set(SID.DIM, "LoadLevelStatus", "0", tonumber(value.veraid))
						luup.variable_set(SID.DIM, "LoadLevelTarget", "0", tonumber(value.veraid))
						luup.variable_set(SID.SWP, "Status", "0", tonumber(value.veraid))
					elseif lampDimStatus ~= "0" then
						debug("(Hue2 Plugin)::(pollHueDevice) : Group[" .. value.hueid .. "] OFF - Value set to 0!")
						luup.variable_set(SID.DIM, "LoadLevelStatus", "0", tonumber(value.veraid))
						luup.variable_set(SID.DIM, "LoadLevelTarget", "0", tonumber(value.veraid))
						luup.variable_set(SID.SWP, "Status", "0", tonumber(value.veraid))
					else
						debug("(Hue2 Plugin)::(pollHueDevice) : Group[" .. value.hueid .. "] OFF - No UI update needed!")
					end
				end
				local iconColorOnLamp = luup.variable_get(SID.HUE, "IconValue", value.veraid) or ""
				local LampValuesOnLamp = luup.variable_get(SID.HUE, "LampValues", value.veraid) or ""
				local iconNow
				local hue,sat,ct
				local LampValuesNow
				local LampHexValueNow
				if value.colormode == "hs" or value.colormode == "xy" then
					iconNow = getIconVal(value.colormode, value.hue)
					LampValuesNow = "hue:".. value.hue .. ";sat:" .. value.sat
					LampHexValueNow = convertHslToHex(value.hue, value.sat)
				else
					iconNow = getIconVal(value.colormode, value.ct)
					LampValuesNow = "ct:" .. value.ct
					LampHexValueNow = convertColorTemperatureToHex(value.ct)
				end
				if iconColorOnLamp ~= iconNow then
					luup.variable_set(SID.HUE, "IconValue", iconNow, value.veraid)
				end
				if LampValuesOnLamp ~= LampValuesNow then
					luup.variable_set(SID.HUE, "LampValues", LampValuesNow, value.veraid)
					luup.variable_set(SID.HUE, "LampHexValue", LampHexValueNow, value.veraid)
				end
			end
		end
		length = 0
		if json.scenes then
			length = getLength(json.scenes)
			if length > 0 then
				if g_sceneNumber ~= length then
					debug("(Hue2 Plugin)::(pollHueDevice) : Hue Presets number have been changed, reloading engine in order to apply the changes!")
					luup.reload()
				end
			else
				if g_sceneNumber ~= 0 then
					debug("(Hue2 Plugin)::(pollHueDevice) : There are no Hue Presets, reloading engine in order to apply the changes!")	
					luup.reload()
				end
			end
		end
		
		if pollType == "false" then
			luup.call_delay( "pollHueDevice", POLLING_RATE , pollType)
		end
		return true
	else
		if FAILED_STATUS_REPORT then
			local getFailedStatus = luup.variable_get("urn:micasaverde-com:serviceId:HaDevice1", "CommFailure", lug_device) or ""
			if getFailedStatus ~= "1" then
				--luup.set_failure(1, lug_device)
				luup.variable_set(SID.HUE, "Status",LANGUAGE_TOKENS[lug_language]["Philips Hue Disconnected!"] , lug_device)
				luup.variable_set(SID.HUE, "BridgeLink", "0" , lug_device)
				displayMessage("Philips Hue Disconnected!", TASK.ERROR_STOP)
				--set all hue lamps as failed
				for k,v in pairs(g_lamps) do
					if v.veraid then
						luup.set_failure(1, v.veraid)
					end
				end
				--set all hue groups as failed
				for k,v in pairs(g_groups) do
					if v.veraid then
						luup.set_failure(1, v.veraid)
					end
				end
			end
		end
		if pollType == "false" then
			luup.call_delay( "pollHueDevice", POLLING_RATE , pollType)
			return true
		else
			return false
		end
	end
end

local function checkInitialStatus()
	local url = g_hueURL .. "/" .. g_username
	http.TIMEOUT = 10
	local body, status, headers = http.request(url)
	if body then
		g_lastState = body
		local json_response = dkjson.decode(body)
		for key, value in pairs(json_response) do
			if value.error ~= nil then
				if value.error.type == 1 or value.error.type == 4 then 
					debug( "(Hue2 Plugin)::(checkInitialStatus) : Unregistered user! Proceeding..." )
					bridgeConnect()
					return
				end
			end
		end
		luup.variable_set(SID.HUE, "Status", LANGUAGE_TOKENS[lug_language]["Philips Hue Connected!"], lug_device)
		luup.variable_set(SID.HUE, "BridgeLink", "1", lug_device)
		displayMessage("Philips Hue Connected!", TASK.BUSY)
		log( "(Hue2 Plugin)::(checkInitialStatus) : Philips Hue Connected!" )
		g_taskHandle = luup.task(LANGUAGE_TOKENS[lug_language]["Startup successful!"], TASK.BUSY, "Hue2 Plugin", g_taskHandle)
		getDevices(json_response)
	else
		luup.variable_set(SID.HUE, "Status", LANGUAGE_TOKENS[lug_language]["Connection with the Bridge could not be established! Check IP or the wired connection!"], lug_device)
		luup.variable_set(SID.HUE, "BridgeLink", "0", lug_device)
		displayMessage("Connection with the Bridge could not be established! Check IP or the wired connection!", TASK.BUSY)
		log( "(Hue2 Plugin)::(checkInitialStatus) : Connection with the Bridge could not be established! Check IP or the wired connection!" )
		FLAGS.BRIDGE = false
	end
end

function createGroup(groupName, lightsIDs)
	log("(Hue2 Plugin)::(createGroup) : groupName = " .. groupName)
	log("(Hue2 Plugin)::(createGroup) : lightsIDs = " .. lightsIDs)
	local Lights = {}
	for k in lightsIDs:gmatch("(%d+)") do
		table.insert(Lights, k)
	end
	local jsondata = { name = groupName, lights = Lights}
    local postdata = dkjson.encode(jsondata)
    log("(Hue2 Plugin)::(createGroup) : post data request = " .. postdata)
    local url =  g_hueURL .. "/" .. g_username .. "/groups"
	local body, status, headers = http.request(url, postdata)
    log("(Hue2 Plugin)::(createGroup) : result data = " .. body)
    local json_response = dkjson.decode(body)
	
	local createError = false
    local errorType = 0
    local errorDescription = ""
	
	for key, value in pairs(json_response) do
		if (value.error ~= nil) then
			createError = true
			errorType = value.error.type
			errorDescription = value.error.description
		end
    end
	if createError then
		log("(Hue2 Plugin)::(createGroup) : Could not create group! Error Type = " .. errorType .. " ; Description = " .. errorDescription )
		return false
	else
		log("(Hue2 Plugin)::(createGroup) : Group " .. groupName .. " successfully created!")
		return true
	end
end

function createHueScene(sceneID,name,lights)
	local data = {}
	local lightsArray = {}
	for k in lights:gmatch("(%d+)") do
		table.insert(lightsArray, k)
	end
	data["name"] = name
	data["lights"] = lightsArray
	
	local senddata = dkjson.encode(data)
	local body = putToHue(senddata, sceneID, "scene")
	local json = dkjson.decode(body)
	
	local flagError = false
	
	for key, value in pairs(json) do
		if (value.error ~= nil) then
			log( "(Hue2 Plugin)::(createHueScene) : Creating Scene ERROR occurred : " .. value.error.type .. " with description : " .. value.error.description)
			flagError = true
		end
    end
	
	if flagError == false then
		log("(Hue2 Plugin)::(createHueScene) : Successfully created scene! " .. name)
		luup.reload()
		return true
	else
		log("(Hue2 Plugin)::(createHueScene) : Please check error/s above!")
		return false
	end
end

function modifyHueScene(scene,light,data)
	
	local value = scene .. "," .. light
	local body = putToHue(data, value, "Mscene")
	local json = dkjson.decode(body)
	
	local flagError = false
	
	for key, value in pairs(json) do
		if (value.error ~= nil) then
			log( "(Hue2 Plugin)::(modifyHueScene) : Modify Scene ERROR occurred : " .. value.error.type .. " with description : " .. value.error.description)
			flagError = true
		end
    end
	
	if flagError == false then
		log("(Hue2 Plugin)::(modifyHueScene) : Successfully modifyed scene!")
		return true
	else
		log("(Hue2 Plugin)::(modifyHueScene) : Please check error/s above!")
		return false
	end
end

function runHueScene(sceneID)
	log("(Hue2 Plugin)::(runHueScene) : Running scene " .. sceneID)
	local data = {}
	data["scene"] = sceneID
	--data["on"] = true
	local senddata = dkjson.encode(data)
	local body = putToHue(senddata, 0, "group")
	local json = dkjson.decode(body)
	local flagError = false
	for key, value in pairs(json) do
		if (value.error ~= nil) then
			log( "(Hue2 Plugin)::(runHueScene) : Running Scene ERROR occurred : " .. value.error.type .. " with description : " .. value.error.description)
			flagError = true
		end
    end
	
	if flagError == false then
		log("(Hue2 Plugin)::(runHueScene) : Successfully runned scene!")
		luup.variable_set(SID.HUE, "LastHuePreset", sceneID, lug_device)
		return true
	else
		log("(Hue2 Plugin)::(runHueScene) : Please check error/s above!")
		return false
	end
end

local function addFavoritesScenesFirst(device)
	local favoriteScenes = ""
	local actionListScene = ""
	local i = 1
	for k,v in pairs(g_scenes) do
		favoriteScenes = favoriteScenes .. g_scenes[k].sceneID
		local sceneName = g_scenes[k].name:match("(.+)%s+o[nf]+ %d*") or g_scenes[k].name:match("(.+)")
		actionListScene = actionListScene .. g_scenes[k].sceneID ..";" .. sceneName
		if i < 6 then
			favoriteScenes = favoriteScenes .. ","
			actionListScene = actionListScene .. ";"
		else
			break
		end
		i = i + 1
	end
	luup.variable_set(SID.HUE, "BridgeFavoriteScenes", favoriteScenes, device)
	luup.variable_set(SID.HUE, "FirstRun", "0", device)
	debug("(Hue2 Plugin)::(addFavoritesScenesFirst) : Favorite Scenes added on first run!")
end

local function createActionListScenes(device)
	local actionListScene = ""
	for k,v in pairs(g_scenes) do
		local sceneName = g_scenes[k].name:match("(.+)%s+o[nf]+ %d+") or g_scenes[k].name:match("(.+)")
		actionListScene = actionListScene .. g_scenes[k].sceneID ..";" .. sceneName .. ";"
	end
	luup.variable_set(SID.HUE, "ActionListScenes", actionListScene, device)
	debug("(Hue2 Plugin)::(createActionListScenes) : Action Scene List created!")
end

local function setHueDevicesVariables()
	local bridgeLights = ""
	for key,value in pairs(g_lamps) do
		bridgeLights = bridgeLights .. g_lamps[key].hueid .. "," .. g_lamps[key].name .. ";" 
	end
	bridgeLights = bridgeLights:sub(1,#bridgeLights -1)
	local bridgeLightsNow = luup.variable_get(SID.HUE, "BridgeLights", lug_device) or ""
	if bridgeLights ~= bridgeLightsNow then
		luup.variable_set(SID.HUE, "BridgeLights", bridgeLights, lug_device)
	end
	
	for key,value in pairs(g_groups) do
		local groupLights = getGroupLights(value.hueid)
		local groupLightsNow = luup.variable_get(SID.HUE, "GroupLights", value.veraid) or ""
		if groupLights ~= groupLightsNow then
			luup.variable_set(SID.HUE, "GroupLights", groupLights, value.veraid)
		end
	end
end

local function getInfos(device)
	luup.variable_set(SID.HUE, "Status", "", device)
	local debugMode = luup.variable_get(SID.HUE, "DebugMode", device) or ""
	if debugMode ~= "" then
		DEBUG_MODE = (debugMode == "1") and true or false
	else
		luup.variable_set(SID.HUE, "DebugMode", (DEBUG_MODE and "1" or "0"), device)
	end
	log("(Hue2 Plugin)::(getInfos) : Debug mode "..(DEBUG_MODE and "enabled" or "disabled")..".")

	local polling_rate = luup.variable_get(SID.HUE, "POLLING_RATE", device) or ""
	if polling_rate ~= "" then
			POLLING_RATE = tonumber(polling_rate)
		else
			luup.variable_set(SID.HUE, "POLLING_RATE", POLLING_RATE, device)
	end
	debug("(Hue2 Plugin)::(getInfos) : POLLING_RATE = " .. POLLING_RATE )
	
	local failedStatusReport = luup.variable_get(SID.HUE, "FailedStatusReport", device) or ""
	if failedStatusReport ~= "" then
		FAILED_STATUS_REPORT = (failedStatusReport == "1") and true or false
	else
		luup.variable_set(SID.HUE, "FailedStatusReport", (FAILED_STATUS_REPORT and "1" or "0"), device)
	end
	log("(Hue2 Plugin)::(getInfos) : Failed Status Report "..(FAILED_STATUS_REPORT and "enabled" or "disabled")..".")
	
	local bridgeLink = luup.variable_get(SID.HUE, "BridgeLink", device) or ""
	if bridgeLink == "" then
		luup.variable_set(SID.HUE, "BridgeLink", "0", device)
	end
	
	findBridge()
	
	local IP = luup.attr_get("ip", device) or ""
	
	if IP ~= nil then
		g_ipAddress = IP
	end
	
	if g_ipAddress == nil or g_ipAddress == "" then
		luup.variable_set(SID.HUE, "BridgeLink", "0", lug_device)
		displayMessage("IP address could not be automatically set! Please add it in IP field, save and reload the engine!", TASK.BUSY)
		luup.variable_set(SID.HUE, "Status", LANGUAGE_TOKENS[lug_language]["IP address could not be automatically set! Please add it in IP field, save and reload the engine!"], lug_device)
		return
	else
		FLAGS.BRIDGE = true
		g_username = luup.attr_get("username", lug_device) or ""
		g_hueURL = "http://" .. g_ipAddress .. "/api"
		debug("(Hue2 Plugin)::(getInfos) : Philips Hue URL = " .. g_hueURL .. " username = "..(g_username or "NIL"))
		checkInitialStatus()
	end
end

function Init(lul_device)
	lug_device = lul_device
	lug_language = GetLanguage()
	if lug_language ~="en" and lug_language ~= "fr" then
		lug_language = "en"
	end
	
	g_taskHandle = luup.task(LANGUAGE_TOKENS[lug_language]["Starting up..."], TASK.ERROR, "Hue2 Plugin", -1)
	getInfos(lug_device)
	debug("(Hue2 Plugin)::(Init) : Got language : " .. lug_language )
	if FLAGS.BRIDGE then
		g_appendPtr = luup.chdev.start(lug_device)
		appendLamps(lug_device)
		appendGroups(lug_device)
		luup.chdev.sync(lug_device, g_appendPtr)
		getChildDevices(lug_device)
		local bridgeLink = luup.variable_get(SID.HUE, "BridgeLink", lug_device) or ""
		if bridgeLink == "1" then
			pollHueDevice("false")
			local firstRun = luup.variable_get(SID.HUE, "FirstRun", lug_device) or ""
			if firstRun == "" or firstRun == "1" then
				addFavoritesScenesFirst(lug_device)
				createActionListScenes(lug_device)
			end
		end
		setHueDevicesVariables()
		
		-- for key,value in pairs(g_lamps) do
			-- debug("(Hue2 Plugin)::(Init) : Lamp " .. key .. " :" )
			-- for k,v in pairs(value) do
				-- debug("(Hue2 Plugin)::(Init) : Lamp[" .. tostring(key) .. "]." .. tostring(k) .. " = " .. tostring(v) )
			-- end
		-- end
		
		-- for k,v in pairs(g_groups) do
			-- debug("(Hue2 Plugin)::(Init) : Group " .. k .. " :" )
			-- for key,val in pairs(v) do
				-- debug("(Hue2 Plugin)::(Init) : Groups[" .. tostring(k) .. "]." .. tostring(key) .." = [" .. tostring(val) .. "]")
			-- end
		-- end
		
		log( "(Hue2 Plugin)::(Startup) : Startup successful!" )
		displayMessage("Startup successful!", TASK.BUSY)
		luup.set_failure(0, lug_device)
	else
		g_taskHandle = luup.task(LANGUAGE_TOKENS[lug_language]["Startup ERROR : Connection with the Bridge could not be established!"], TASK.BUSY, "Philips Hue", g_taskHandle)
		log( "(Hue2 Plugin)::(Startup) : Startup ERROR : Connection with the Bridge could not be established!" )
		luup.set_failure(1, lug_device)
	end
end
