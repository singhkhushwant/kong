local dynamic_hook = require("kong.dynamic_hook")
local utils = require("kong.plugins.opentelemetry.utils")


local function set_observability(data)
  utils.start_all_hooks()
  if data.action == "start" then
    dynamic_hook.enable_by_default("opentelemetry-shadow")
  end
  if data.action == "stop" then
    dynamic_hook.disable_by_default("opentelemetry-shadow")
  end
end


-- log level worker event updates
local function worker_handler(data)
  print("data = " .. require("inspect")(data))
  local worker = ngx.worker.id() or -1
  -- maybeFIXME: The logs say that only one worker (0) receives this event but it appears that all workers receive it
  -- what's wrong here?
  ngx.log(ngx.NOTICE, "observability foo worker event received for worker ", worker)
  set_observability(data)
end


local function init_worker()
  kong.worker_events.register(worker_handler, "observability-debug-session", "toggle")
end


return {
  init_worker = init_worker,
}
