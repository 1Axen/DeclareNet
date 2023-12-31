--!native
--!optimize 2

local fs = require("@lune/fs")

local Parser = require("../Parser")
local Builder = require("../Modules/Builder")
local Prefabs = require("./Prefabs")

local Sources = {
	Base = if _G.BUNDLED then (require("Base") :: any) else fs.readFile("./Templates/Base.txt"),
	Client = string.split(if _G.BUNDLED then (require("Client") :: any) else fs.readFile("./Templates/Client.txt"), "-- SPLIT --"),
	Server = string.split(if _G.BUNDLED then (require("Server") :: any) else fs.readFile("./Templates/Server.txt"), "-- SPLIT --"),
}

local DIRECTIVES = "--!strict\n--!native\n--!optimize 2\n\n"
local OPTIONAL = `if buffer.readu8(RecieveBuffer, Read(1)) == 1 then`
local YIELD_BODY = {
	"Calls[InvocationIdentifier] = coroutine.running()",
	"local Success, Return = coroutine.yield()",
	"if not Success then error(Return) end",
	"return Return"
}
local EVENT_BODY =
	"\tRecieveCursor = 0\n\tRecieveBuffer = Buffer\n\tlocal Size = buffer.len(RecieveBuffer)\n\twhile RecieveCursor < Size do\n\t\tlocal Index = buffer.readu8(RecieveBuffer, Read(1))"

local Types = Builder.new()
local Imports = Builder.new()
local Return = Builder.new()
local ReliableEvents = Builder.new()
local UnreliableEvents = Builder.new()

local Options: Parser.Options = {}

local Channels: { [string]: { Count: number, Listening: boolean } } = {
	Reliable = { Count = 0, Listening = false },
	Unreliable = { Count = 0, Listening = false },
}

local Writers = {}

local TypePrefabs = Prefabs.Types
local AssertPrefabs = Prefabs.Asserts
local Primitives = Prefabs.Primitives

local function GenerateEnumLiterals(Enums: { string }): string
	local Literal = ""
	for Index, EnumItem in Enums do
		Literal ..= `"{EnumItem}"{Index < #Enums and " | " or ""}`
	end
	return Literal
end

function Writers.Type(Identifier: string, Type: string, Optional: boolean, Read: string, Write: string, Reference: string?, Simple: boolean?, Arguments: string?): string
	if Optional then
		Type = `{Type}?`
	end

	local Result = Builder.new("\n")
	if not Reference then
        Result.Push(`export type {Identifier} = {Type}`, 2)
	end
	
	Result.Push(`function Types.Write{Identifier}(Value: {Reference or Identifier}{Arguments and ", " .. Arguments or ""})`)
	Result.Push(Write, 0)
	Result.Push(`end`, 2)
	Result.Push(`function Types.Read{Identifier}(): {Reference or Identifier}`)
	if not Simple then
		Result.Push(`local Value: {Reference or Identifier};`, 1, 1)
	end
	Result.Push(Read, 0)
	if not Simple then
		Result.Push("return Value", 1, 1)
	end
	Result.Push(`end`)

	return Result.Dump()
end

function Writers.Optional(ReadBody: string, WriteBody: string, Variable: string): (string, string)
	local Read = Builder.new()
	local Write = Builder.new()

	local ReadLines = string.split(ReadBody, "\n")
	local WriteLines = string.split(WriteBody, "\n")

	Read.Push(OPTIONAL, 1, 1)
	Read.PushLines(ReadLines, 0, 1)
	Read.Push("end", 1, 1)

	Write.Push(Prefabs.Types.u8.Write(`({Variable} ~= nil) and 1 or 0`), 1, 1)
	Write.Push(`if {Variable} ~= nil then`, 1, 1)
	Write.PushLines(WriteLines, 0, 1)
	Write.Push("end", 1, 1)

	return Read.Dump(), Write.Dump()
end

