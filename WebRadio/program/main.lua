
package.path = package.path .. ";/mnt/mmc/ports/WebRadio/libs/?.lua"
-- Caminho do arquivo de PIDs
local pidFilePath = "/mnt/mmc/ports/WebRadio/PID.dat"

local previousLogoLoadError = nil

local json = require("json")
local ffi = require("ffi")
local socket = require("socket")

ffi.cdef[[
    int open(const char *pathname, int flags);
    int read(int fd, void *buf, size_t count);
    int close(int fd);
]]

local O_RDONLY = 0
local bars = {}
local numBars = 64
local pipe_fd

local stations = {}
local currentStation = 1
local stationLogo
local player_process
local pid
local font

local logPath = "/mnt/mmc/ports/WebRadio/debug.log"
local downloadLogo = true
local logoLoadingThread = nil
local logoChannel = love.thread.getChannel("logoChannel")
local logoLoadError = false

-- Função para log
local function log(message)
    local file, err = io.open(logPath, "a")
    if not file then
        print("Erro ao abrir debug.log: " .. err)
        return
    end
    local success, writeErr = pcall(function()
        file:write(os.date("%Y-%m-%d %H:%M:%S") .. " - " .. message .. "\n")
    end)
    if not success then
        print("Erro ao escrever no debug.log: " .. writeErr)
    end
    file:close()
end

local function killOldPIDs(keepPID)
    local file, err = io.open(pidFilePath, "r")
    if not file then
        log("Erro ao abrir o arquivo PID.dat para leitura: " .. err)
        return
    end

    local pids = {}
    for line in file:lines() do
        local pid = tonumber(line)
        if pid and pid ~= keepPID then
            table.insert(pids, pid)
        end
    end
    file:close()

    -- Kill all PIDs except the keepPID
    for _, pid in ipairs(pids) do
        os.execute("kill " .. pid)
        log("Matando PID " .. pid)
    end

    -- Update the PID file to only keep the most recent PID
    file, err = io.open(pidFilePath, "w")
    if not file then
        log("Erro ao abrir o arquivo PID.dat para escrita: " .. err)
        return
    end
    file:write(keepPID .. "\n")
    file:close()
    log("PID " .. keepPID .. " mantido no arquivo PID.dat")
end

-- Função para adicionar um PID ao arquivo
local function addPIDToFile(pid)
    local file, err = io.open(pidFilePath, "a")
    if not file then
        log("Erro ao abrir o arquivo PID.dat para escrita: " .. err)
        return
    end
    file:write(pid .. "\n")
    file:close()
    log("PID " .. pid .. " adicionado ao arquivo PID.dat")
end

-- Função para remover um PID do arquivo
local function removePIDFromFile(pid)
    local file, err = io.open(pidFilePath, "r")
    if not file then
        log("Erro ao abrir o arquivo PID.dat para leitura: " .. err)
        return
    end

    local lines = {}
    for line in file:lines() do
        if line ~= tostring(pid) then
            table.insert(lines, line)
        end
    end
    file:close()

    file, err = io.open(pidFilePath, "w")
    if not file then
        log("Erro ao abrir o arquivo PID.dat para escrita: " .. err)
        return
    end

    for _, line in ipairs(lines) do
        file:write(line .. "\n")
    end
    file:close()
    log("PID " .. pid .. " removido do arquivo PID.dat")
end



-- Carrega os dados JSON
function love.load()
    log("Iniciando carregamento da aplicação...")

    local file, err = love.filesystem.read("stations.json")
    if not file then
        log("Erro ao ler o arquivo JSON: " .. err)
        return
    end
    stations = json.decode(file)
    if not stations then
        log("Erro ao decodificar os dados JSON")
        return
    end

    log("Estações carregadas com sucesso")

    font = love.graphics.newFont(30)

    for i = 1, numBars do
        bars[i] = 0
    end

    pipe_fd = ffi.C.open("/tmp/pipewire-audio.raw", O_RDONLY)
    if pipe_fd == -1 then
        log("Erro ao abrir pipe nomeado")
    else
        log("Pipe nomeado aberto com sucesso")
    end

    loadStation(currentStation)
end

-- Função para iniciar o download do logo em uma thread separada
local function startLogoLoadingThread(logoUrl)
    if logoLoadingThread then
        logoLoadingThread:release()
    end

    logoLoadError = false

    log("Iniciando carregamento do logo: " .. logoUrl)

    -- Cria e inicia uma nova thread para o download do logo
    logoLoadingThread = love.thread.newThread([[
        local http = require("socket.http")
        local ltn12 = require("ltn12")
        local love = require("love")

        local logoUrl = ...
        local response_body = {}
        local res, code, headers, status = http.request{
            url = logoUrl,
            sink = ltn12.sink.table(response_body),
            timeout = 10
        }

        if res then
            if code == 200 then
                local logoData = love.filesystem.newFileData(table.concat(response_body), "logo.png")
                love.thread.getChannel("logoChannel"):push(logoData)
                love.thread.getChannel("logoChannel"):push("done")
            else
                love.thread.getChannel("logoChannel"):push(nil)
                love.thread.getChannel("logoChannel"):push("failed")
            end
        else
            love.thread.getChannel("logoChannel"):push(nil)
            love.thread.getChannel("logoChannel"):push("failed")
        end
    ]])
    logoLoadingThread:start(logoUrl)
