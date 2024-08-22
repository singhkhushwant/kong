local handler = require("kong.plugins.opentelemetry._handler")(15)
local dynamic_hook = require("kong.dynamic_hook")


local OpenTelemetryShadow = {}

OpenTelemetryShadow = {
  VERSION = handler.VERSION,
  PRIORITY = handler.PRIORITY,
}
local function _handler_access(config)
  print("IN THE ACTUAL FUNCTION THAT THE HOOK ENABLES: ctx = " .. require("inspect")(config))
  handler:access(config)
end

local function _handler_header_filter(config)
  handler:header_filter(config)
end

local function _handler_log(config)
  handler:log(config)
end

function OpenTelemetryShadow:init()
  print("WE ARE IN SHADOW INIT")
  dynamic_hook.hook("opentelemetry-shadow", "access", _handler_access)
  dynamic_hook.hook("opentelemetry-shadow", "header_filter", _handler_header_filter)
  dynamic_hook.hook("opentelemetry-shadow", "log", _handler_log)
end


function OpenTelemetryShadow:access(config)
  print("BEFORE THE HOOK IN ACCESS: ctx = " .. require("inspect")(config))
  dynamic_hook.run_hook("opentelemetry-shadow", "access", config)
end

function OpenTelemetryShadow:header_filter(config)
  dynamic_hook.run_hook("opentelemetry-shadow", "header_filter", config)
end

function OpenTelemetryShadow:log(config)
  dynamic_hook.run_hook("opentelemetry-shadow", "log", config)
end


return OpenTelemetryShadow