function Writers.TypeDeclaration(
	TypeDeclaration: Parser.TypeDeclaration,
	Variable: string?
): (string, string, string)
	local Value = TypeDeclaration.Value
	local Primitive = Primitives[Value.Primitive]
	if not Primitive then
		error(`Missing primitive for {Value.Primitive}`)
	end

	local Type = Primitive.Type
	if Value.Array then
		Type = `\{{Type}\}`
	end

	local Read, Write = Primitive.Generate(Value.Array, Value.Range, Variable)
	if Value.Optional then
		Read, Write = Writers.Optional(Read, Write, Variable or "Value")
	end

	return Type, Read, Write
end

function Writers.EnumDeclaration(
	EnumDeclaration: Parser.EnumDeclaration,
	Variable: string?
): (string, string, string)
	local Value = EnumDeclaration.Value
	local Enums = Value.Enums
	local Variable = Variable or "Value"

	--> Builders
	local Read = Builder.new()
	local Write = Builder.new()
	local Type = GenerateEnumLiterals(Enums)

	--> Write operation
	for Index, EnumItem in Enums do
		Write.Push(`{Index > 1 and "else" or ""}if {Variable} == "{EnumItem}" then`, 1, 1)
		Write.Push(TypePrefabs.u8.Write(Index - 1), 1, 2)
	end
	Write.Push("else", 1, 1)
	Write.Push(`error(\`Unexpected enum: \{{Variable}\}, expectd one of {Type}.\`)`, 1, 2)
	Write.Push("end", 1, 1)

	-- Read operation
	Read.Push(TypePrefabs.u8.Read("local Index"), 1, 1)
	for Index, EnumItem in Enums do
		Read.Push(`{Index > 1 and "else" or ""}if Index == {Index - 1} then`, 1, 1)
		Read.Push(`{Variable} = "{EnumItem}"`, 1, 2)
	end
	Read.Push("else", 1, 1)
	Read.Push(`error(\`Unexpected enum: \{{Variable}\}\`)`, 1, 2)
	Read.Push("end", 1, 1)

	Read = Read.Dump()
	Write = Write.Dump()

	if Value.Optional then
		Read, Write = Writers.Optional(Read, Write, Variable or "Value")
	end

	return Type, Read, Write
end

function Writers.StructDeclaration(StructDeclaration: Parser.StructDeclaration): string
	local Type = Builder.new()
	local Read = Builder.new()
	local Write = Builder.new()

	local function BuildStructType(StructDeclaration: Parser.StructDeclaration, Tabs: number, Indent: number, Path: string)
		local Value = StructDeclaration.Value
		local Optional = Value.Optional
		local StructTabs = Tabs

		if Optional then
			Read.Push(OPTIONAL, 1, StructTabs)
			Write.Push(Prefabs.Types.u8.Write(`({Path} ~= nil) and 1 or 0`), 1, StructTabs)
			Write.Push(`if {Path} ~= nil then`, 1, StructTabs)
			Tabs += 1
		end

		Type.Push(`{Indent > 0 and `{Value.Identifier}: ` or ""}\{`, 1, Indent)
		Read.Push(`{Path} = \{\} :: any`, 1, Tabs)

		for Index, Field in Value.Fields do
			local FieldType: string
			local FieldValue = Field.Value
			local FieldIdentifier = FieldValue.Identifier
			local Variable = `{Path}.{FieldIdentifier}`

			if Field.Type == "TypeDeclaration" or Field.Type == "EnumDeclaration" then
				local Writer = Writers[Field.Type]
				local DeclarationType, DeclarationRead, DeclarationWrite = Writer(Field, Variable)

				if Field.Type == "EnumDeclaration" then
					DeclarationRead = string.gsub(DeclarationRead, `{Variable} ==`, `{FieldIdentifier} ==`)
				end

				FieldType = DeclarationType
				Read.PushLines(string.split(DeclarationRead, "\n"), 0, Tabs - 1)
				Write.PushLines(string.split(DeclarationWrite, "\n"), 0, Tabs - 1)
			elseif Field.Type == "StructDeclaration" then
				BuildStructType(Field, Tabs, Indent + 1, Variable)
				continue
			elseif Field.Type == "TypeReference" then
				local TypeReference: Parser.TypeReference = Field
				FieldType = TypeReference.Value.Reference

				--local ReferenceRead, ReferenceWrite = Prefabs.Primitives.Reference.Generate(FieldType)
				--print(ReferenceRead, ReferenceWrite)
				
				Read.Push(`{Variable} = Types.Read{FieldType}()`, 1, Tabs)
				Write.Push(`Types.Write{FieldType}({Variable})`, 1, Tabs)
			end

			if FieldValue.Optional then
				FieldType = `({FieldType})?`
			end

			Type.Push(`{FieldIdentifier}: {FieldType}{Index < #Value.Fields and "," or ""}`, 1, Indent + 1)
		end

		if Optional then
			Read.Push("end", 1, StructTabs)
			Write.Push("end", 1, StructTabs)
		end

		Type.Push("}", Indent > 0 and 1 or 0, Indent)
	end

	BuildStructType(StructDeclaration, 1, 0, "Value")

	return Type.Dump(), Read.Dump(), Write.Dump()
