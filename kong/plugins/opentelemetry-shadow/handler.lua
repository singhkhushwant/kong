local handler = require("kong.plugins.opentelemetry._handler")(15)
local dynamic_hook = require("kong.dynamic_hook")


local OpenTelemetryShadow = {}

OpenTelemetryShadow = {
  VERSION = handler.VERSION,
  PRIORITY = handler.PRIORITY,
}


function OpenTelemetryShadow:init_worker()
  local function _handler_configure(configs)
    handler.header_configure(configs)
  end

  local function _handler_access(ctx)
    handler.access(ctx)
  end

  local function _handler_header_filter(ctx)
    handler.header_filter(ctx)
  end

  local function _handler_log(ctx)
    handler.log(ctx)
  end
  dynamic_hook.hook("opentelemetry-shadow", "configure", _handler_configure)
  dynamic_hook.hook("opentelemetry-shadow", "access", _handler_access)
  dynamic_hook.hook("opentelemetry-shadow", "header_filter", _handler_header_filter)
  dynamic_hook.hook("opentelemetry-shadow", "log", _handler_log)
end

function OpenTelemetryShadow:configure(configs)
  dynamic_hook.run_hook("opentelemetry-shadow", "configure", configs)
end

function OpenTelemetryShadow:access(ctx)
  dynamic_hook.run_hook("opentelemetry-shadow", "access", ctx)
end

function OpenTelemetryShadow:header_filter(ctx)
  dynamic_hook.run_hook("opentelemetry-shadow", "header_filter", ctx)
end

function OpenTelemetryShadow:log(ctx)
  dynamic_hook.run_hook("opentelemetry-shadow", "log", ctx)
end


return OpenTelemetryShadow
