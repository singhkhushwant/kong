local handler = require("kong.plugins.opentelemetry._handler")(15)
local dynamic_hook = require("kong.dynamic_hook")


local OpenTelemetryShadow = {}

OpenTelemetryShadow = {
  VERSION = handler.VERSION,
  PRIORITY = handler.PRIORITY,
}
local function _handler_access(config)
  handler:access(config)
end

local function _handler_header_filter(config)
  handler:header_filter(config)
end

local function _handler_log(config)
  handler:log(config)
end

-- function OpenTelemetryShadow:init_worker()
  -- dynamic_hook.hook("opentelemetry-shadow", "access", _handler_access)
  -- dynamic_hook.hook("opentelemetry-shadow", "header_filter", _handler_header_filter)
  -- dynamic_hook.hook("opentelemetry-shadow", "log", _handler_log)
-- end

function OpenTelemetryShadow:configure(configs)
  -- dynamic_hook.run_hook("opentelemetry-shadow", "access", config)
  return handler:configure(configs)
end

function OpenTelemetryShadow:access(config)
  -- dynamic_hook.run_hook("opentelemetry-shadow", "access", config)
  return _handler_access(config)
end

function OpenTelemetryShadow:header_filter(config)
  return _handler_header_filter(config)
  -- dynamic_hook.run_hook("opentelemetry-shadow", "header_filter", config)
end

function OpenTelemetryShadow:log(config)
  -- dynamic_hook.run_hook("opentelemetry-shadow", "log", config)
  print("in shadow plugin / log, config = " .. require("inspect")(config))
  return _handler_log(config)
end


return OpenTelemetryShadow