end

local function WriteBody(Identifier: string, Data: Parser.Declaration, Index: number, Invocation: true?): string
	local Read = Builder.new()
	local Write = Builder.new()

	local Type, Reference;
	Write.Push(TypePrefabs.u8.Write(Index), 1, 1)
	
	if Invocation then
		Write.Push(TypePrefabs.u8.Write("InvocationIdentifier"), 1, 1)
		Write.Push(TypePrefabs.u8.Write("1"), 1, 1)

		Read.Push(`local {TypePrefabs.u8.Read("Success")} == 1`, 1, 1)
		Read.Push(`if not Success then`, 1, 1)
		local ErrorRead = string.gsub(TypePrefabs.string.Read("Error"), "\t", "")
		Read.PushLines(string.split(ErrorRead, "\n"), 0, 2)
		Read.Push("error(Error)", 1, 2)
		Read.Push(`end`, 1, 1)
	end

	if Data.Type == "TypeReference" then
		local TypeReference: Parser.TypeReference = Data :: Parser.TypeReference
		Type = TypeReference.Value.Reference
		Reference = TypeReference.Value.Reference

		Read.Push(`return Types.Read{Reference}()`, 1, 1)
		Write.Push(`Types.Write{Reference}(Value)`, 1, 1)
	else
		local Writer = Writers[Data.Type]
		local DeclarationType, DeclarationRead, DeclarationWrite = Writer(Data)
		DeclarationType = string.gsub(DeclarationType, "\n", " ")
		DeclarationType = string.gsub(DeclarationType, "\t", "")

		Type = DeclarationType
		Read.Push(DeclarationRead, 0)
		Write.Push(DeclarationWrite, 0)
	end

	Types.Push(Writers.Type(Identifier, Type, Data.Value.Optional, Read.Dump(), Write.Dump(), Type, Reference ~= nil, Invocation and "InvocationIdentifier: number"), 0)
	return Type
end

