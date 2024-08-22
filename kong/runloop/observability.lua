local dynamic_hook = require("kong.dynamic_hook")


local function set_observability ()
  dynamic_hook.enable_by_default("opentelemetry-shadow")
end


-- log level worker event updates
local function worker_handler()
  local worker = ngx.worker.id() or -1
  ngx.log(ngx.NOTICE, "observability foo worker event received for worker ", worker)
  set_observability()
end


local function init_worker()
  kong.worker_events.register(worker_handler, "observability", "start-session")
end


return {
  init_worker = init_worker,
}
