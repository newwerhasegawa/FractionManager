script_name("FractionManager")
script_version("0.9.9")
script_authors("Newwer Hasegawa")

local encoding = require 'encoding'
local sampev = require 'lib.samp.events'
local vkeys = require 'lib.vkeys'

encoding.default = 'CP1251'
local u8 = encoding.UTF8
math.randomseed(os.time())

-- ================= [ ССЫЛКИ ] =================
-- ?? ВСТАВЬ СЮДА СВОЮ НОВУЮ ССЫЛКУ ОТ GOOGLE APPS SCRIPT:
local GAS_URL = "https://script.google.com/macros/s/AKfycbyYTiChuuyR-SaBXku1_rzrybLN20aKtZyWpqjTmHavoKC6tx1WRqAQbiq_FwQLmd4gnw/exec"

local fm_dir = getWorkingDirectory() .. "\\config\\FractionManager\\"
local localLecturesJson = fm_dir .. "lectures.json"
local localLecturesVer = fm_dir .. "lectures_version.txt"
local LECTURES_JSON_URL = "https://raw.githubusercontent.com/newwerhasegawa/FractionManager/main/lectures.json"
local LECTURES_VER_URL = "https://raw.githubusercontent.com/newwerhasegawa/FractionManager/main/lectures_version.txt"

local SCRIPT_VER_URL = "https://raw.githubusercontent.com/newwerhasegawa/FractionManager/refs/heads/main/version.txt"
local SCRIPT_URL = "https://raw.githubusercontent.com/newwerhasegawa/FractionManager/refs/heads/main/FractionManager.lua"

-- ================= [ ПЕРЕМЕННЫЕ ] =================
local cadetsOnline = {}
local tempCadets = {}
local factionOnline = {} 
local cadetsDB = {}
local isUpdating = false
local lastSyncTimer = os.clock()
local lastPingTimer = 0
local showHUD = true 
local font = nil
local selectedCadet = nil
local selectedStaffMember = nil 
local offlineMembersList = {} 
local lecturesDB = {}
local lectureKeys = {}
local stopLecture = false
local paused = false
local lectureThread = nil

local updateTriggered = false 
local isScriptActive = false 
local welcomeShown = false 
local lastClickTick = 0 
local wasPaused = false 

local myCachedNick = nil

-- Ролевая система
local myRole = "User"
local myPrio = 0
local isMaster = false
local forcedMasterSync = false

-- ================= [ ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ] =================
local function safe_u8(str)
    return u8(tostring(str or ""))
end

local function checkCooldown()
    if os.clock() - lastClickTick < 0.5 then return false end
    lastClickTick = os.clock()
    return true
end

local function trim(s) 
    return s and tostring(s):match("^%s*(.-)%s*$") or "" 
end

local function urlencode(str)
    if str then
        str = string.gsub(str, "([^%w ])", function(c) return string.format("%%%02X", string.byte(c)) end)
        str = string.gsub(str, " ", "+")
    end
    return str
end

local function isMarked(val)
    if val == nil or val == "" then return false end
    local num = tonumber(val)
    if num then return num >= 1 end
    local str = tostring(val):lower()
    return str == "true" or str == "1" or str == "да"
end

local function GetNick()
    if myCachedNick then return myCachedNick end
    local res, myid = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if res and myid ~= -1 then
        local nick = sampGetPlayerNickname(myid)
        if nick then 
            myCachedNick = nick:gsub("_", " ")
            return myCachedNick 
        end
    end
    return "Инструктор"
end

local function smartWait(ms)
    local timer = 0
    while timer < ms do
        if not paused then
            timer = timer + 100
        end
        wait(100)
        if stopLecture then return true end
    end
    return false
end

local function showWelcomeMessage()
    local scr = thisScript()
    sampAddChatMessage("{0633E5}" .. scr.name .. " {FFFFFF}v.{C8271E}" .. scr.version .. "{FFFFFF} authors {3645E2}" .. table.concat(scr.authors, ", ") .. "{FFFFFF} был успешно загружен!", 0x0633E5)
    sampAddChatMessage("{FFFFFF}Для активации/деактивации скрипта нажмите клавишу '{C8271E}F5{FFFFFF}'.", 0x0633E5)
    sampAddChatMessage("{FFFFFF}Главное меню скрипта - {C8271E}/fm{FFFFFF}, поставить на паузу лекцию клавиша '{C8271E}I{FFFFFF}'.", 0x0633E5)
    sampAddChatMessage("{FFFFFF}Обновить информацию вручную - {C8271E}/updc{FFFFFF}.", 0x0633E5)
    sampAddChatMessage("{FFFFFF}Принудительно обновить таблицу /members - {C8271E}/updmembers{FFFFFF}.", 0x0633E5)
end

local dlQueue = {}
local function queueHttpRequest(url, callback)
    table.insert(dlQueue, {url = url, callback = callback})
end

-- ================= [ МЕНЮ ] =================
local function openFmMenu()
    if myPrio < 2 then
        sampAddChatMessage("{0633E5}[FM] {FF0000}У вас нет доступа к меню управления кадетами.", -1)
        return
    end

    local toggleText = showHUD and "{FF0000}Выключить HUD" or "{00FF00}Включить HUD"
    local s = toggleText .. "\n{0633E5}Лекции\n{0633E5}Обновить список кадетов\n{FFFFFF}" 
    
    if #cadetsOnline > 0 then
        for i, v in ipairs(cadetsOnline) do 
            if v and v.displayName and v.id then
                s = s .. v.displayName .. " [" .. v.id .. "]\n" 
            end
        end
    else
        s = s .. "{A9A9A9}Кадетов в сети нет\n"
    end
    
    sampShowDialog(9910, "{0633E5}Управление кадетами", s, "Выбрать", "Назад", 2)
end

local function showMyStat()
    if not u8 then 
        sampAddChatMessage("{0633E5}[FM] {FF0000}Ошибка: Библиотека encoding не загружена!", -1)
        return 
    end

    sampAddChatMessage("{0633E5}[FM] {FFFFFF}Запрос личной статистики...", -1)
    
    local myNick = GetNick()
    queueHttpRequest(GAS_URL .. "?action=mystat&name=" .. urlencode(safe_u8(myNick)), function(content)
        if content and content ~= "" then
            local res, data = pcall(decodeJson, content)
            if res and type(data) == "table" and data.sheet and data.headers and data.row then
                local sheetName = u8:decode(tostring(data.sheet)) or "Неизвестно"
                local text = string.format("{00FF00}Подразделение:{FFFFFF} %s\n\n", sheetName)
                
                local h = data.headers
                local r = data.row
                
                for i = 1, #h do
                    if h[i] and r[i] then
                        local headerName = u8:decode(tostring(h[i]))
                        local rowValue = u8:decode(tostring(r[i]))
                        
                        if headerName ~= "" and rowValue ~= "" and rowValue ~= "0" and rowValue ~= "false" then
                            text = text .. "{A020F0}" .. headerName .. ":{FFFFFF} " .. rowValue .. "\n"
                        end
                    end
                end
                
                local titleNick = r[1] and u8:decode(tostring(r[1])) or myNick
                sampShowDialog(9920, "{0633E5}Моя статистика: " .. titleNick, text, "Закрыть", "", 0)
            else
                sampAddChatMessage("{0633E5}[FM] {FF0000}Ваши данные не найдены или таблица вернула ошибку.", -1)
            end
        else
            sampAddChatMessage("{0633E5}[FM] {FF0000}Ошибка: Пустой ответ от сервера.", -1)
        end
    end)
