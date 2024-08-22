local otel_traces = require "kong.plugins.opentelemetry.traces"
local otel_logs = require "kong.plugins.opentelemetry.logs"
local otel_utils = require "kong.plugins.opentelemetry.utils"
local kong_meta = require "kong.meta"

return function(priority)
  local OpenTelemetryHandler = {
    VERSION = kong_meta.version,
    PRIORITY = priority,
  }

  function OpenTelemetryHandler:configure(configs)
    print("self = " .. require("inspect")(self))
    print("WERE IN CONFIGURE")
    print("configs = " .. require("inspect")(configs))
    if configs then
      for _, config in ipairs(configs) do
        if config.logs_endpoint then
          otel_utils.start_log_hooks()
        end

        -- enable instrumentations based on the value of `config.tracing_instrumentations`
        otel_utils.start_instrumentation_hooks()
      end
    end
  end

  function OpenTelemetryHandler:access(conf)
    print("FROM PARENT OTEL conf = " .. require("inspect")(conf))
    -- Traces
    if conf.traces_endpoint then
      otel_traces.access(conf)
    end
    -- Dynamic configurable array which contains instrumentation scopes (route, plugins, all)
    -- In here we enable the hook, which based on the configuration, which can change at runtine,
  end

  function OpenTelemetryHandler:header_filter(conf)
    -- Traces
    if conf.traces_endpoint then
      otel_traces.header_filter(conf)
    end
  end

  function OpenTelemetryHandler:log(conf)
    -- Traces
    if conf.traces_endpoint then
      otel_traces.log(conf)
    end

    -- Logs
    if conf.logs_endpoint then
      otel_logs.log(conf)
    end
  end

  return OpenTelemetryHandler
end
