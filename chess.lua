--!native
--!optimize 2

---- environment ----
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local MathSqrt = math.sqrt
local TableInsert = table.insert
local TableConcat = table.concat
local TableCreate = table.create
local TableClear = table.clear
local StringFormat = string.format
local StringSub = string.sub
local Pcall = pcall
local OsClock = os.clock
local TaskSpawn = task.spawn

---- constants ----
local SCAN_INTERVAL: number = 0.5
local MAX_TABLE_DISTANCE: number = 50
local STOCKFISH_REQUEST_INTERVAL: number = 2
local STOCKFISH_DEPTH: number = 8

local STOCKFISH_SERVER_URL: string = "http://127.0.0.1:5000/analyze"

local LINE_COLOR: Color3 = Color3.fromRGB(0, 255, 0)
local CIRCLE_COLOR: Color3 = Color3.fromRGB(255, 255, 0)
local LINE_THICKNESS: number = 3
local CIRCLE_RADIUS: number = 15

local FILES: {string} = {"a", "b", "c", "d", "e", "f", "g", "h"}
local RANKS: {string} = {"1", "2", "3", "4", "5", "6", "7", "8"}

local PIECE_FEN_MAP: {[string]: string} = {
    White_Pawn = "P", White_Knight = "N", White_Bishop = "B",
    White_Rook = "R", White_Queen = "Q", White_King = "K",
    Black_Pawn = "p", Black_Knight = "n", Black_Bishop = "b",
    Black_Rook = "r", Black_Queen = "q", Black_King = "k"
}

local FILE_MAP: {[string]: number} = {
    a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8
}

---- types ----
export type ChessPiece = {
    name: string,
    color: string,
    type: string,
    tile: string,
    model: Model,
    position: Vector3?
}

export type ChessBoard = {[string]: ChessPiece?}

export type ChessMove = {
    from: string,
    to: string,
    piece: ChessPiece?,
    capture: ChessPiece?,
    fromPos: Vector3?,
    toPos: Vector3?,
    evaluation: number?
}

export type ChessTable = {
    model: Model,
    isActive: boolean,
    board: ChessBoard,
    pieces: {ChessPiece},
    playerColor: string?,
    whitePlayer: string?,
    blackPlayer: string?,
    bestMove: ChessMove?,
    boardFolder: Instance?,
    lastStockfishRequest: number,
    currentFEN: string?,
    pendingRequest: boolean
}

---- variables ----
local LocalPlayer: Player? = Players.LocalPlayer
local Camera: Camera? = Workspace.CurrentCamera
local ActiveTables: {[Model]: ChessTable} = {}
local LastScanTime: number = 0
local LastPrintTime: number = 0

local TempFENBuffer: {string} = TableCreate(8)

local RequestQueue: {{table: ChessTable, fen: string}} = {}
local ProcessingRequest: boolean = false

---- helper functions ----

local function ValidateParent(instance: Instance?): boolean
    if not instance then return false end
    local success: boolean = Pcall(function()
        return instance.Parent ~= nil
    end)
    return success
end

local function SafeFindFirstChild(instance: Instance?, name: string): Instance?
    if not instance or not ValidateParent(instance) then return nil end
    local success: boolean, result: Instance? = Pcall(function()
        return instance:FindFirstChild(name)
    end)
    return success and result or nil
end

local function SafeGetChildren(instance: Instance?): {Instance}?
    if not instance or not ValidateParent(instance) then return nil end
    local success: boolean, result: {Instance}? = Pcall(function()
        return instance:GetChildren()
    end)
    return success and result or nil
end

local function GetInstanceName(instance: Instance?): string?
    if not instance or not ValidateParent(instance) then return nil end
    local success: boolean, name: string? = Pcall(function()
        return instance.Name
    end)
    return success and name or nil
end

local function GetBoolValue(instance: Instance?): boolean?
    if not instance or not ValidateParent(instance) then return nil end
    local success: boolean, value: boolean? = Pcall(function()
        return (instance :: any).Value
    end)
    return success and value or nil
end

local function GetStringValue(instance: Instance?): string?
    if not instance or not ValidateParent(instance) then return nil end
    local success: boolean, value: string? = Pcall(function()
        return (instance :: any).Value
    end)
    return success and value or nil
end

local function GetPartPosition(part: BasePart?): Vector3?
    if not part or not ValidateParent(part) then return nil end
    local success: boolean, pos: Vector3? = Pcall(function()
        return part.Position
    end)
    return success and pos or nil
end