end

-- ================= [ АВТООБНОВЛЕНИЕ СКРИПТА ] =================
local function checkScriptUpdate()
    if updateTriggered then return end
    queueHttpRequest(SCRIPT_VER_URL .. "?t=" .. os.time(), function(remoteVer)
        if not remoteVer then return end
        local currentVer = thisScript().version
        local cleanRemoteVer = trim(remoteVer):match("[%d%.]+")
        
        if cleanRemoteVer and cleanRemoteVer ~= currentVer then
            updateTriggered = true
            sampAddChatMessage("{0633E5}[FM] {FFFFFF}Найдена версия скрипта {00FF00}v." .. cleanRemoteVer .. "{FFFFFF}. Нажмите {00FF00}Y{FFFFFF} для обновления или {FF0000}N{FFFFFF} для отказа (15 сек).", -1)
            
            lua_thread.create(function()
                local timer = os.clock()
                local answered = false
                while os.clock() - timer < 15.0 do
                    wait(0)
                    if wasKeyPressed(vkeys.VK_Y) and not sampIsChatInputActive() and not sampIsDialogActive() then
                        sampAddChatMessage("{0633E5}[FM] {FFFFFF}Начинаю загрузку...", -1)
                        answered = true
                        queueHttpRequest(SCRIPT_URL .. "?t=" .. os.time(), function(content)
                            if content and content:find("script_name") then
                                local f = io.open(thisScript().path, "wb")
                                if f then
                                    f:write(u8:decode(content))
                                    f:close()
                                    sampAddChatMessage("{0633E5}[FM] {00FF00}Файл обновлен. Перезагрузка через 1 сек...", -1)
                                    lua_thread.create(function()
                                        wait(1000) 
                                        thisScript():reload()
                                    end)
                                else
                                    sampAddChatMessage("{0633E5}[FM] {FF0000}Ошибка: Файл занят другой программой!", -1)
                                    updateTriggered = false
                                end
                            else
                                sampAddChatMessage("{0633E5}[FM] {FF0000}Ошибка: Получен пустой файл обновления.", -1)
                                updateTriggered = false
                            end
                        end)
                        break
                    elseif wasKeyPressed(vkeys.VK_N) and not sampIsChatInputActive() and not sampIsDialogActive() then
                        sampAddChatMessage("{0633E5}[FM] {FF0000}Обновление скрипта отменено пользователем.", -1)
                        answered = true
                        updateTriggered = false
                        break
                    end
                end
                if not answered then
                    sampAddChatMessage("{0633E5}[FM] {FF0000}Время вышло. Обновление скрипта отменено автоматически.", -1)
                    updateTriggered = false
                end
            end)
        end
    end)
end

-- ================= [ ФУНКЦИИ ЛЕКЦИЙ ] =================
local function loadLecturesLocally()
    if not doesFileExist(localLecturesJson) then return false end
    local f = io.open(localLecturesJson, "r")
    if f then
        local content = f:read("*all")
        f:close()
        if content and #content > 0 then
            local res, data = pcall(decodeJson, content)
            if res and type(data) == "table" then
                lecturesDB = {} 
                lectureKeys = {}
                for k, lines in pairs(data) do
                    local decodedKey = u8:decode(k)
                    lecturesDB[decodedKey] = {}
                    if type(lines) == "table" then
                        for _, line in ipairs(lines) do
                            table.insert(lecturesDB[decodedKey], u8:decode(line))
                        end
                        table.insert(lectureKeys, decodedKey)
                    end
                end
                table.sort(lectureKeys)
                return true
            end
        end
    end
    return false
end

local function updateLecturesFromGitHub()
    local localVer = 0
    if doesFileExist(localLecturesVer) then
        local f = io.open(localLecturesVer, "r")
        if f then 
            local content = f:read("*all")
            if content then localVer = tonumber(content:match("%d+")) or 0 end
            f:close() 
        end
    end
    
    queueHttpRequest(LECTURES_VER_URL .. "?t=" .. os.time(), function(content)
        if not content then return end
        local gitVer = tonumber(content:match("%d+")) or 0
        if gitVer > localVer then
            sampAddChatMessage("{0633E5}[FM] {FFFFFF}Найдено обновление лекций. Нажмите {00FF00}Y{FFFFFF} для обновления или {FF0000}N{FFFFFF} (15 сек).", -1)
            
            lua_thread.create(function()
                local timer = os.clock()
                local answered = false
                while os.clock() - timer < 15.0 do
                    wait(0)
                    if wasKeyPressed(vkeys.VK_Y) and not sampIsChatInputActive() and not sampIsDialogActive() then
                        sampAddChatMessage("{0633E5}[FM] {FFFFFF}Загрузка обновления лекций...", -1)
                        answered = true
                        queueHttpRequest(LECTURES_JSON_URL .. "?t=" .. os.time(), function(jsonContent)
                            if not jsonContent then return end
                            local fJson = io.open(localLecturesJson, "w")
                            if fJson then fJson:write(jsonContent); fJson:close() end
                            local fVer = io.open(localLecturesVer, "w")
                            if fVer then fVer:write(tostring(gitVer)); fVer:close() end
                            loadLecturesLocally()
                            sampAddChatMessage("{0633E5}[FM] {00FF00}Лекции успешно обновлены!", -1)
                        end)
                        break
                    elseif wasKeyPressed(vkeys.VK_N) and not sampIsChatInputActive() and not sampIsDialogActive() then
                        sampAddChatMessage("{0633E5}[FM] {FF0000}Обновление лекций отменено пользователем.", -1)
                        loadLecturesLocally()
                        answered = true
                        break
                    end
                end
                if not answered then
                    sampAddChatMessage("{0633E5}[FM] {FF0000}Время вышло. Обновление лекций отменено автоматически.", -1)
                    loadLecturesLocally()
                end
            end)
        else
            loadLecturesLocally()
        end
    end)
end

local function startLecturePlay(key)
    paused = false
    lectureThread = lua_thread.create(function()
        if lecturesDB[key] then
            for _, rawLine in ipairs(lecturesDB[key]) do
                if stopLecture then break end
                local text = rawLine:gsub("%s*%[wait:%d+%]$", "")
                local waitTime = rawLine:match("%[wait:(%d+)%]") or 8000
                sampSendChat(text:gsub("{name}", GetNick()))
                if smartWait(tonumber(waitTime)) then break end
            end
        end
        lectureThread = nil
        if not stopLecture then
            sampAddChatMessage("{0633E5}[FM] {FFFFFF}Лекция окончена", -1)
        end
        stopLecture = false
    end)
