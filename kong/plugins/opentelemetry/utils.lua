local http = require "resty.http"
local clone = require "table.clone"
local dynamic_hook = require "kong.dynamic_hook"
local o11y_logs = require "kong.observability.logs"

local tostring = tostring
local null = ngx.null


local CONTENT_TYPE_HEADER_NAME = "Content-Type"
local DEFAULT_CONTENT_TYPE_HEADER = "application/x-protobuf"
local DEFAULT_HEADERS = {
  [CONTENT_TYPE_HEADER_NAME] = DEFAULT_CONTENT_TYPE_HEADER
}

local _log_prefix = "[otel] "

local function http_export_request(conf, pb_data, headers)
  local httpc = http.new()
  httpc:set_timeouts(conf.connect_timeout, conf.send_timeout, conf.read_timeout)
  local res, err = httpc:request_uri(conf.endpoint, {
    method = "POST",
    body = pb_data,
    headers = headers,
  })

  if not res then
    return false, "failed to send request: " .. err

  elseif res and res.status ~= 200 then
    return false, "response error: " .. tostring(res.status) .. ", body: " .. tostring(res.body)
  end

  return true
end


local function rpc_export_request(conf, data)
  -- print("conf = " .. require("inspect")(conf))
  -- kong.rpc:call(kong.configuration.cluster_control_plane, "kong.observability.debug-session.v1.toggle", data)
  print("in OTel plugin / rpc_call handler")
  kong.rpc:call("control_plane", "kong.observability.debug-session.v1.toggle", data)
  return true
end


local function get_headers(conf_headers)
  if not conf_headers or conf_headers == null then
    return DEFAULT_HEADERS
  end

  if conf_headers[CONTENT_TYPE_HEADER_NAME] then
    return conf_headers
  end

  local headers = clone(conf_headers)
  headers[CONTENT_TYPE_HEADER_NAME] = DEFAULT_CONTENT_TYPE_HEADER
  return headers
end

  local function start_log_hooks()
      dynamic_hook.hook("observability_logs", "push", o11y_logs.maybe_push)
      dynamic_hook.enable_by_default("observability_logs")
  end

  local function start_instrumentation_hooks()
      dynamic_hook.enable_by_default("instrumentations:request")
  end

  local function start_all_hooks()
    print("IN START_ALL LOGS")
    start_log_hooks()
    start_instrumentation_hooks()
  end



return {
  http_export_request = http_export_request,
  rpc_export_request = rpc_export_request,
  get_headers = get_headers,
  _log_prefix = _log_prefix,
  start_all_hooks = start_all_hooks,
  start_log_hooks = start_log_hooks,
  start_instrumentation_hooks = start_instrumentation_hooks,
}