end

function loadStation(index)
    log("Iniciando carregamento da estação " .. index)

    -- Handle old PIDs
    if pid then
        log("Parando o stream atual com PID " .. pid)
        os.execute("kill " .. pid)
        player_process:close()
        removePIDFromFile(pid)  -- Remove the old PID from the file
        pid = nil
    end

    stationLogo = nil

    local station = stations[index]

    love.graphics.clear()
    love.graphics.setFont(font)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print("Nome: " .. station["Radio Name"], 50, 300)
    love.graphics.print("País: " .. station["Radio Country"], 50, 350)
    love.graphics.printf("Descrição: " .. station["Radio Description"], 50, 400, 400)
    love.graphics.print("Carregando logo...", 50, 450)
    love.graphics.present()

    player_process = io.popen("mpv --no-video " .. station["Radio URL for stream"] .. " & echo $!")
    pid = player_process:read("*n")

    log("Novo stream iniciado com PID " .. pid)
    addPIDToFile(pid)  -- Add the new PID to the file
    killOldPIDs(pid)   -- Kill old PIDs and keep only the new one

    local newLogoUrl = station["Radio Logo picture"]
    if downloadLogo and newLogoUrl and newLogoUrl ~= "" then
        startLogoLoadingThread(newLogoUrl)
    else
        log("Nenhuma URL de logo fornecida ou download de logo desativado.")
        logoLoadingThread = nil
        logoLoadError = true
    end

    log("Carregamento da estação " .. index .. " concluído")
end


function love.update(dt)
    -- Verifica se há um novo logo na fila
    local logoData = logoChannel:pop()
    if logoData then
        if type(logoData) == "userdata" then
            stationLogo = love.graphics.newImage(logoData)
            log("Logo carregado com sucesso")
            logoLoadError = false
        elseif logoData == "failed" then
            log("Falha ao carregar logo")
            stationLogo = nil
            logoLoadError = true
        end
    end

    local buffer = ffi.new("int16_t[?]", numBars)
    local bytes_read = ffi.C.read(pipe_fd, buffer, numBars * 2)

    if bytes_read > 0 then
        for i = 1, numBars do
            bars[i] = math.abs(buffer[i - 1] / 32768.0) * 200
        end
    end
end


function love.draw()
    local station = stations[currentStation]

    love.graphics.setFont(font)
    love.graphics.setColor(1, 1, 1)

    if stationLogo then
        love.graphics.draw(stationLogo, 50, 50, 0, 0.5, 0.5)
    else
        love.graphics.print("Nome: " .. station["Radio Name"], 50, 300)
        love.graphics.print("País: " .. station["Radio Country"], 50, 350)
        love.graphics.printf("Descrição: " .. station["Radio Description"], 50, 400, 400)

        if logoLoadError then
            if previousLogoLoadError ~= true then
                log("Tentando desenhar a mensagem de erro na interface")
                previousLogoLoadError = true  -- Atualiza o estado
            end
            love.graphics.print("Não foi possível descarregar o logo", 50, 450)
        else
            if previousLogoLoadError ~= false then
                previousLogoLoadError = false  -- Atualiza o estado
            end
            love.graphics.print("Carregando logo...", 50, 450)
        end
    end

    local barWidth = 10
    local spacing = 5
    local startX = 50
    local startY = 550
    for i = 1, numBars do
        love.graphics.setColor(0.2, 0.8, 0.2)
        love.graphics.rectangle("fill", startX + (i - 1) * (barWidth + spacing), startY - bars[i], barWidth, bars[i])
    end
end

function love.keypressed(key)
    if key == "right" then
        currentStation = currentStation % #stations + 1
        log("Mudando para a próxima estação: " .. currentStation)
        loadStation(currentStation)
    elseif key == "left" then
        currentStation = (currentStation - 2) % #stations + 1
        log("Mudando para a estação anterior: " .. currentStation)
        loadStation(currentStation)
    elseif key == "a" then
        log("Saindo da aplicação pressionando 'A'")
        love.event.quit()
    end
end


function love.quit()
    log("Saindo da aplicação...")

    if pid then
        log("Parando o player com PID " .. pid)
        os.execute("kill " .. pid)
        player_process:close()
        removePIDFromFile(pid)  -- Remove o PID do arquivo ao sair
    end

    if pipe_fd then
        ffi.C.close(pipe_fd)
        log("Pipe nomeado fechado")
    end
end