end

-- ================= [ БАЗА ДАННЫХ И СИНХРОНИЗАЦИЯ ] =================
local function updateFromBase()
    queueHttpRequest(GAS_URL .. "?action=read&t=" .. os.time(), function(content)
        if content and (content:sub(1,1) == "[" or content:sub(1, 1) == "{") then
            local res, data = pcall(decodeJson, content)
            if res and type(data) == "table" then
                local temp = {}
                for _, row in ipairs(data) do
                    if type(row) == "table" then
                        local n = trim(row.name or row.Nickname)
                        if n ~= "" then temp[n:gsub(" ", "_")] = row end
                    end
                end
                cadetsDB = temp
            end
        end
    end)
end

local function updateCadetInBase(name, col, joinDate, shouldSyncAfter, extraVal)
    if not name or myPrio < 2 then return end
    
    local safeName = urlencode(safe_u8(name))
    local safeInst = urlencode(safe_u8(GetNick()))
    
    local url = GAS_URL .. "?action=update&name=" .. safeName .. "&instructor=" .. safeInst
    
    if col then url = url .. "&col=" .. urlencode(safe_u8(col)) end
    if joinDate then url = url .. "&joinDate=" .. urlencode(safe_u8(joinDate)) end
    if extraVal and tostring(extraVal) ~= "" then 
        url = url .. "&val=" .. urlencode(safe_u8(extraVal)) 
    end
    
    queueHttpRequest(url, function(content)
        if content and (content:find("Not found") or content:find("Player not found")) then
            sampAddChatMessage("{0633E5}[FM] {FF0000}Ошибка: Игрок {FFFFFF}" .. tostring(name) .. "{FF0000} не найден в таблице!", -1)
        else
            if shouldSyncAfter then
                sampAddChatMessage("{0633E5}[FM] {00FF00}Отметка подтверждена базой. Обновляю данные кадетов...", -1)
                updateFromBase()
            end
        end
    end)
end

function syncAll(silent)
    if isUpdating then return end
    
    if myPrio < 2 and not isMaster and not forcedMasterSync and silent then return end 

    lastSyncTimer = os.clock()
    if not silent and not forcedMasterSync then
        sampAddChatMessage("{0633E5}[FM] {FFFFFF}Синхронизация...", -1)
    end
    
    if myPrio >= 2 or isMaster or forcedMasterSync then
        updateFromBase()
        
        lua_thread.create(function()
            wait(500)
            tempCadets = {}
            factionOnline = {} 
            isUpdating = true
            sampSendChat("/members")
            
            local timer = os.clock()
            while isUpdating do
                wait(100)
                if os.clock() - timer > 3.0 then
                    isUpdating = false
                    if not silent then
                        sampAddChatMessage("{0633E5}[FM] {FF0000}Таймаут команды /members (Сервер не ответил).", -1)
                    end
                    break
                end
            end
            
            if not silent and #cadetsOnline == 0 and myPrio >= 2 then
                if forcedMasterSync then
                    sampAddChatMessage("{0633E5}[FM] {FFFFFF}В сети нет кадетов, обновляем общий список /members.", -1)
                else
                    sampAddChatMessage("{0633E5}[FM] {FF0000}Кадетов в сети нет.", -1)
                end
            end
        end)
    end
end