local function GetModelPosition(model: Model): Vector3?
    if not ValidateParent(model) then return nil end
    
    local success: boolean, primaryPart: BasePart? = Pcall(function()
        return model.PrimaryPart
    end)
    
    if success and primaryPart and ValidateParent(primaryPart) then
        return GetPartPosition(primaryPart)
    end
    
    local children: {Instance}? = SafeGetChildren(model)
    if children then
        for i = 1, #children do
            local child: Instance = children[i]
            if ValidateParent(child) then
                local className: string? = nil
                Pcall(function()
                    className = child.ClassName
                end)
                
                if className == "BasePart" or className == "Part" or className == "MeshPart" then
                    return GetPartPosition(child :: BasePart)
                end
            end
        end
    end
    
    return nil
end

local function GetPlayerPosition(): Vector3?
    if not LocalPlayer then return nil end
    
    local success: boolean, character: Model? = Pcall(function()
        return LocalPlayer.Character
    end)
    
    if not success or not character or not ValidateParent(character) then return nil end
    
    local hrp: Instance? = SafeFindFirstChild(character, "HumanoidRootPart")
    if not hrp or not ValidateParent(hrp) then return nil end
    
    return GetPartPosition(hrp :: BasePart)
end

local function GetDistanceToPlayer(position: Vector3): number?
    local playerPos: Vector3? = GetPlayerPosition()
    if not playerPos then return nil end
    
    local dx: number = position.X - playerPos.X
    local dy: number = position.Y - playerPos.Y
    local dz: number = position.Z - playerPos.Z
    
    return MathSqrt(dx*dx + dy*dy + dz*dz)
end

local function GetTilePosition(boardFolder: Instance?, tile: string): Vector3?
    if not boardFolder or not ValidateParent(boardFolder) then return nil end
    local tilePart: Instance? = SafeFindFirstChild(boardFolder, tile)
    if not tilePart or not ValidateParent(tilePart) then return nil end
    return GetPartPosition(tilePart :: BasePart)
end

local function SafeWorldToScreen(camera: Camera?, position: Vector3): (Vector3?, boolean)
    if not camera or not ValidateParent(camera) then return nil, false end
    
    local success: boolean, screenPos: Vector3?, onScreen: boolean? = Pcall(function()
        local sp, os = camera:WorldToScreenPoint(position)
        return sp, os
    end)
    
    if success and screenPos and onScreen then
        return screenPos, onScreen
    end
    
    return nil, false
end

---- chess logic ----

local function ParsePieceName(pieceName: string): (string?, string?)
    local underscore: number? = pieceName:find("_")
    if not underscore then return nil, nil end
    return StringSub(pieceName, 1, underscore - 1), StringSub(pieceName, underscore + 1)
end

local function TileToCoords(tile: string): (number?, number?)
    if #tile ~= 2 then return nil, nil end
    local fileNum: number? = FILE_MAP[StringSub(tile, 1, 1)]
    local rankNum: number? = tonumber(StringSub(tile, 2, 2))
    if fileNum and rankNum and rankNum >= 1 and rankNum <= 8 then
        return fileNum, rankNum
    end
    return nil, nil
end

local function CoordsToTile(file: number, rank: number): string?
    if file < 1 or file > 8 or rank < 1 or rank > 8 then return nil end
    return FILES[file] .. RANKS[rank]
end

local function IsValidTile(tile: string): boolean
    if tile == "-" then return false end
    local file, rank = TileToCoords(tile)
    return file ~= nil and rank ~= nil
end

local function GenerateFEN(chessTable: ChessTable): string?
    if not chessTable.playerColor then return nil end
    
    TableClear(TempFENBuffer)
    
    for rank = 8, 1, -1 do
        local rankStr: string = ""
        local emptyCount: number = 0
        
        for file = 1, 8 do
            local tile: string? = CoordsToTile(file, rank)
            if not tile then continue end
            
            local piece: ChessPiece? = chessTable.board[tile]
            
            if piece then
                if emptyCount > 0 then
                    rankStr = rankStr .. tostring(emptyCount)
                    emptyCount = 0
                end
                local fenChar: string? = PIECE_FEN_MAP[piece.color .. "_" .. piece.type]
                if fenChar then
                    rankStr = rankStr .. fenChar
                end
            else
                emptyCount = emptyCount + 1
            end
        end
        
        if emptyCount > 0 then
            rankStr = rankStr .. tostring(emptyCount)
        end
        
        TableInsert(TempFENBuffer, rankStr)
    end
    
    local position: string = TableConcat(TempFENBuffer, "/")
    local activeColor: string = chessTable.playerColor == "White" and "w" or "b"
    return StringFormat("%s %s KQkq - 0 1", position, activeColor)
