--[[
  GoogiVM (custom_loadstring_full.lua)
  Pure-Lua Lua 5.1 compiler and bytecode interpreter.
  Does not use load, loadstring, FFI, debug, io, or os.

  API:
    local custom_loadstring = dofile("custom_loadstring_full.lua")
    local chunk, err = custom_loadstring(source, env, options)

  The implementation is split into three runtime files:
    gvm_compiler.lua  lexer, parser, emitter and optimizer
    gvm_runtime.lua   prototypes, closures, frames and execution
    custom_loadstring_full.lua  this public entry point and module loader

  Lua 5.1 does not include bitwise operators; expose a library such as
  `bit` through `env` if needed.
]]

local tconcat = table.concat
local tostring = tostring

local function load_module(name)
    local paths = {
        name,
        "$CONTENT_DATA/Scripts/" .. name,
        "$CONTENT_DATA/Scripts/GoogiVM/" .. name,
    }
    local errors = {}
    for i = 1, #paths do
        local ok, mod = pcall(dofile, paths[i])
        if ok and mod ~= nil then
            return mod
        end
        errors[#errors + 1] = paths[i] .. ": " .. tostring(mod)
    end
    error("GoogiVM: failed to load " .. name .. "\n" .. tconcat(errors, "\n"), 0)
end

local runtime = load_module("gvm_runtime.lua")
local build = load_module("gvm_compiler.lua")
local custom_loadstring = build(runtime)

return custom_loadstring