function Writers.EventDeclaration(
	EventDeclaration: Parser.EventDeclaration,
	Context: "Client" | "Server",
	ReliableEvents: Builder.Builder,
	UnreliableEvents: Builder.Builder
): string
	local Value = EventDeclaration.Value
	local IsServer = (Context == "Server")
	local IsReliable = (Value.Type == "Reliable")
	local Arguments = (IsServer and "Player, " or "")

    local Channel = Channels[Value.Type]
	local EventIndex = Channel.Count
	local Identifier = `EVENT_{Value.Identifier}`

	--> Type generation
	local Type = WriteBody(Identifier, Value.Data, EventIndex)

	--> Body generation
	local Event = Builder.new()
	Event.Push(`{Value.Identifier} = \{`, 1, 1)
	
	if Value.From ~= Context then
		local Index = `{Value.Type}[{EventIndex}]`
		local Queue = `Queue.{Index}`
        local Events = `Events.{Index}`

		--> Allocate queue table at require time instead of creating one at runtime
		Types.PushFront(`{Queue} = table.create(256)`)

		Event.Push(`On = function(Listener: ({Arguments}{Type}) -> ())`, 1, 2)
		Event.Push(`{Events} = Listener`, 1, 3)
		Event.Push(`task.spawn(function()`, 1, 3)
		Event.Push(`local EventQueue = {Queue} or \{\}`, 1, 4)
		--Event.Push(`if not Queue then return end`, 1, 4)
		Event.Push(`{Queue} = nil`, 1, 4)
		Event.Push(`for Index, Arguments in EventQueue do`, 1, 4)
		Event.Push(`Listener(table.unpack(Arguments))`, 1, 5)
		Event.Push(`end`, 1, 4)
		Event.Push(`end)`, 1, 3)
		Event.Push(`end`, 1, 2)

		local EventBuilder = (IsReliable and ReliableEvents or UnreliableEvents)
		EventBuilder.Push(`{Channel.Listening and "elseif" or "if"} Index == {EventIndex} then`, 1, 2)
		EventBuilder.Push(`local Value = Types.Read{Identifier}()`, 1, 3)
		EventBuilder.Push(`if {Events} then`, 1, 3)
		EventBuilder.Push(`{Events}({Arguments}Value)`, 1, 4)
		EventBuilder.Push("else", 1, 3)
		EventBuilder.Push(`if #{Queue} > 256 then warn("[Blink]: Event queue of \\"{Value.Identifier}\\" exceeded 256, did you forget to implement a listener?") end`, 1, 4)
		EventBuilder.Push(`table.insert({Queue}, \{{Arguments}Value\})`, 1, 4)
		EventBuilder.Push("end", 1, 3)

		Channel.Listening = true
	elseif IsServer then
        --> Single fire
        Event.Push(`Fire = function(Player: Player, Value: {Type})`, 1, 2)
        if IsReliable then
            Event.Push(`Load(PlayersMap[Player])`, 1, 3)
            Event.Push(`Types.Write{Identifier}(Value)`, 1, 3)
            Event.Push(`PlayersMap[Player] = Save()`, 1, 3)
        else
            Event.Push(`Load()`, 1, 3)
            Event.Push(`Types.Write{Identifier}(Value)`, 1, 3)
            Event.Push(`local Buffer = buffer.create(SendCursor)`, 1, 3)
            Event.Push(`buffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)`, 1, 3)
            Event.Push(`Unreliable:FireClient(Player, Buffer)`, 1, 3)
        end
        Event.Push(`end,`, 1, 2)

        --> Fire all
        Event.Push(`FireAll = function(Value: {Type})`, 1, 2)
		Event.Push(`Load()`, 1, 3)
		Event.Push(`Types.Write{Identifier}(Value)`, 1, 3)
        if IsReliable then
            Event.Push(`for _, Player in Players:GetPlayers() do`, 1, 3)
			Event.Push(`PlayersMap[Player] = Save()`, 1, 4)
			Event.Push(`end`, 1, 3)
        else
            Event.Push(`local Buffer = buffer.create(SendCursor)`, 1, 3)
            Event.Push(`buffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)`, 1, 3)
            Event.Push(`Unreliable:FireAllClients(Buffer)`, 1, 3)
        end
        Event.Push(`end,`, 1, 2)

        --> Fire list
        Event.Push(`FireList = function(List: \{Player\}, Value: {Type})`, 1, 2)
		Event.Push(`Load()`, 1, 3)
		Event.Push(`Types.Write{Identifier}(Value)`, 1, 3)
        if IsReliable then
            Event.Push(`for _, Player in List do`, 1, 3)
			Event.Push(`PlayersMap[Player] = Save()`, 1, 4)
			Event.Push(`end`, 1, 3)
        else
            Event.Push(`local Buffer = buffer.create(SendCursor)`, 1, 3)
            Event.Push(`buffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)`, 1, 3)
            Event.Push(`for _, Player in List do`, 1, 3)
			Event.Push(`Unreliable:FireClient(Player, Buffer)`, 1, 4)
			Event.Push(`end`, 1, 3)
        end
        Event.Push(`end,`, 1, 2)

        --> Fire except
        Event.Push(`FireExcept = function(Except: Player, Value: {Type})`, 1, 2)
		Event.Push(`Load()`, 1, 3)
		Event.Push(`Types.Write{Identifier}(Value)`, 1, 3)
        if IsReliable then
            Event.Push(`for _, Player in Players:GetPlayers() do`, 1, 3)
			Event.Push(`if Player == Except then continue end`, 1, 4)
            Event.Push(`PlayersMap[Player] = Save()`, 1, 4)
            Event.Push(`end`, 1, 3)
        else
            Event.Push(`local Buffer = buffer.create(SendCursor)`, 1, 3)
            Event.Push(`buffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)`, 1, 3)
            Event.Push(`for _, Player in Players:GetPlayers() do`, 1, 3)
			Event.Push(`if Player == Except then continue end`, 1, 4)
			Event.Push(`Unreliable:FireClient(Player, Buffer)`, 1, 4)
			Event.Push(`end`, 1, 3)
        end
        Event.Push(`end`, 1, 2)
    else
        Event.Push(`Fire = function(Value: {Type})`, 1, 2)
        if IsReliable then
            Event.Push(`Types.Write{Identifier}(Value)`, 1, 3)
        else
            Event.Push(`local Previous = Save()`, 1, 3)
            Event.Push(`Load()`, 1, 3)
            Event.Push(`Types.Write{Identifier}(Value)`, 1, 3)
            Event.Push(`local Buffer = buffer.create(SendCursor)`, 1, 3)
            Event.Push(`buffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)`, 1, 3)
            Event.Push(`Unreliable:FireServer(Buffer)`, 1, 3)
            Event.Push(`Load(Previous)`, 1, 3)
        end
        Event.Push(`end`, 1, 2)
    end

	Event.Push(`},`, 1, 1)
	return Event.Dump()
