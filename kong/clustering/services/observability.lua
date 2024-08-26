local _M = {}


local function rpc_consume_data(_node_id, data)
  print("_node_id = " .. require("inspect")(_node_id))
  print("FROM THE RPC CALL data = " .. require("inspect")(data))
  return true
end


function _M.init(manager)
  manager.callbacks:register("kong.observability.debug-session.v1.toggle", rpc_consume_data)
end

return _M