-- ================= [ MAIN ] =================
function main()
    if not doesDirectoryExist(fm_dir) then createDirectory(getWorkingDirectory() .. "\\config"); createDirectory(fm_dir) end
    while not isSampAvailable() do wait(100) end
    font = renderCreateFont("Arial", 8, 5)
    loadLecturesLocally()
    
    lua_thread.create(function()
        while true do
            wait(50)
            if #dlQueue > 0 then
                local req = table.remove(dlQueue, 1)
                local tempPath = string.format("%stmp_%d%d.tmp", fm_dir, os.time(), math.random(1000, 9999))
                local isDone = false
                
                _G.current_dl_cb = function(id, status)
                    if status == 6 or status == 58 or status == 7 or status == -1 then
                        isDone = true
                    end
                end
                
                local res = pcall(downloadUrlToFile, req.url, tempPath, _G.current_dl_cb)
                if res then
                    local startTime = os.clock()
                    while not isDone do
                        wait(50)
                        if os.clock() - startTime > 20.0 then break end 
                    end
                end
                
                local content = nil
                if doesFileExist(tempPath) then
                    local f = io.open(tempPath, "r")
                    if f then
                        content = f:read("*all")
                        f:close()
                    end
                    os.remove(tempPath)
                end
                
                if req.callback then pcall(req.callback, content) end
            end
        end
    end)
    
    lua_thread.create(function()
        checkScriptUpdate() 
        wait(4000)
        updateLecturesFromGitHub()
    end)

    sampRegisterChatCommand("fm", function()
        if not isScriptActive then return end
        if not checkCooldown() then return end
        local s = "1. Управление составом\n2. Управление кадетами\n3. Моя статистика"
        sampShowDialog(9909, "{0633E5}Главное меню", s, "Выбрать", "Закрыть", 2)
    end)
    
    sampRegisterChatCommand("updc", function()
        if not isScriptActive then return end
        if not checkCooldown() then return end
        sampAddChatMessage("{0633E5}[FM] {FFFFFF}Запуск ручного обновления...", -1)
        lua_thread.create(function()
            forcedMasterSync = true
            syncAll(false)
            wait(600)
            while isUpdating do wait(100) end
            wait(1000)
            forcedMasterSync = false
            sampAddChatMessage("{0633E5}[FM] {00FF00}Ручное обновление завершено.", -1)
        end)
    end)

    sampRegisterChatCommand("updmembers", function()
        if not isScriptActive then return end
        if not checkCooldown() then return end
        sampAddChatMessage("{0633E5}[FM] {FFFFFF}Запуск принудительного обновления таблицы /members...", -1)
        lua_thread.create(function()
            local oldMaster = isMaster
            isMaster = true
            forcedMasterSync = true
            syncAll(false)
            wait(600)
            while isUpdating do wait(100) end
            wait(1000)
            isMaster = oldMaster
            forcedMasterSync = false
            sampAddChatMessage("{0633E5}[FM] {00FF00}Обновление members завершено.", -1)
        end)
    end)

    while true do
        wait(0)
        
        local currentPause = isPauseMenuActive()
        if currentPause and not wasPaused then
            wasPaused = true
        elseif not currentPause and wasPaused then
            wasPaused = false
            lastPingTimer = os.clock()
            lastSyncTimer = os.clock()
        end
        
        if not welcomeShown and sampIsLocalPlayerSpawned() then
            welcomeShown = true
            lua_thread.create(function()
                wait(1000) 
                showWelcomeMessage()
            end)
        end
        
        if wasKeyPressed(vkeys.VK_F5) and not sampIsChatInputActive() and not sampIsDialogActive() then
            if checkCooldown() then
                isScriptActive = not isScriptActive
                if isScriptActive then
                    sampAddChatMessage("{0633E5}[FM] {00FF00}Скрипт активирован! Определение прав...", -1)
                    local res, myid = sampGetPlayerIdByCharHandle(PLAYER_PED)
                    local reqId = (res and myid ~= -1) and myid or 999999
                
                    queueHttpRequest(GAS_URL .. "?action=ping&name=" .. urlencode(safe_u8(GetNick())) .. "&afk=false&id=" .. tostring(reqId), function(content)
                        if content then
                            local res, data = pcall(decodeJson, content)
                            if res and type(data) == "table" then
                                myRole = data.role
                                myPrio = data.prio
                                isMaster = data.isMaster
                                sampAddChatMessage("{0633E5}[FM] {FFFFFF}Ваша роль: {00FF00}" .. myRole .. (isMaster and " (Мастер)" or ""), -1)
                                if myPrio >= 2 or isMaster then syncAll(true) end
                            else
                                sampAddChatMessage("{0633E5}[FM] {FF0000}Ответ базы данных не распознан. Попробуйте еще раз.", -1)
                            end
                        else
                            sampAddChatMessage("{0633E5}[FM] {FF0000}База данных не ответила.", -1)
                        end
                    end)
                else
                    sampAddChatMessage("{0633E5}[FM] {FF0000}Скрипт выключен!", -1)
                end
            end
        end
        
        if isScriptActive and not isPauseMenuActive() then
            
            if os.clock() - lastPingTimer >= 30.0 then
                local res, myid = sampGetPlayerIdByCharHandle(PLAYER_PED)
                local reqId = (res and myid ~= -1) and myid or 999999
                queueHttpRequest(GAS_URL .. "?action=ping&name=" .. urlencode(safe_u8(GetNick())) .. "&afk=false&id=" .. tostring(reqId), function(content)
                    if content then
                        local res, data = pcall(decodeJson, content)
                        if res and type(data) == "table" then
                            if myRole ~= data.role then
                                sampAddChatMessage("{0633E5}[FM] {FFFFFF}Ваша роль обновлена: {00FF00}" .. data.role, -1)
                            end
                            if not isMaster and data.isMaster then
                                sampAddChatMessage("{0633E5}[FM] {00FF00}Вы назначены Мастером сессии. /members синхронизируется через вас.", -1)
                            end
                            myRole = data.role
                            myPrio = data.prio
                            isMaster = data.isMaster
                        end
                    end
                end)
                lastPingTimer = os.clock()
            end

            if os.clock() - lastSyncTimer >= 90.0 then
                if not sampIsChatInputActive() and not sampIsDialogActive() and not isUpdating then
                    if myPrio >= 2 or isMaster then
                        syncAll(true)
                    end
                end
            end

            if isKeyDown(vkeys.VK_CONTROL) and wasKeyPressed(vkeys.VK_R) then
                if not sampIsChatInputActive() and not sampIsDialogActive() then
                    sampAddChatMessage("{0633E5}[FM] {FFFFFF}Принудительная остановка и перезагрузка...", -1)
                    if lectureThread then
                        stopLecture = true
                        pcall(function() lectureThread:terminate() end) 
                        lectureThread = nil
                    end
                    isUpdating = false
                    lua_thread.create(function()
                        wait(100)
                        thisScript():reload()
                    end)
                end
            end

            if wasKeyPressed(vkeys.VK_I) and not sampIsChatInputActive() and not sampIsDialogActive() then
                if lectureThread then
                    paused = not paused
                    sampAddChatMessage(paused and "{0633E5}[FM] {FF0000}Лекция на паузе" or "{0633E5}[FM] {00FF00}Лекция продолжена", -1)
                end
            end

            if showHUD and myPrio >= 2 and not isKeyDown(vkeys.VK_F7) and font then
                local count = #cadetsOnline
                local boxWidth = renderGetFontDrawTextLength(font, "Кадеты Онлайн") + 20
                if count > 0 then
                    for i, v in ipairs(cadetsOnline) do
                        if v and v.displayName and v.id then
                            local fullText = string.format("%d. %s [%s] [Л][Т][П][Д]", i, v.displayName, v.id)
                            local w = renderGetFontDrawTextLength(font, fullText) + 15
                            if w > boxWidth then boxWidth = w end
                        end
                    end
                end

                local boxHeight = count > 0 and (35 + (count * 14)) or 50
                renderDrawBox(20, 320, boxWidth, boxHeight, 0x95000000)
                renderFontDrawText(font, "Кадеты Онлайн", 28, 325, 0xFF4682B4)
                
                if count > 0 then
                    local renderIndex = 1
                    for i, v in ipairs(cadetsOnline) do
                        if v and v.rawName then
                            local l, t, p, dPassed, raising = false, false, false, false, false
                            local safeName = trim(v.rawName)
                            local db = cadetsDB and cadetsDB[safeName] or nil
                            if db then
                                l = isMarked(db.lecture)
                                t = isMarked(db.theory)
                                p = isMarked(db.practice)
                                dPassed = isMarked(db.isTwoDays) 
                                raising = isMarked(db.raising) 
                            end
                            local baseX, baseY = 28, 338 + (renderIndex * 14)

                            local isReady = (raising or dPassed) 

                            if isReady then
                                renderFontDrawText(font, string.format("%d. %s [%s]", renderIndex, v.displayName or "Unknown", v.id or "0"), baseX, baseY, 0xFF00FF00)
                            else
                                local textBase = string.format("%d. %s [%s] ", renderIndex, v.displayName or "Unknown", v.id or "0")
                                renderFontDrawText(font, textBase, baseX, baseY, 0xFFFFFFFF)
                                
                                local offset = renderGetFontDrawTextLength(font, textBase)
                                renderFontDrawText(font, "[Л]", baseX + offset, baseY, l and 0xFF00FF00 or 0xFFFF4D4D)
                                offset = offset + renderGetFontDrawTextLength(font, "[Л]")
                                renderFontDrawText(font, "[Т]", baseX + offset, baseY, t and 0xFF00FF00 or 0xFFFF4D4D)
                                offset = offset + renderGetFontDrawTextLength(font, "[Т]")
                                renderFontDrawText(font, "[П]", baseX + offset, baseY, p and 0xFF00FF00 or 0xFFFF4D4D)
                                offset = offset + renderGetFontDrawTextLength(font, "[П]")
                                renderFontDrawText(font, "[Д]", baseX + offset, baseY, dPassed and 0xFF00FF00 or 0xFFFF4D4D)
                            end
                            
                            renderIndex = renderIndex + 1
                        end
                    end
                else
                    renderFontDrawText(font, "—", 28, 345, 0xFFFFFFFF)
                end
            end
        end
    end
