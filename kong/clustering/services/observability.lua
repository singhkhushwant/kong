local _M = {}


local dynamic_hook = require("kong.dynamic_hook")



local function rpc_set_session_start(_node_id, foo)

  -- broadcast to all workers in a node
  local ok, err = kong.worker_events.post("observability", "start-session", {})
  if not ok then
    return nil, err
  end

  -- todo: maybe add a value in the shm to indicate that a debug session is active so that other
  --       workers can copy the behavior

  dynamic_hook.enable_by_default("opentelemetry-shadow")

  return "ok", nil
  -- return true
end


local function rpc_get_session_start(_node_id)
  return {
    foo = "bar",
  }
end



function _M.init(manager)
  manager.callbacks:register("kong.observability.foo.v1.set_start", rpc_set_session_start)
  manager.callbacks:register("kong.observability.foo.v1.get_start", rpc_get_session_start)
end


return _M
