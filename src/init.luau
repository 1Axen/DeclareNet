local fs = require("@lune/fs")
local stdio = require("@lune/stdio")
local process = require("@lune/process")

local Parser = require("./Parser.luau")
local Generator = require("./Generator.luau")

local SourceParser = Parser.new()

local Arguments = process.args
if #Arguments < 2 then
    error("Too few arguments!")
elseif #Arguments > 2 then
    error("Too many arguments!")
end

local SourcePath = Arguments[1]
local OutputPath = Arguments[2]

stdio.write(stdio.color("cyan"))
print(`Reading source from {SourcePath} and writing output to {OutputPath}.`)

local Source = fs.readFile(SourcePath)

if not fs.isDir(OutputPath) then
    warn(`Output directory doesn't exist, creating one.`)
    fs.writeDir(OutputPath)
end

stdio.write(stdio.color("blue"))
print("Parsing source into AST.")
local AbstractSyntaxTree = SourceParser:Parse(Source)

print("Parsing AST.")
fs.writeFile(`{OutputPath}/Server.luau`, Generator("Server", AbstractSyntaxTree))
fs.writeFile(`{OutputPath}/Client.luau`, Generator("Client", AbstractSyntaxTree))

stdio.write(stdio.color("green"))
print("Network files generated!")
stdio.write(stdio.color("white"))