end

function Writers.FunctionDeclaration(
	FunctionDeclaration: Parser.FunctionDeclaration,
	Context: "Client" | "Server",
	ReliableEvents: Builder.Builder
): string
	local Value = FunctionDeclaration.Value
	local Yield = Value.Yield

	local IsFuture = (Yield == "Future")
	local IsPromise = (Yield == "Promise")
	local IsCoroutine = (Yield == "Coroutine")

	if IsFuture and not Options.FutureLibrary then
		error(`Cannot use yield type: "Future", without providing a path to the future library.`)
	end

	if IsPromise and not Options.PromiseLibrary then
		error(`Cannot use yield type: "Promise", without providing a path to the promise library.`)
	end

	local Channel = Channels.Reliable
	local FunctionIndex = Channel.Count

	local Index = `Reliable[{FunctionIndex}]`
	local Queue = `Queue.{Index}`
    local Events = `Events.{Index}`

	local DataIdentifier = `FUNCTION_DATA_{Value.Identifier}`
	local ReturnIdentifier = `FUNCTION_RETURN_{Value.Identifier}` 

	--> Type generation
	local DataType = WriteBody(DataIdentifier, Value.Data, FunctionIndex, true)
	local ReturnType = WriteBody(ReturnIdentifier, Value.Return, FunctionIndex, true)

	--> Allocate queue table at require time instead of creating one at runtime
	Types.PushFront(`{Queue} = table.create(256)`)

	--> Body generation
	local Function = Builder.new()
	Function.Push(`{Value.Identifier} = \{`, 1, 1)

	if Context == "Server" then
		Function.Push(`On = function(Callback: (Player, {DataType}) -> ({ReturnType}))`, 1, 2)
		Function.Push(`assert({Events} == nil, "A function callback can only bet set once")`, 1, 3)
		Function.Push(`{Events} = function(Player: Player, Value: {DataType}, InvocationIdentifier: number)`, 1, 3)

		Function.Push(`local Return: {DataType};`, 1, 4)
		Function.Push(`local Success, Trace = pcall(function() Return = Callback(Player, Value) end)`, 1, 4)

		Function.Push(`Load(PlayersMap[Player])`, 1, 4)
		Function.Push(`if not Success then`, 1, 4)
		Function.Push(`buffer.writeu8(SendBuffer, Allocate(1), {FunctionIndex})`, 1, 5)
		Function.Push(`buffer.writeu8(SendBuffer, Allocate(1), InvocationIdentifier)`, 1, 5)
		Function.Push(`buffer.writeu8(SendBuffer, Allocate(1), 0)`, 1, 5)
		
		local ErrorWrite = TypePrefabs.string.Write("Trace") 
		ErrorWrite = string.gsub(ErrorWrite, "\t", "")
		Function.PushLines(string.split(ErrorWrite, "\n"), 0, 5)

		Function.Push(`else`, 1, 4)
		Function.Push(`Types.Write{ReturnIdentifier}(Return, InvocationIdentifier)`, 1, 5)
		Function.Push(`end`, 1, 4)
        Function.Push(`PlayersMap[Player] = Save()`, 1, 4)
		Function.Push(`end`, 1, 3)

		Function.Push(`task.defer(function()`, 1, 3)
		Function.Push(`local FunctionQueue = {Queue} or \{\}`, 1, 4)
		Function.Push(`{Queue} = nil`, 1, 4)
		Function.Push(`for Index, Arguments in FunctionQueue do`, 1, 4)
		Function.Push(`{Events}(table.unpack(Arguments))`, 1, 5)
		Function.Push(`end`, 1, 4)
		Function.Push(`end)`, 1, 3)

		Function.Push(`end`, 1, 2)

		ReliableEvents.Push(`{Channel.Listening and "elseif" or "if"} Index == {FunctionIndex} then`, 1, 2)
		ReliableEvents.Push(`local {TypePrefabs.u8.Read("InvocationIdentifier")}`, 1, 3)
		ReliableEvents.Push(`local Value = Types.Read{DataIdentifier}()`, 1, 3)
		ReliableEvents.Push(`if {Events} then`, 1, 3)
		ReliableEvents.Push(`{Events}(Player, Value, InvocationIdentifier)`, 1, 4)
		ReliableEvents.Push(`else`, 1, 3)
		ReliableEvents.Push(`if #{Queue} > 256 then warn("[Blink]: Function queue of \\"{Value.Identifier}\\" exceeded 256, did you forget to implement a callback?") end`, 1, 4)
		ReliableEvents.Push(`table.insert({Queue}, \{Player, Value, InvocationIdentifier\})`, 1, 4)
		ReliableEvents.Push(`end`, 1, 3)
	else
		Function.Push(`Invoke = function(Value: {DataType})`, 1, 2)
		Function.Push(`local InvocationIdentifier = Invoke()`, 1, 3)
		Function.Push(`Types.Write{DataIdentifier}(Value, InvocationIdentifier)`, 1, 3)
		
		if IsCoroutine then
			Function.PushLines(YIELD_BODY, 0, 3)
		elseif IsFuture then
			Function.Push(`return Future.Try(function()`, 1, 3)
			Function.PushLines(YIELD_BODY, 0, 4)
			Function.Push(`end)`, 1, 3)
		elseif IsPromise then
			Function.Push(`return Promise.new(function(Resolve, Reject, OnCancel)`, 1, 3)
			Function.Push("OnCancel(function()", 1, 4)
			Function.Push(`Calls[InvocationIdentifier] = nil`, 1, 5)
			Function.Push("end)", 1, 4)
			Function.Push(YIELD_BODY[1], 1, 4)
			Function.Push(YIELD_BODY[2], 1, 4)
			Function.Push("if not Success then Reject(Return) end", 1, 4)
			Function.Push("Resolve(Return)", 1, 4)
			Function.Push(`end)`, 1, 3)
		end

		Function.Push(`end`, 1, 2)

		ReliableEvents.Push(`{Channel.Listening and "elseif" or "if"} Index == {FunctionIndex} then`, 1, 2)
		ReliableEvents.Push(`local {TypePrefabs.u8.Read("InvocationIdentifier")}`, 1, 3)
		ReliableEvents.Push(`if Calls[InvocationIdentifier] then`, 1, 3)
		ReliableEvents.Push(`local Success, Value = pcall(function() return Types.Read{ReturnIdentifier}() end)`, 1, 4)
		ReliableEvents.Push(`task.spawn(Calls[InvocationIdentifier], Success, Value)`, 1, 4)
		ReliableEvents.Push(`end`, 1, 3)
	end

	Channel.Listening = true
	Function.Push(`},`, 1, 1)

	return Function.Dump()
