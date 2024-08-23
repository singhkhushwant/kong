local _M = {}


local dynamic_hook = require("kong.dynamic_hook")


local function rpc_set_session_start(_node_id, data)
  print("data = " .. require("inspect")(data))

  -- broadcast to all workers in a node
  local ok, err = kong.worker_events.post("observability-debug-session", "toggle", data)
  if not ok then
    return nil, err
  end

  -- todo: maybe add a value in the shm to indicate that a debug session is active so that other
  --       workers can copy the behavior

  -- TODO: we don't know if we need this _here_. Who is receiving this event?
  -- when we broadcast the worker_event every worker receives it (but not the one that it sent?)
  -- dynamic_hook.enable_by_default("opentelemetry-shadow")

  return "ok", nil
end


function _M.init(manager)
  manager.callbacks:register("kong.observability.debug-session.v1.toggle", rpc_set_session_start)
end

return _M