end

-- ================= [ ОБРАБОТКА ДИАЛОГОВ ] =================
function sampev.onSendDialogResponse(id, btn, lst, inp)
    if not checkCooldown() then return false end 

    if id == 9909 then
        if btn == 1 then
            if lst == 0 then 
                -- ПРОВЕРКА ПРАВ: ТОЛЬКО STAFF (3) И SUPERADMIN (4)
                if myPrio < 3 then
                    sampAddChatMessage("{0633E5}[FM] {FF0000}Управление составом доступно только для Staff и SuperAdmin.", -1)
                    lua_thread.create(function() wait(50); sampShowDialog(9909, "{0633E5}Главное меню", "1. Управление составом\n2. Управление кадетами\n3. Моя статистика", "Выбрать", "Закрыть", 2) end)
                    return false
                end
                lua_thread.create(function() 
                    wait(50)
                    sampShowDialog(9930, "{0633E5}Управление составом", "Список людей онлайн на повышение\nУправление игроками (онлайн)\nУправление игроками (оффлайн)", "Выбрать", "Назад", 2)
                end)
            elseif lst == 1 then 
                lua_thread.create(function() wait(50); openFmMenu() end)
            elseif lst == 2 then 
                lua_thread.create(function() wait(50); showMyStat() end)
            end
        end
        return false

    elseif id == 9930 then
        if btn == 1 then
            if lst == 0 then
                sampAddChatMessage("{0633E5}[FM] {FFFFFF}Список людей на повышение - {FF0000}В разработке", -1)
                lua_thread.create(function() 
                    wait(50)
                    sampShowDialog(9930, "{0633E5}Управление составом", "Список людей онлайн на повышение\nУправление игроками (онлайн)\nУправление игроками (оффлайн)", "Выбрать", "Назад", 2)
                end)
            elseif lst == 1 then
                local s = "Ник\tЗвание\n"
                s = s .. "{FFD700}?? Обновить список\t-\n" 
                if #factionOnline > 0 then
                    for i, v in ipairs(factionOnline) do
                        local displayRank = (v.rank and v.rank ~= "") and v.rank or "Неизвестно"
                        s = s .. v.rawName .. " [" .. v.id .. "]\t{A9A9A9}" .. displayRank .. "\n"
                    end
                end
                lua_thread.create(function() wait(50); sampShowDialog(9932, "{0633E5}Выберите игрока (онлайн)", s, "Выбрать", "Назад", 5) end)
            elseif lst == 2 then
                local depts = "Staff\nPolice Academy [PA]\nCentral Patrol Division [CPD]\nCrime Scene Investigation [CSI]\nCadets"
                lua_thread.create(function() wait(50); sampShowDialog(9933, "{0633E5}Выберите отдел", depts, "Выбрать", "Назад", 2) end)
            end
        else
            lua_thread.create(function() wait(50); sampShowDialog(9909, "{0633E5}Главное меню", "1. Управление составом\n2. Управление кадетами\n3. Моя статистика", "Выбрать", "Закрыть", 2) end)
        end
        return false

    elseif id == 9932 then 
        if btn == 1 then
            if lst == 0 then 
                sampAddChatMessage("{0633E5}[FM] {FFFFFF}Запрашиваем свежий список /members...", -1)
                lua_thread.create(function()
                    syncAll(true) 
                    local timer = os.clock()
                    while isUpdating and (os.clock() - timer < 3.0) do wait(100) end
                    wait(300) 
                    
                    local s = "Ник\tЗвание\n"
                    s = s .. "{FFD700}?? Обновить список\t-\n"
                    if #factionOnline > 0 then
                        for i, v in ipairs(factionOnline) do
                            local displayRank = (v.rank and v.rank ~= "") and v.rank or "Неизвестно"
                            s = s .. v.rawName .. " [" .. v.id .. "]\t{A9A9A9}" .. displayRank .. "\n"
                        end
                    end
                    sampShowDialog(9932, "{0633E5}Выберите игрока (онлайн)", s, "Выбрать", "Назад", 5)
                end)
                return false
            end
            
            local selected = factionOnline[lst] 
            if selected then
                selectedStaffMember = selected.rawName
                lua_thread.create(function() wait(50); sampShowDialog(9934, "{0633E5}Действия: " .. selectedStaffMember, "Перенос между отделами\nВыдать выговор\nОставить комментарий\n{A020F0}Информация о сотруднике", "Выбрать", "Назад", 2) end)
            end
        else
            lua_thread.create(function() wait(50); sampShowDialog(9930, "{0633E5}Управление составом", "Список людей онлайн на повышение\nУправление игроками (онлайн)\nУправление игроками (оффлайн)", "Выбрать", "Назад", 2) end)
        end
        return false

    elseif id == 9933 then 
        if btn == 1 then
            local deptsList = {"Staff", "Police Academy [PA]", "Central Patrol Division [CPD]", "Crime Scene Investigation [CSI]", "Cadets"}
            local selectedDept = deptsList[lst + 1]
            if selectedDept then
                sampAddChatMessage("{0633E5}[FM] {FFFFFF}Загрузка списка сотрудников отдела " .. selectedDept .. "...", -1)
                
                queueHttpRequest(GAS_URL .. "?action=get_dept&dept=" .. urlencode(safe_u8(selectedDept)), function(content)
                    if content and (content:sub(1,1) == "[" or content:sub(1,1) == "{") then
                        local res, data = pcall(decodeJson, content)
                        if res and type(data) == "table" and #data > 0 then
                            local s = "Ник\tЗвание\n"
                            offlineMembersList = {}
                            for i, item in ipairs(data) do
                                local decodedName = ""
                                local decodedRank = ""
                                
                                if type(item) == "table" then
                                    decodedName = u8:decode(item.name or "")
                                    decodedRank = u8:decode(item.rank or "")
                                else
                                    decodedName = u8:decode(item or "")
                                end
                                
                                table.insert(offlineMembersList, decodedName)
                                
                                local displayRank = (decodedRank and decodedRank ~= "") and decodedRank or "Неизвестно"
                                s = s .. decodedName .. "\t{A9A9A9}" .. displayRank .. "\n"
                            end
                            lua_thread.create(function() wait(50); sampShowDialog(9938, "{0633E5}Сотрудники: " .. selectedDept, s, "Выбрать", "Назад", 5) end)
                        else
                            sampAddChatMessage("{0633E5}[FM] {FF0000}Отдел пуст или данные не найдены.", -1)
                            lua_thread.create(function() wait(50); sampShowDialog(9933, "{0633E5}Выберите отдел", "Staff\nPolice Academy [PA]\nCentral Patrol Division [CPD]\nCrime Scene Investigation [CSI]\nCadets", "Выбрать", "Назад", 2) end)
                        end
                    else
                        sampAddChatMessage("{0633E5}[FM] {FF0000}Ошибка. Сервер вернул неверные данные.", -1)
                    end
                end)
            end
        else
            lua_thread.create(function() wait(50); sampShowDialog(9930, "{0633E5}Управление составом", "Список людей онлайн на повышение\nУправление игроками (онлайн)\nУправление игроками (оффлайн)", "Выбрать", "Назад", 2) end)
        end
        return false

    elseif id == 9938 then 
        if btn == 1 then
            local selected = offlineMembersList[lst + 1]
            if selected then
                selectedStaffMember = selected
                lua_thread.create(function() wait(50); sampShowDialog(9934, "{0633E5}Действия: " .. selectedStaffMember, "Перенос между отделами\nВыдать выговор\nОставить комментарий\n{A020F0}Информация о сотруднике", "Выбрать", "Назад", 2) end)
            end
        else
            local depts = "Staff\nPolice Academy [PA]\nCentral Patrol Division [CPD]\nCrime Scene Investigation [CSI]\nCadets"
            lua_thread.create(function() wait(50); sampShowDialog(9933, "{0633E5}Выберите отдел", depts, "Выбрать", "Назад", 2) end)
        end
        return false

    elseif id == 9934 then 
        if btn == 1 then
            if lst == 0 then 
                local depts = "Staff\nPolice Academy [PA]\nCentral Patrol Division [CPD]\nCrime Scene Investigation [CSI]\nCadets"
                lua_thread.create(function() wait(50); sampShowDialog(9935, "{0633E5}Перенос: " .. selectedStaffMember, depts, "Выбрать", "Назад", 2) end)
            elseif lst == 1 then 
                lua_thread.create(function() wait(50); sampShowDialog(9936, "{0633E5}Выговор: " .. selectedStaffMember, "{FFFFFF}Введите причину выговора:", "Выдать", "Назад", 1) end)
            elseif lst == 2 then 
                lua_thread.create(function() wait(50); sampShowDialog(9937, "{0633E5}Комментарий: " .. selectedStaffMember, "{FFFFFF}Введите текст комментария:", "Отправить", "Назад", 1) end)
            elseif lst == 3 then 
                sampAddChatMessage("{0633E5}[FM] {FFFFFF}Запрос информации о сотруднике " .. selectedStaffMember .. "...", -1)
                queueHttpRequest(GAS_URL .. "?action=mystat&name=" .. urlencode(safe_u8(selectedStaffMember)), function(content)
                    if content and content ~= "" then
                        local res, data = pcall(decodeJson, content)
                        if res and type(data) == "table" and data.sheet and data.headers and data.row then
                            local sheetName = u8:decode(tostring(data.sheet)) or "Неизвестно"
                            local text = string.format("{00FF00}Подразделение:{FFFFFF} %s\n\n", sheetName)
                            
                            local h = data.headers
                            local r = data.row
                            
                            for i = 1, #h do
                                if h[i] and r[i] then
                                    local headerName = u8:decode(tostring(h[i]))
                                    local rowValue = u8:decode(tostring(r[i]))
                                    
                                    if headerName ~= "" and rowValue ~= "" and rowValue ~= "0" and rowValue ~= "false" then
                                        text = text .. "{A020F0}" .. headerName .. ":{FFFFFF} " .. rowValue .. "\n"
                                    end
                                end
                            end
                            
                            local titleNick = r[1] and u8:decode(tostring(r[1])) or selectedStaffMember
                            sampShowDialog(9940, "{0633E5}Информация: " .. titleNick, text, "Назад", "", 0)
                        else
                            sampAddChatMessage("{0633E5}[FM] {FF0000}Данные сотрудника не найдены.", -1)
                        end
                    else
                        sampAddChatMessage("{0633E5}[FM] {FF0000}Ошибка: Пустой ответ от сервера.", -1)
                    end
                end)
            end
        else
            lua_thread.create(function() wait(50); sampShowDialog(9930, "{0633E5}Управление составом", "Список людей онлайн на повышение\nУправление игроками (онлайн)\nУправление игроками (оффлайн)", "Выбрать", "Назад", 2) end)
        end
        return false
        
    elseif id == 9940 then
        lua_thread.create(function() wait(50); sampShowDialog(9934, "{0633E5}Действия: " .. selectedStaffMember, "Перенос между отделами\nВыдать выговор\nОставить комментарий\n{A020F0}Информация о сотруднике", "Выбрать", "Назад", 2) end)
        return false

    elseif id == 9935 then 
        if btn == 1 then
            local depts = {"Staff", "Police Academy [PA]", "Central Patrol Division [CPD]", "Crime Scene Investigation [CSI]", "Cadets"}
            local targetDept = depts[lst + 1]
            sampAddChatMessage("{0633E5}[FM] {FFFFFF}Запрос на перенос отправлен...", -1)
            local url = GAS_URL .. "?action=move_dept&name=" .. urlencode(safe_u8(selectedStaffMember)) .. "&target=" .. urlencode(safe_u8(targetDept)) .. "&inst=" .. urlencode(safe_u8(GetNick()))
            queueHttpRequest(url, function(content)
                if content and (content:find("Not found") or content:find("Player not found")) then
                    sampAddChatMessage("{0633E5}[FM] {FF0000}Ошибка: Сотрудник {FFFFFF}" .. tostring(selectedStaffMember) .. "{FF0000} не найден в таблице!", -1)
                else
                    sampAddChatMessage("{0633E5}[FM] {00FF00}Игрок {FFFFFF}" .. tostring(selectedStaffMember) .. "{00FF00} перенесен в {FFFFFF}" .. targetDept .. "{00FF00}!", -1)
                    updateFromBase()
                end
            end)
        else
            lua_thread.create(function() wait(50); sampShowDialog(9934, "{0633E5}Действия: " .. selectedStaffMember, "Перенос между отделами\nВыдать выговор\nОставить комментарий\n{A020F0}Информация о сотруднике", "Выбрать", "Назад", 2) end)
        end
        return false

    elseif id == 9936 then 
        if btn == 1 and inp and inp ~= "" then
            sampAddChatMessage("{0633E5}[FM] {FFFFFF}Запись выговора...", -1)
            local url = GAS_URL .. "?action=update_offline&name=" .. urlencode(safe_u8(selectedStaffMember)) .. "&col=warning&val=" .. urlencode(safe_u8(inp)) .. "&inst=" .. urlencode(safe_u8(GetNick()))
            queueHttpRequest(url, function(content)
                if content and (content:find("Not found") or content:find("Player not found")) then
                    sampAddChatMessage("{0633E5}[FM] {FF0000}Ошибка: Сотрудник {FFFFFF}" .. tostring(selectedStaffMember) .. "{FF0000} не найден в таблице!", -1)
                else
                    sampAddChatMessage("{0633E5}[FM] {00FF00}Выговор игроку {FFFFFF}" .. tostring(selectedStaffMember) .. "{00FF00} успешно записан!", -1)
                    updateFromBase()
                end
            end)
        else
            lua_thread.create(function() wait(50); sampShowDialog(9934, "{0633E5}Действия: " .. selectedStaffMember, "Перенос между отделами\nВыдать выговор\nОставить комментарий\n{A020F0}Информация о сотруднике", "Выбрать", "Назад", 2) end)
        end
        return false

    elseif id == 9937 then 
        if btn == 1 and inp and inp ~= "" then
            sampAddChatMessage("{0633E5}[FM] {FFFFFF}Запись комментария...", -1)
            local url = GAS_URL .. "?action=update_offline&name=" .. urlencode(safe_u8(selectedStaffMember)) .. "&col=comment&val=" .. urlencode(safe_u8(inp)) .. "&inst=" .. urlencode(safe_u8(GetNick()))
            queueHttpRequest(url, function(content)
                if content and (content:find("Not found") or content:find("Player not found")) then
                    sampAddChatMessage("{0633E5}[FM] {FF0000}Ошибка: Сотрудник {FFFFFF}" .. tostring(selectedStaffMember) .. "{FF0000} не найден в таблице!", -1)
                else
                    sampAddChatMessage("{0633E5}[FM] {00FF00}Комментарий к {FFFFFF}" .. tostring(selectedStaffMember) .. "{00FF00} успешно записан!", -1)
                    updateFromBase() 
                end
            end)
        else
            lua_thread.create(function() wait(50); sampShowDialog(9934, "{0633E5}Действия: " .. selectedStaffMember, "Перенос между отделами\nВыдать выговор\nОставить комментарий\n{A020F0}Информация о сотруднике", "Выбрать", "Назад", 2) end)
        end
        return false

    elseif id == 9910 then
        if btn == 1 then
            if lst == 0 then 
                showHUD = not showHUD
                sampAddChatMessage(showHUD and "{0633E5}[FM] {00FF00}HUD включен" or "{0633E5}[FM] {FF0000}HUD выключен", -1)
                lua_thread.create(function() wait(50); openFmMenu() end)
            elseif lst == 1 then 
                if myPrio < 2 then
                    sampAddChatMessage("{0633E5}[FM] {FF0000}Вам недоступно чтение лекций.", -1)
                    lua_thread.create(function() wait(50); openFmMenu() end)
                    return false
                end
                if #lectureKeys == 0 then loadLecturesLocally() end
                if #lectureKeys == 0 then
                    sampAddChatMessage("{0633E5}[FM] {FF0000}Список лекций пуст!", -1)
                    lua_thread.create(function() wait(50); openFmMenu() end)
                    return false
                end
                local s = ""
                for _, k in ipairs(lectureKeys) do s = s .. k .. "\n" end
                lua_thread.create(function() wait(50); sampShowDialog(9913, "{0633E5}Меню лекций", s, "Выбрать", "Отмена", 2) end)
            elseif lst == 2 then 
                syncAll(false)
            else 
                if #cadetsOnline > 0 then
                    selectedCadet = cadetsOnline[lst - 2]
                    if selectedCadet and selectedCadet.displayName then
                        lua_thread.create(function()
                            wait(50)
                            sampShowDialog(9911, "{0633E5}" .. selectedCadet.displayName, "Лекция\nТеория\nПрактика\nОтчет\nКомментарий\n{A020F0}Информация\n{FF0000}Сброс прогресса", "ОК", "Назад", 2)
                        end)
                    end
                end
            end
        else
            lua_thread.create(function() 
                wait(50)
                sampShowDialog(9909, "{0633E5}Главное меню", "1. Управление составом\n2. Управление кадетами\n3. Моя статистика", "Выбрать", "Закрыть", 2)
            end)
        end
        return false
    elseif id == 9911 then
        if btn == 1 then
            if not selectedCadet or not selectedCadet.rawName then return false end
            local safeName = trim(selectedCadet.rawName)
            
            if lst == 5 then
                local db = cadetsDB and cadetsDB[safeName] or nil
                local l = (db and isMarked(db.lecture)) and "{00FF00}прошел" or "{FF0000}не прошел"
                local t = (db and isMarked(db.theory)) and "{00FF00}прошел" or "{FF0000}не прошел"
                local p = (db and isMarked(db.practice)) and "{00FF00}прошел" or "{FF0000}не прошел"
                local d = (db and isMarked(db.isTwoDays)) and "{00FF00}прошло" or "{FF0000}не прошло"
                local rep = (db and db.report and db.report ~= "") and "{00FF00}залит" or "{FF0000}не залит"
                local com = (db and db.comment and db.comment ~= "") and "{00FF00}добавлен" or "{FF0000}не добавлен"
                local info_text = string.format("Лекция: %s\n{FFFFFF}Теория: %s\n{FFFFFF}Практика: %s\n{FFFFFF}Два дня: %s\n{FFFFFF}Отчет: %s\n{FFFFFF}Комментарий: %s", l, t, p, d, rep, com)
                lua_thread.create(function() wait(50); sampShowDialog(9912, "{0633E5}Инфо: " .. (selectedCadet.displayName or ""), info_text, "Назад", "", 0) end)
            elseif lst == 6 then
                sampAddChatMessage("{0633E5}[FM] {FFFFFF}Запрос на сброс отправлен...", -1)
                if cadetsDB and cadetsDB[safeName] then cadetsDB[safeName] = nil end
                updateCadetInBase(selectedCadet.rawName, "reset", nil, true)
                lua_thread.create(function()
                    wait(100)
                    if selectedCadet and selectedCadet.displayName then
                        sampShowDialog(9911, "{0633E5}" .. selectedCadet.displayName, "Лекция\nТеория\nПрактика\nОтчет\nКомментарий\n{A020F0}Информация\n{FF0000}Сброс прогресса", "ОК", "Назад", 2)
                    end
                end)
            elseif lst == 3 then
                lua_thread.create(function() wait(50); sampShowDialog(9914, "{0633E5}Отчет", "{FFFFFF}Введите ссылку на отчет:", "Отправить", "Отмена", 1) end)
            elseif lst == 4 then
                lua_thread.create(function() wait(50); sampShowDialog(9915, "{0633E5}Комментарий", "{FFFFFF}Введите комментарий:", "Отправить", "Отмена", 1) end)
            else
                local columns = {"lecture", "theory", "practice"}
                local colName = columns[lst + 1]
                if colName then
                    sampAddChatMessage("{0633E5}[FM] {FFFFFF}Запрос на обновление...", -1)
                    if not cadetsDB then cadetsDB = {} end
                    if not cadetsDB[safeName] then cadetsDB[safeName] = {} end
                    cadetsDB[safeName][colName] = "1"
                    updateCadetInBase(selectedCadet.rawName, colName, nil, true)
                    lua_thread.create(function()
                        wait(100)
                        if selectedCadet and selectedCadet.displayName then
                            sampShowDialog(9911, "{0633E5}" .. selectedCadet.displayName, "Лекция\nТеория\nПрактика\nОтчет\nКомментарий\n{A020F0}Информация\n{FF0000}Сброс прогресса", "ОК", "Назад", 2)
                        end
                    end)
                end
            end
        else
            lua_thread.create(function() wait(50); openFmMenu() end)
        end
        return false
    elseif id == 9912 then
        lua_thread.create(function() 
            wait(50)
            if selectedCadet and selectedCadet.displayName then
                sampShowDialog(9911, "{0633E5}" .. selectedCadet.displayName, "Лекция\nТеория\nПрактика\nОтчет\nКомментарий\n{A020F0}Информация\n{FF0000}Сброс прогресса", "ОК", "Назад", 2) 
            end
        end)
        return false
    elseif id == 9913 then
        if btn == 1 then
            local key = lectureKeys[lst + 1]
            if key and lecturesDB[key] then
                if lectureThread then
                    stopLecture = true
                    lua_thread.create(function()
                        while lectureThread ~= nil do wait(10) end
                        stopLecture = false
                        startLecturePlay(key)
                    end)
                else
                    startLecturePlay(key)
                end
            end
        else
            lua_thread.create(function() wait(50); openFmMenu() end)
        end
        return false
    elseif id == 9914 then
        if btn == 1 and inp and inp:match("%S") then
            if not selectedCadet or not selectedCadet.rawName then return false end
            local safeName = trim(selectedCadet.rawName)
            if not cadetsDB then cadetsDB = {} end
            if not cadetsDB[safeName] then cadetsDB[safeName] = {} end
            cadetsDB[safeName].report = inp
            updateCadetInBase(selectedCadet.rawName, "report", nil, true, inp)
        else
            lua_thread.create(function() 
                wait(50)
                if selectedCadet and selectedCadet.displayName then
                    sampShowDialog(9911, "{0633E5}" .. selectedCadet.displayName, "Лекция\nТеория\nПрактика\nОтчет\nКомментарий\n{A020F0}Информация\n{FF0000}Сброс прогресса", "ОК", "Назад", 2) 
                end
            end)
        end
        return false
    elseif id == 9915 then
        if btn == 1 and inp and inp:match("%S") then
            if not selectedCadet or not selectedCadet.rawName then return false end
            local safeName = trim(selectedCadet.rawName)
            if not cadetsDB then cadetsDB = {} end
            if not cadetsDB[safeName] then cadetsDB[safeName] = {} end
            cadetsDB[safeName].comment = inp
            updateCadetInBase(selectedCadet.rawName, "comment", nil, true, inp)
        else
            lua_thread.create(function() 
                wait(50)
                if selectedCadet and selectedCadet.displayName then
                    sampShowDialog(9911, "{0633E5}" .. selectedCadet.displayName, "Лекция\nТеория\nПрактика\nОтчет\nКомментарий\n{A020F0}Информация\n{FF0000}Сброс прогресса", "ОК", "Назад", 2) 
                end
            end)
        end
        return false
    end