end

return function(Context: "Client" | "Server", AbstractSyntaxTree: Parser.Body, UserOptions: Parser.Options): string
	--> Reset previous generation
	Types.Dump()
	Imports.Dump()
	Return.Dump()
	ReliableEvents.Dump()
	UnreliableEvents.Dump()

	Options = UserOptions
	Channels.Reliable.Count = 0
	Channels.Unreliable.Count = 0
	Channels.Reliable.Listening = false
	Channels.Unreliable.Listening = false

	--> Import async libraries
	if UserOptions.FutureLibrary then
		Imports.Push(`local Future = require({UserOptions.FutureLibrary})`)
	end

	if UserOptions.PromiseLibrary then
		Imports.Push(`local Promise = require({UserOptions.PromiseLibrary})`)
	end

	--> Generate remote connections
	local Signal = (Context == "Client" and "OnClientEvent" or "OnServerEvent")
	local Arguments = (Context == "Server" and "Player: Player, " or "") .. "Buffer: buffer"

	ReliableEvents.Push(`Reliable.{Signal}:Connect(function({Arguments})`)
	UnreliableEvents.Push(`Unreliable.{Signal}:Connect(function({Arguments})`)

	ReliableEvents.Push(EVENT_BODY)
	UnreliableEvents.Push(EVENT_BODY)

	--> Generate replication loop
	local Replication = "\nRunService.Heartbeat:Connect(StepReplication)\n"
	if Options.ManualReplication then
		Replication = ""
		Return.Push("StepReplication = StepReplication,", 1, 1)
	end

	--> Generate types & events/functions
	for Index, Declaration in AbstractSyntaxTree.Value do
		local Writer = Writers[Declaration.Type]
		if not Writer then
			warn(`{Declaration.Type} has no writer.`)
			continue
		end

		if Declaration.Type == "EventDeclaration" or Declaration.Type == "FunctionDeclaration" then
			Return.Push(Writer(Declaration, Context, ReliableEvents, UnreliableEvents), 0)
			;(Channels[Declaration.Value.Type] or Channels.Reliable).Count += 1
			continue
		end

		local Type, Read, Write = Writer(Declaration)
		Types.Push(Writers.Type(Declaration.Value.Identifier, Type, Declaration.Value.Optional, Read, Write), 0)
	end

	--> Close remote connection functions
	if Channels.Reliable.Listening then
		ReliableEvents.Push("end", 1, 2)
	end

	if Channels.Unreliable.Listening then
		UnreliableEvents.Push("end", 1, 2)
	end

	ReliableEvents.Push("end", 1, 1)
	UnreliableEvents.Push("end", 1, 1)

	ReliableEvents.Push("end)", 2)
	UnreliableEvents.Push("end)")

	--> Generate context source
	local Source = Sources[Context]
	return DIRECTIVES
        .. Source[1]
		.. Imports.Dump()
		.. Sources.Base
		.. Types.Dump()
		.. Source[2]
		.. Replication
		.. ReliableEvents.Dump()
		.. UnreliableEvents.Dump()
		.. `\nreturn \{\n{Return.Dump()}\}`
end