end

---- STOCKFISH API ----

local function ParseStockfishMove(moveStr: string): (string?, string?)
    if #moveStr < 4 then return nil, nil end
    return StringSub(moveStr, 1, 2), StringSub(moveStr, 3, 4)
end

local function RequestStockfishMove(chessTable: ChessTable): ()
    local currentTime: number = OsClock()
    
    if chessTable.pendingRequest then return end
    if currentTime - chessTable.lastStockfishRequest < STOCKFISH_REQUEST_INTERVAL then return end
    
    local fen: string? = GenerateFEN(chessTable)
    if not fen or chessTable.currentFEN == fen then return end
    
    chessTable.lastStockfishRequest = currentTime
    chessTable.currentFEN = fen
    chessTable.pendingRequest = true
    
    TableInsert(RequestQueue, {table = chessTable, fen = fen})
end

local function ProcessRequestQueue(): ()
    if ProcessingRequest then return end
    if #RequestQueue == 0 then return end
    
    ProcessingRequest = true
    
    TaskSpawn(function()
        while #RequestQueue > 0 do
            local request = table.remove(RequestQueue, 1)
            local chessTable = request.table
            local fen = request.fen
            
            if not ValidateParent(chessTable.model) then
                chessTable.pendingRequest = false
                continue
            end
            task.wait(0.8)
            
            if not ValidateParent(chessTable.model) then
                chessTable.pendingRequest = false
                continue
            end
            
            local success: boolean, response: string? = Pcall(function()
                local requestData: string = StringFormat('{"fen":"%s","depth":%d}', fen, STOCKFISH_DEPTH)
                return game:HttpPost(STOCKFISH_SERVER_URL, requestData, "application/json", "application/json", "")
            end)
            chessTable.pendingRequest = false
            
            if success and response and #response > 0 then
                local bestmove: string? = response:match('"bestmove":"([^"]+)"')
                local evaluation: string? = response:match('"evaluation":([%-]?%d+%.?%d*)')
                
                if bestmove then
                    local from, to = ParseStockfishMove(bestmove)
                    
                    if from and to and IsValidTile(from) and IsValidTile(to) then
                        local piece: ChessPiece? = chessTable.board[from]
                        local capture: ChessPiece? = chessTable.board[to]
                        
                        local fromPos: Vector3? = piece and piece.position or GetTilePosition(chessTable.boardFolder, from)
                        local toPos: Vector3? = GetTilePosition(chessTable.boardFolder, to)
                        
                        chessTable.bestMove = {
                            from = from,
                            to = to,
                            piece = piece,
                            capture = capture,
                            fromPos = fromPos,
                            toPos = toPos,
                            evaluation = evaluation and tonumber(evaluation) or nil
                        }
                    end
                end
            end
            task.wait(0.5)
        end
        
        ProcessingRequest = false
    end)
end



---- SCANNING ----

local function ParseChessTable(tableModel: Model): ChessTable?
    local isActiveValue: Instance? = SafeFindFirstChild(tableModel, "IsGameActive")
    local isActive: boolean? = GetBoolValue(isActiveValue)
    
    if not isActive then return nil end
    
    local whitePlayerValue: Instance? = SafeFindFirstChild(tableModel, "WhitePlayer")
    local blackPlayerValue: Instance? = SafeFindFirstChild(tableModel, "BlackPlayer")
    
    local whitePlayer: string? = GetStringValue(whitePlayerValue)
    local blackPlayer: string? = GetStringValue(blackPlayerValue)
    
    local playerColor: string? = nil
    if LocalPlayer then
        local playerName: string? = nil
        Pcall(function()
            playerName = LocalPlayer.Name
        end)
        
        if playerName then
            if whitePlayer == playerName then
                playerColor = "White"
            elseif blackPlayer == playerName then
                playerColor = "Black"
            end
        end
    end
    
    if not playerColor then return nil end
    
    local boardFolder: Instance? = SafeFindFirstChild(tableModel, "Board")
    local piecesFolder: Instance? = SafeFindFirstChild(tableModel, "Pieces")
    
    if not piecesFolder then return nil end
    
    local pieces: {ChessPiece} = {}
    local board: ChessBoard = {}
    
    local pieceModels: {Instance}? = SafeGetChildren(piecesFolder)
    if not pieceModels then return nil end
    
    for i = 1, #pieceModels do
        local pieceModel: Instance = pieceModels[i]
        local pieceName: string? = GetInstanceName(pieceModel)
        
        if pieceName then
            local color, pieceType = ParsePieceName(pieceName)
            
            if color and pieceType then
                local tileValue: Instance? = SafeFindFirstChild(pieceModel, "tile")
                local tile: string? = GetStringValue(tileValue)
                
                if tile and tile ~= "-" and IsValidTile(tile) then
                    local position: Vector3? = GetModelPosition(pieceModel :: Model)
                    
                    local piece: ChessPiece = {
                        name = pieceName,
                        color = color,
                        type = pieceType,
                        tile = tile,
                        model = pieceModel :: Model,
                        position = position
                    }
                    
                    TableInsert(pieces, piece)
                    board[tile] = piece
                end
            end
        end
    end
    
    if #pieces == 0 then return nil end
    
    return {
        model = tableModel,
        isActive = isActive,
        board = board,
        pieces = pieces,
        playerColor = playerColor,
        whitePlayer = whitePlayer,
        blackPlayer = blackPlayer,
        bestMove = nil,
        boardFolder = boardFolder,
        lastStockfishRequest = 0,
        currentFEN = nil,
        pendingRequest = false
    }