end

function sampev.onServerMessage(clr, txt)
    if not txt then return end 
    local cleanTxt = txt:gsub("{%x+}", "") 
    
    if isUpdating then
        if cleanTxt:find("ID:") and cleanTxt:find("|") then
            local id, date_mem, nick = cleanTxt:match("ID:%s*(%d+)%s*|%s*%d+:%d+%s*([%d%.]+)%s*|%s*([%a%d_]+)")

            if nick and id then
                local rank = ""
                local rest_of_line = cleanTxt:match(nick .. ".-:%s*(.+)")

                if rest_of_line then
                    rank = rest_of_line:match("^(.-)%s*%-") or rest_of_line
                    rank = trim(rank)
                end

                table.insert(factionOnline, {rawName = nick, id = id, rank = rank, joinDate = date_mem or ""})
                
                if cleanTxt:find("Кадет") or cleanTxt:find("Cadet") then
                    table.insert(tempCadets, {rawName = nick, displayName = nick:gsub("_", " "), id = id, joinDate = date_mem or ""})
                end
            end
            return false
        end
        
        if cleanTxt:find("Всего%:") or cleanTxt:find("Всего в сети") or cleanTxt:find("Онлайн организации") then
            isUpdating = false
            cadetsOnline = tempCadets
            
            if myPrio >= 2 then
                local batchData = {}
                for _, c in ipairs(cadetsOnline) do 
                    if c and c.rawName then
                        table.insert(batchData, {n = safe_u8(c.rawName), d = safe_u8(c.joinDate)})
                    end
                end
                
                if #batchData > 0 then
                    local chunkSize = 15
                    local instNick = urlencode(safe_u8(GetNick()))
                    for i = 1, #batchData, chunkSize do
                        local chunk = {}
                        for j = i, math.min(i + chunkSize - 1, #batchData) do
                            table.insert(chunk, batchData[j])
                        end
                        local safeJson = urlencode(encodeJson(chunk))
                        local batchUrl = GAS_URL .. "?action=batch_sync&instructor=" .. instNick .. "&data=" .. safeJson
                        queueHttpRequest(batchUrl, function() end)
                    end
                end
            end
            
            if isMaster or forcedMasterSync then
                local onlineData = {}
                for _, m in ipairs(factionOnline) do
                    table.insert(onlineData, {n = safe_u8(m.rawName), id = safe_u8(m.id), r = safe_u8(m.rank)})
                end
                
                if #onlineData > 0 then
                    local chunkSize = 15
                    for i = 1, #onlineData, chunkSize do
                        local chunk = {}
                        for j = i, math.min(i + chunkSize - 1, #onlineData) do
                            table.insert(chunk, onlineData[j])
                        end
                        
                        local safeOnlineJson = urlencode(encodeJson(chunk))
                        local isFirst = (i == 1) and "&clear=true" or ""
                        local updateOnlineUrl = GAS_URL .. "?action=update_online&list=" .. safeOnlineJson .. isFirst
                        
                        if i == 1 then
                            sampAddChatMessage("{0633E5}[FM] {FFFFFF}Сотрудников найдено: {00FF00}" .. #onlineData .. "{FFFFFF}. Отправляем в таблицу...", -1)
                        end
                        
                        queueHttpRequest(updateOnlineUrl, function(res)
                            if res and res:find("Members synced") then
                                if i + chunkSize > #onlineData then
                                    sampAddChatMessage("{0633E5}[FM] {00FF00}Лист Members успешно обновлен!", -1)
                                end
                            else
                                sampAddChatMessage("{0633E5}[FM] {FF0000}Ошибка записи таблицы. Ответ сервера: " .. tostring(res), -1)
                            end
                        end)
                    end
                else
                    sampAddChatMessage("{0633E5}[FM] {FF0000}Ошибка: скрипт не нашел ни одного сотрудника в /members. Проверь парсер.", -1)
                end
            end
            
            return false
        end
        
        return false 
    end
end