end

local function ScanChessTables(): ()
    local currentTime: number = OsClock()
    if currentTime - LastScanTime < SCAN_INTERVAL then return end
    LastScanTime = currentTime
    
    local children: {Instance}? = SafeGetChildren(Workspace)
    if not children then return end
    
    local foundTables: {[Model]: boolean} = {}
    
    for i = 1, #children do
        local child: Instance = children[i]
        local childName: string? = GetInstanceName(child)
        
        if childName == "ChessTableset" and ValidateParent(child) then
            local tableModel: Model = child :: Model
            local tablePos: Vector3? = GetModelPosition(tableModel)
            
            if tablePos then
                local distance: number? = GetDistanceToPlayer(tablePos)
                
                if distance and distance <= MAX_TABLE_DISTANCE then
                    foundTables[tableModel] = true
                    
                    if not ActiveTables[tableModel] then
                        local chessTable: ChessTable? = ParseChessTable(tableModel)
                        if chessTable then
                            ActiveTables[tableModel] = chessTable
                        end
                    end
                end
            end
        end
    end
    
    for tableModel, chessTable in pairs(ActiveTables) do
        if not foundTables[tableModel] or not ValidateParent(tableModel) then
            ActiveTables[tableModel] = nil
        else
            local updatedTable: ChessTable? = ParseChessTable(tableModel)
            if updatedTable then
                updatedTable.lastStockfishRequest = chessTable.lastStockfishRequest
                updatedTable.currentFEN = chessTable.currentFEN
                updatedTable.pendingRequest = chessTable.pendingRequest
                updatedTable.bestMove = chessTable.bestMove
                ActiveTables[tableModel] = updatedTable
            else
                ActiveTables[tableModel] = nil
            end
        end
    end
    local validQueue: {{table: ChessTable, fen: string}} = {}
    for i = 1, #RequestQueue do
        local request = RequestQueue[i]
        if ValidateParent(request.table.model) and ActiveTables[request.table.model] then
            TableInsert(validQueue, request)
        else
            request.table.pendingRequest = false
        end
    end
    RequestQueue = validQueue
end

local function RequestStockfishAnalysis(): ()
    for tableModel, chessTable in pairs(ActiveTables) do
        if ValidateParent(tableModel) then
            Pcall(function()
                RequestStockfishMove(chessTable)
            end)
        end
    end
end

---- RENDERING ----

local function RenderBestMoves(): ()
    if not Camera or not ValidateParent(Camera) then
        Camera = Workspace.CurrentCamera
        return
    end
    
    for tableModel, chessTable in pairs(ActiveTables) do
        local bestMove: ChessMove? = chessTable.bestMove
        
        if bestMove and bestMove.fromPos and bestMove.toPos then
            local fromScreen, fromOnScreen = SafeWorldToScreen(Camera, bestMove.fromPos)
            local toScreen, toOnScreen = SafeWorldToScreen(Camera, bestMove.toPos)
            
            if fromScreen and toScreen and fromOnScreen and toOnScreen then
                DrawingImmediate.Line(fromScreen, toScreen, LINE_COLOR, 1, 1, LINE_THICKNESS)
                DrawingImmediate.FilledCircle(toScreen, CIRCLE_RADIUS, CIRCLE_COLOR, 1)
            end
        end
    end
end

---- RUNTIME ----

RunService.PreLocal:Connect(function()
    Pcall(ScanChessTables)
    Pcall(RequestStockfishAnalysis)
    Pcall(ProcessRequestQueue) 
end)

RunService.Render:Connect(function()
    Pcall(RenderBestMoves)
end)
