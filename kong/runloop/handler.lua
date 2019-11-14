-- Kong runloop

local ck           = require "resty.cookie"
local meta         = require "kong.meta"
local utils        = require "kong.tools.utils"
local Router       = require "kong.router"
local balancer     = require "kong.runloop.balancer"
local reports      = require "kong.reports"
local constants   = require "kong.constants"
local singletons  = require "kong.singletons"
local certificate = require "kong.runloop.certificate"
local workspaces  = require "kong.workspaces"
local tracing     = require "kong.tracing"
local concurrency  = require "kong.concurrency"
local PluginsIterator = require "kong.runloop.plugins_iterator"
local file_helpers = require "kong.portal.file_helpers"


local kong         = kong
local type         = type
local ipairs       = ipairs
local tostring     = tostring
local tonumber     = tonumber
local sub          = string.sub
local byte         = string.byte
local gsub         = string.gsub
local find         = string.find
local lower        = string.lower
local fmt          = string.format
local ngx          = ngx
local var          = ngx.var
local log         = ngx.log
local exit         = ngx.exit
local header       = ngx.header
local timer_at     = ngx.timer.at
local timer_every  = ngx.timer.every
local re_match     = ngx.re.match
local re_find      = ngx.re.find
local subsystem    = ngx.config.subsystem
local clear_header = ngx.req.clear_header
local starttls     = ngx.req.starttls -- luacheck: ignore
local unpack      = unpack


local ERR   = ngx.ERR
local INFO  = ngx.INFO
local WARN  = ngx.WARN
local DEBUG = ngx.DEBUG
local ERROR = ngx.ERROR
local COMMA = byte(",")
local SPACE = byte(" ")


local SUBSYSTEMS = constants.PROTOCOLS_WITH_SUBSYSTEM
local EMPTY_T = {}
local TTL_ZERO = { ttl = 0 }


local ROUTER_SYNC_OPTS
local ROUTER_ASYNC_OPTS
local PLUGINS_ITERATOR_SYNC_OPTS
local PLUGINS_ITERATOR_ASYNC_OPTS


local get_plugins_iterator, get_updated_plugins_iterator
local build_plugins_iterator, update_plugins_iterator
local rebuild_plugins_iterator

local get_updated_router, build_router, update_router
local server_header = meta._SERVER_TOKENS
local rebuild_router

-- for tests
local _set_update_plugins_iterator
local _set_update_router
local _set_build_router
local _set_router
local _set_router_version


local update_lua_mem
do
  local pid = ngx.worker.pid
  local kong_shm = ngx.shared.kong

  local LUA_MEM_SAMPLE_RATE = 10 -- seconds
  local last = ngx.time()

  local collectgarbage = collectgarbage

  update_lua_mem = function(force)
    local time = ngx.time()

    if force or time - last >= LUA_MEM_SAMPLE_RATE then
      local count = collectgarbage("count")

      local ok, err = kong_shm:safe_set("kong:mem:" .. pid(), count)
      if not ok then
        log(ERROR, "could not record Lua VM allocated memory: ", err)
      end

      last = ngx.time()
    end
  end
end


local function csv_iterator(s, b)
  if b == -1 then
    return
  end

  local e = find(s, ",", b, true)
  local v
  local l
  if e then
    if e == b then
      return csv_iterator(s, b + 1) -- empty string
    end
    v = sub(s, b, e - 1)
    l = e - b
    b = e + 1

  else
    if b > 1 then
      v = sub(s, b)
    else
      v = s
    end

    l = #v
    b = -1 -- end iteration
  end

  if l == 1 and (byte(v) == SPACE or byte(v) == COMMA) then
    return csv_iterator(s, b)
  end

  if byte(v, 1, 1) == SPACE then
    v = gsub(v, "^%s+", "")
  end

  if byte(v, -1) == SPACE then
    v = gsub(v, "%s+$", "")
  end

  if v == "" then
    return csv_iterator(s, b)
  end

  return b, v
end


local function csv(s)
  if type(s) ~= "string" or s == "" then
    return csv_iterator, s, -1
  end

  s = lower(s)
  if s == "close" or s == "upgrade" or s == "keep-alive" then
    return csv_iterator, s, -1
  end

  return csv_iterator, s, 1
end


local function register_events()
  -- initialize local local_events hooks
  local db             = kong.db
  local cache          = kong.cache
  local worker_events  = kong.worker_events
  local cluster_events = kong.cluster_events


  -- events dispatcher

  worker_events.register(function(data)
    if not data.schema then
      log(ERR, "[events] missing schema in crud subscriber")
      return
    end

    local workspaces, err = db.workspaces:select_all(nil, {skip_rbac = true})
    if err then
      log(ngx.ERR, "[events] could not fetch workspaces: ", err)
    end

    if not data.entity then
      log(ERR, "[events] missing entity in crud subscriber")
      return
    end

    -- invalidate this entity anywhere it is cached if it has a
    -- caching key

    local cache_key = db[data.schema.name]:cache_key(data.entity, nil, nil,
                                                     nil, nil, true)

    if cache_key then
      cache:invalidate(cache_key, workspaces)
    end

    -- if we had an update, but the cache key was part of what was updated,
    -- we need to invalidate the previous entity as well

    if data.old_entity then
      cache_key = db[data.schema.name]:cache_key(data.old_entity, nil, nil,
                                                 nil, nil, true)
      if cache_key then
        cache:invalidate(cache_key, workspaces)
      end
    end

    if not data.operation then
      log(ERR, "[events] missing operation in crud subscriber")
      return
    end

    -- public worker events propagation

    local entity_channel           = data.schema.table or data.schema.name
    local entity_operation_channel = fmt("%s:%s", entity_channel,
                                         data.operation)

    -- crud:routes
    local ok, err = worker_events.post_local("crud", entity_channel, data)
    if not ok then
      log(ERR, "[events] could not broadcast crud event: ", err)
      return
    end

    -- crud:routes:create
    ok, err = worker_events.post_local("crud", entity_operation_channel, data)
    if not ok then
      log(ERR, "[events] could not broadcast crud event: ", err)
      return
    end
  end, "dao:crud")


  -- local events (same worker)


  worker_events.register(function()
    log(DEBUG, "[events] Route updated, invalidating router")
    cache:invalidate("router:version")
  end, "crud", "routes")


  worker_events.register(function(data)
    if data.operation ~= "create" and
        data.operation ~= "delete"
    then
      -- no need to rebuild the router if we just added a Service
      -- since no Route is pointing to that Service yet.
      -- ditto for deletion: if a Service if being deleted, it is
      -- only allowed because no Route is pointing to it anymore.
      log(DEBUG, "[events] Service updated, invalidating router")
      cache:invalidate("router:version")
    end
  end, "crud", "services")


  worker_events.register(function(data)
    log(DEBUG, "[events] Plugin updated, invalidating plugins iterator")
    cache:invalidate("plugins_iterator:version")
  end, "crud", "plugins")


  -- SSL certs / SNIs invalidations


  worker_events.register(function(data)
    log(DEBUG, "[events] SNI updated, invalidating cached certificates")
    local sni = data.old_entity or data.entity
    local sni_wild_pref, sni_wild_suf = certificate.produce_wild_snis(sni.name)
    cache:invalidate("snis:" .. sni.name)

    if sni_wild_pref then
      cache:invalidate("snis:" .. sni_wild_pref)
    end

    if sni_wild_suf then
      cache:invalidate("snis:" .. sni_wild_suf)
    end
  end, "crud", "snis")


  worker_events.register(function(data)
    log(DEBUG, "[events] SSL cert updated, invalidating cached certificates")
    local certificate = data.entity

    for sni, err in db.snis:each_for_certificate({ id = certificate.id }) do
      if err then
        log(ERR, "[events] could not find associated snis for certificate: ",
                  err)
        break
      end

      local cache_key = "certificates:" .. sni.certificate.id
      cache:invalidate(cache_key)
    end
  end, "crud", "certificates")


  -- target updates


  -- worker_events local handler: event received from DAO
  worker_events.register(function(data)
    local operation = data.operation
    local target = data.entity
    -- => to worker_events node handler
    local ok, err = worker_events.post("balancer", "targets", {
        operation = data.operation,
        entity = data.entity,
      })
    if not ok then
      log(ERR, "failed broadcasting target ",
          operation, " to workers: ", err)
    end
    -- => to cluster_events handler
    local key = fmt("%s:%s", operation, target.upstream.id)
    ok, err = cluster_events:broadcast("balancer:targets", key)
    if not ok then
      log(ERR, "failed broadcasting target ", operation, " to cluster: ", err)
    end
  end, "crud", "targets")


  -- worker_events node handler
  worker_events.register(function(data)
    local operation = data.operation
    local target = data.entity

    -- => to balancer update
    workspaces.run_with_ws_scope({}, balancer.on_target_event,
                                  operation, target)
  end, "balancer", "targets")


  -- cluster_events handler
  cluster_events:subscribe("balancer:targets", function(data)
    local operation, key = unpack(utils.split(data, ":"))
    local entity
    if key ~= "all" then
      entity = {
        upstream = { id = key },
      }
    else
      entity = "all"
    end
    -- => to worker_events node handler
    local ok, err = worker_events.post("balancer", "targets", {
        operation = operation,
        entity = entity
      })
    if not ok then
      log(ERR, "failed broadcasting target ", operation, " to workers: ", err)
    end
  end)


  -- manual health updates
  cluster_events:subscribe("balancer:post_health", function(data)
    local pattern = "([^|]+)|([^|]+)|([^|]+)|([^|]+)|(.*)"
    local ip, port, health, id, name = data:match(pattern)
    port = tonumber(port)
    local upstream = { id = id, name = name }
    local _, err = balancer.post_health(upstream, ip, port, health == "1")
    if err then
      log(ERR, "failed posting health of ", name, " to workers: ", err)
    end
  end)


  -- upstream updates


  -- worker_events local handler: event received from DAO
  worker_events.register(function(data)
    local operation = data.operation
    local upstream = data.entity
    -- => to worker_events node handler
    local ok, err = worker_events.post("balancer", "upstreams", {
        operation = data.operation,
        entity = data.entity,
      })
    if not ok then
      log(ERR, "failed broadcasting upstream ",
          operation, " to workers: ", err)
    end
    -- => to cluster_events handler
    local key = fmt("%s:%s:%s", operation, upstream.id, upstream.name)
    local ok, err = cluster_events:broadcast("balancer:upstreams", key)
    if not ok then
      log(ERR, "failed broadcasting upstream ", operation, " to cluster: ", err)
    end
  end, "crud", "upstreams")


  -- worker_events node handler
  worker_events.register(function(data)
    local operation = data.operation
    local upstream = data.entity

    local workspace_list, err = db.workspaces:select_all(nil, {skip_rbac = true})
    if err then
      log(ngx.ERR, "[events] could not fetch workspaces: ", err)
      return
    end

    -- => to balancer update
    workspaces.run_with_ws_scope({}, balancer.on_upstream_event, operation,
                                  upstream, workspace_list)
  end, "balancer", "upstreams")


  cluster_events:subscribe("balancer:upstreams", function(data)
    local operation, id, name = unpack(utils.split(data, ":"))
    local entity = {
      id = id,
      name = name,
    }
    -- => to worker_events node handler
    local ok, err = worker_events.post("balancer", "upstreams", {
        operation = operation,
        entity = entity
      })
    if not ok then
      log(ERR, "failed broadcasting upstream ", operation, " to workers: ", err)
    end
  end)


  worker_events.register(function(data)
    log(DEBUG, "[events] workspace_entites updated, invalidating API workspace scope")
    local target = data.entity
    if target.entity_type == "apis" or target.entity_type == "routes" then
      local ws_scope_key = fmt("apis_ws_resolution:%s", target.entity_id)
      cache:invalidate(ws_scope_key)
    end
  end, "crud", "workspace_entities")

  -- initialize balancers for active healthchecks
  ngx.timer.at(0, function()
    workspaces.run_with_ws_scope({}, balancer.init)
  end)

  if singletons.configuration.audit_log then
    log(DEBUG, "register audit log events handler")
    local audit_log = require "kong.enterprise_edition.audit_log"
    worker_events.register(audit_log.dao_audit_handler, "dao:crud")
  end

  -- rbac token ident cache handling
  worker_events.register(function(data)
    singletons.cache:invalidate("rbac_user_token_ident:" ..
                                data.entity.user_token_ident)

    -- clear a patched ident range cache, if appropriate
    -- this might be nil if we in-place upgrade a pt token
    if data.old_entity and data.old_entity.user_token_ident then
      singletons.cache:invalidate("rbac_user_token_ident:" ..
                                  data.old_entity.user_token_ident)
    end
  end, "crud", "rbac_users")


  -- declarative config updates


  if db.strategy == "off" then
    worker_events.register(function()
      cache:flip()
    end, "declarative", "flip_config")
  end


  -- portal router events
  worker_events.register(function(data)
    local file = data.entity
    if file_helpers.is_config_path(file.path) or
       file_helpers.is_content_path(file.path) or
       file_helpers.is_spec_path(file.path) then
      local workspace = workspaces.get_workspace()
      local cache_key = "portal_router-" .. workspace.name .. ":version"
      local cache_val = tostring(file.created_at) .. file.checksum

      -- to node worker event
      local ok, err = worker_events.post("portal", "router", {
        cache_key = cache_key,
        cache_val = cache_val,
      })
      if not ok then
        log(ERR, "failed broadcasting portal:router event to workers: ", err)
      end

      -- to cluster worker event
      local cluster_key = cache_key .. "|" .. cache_val
      local ok, err = cluster_events:broadcast("portal:router", cluster_key)
      if not ok then
        log(ERR, "failed broadcasting portal:router event to cluster: ", err)
      end
    end
  end, "crud", "files")


  cluster_events:subscribe("portal:router", function(data)
    local cache_key, cache_val = unpack(utils.split(data, "|"))
    local ok, err = worker_events.post("portal", "router", {
      cache_key = cache_key,
      cache_val = cache_val,
    })
    if not ok then
      log(ERR, "failed broadcasting portal:router event to workers: ", err)
    end
  end)


  worker_events.register(function(data)
    singletons.portal_router.set_version(data.cache_key, data.cache_val)
  end, "portal", "router")
end


-- @param name "router" or "plugins_iterator"
-- @param callback A function that will update the router or plugins_iterator
-- @param version target version
-- @param opts concurrency options, including lock name and timeout.
-- @returns true if callback was either successfully executed synchronously,
-- enqueued via async timer, or not needed (because current_version == target).
-- nil otherwise (callback was neither called successfully nor enqueued,
-- or an error happened).
-- @returns error message as a second return value in case of failure/error
local function rebuild(name, callback, version, opts)
  local current_version, err = kong.cache:get(name .. ":version", TTL_ZERO,
                                              utils.uuid)
  if err then
    return nil, "failed to retrieve " .. name .. " version: " .. err
  end

  if current_version == version then
    return true
  end

  return concurrency.with_coroutine_mutex(opts, callback)
end


do
  local plugins_iterator


  build_plugins_iterator = function(version)
    local new_iterator, err = PluginsIterator.new(version)
    if not new_iterator then
      return nil, err
    end
    plugins_iterator = new_iterator
    return true
  end


  update_plugins_iterator = function()
    local version, err = kong.cache:get("plugins_iterator:version", TTL_ZERO,
                                        utils.uuid)
    if err then
      return nil, "failed to retrieve plugins iterator version: " .. err
    end

    if plugins_iterator and plugins_iterator.version == version then
      return true
    end

    local ok, err = build_plugins_iterator(version)
    if not ok then
      return nil, --[[ 'err' fully formatted ]] err
    end

    return true
  end


  rebuild_plugins_iterator = function(timeout)
    local plugins_iterator_version = plugins_iterator and plugins_iterator.version
    return rebuild("plugins_iterator", update_plugins_iterator,
                   plugins_iterator_version, timeout)
  end


  get_updated_plugins_iterator = function()
    if kong.configuration.router_consistency == "strict" then
      local ok, err = rebuild_plugins_iterator(PLUGINS_ITERATOR_SYNC_OPTS)
      if not ok then
        -- If an error happens while updating, log it and return non-updated
        -- version
        log(ERR, "could not rebuild plugins iterator: ", err,
                 " (stale plugins iterator will be used)")
      end
    end
    return plugins_iterator
  end


  get_plugins_iterator = function()
    return plugins_iterator
  end


  -- for tests only
  _set_update_plugins_iterator = function(f)
    update_plugins_iterator = f
  end
end


do
  -- Given a protocol, return the subsystem that handles it
  local router
  local router_version


  local function should_process_route(route)
    for _, protocol in ipairs(route.protocols) do
      if SUBSYSTEMS[protocol] == subsystem then
        return true
      end
    end

    return false
  end


  local function load_service_from_db(service_pk)
    local service, err = kong.db.services:select(service_pk)
    if service == nil then
      -- the third value means "do not cache"
      return nil, err, -1
    end
    return service
  end


  local function build_services_init_cache(db)
    local services_init_cache = {}

    for service, err in db.services:each() do
      if err then
        return nil, err
      end

      services_init_cache[service.id] = service
    end

    return services_init_cache
  end


  local function get_service_for_route(db, route, services_init_cache)
    local service_pk = route.service
    if not service_pk then
      return nil
    end

    local id = service_pk.id
    local service = services_init_cache[id]
    if service then
      return service
    end

    local err

    -- kong.cache is not available on init phase
    if kong.cache then
      local cache_key = db.services:cache_key(service_pk.id)
      service, err = kong.cache:get(cache_key, TTL_ZERO,
                                    load_service_from_db, service_pk)

    else -- init phase, not present on init cache

      -- A new service/route has been inserted while the initial route
      -- was being created, on init (perhaps by a different Kong node).
      -- Load the service individually and update services_init_cache with it
      service, err = load_service_from_db(service_pk)
      services_init_cache[id] = service
    end

    if err then
      return nil, "error raised while finding service for route (" .. route.id .. "): " ..
                  err

    elseif not service then
      return nil, "could not find service for route (" .. route.id .. ")"
    end


    -- TODO: this should not be needed as the schema should check it already
    if SUBSYSTEMS[service.protocol] ~= subsystem then
      log(WARN, "service with protocol '", service.protocol,
                "' cannot be used with '", subsystem, "' subsystem")

      return nil
    end

    return service
  end


  build_router = function(version)
    local db = kong.db
    local routes, i = {}, 0

    local err
    -- The router is initially created on init phase, where kong.cache is still not ready
    -- For those cases, use a plain Lua table as a cache instead
    local services_init_cache = {}
    if not kong.cache then
      services_init_cache, err = build_services_init_cache(db)
      if err then
        services_init_cache = {}
        log(WARN, "could not build services init cache: ", err)
      end
    end

    for route, err in db.routes:each() do
      if err then
        return nil, "could not load routes: " .. err
      end

      if should_process_route(route) then
        local service, err = get_service_for_route(db, route, services_init_cache)
        if err then
          return nil, err
        end

        local r = {
          route   = route,
          service = service,
        }

        i = i + 1
        routes[i] = r
      end
    end

    local new_router, err = Router.new(routes)
    tracing.wrap_router(new_router)
    if not new_router then
      return nil, "could not create router: " .. err
    end

    router = new_router

    if version then
      router_version = version
    end

    singletons.router = router

    return true
  end


  update_router = function()
    -- we might not need to rebuild the router (if we were not
    -- the first request in this process to enter this code path)
    -- check again and rebuild only if necessary
    local version, err = kong.cache:get("router:version", TTL_ZERO, utils.uuid)
    if err then
      return nil, "failed to retrieve router version: " .. err
    end

    if version == router_version then
      return true
    end

    local ok, err = build_router(version)
    if not ok then
      return nil, --[[ 'err' fully formatted ]] err
    end

    return true
  end


  rebuild_router = function(opts)
    return rebuild("router", update_router, router_version, opts)
  end


  get_updated_router = function()
    if kong.configuration.router_consistency == "strict" then
      local ok, err = rebuild_router(ROUTER_SYNC_OPTS)
      if not ok then
        -- If an error happens while updating, log it and return non-updated
        -- version.
        log(ERR, "could not rebuild router: ", err,
                 " (stale router will be used)")
      end
    end
    return router
  end


  -- for tests only
  _set_update_router = function(f)
    update_router = f
  end


  -- for tests only
  _set_build_router = function(f)
    build_router = f
  end


  -- for tests only
  _set_router = function(r)
    router = r
  end


  -- for tests only
  _set_router_version = function(v)
    router_version = v
  end
end


local balancer_prepare
do
  local get_certificate = certificate.get_certificate

  function balancer_prepare(ctx, scheme, host_type, host, port,
                            service, route)
    local balancer_data = {
      scheme         = scheme,    -- scheme for balancer: http, https
      type           = host_type, -- type of 'host': ipv4, ipv6, name
      host           = host,      -- target host per `service` entity
      port           = port,      -- final target port
      try_count      = 0,         -- retry counter
      tries          = {},        -- stores info per try
      ssl_ctx        = kong.default_client_ssl_ctx, -- SSL_CTX* to use
      -- ip          = nil,       -- final target IP address
      -- balancer    = nil,       -- the balancer object, if any
      -- hostname    = nil,       -- hostname of the final target IP
      -- hash_cookie = nil,       -- if Upstream sets hash_on_cookie
      -- balancer_handle = nil,   -- balancer handle for the current connection
    }

    do
      local s = service or EMPTY_T

      balancer_data.retries         = s.retries         or 5
      balancer_data.connect_timeout = s.connect_timeout or 60000
      balancer_data.send_timeout    = s.write_timeout   or 60000
      balancer_data.read_timeout    = s.read_timeout    or 60000
    end

    ctx.service          = service
    ctx.route            = route
    ctx.balancer_data    = balancer_data
    ctx.balancer_address = balancer_data -- for plugin backward compatibility

    if service then
      local client_certificate = service.client_certificate
      if client_certificate then
        local cert, err = get_certificate(client_certificate)
        if not cert then
          log(ERR, "unable to fetch upstream client TLS certificate ",
                   client_certificate.id, ": ", err)
          return
        end

        local res
        res, err = kong.service.set_tls_cert_key(cert.cert, cert.key)
        if not res then
          log(ERR, "unable to apply upstream client TLS certificate ",
                   client_certificate.id, ": ", err)
        end
      end
    end
  end
end


local function balancer_execute(ctx)
  local balancer_data = ctx.balancer_data

  do -- Check for KONG_ORIGINS override
    local origin_key = balancer_data.scheme .. "://" ..
                       utils.format_host(balancer_data)
    local origin = singletons.origins[origin_key]
    if origin then
      balancer_data.scheme = origin.scheme
      balancer_data.type = origin.type
      balancer_data.host = origin.host
      balancer_data.port = origin.port
    end
  end

  local ok, err, errcode = balancer.execute(balancer_data, ctx)
  if not ok and errcode == 500 then
    err = "failed the initial dns/balancer resolve for '" ..
          balancer_data.host .. "' with: " .. tostring(err)
  end

  return ok, err, errcode
end


local function set_init_versions_in_cache()
  local ok, err = kong.cache:get("router:version", TTL_ZERO, function()
    return "init"
  end)
  if not ok then
    return nil, "failed to set router version in cache: " .. tostring(err)
  end

  local ok, err = kong.cache:get("plugins_iterator:version", TTL_ZERO, function()
    return "init"
  end)
  if not ok then
    return nil, "failed to set plugins iterator version in cache: " ..
                tostring(err)
  end

  return true
end


-- in the table below the `before` and `after` is to indicate when they run:
-- before or after the plugins
return {
  build_router = build_router,

  build_plugins_iterator = build_plugins_iterator,
  update_plugins_iterator = update_plugins_iterator,
  get_plugins_iterator = get_plugins_iterator,
  get_updated_plugins_iterator = get_updated_plugins_iterator,
  set_init_versions_in_cache = set_init_versions_in_cache,

  -- exposed only for tests
  _set_router = _set_router,
  _set_update_router = _set_update_router,
  _set_build_router = _set_build_router,
  _set_router_version = _set_router_version,
  _set_update_plugins_iterator = _set_update_plugins_iterator,
  _get_updated_router = get_updated_router,
  _update_lua_mem = update_lua_mem,

  init_worker = {
    before = function()
      if kong.configuration.anonymous_reports then
        reports.configure_ping(kong.configuration)
        reports.add_ping_value("database_version", kong.db.infos.db_ver)
        reports.toggle(true)
        reports.init_worker()
      end

      update_lua_mem(true)

      register_events()


      -- initialize balancers for active healthchecks
      timer_at(0, function()
        balancer.init()
      end)

      local router_update_frequency = kong.configuration.router_update_frequency or 1

      timer_every(router_update_frequency, function(premature)
        if premature then
          return
        end

        -- Don't wait for the semaphore (timeout = 0) when updating via the
        -- timer.
        -- If the semaphore is locked, that means that the rebuild is
        -- already ongoing.
        local ok, err = rebuild_router(ROUTER_ASYNC_OPTS)
        if not ok then
          log(ERR, "could not rebuild router via timer: ", err)
        end
      end)

      timer_every(router_update_frequency, function(premature)
        if premature then
          return
        end

        local ok, err = rebuild_plugins_iterator(PLUGINS_ITERATOR_ASYNC_OPTS)
        if not ok then
          log(ERR, "could not rebuild plugins iterator via timer: ", err)
        end
      end)

      do
        local rebuild_timeout = 60

        if kong.configuration.database == "cassandra" then
          rebuild_timeout = kong.configuration.cassandra_timeout / 1000
        end

        if kong.configuration.database == "postgres" then
          rebuild_timeout = kong.configuration.pg_timeout / 1000
        end

        ROUTER_SYNC_OPTS = {
          name = "router",
          timeout = rebuild_timeout,
          on_timeout = "run_unlocked",
        }
        ROUTER_ASYNC_OPTS = {
          name = "router",
          timeout = 0,
          on_timeout = "return_true",
        }
        PLUGINS_ITERATOR_SYNC_OPTS = {
          name = "plugins_iterator",
          timeout = rebuild_timeout,
          on_timeout = "run_unlocked",
        }
        PLUGINS_ITERATOR_ASYNC_OPTS = {
          name = "plugins_iterator",
          timeout = 0,
          on_timeout = "return_true",
        }
      end

    end
  },
  preread = {
    before = function(ctx)
      local router = get_updated_router()

      local match_t = router.exec()
      if not match_t then
        log(ERR, "no Route found with those values")
        return exit(500)
      end

      local ssl_termination_ctx -- OpenSSL SSL_CTX to use for termination

      local ssl_preread_alpn_protocols = var.ssl_preread_alpn_protocols
      -- ssl_preread_alpn_protocols is a comma separated list
      -- see https://trac.nginx.org/nginx/ticket/1616
      if kong.configuration.service_mesh and ssl_preread_alpn_protocols and
        -- ssl_preread_alpn_protocols:find(mesh.get_mesh_alpn(), 1, true) and
        true then
        -- -- Is probably an incoming service mesh connection
        -- -- terminate service-mesh Mutual TLS
        -- ssl_termination_ctx = mesh.mesh_server_ssl_ctx
        ctx.is_service_mesh_request = true
      else
        -- TODO: stream router should decide if TLS is terminated or not
        -- XXX: for now, use presence of SNI to terminate.
        local sni = var.ssl_preread_server_name
        if sni then
          log(DEBUG, "SNI: ", sni)

          local err
          ssl_termination_ctx, err = certificate.find_certificate(sni)
          if not ssl_termination_ctx then
            log(ERR, err)
            return exit(ERROR)
          end

          -- TODO Fake certificate phase?

          log(INFO, "attempting to terminate TLS")
        end
      end

      -- Terminate TLS
      if ssl_termination_ctx and not starttls(ssl_termination_ctx) then
        -- errors are logged by nginx core
        return exit(ERROR)
      end

      local route = match_t.route
      local service = match_t.service
      local upstream_url_t = match_t.upstream_url_t

      if not service then
        -----------------------------------------------------------------------
        -- Serviceless stream route
        -----------------------------------------------------------------------
        local service_scheme = ssl_termination_ctx and "tls" or "tcp"
        local service_host   = var.server_addr

        match_t.upstream_scheme = service_scheme
        upstream_url_t.scheme = service_scheme -- for completeness
        upstream_url_t.type = utils.hostname_type(service_host)
        upstream_url_t.host = service_host
        upstream_url_t.port = tonumber(var.server_port, 10)
      end

      balancer_prepare(ctx, match_t.upstream_scheme,
                       upstream_url_t.type,
                       upstream_url_t.host,
                       upstream_url_t.port,
                       service, route)
    end,
    after = function(ctx)
      local ok, err, errcode = balancer_execute(ctx)
      if not ok then
        local body = utils.get_default_exit_body(errcode, err)
        return kong.response.exit(errcode, body)
      end
    end
  },
  certificate = {
    before = function(_)
      certificate.execute()
    end
  },
  rewrite = {
    before = function(ctx)
      -- special handling for proxy-authorization and te headers in case
      -- the plugin(s) want to specify them (store the original)
      ctx.http_proxy_authorization = var.http_proxy_authorization
      ctx.http_te                  = var.http_te

      -- if kong.configuration.service_mesh then
      --   mesh.rewrite(ctx)
      -- end
    end,
  },
  access = {
    before = function(ctx)
      -- if there is a gRPC service in the context, don't re-execute the pre-access
      -- phase handler - it has been executed before the internal redirect
      if ctx.service and (ctx.service.protocol == "grpc" or
                          ctx.service.protocol == "grpcs")
      then
        return
      end

      -- routing request
      local router = get_updated_router()
      local match_t = router.exec()
      if not match_t then
        return kong.response.exit(404, { message = "no Route matched with those values" })
      end

      local http_version   = ngx.req.http_version()
      local scheme         = var.scheme
      local host           = var.host
      local port           = tonumber(var.server_port, 10)
      local content_type   = var.content_type

      local route          = match_t.route
      local service        = match_t.service
      local upstream_url_t     = match_t.upstream_url_t

      local realip_remote_addr = var.realip_remote_addr
      local forwarded_proto
      local forwarded_host
      local forwarded_port

      -- X-Forwarded-* Headers Parsing
      --
      -- We could use $proxy_add_x_forwarded_for, but it does not work properly
      -- with the realip module. The realip module overrides $remote_addr and it
      -- is okay for us to use it in case no X-Forwarded-For header was present.
      -- But in case it was given, we will append the $realip_remote_addr that
      -- contains the IP that was originally in $remote_addr before realip
      -- module overrode that (aka the client that connected us).

      local trusted_ip = kong.ip.is_trusted(realip_remote_addr)
      if trusted_ip then
        forwarded_proto = var.http_x_forwarded_proto or scheme
        forwarded_host  = var.http_x_forwarded_host  or host
        forwarded_port  = var.http_x_forwarded_port  or port

      else
        forwarded_proto = scheme
        forwarded_host  = host
        forwarded_port  = port
      end

      local protocols = route.protocols
      if (protocols and protocols.https and not protocols.http and
          forwarded_proto ~= "https")
      then
        local redirect_status_code = route.https_redirect_status_code or 426

        if redirect_status_code == 426 then
          return kong.response.exit(426, { message = "Please use HTTPS protocol" }, {
            ["Connection"] = "Upgrade",
            ["Upgrade"]    = "TLS/1.2, HTTP/1.1",
          })
        end

        if redirect_status_code == 301 or
          redirect_status_code == 302 or
          redirect_status_code == 307 or
          redirect_status_code == 308 then
          header["Location"] = "https://" .. forwarded_host .. var.request_uri
          return kong.response.exit(redirect_status_code)
        end
      end

      -- mismatch: non-http/2 request matched grpc route
      if (protocols and (protocols.grpc or protocols.grpcs) and http_version ~= 2 and
        (content_type and sub(content_type, 1, #"application/grpc") == "application/grpc"))
      then
        return kong.response.exit(426, { message = "Please use HTTP2 protocol" }, {
          ["connection"] = "Upgrade",
          ["upgrade"]    = "HTTP/2",
        })
      end

      -- mismatch: non-grpc request matched grpc route
      if (protocols and (protocols.grpc or protocols.grpcs) and
        (not content_type or sub(content_type, 1, #"application/grpc") ~= "application/grpc"))
      then
        return kong.response.exit(415, { message = "Non-gRPC request matched gRPC route" })
      end

      -- mismatch: grpc request matched grpcs route
      if (protocols and protocols.grpcs and not protocols.grpc and
        forwarded_proto ~= "https")
      then
        return kong.response.exit(200, nil, {
          ["grpc-status"] = 1,
          ["grpc-message"] = "gRPC request matched gRPCs route",
        })
      end

      if not service then
        -----------------------------------------------------------------------
        -- Serviceless HTTP / HTTPS / HTTP2 route
        -----------------------------------------------------------------------
        local service_scheme
        local service_host
        local service_port

        -- 1. try to find information from a request-line
        local request_line = var.request
        if request_line then
          local matches, err = re_match(request_line, [[\w+ (https?)://([^/?#\s]+)]], "ajos")
          if err then
            log(WARN, "pcre runtime error when matching a request-line: ", err)

          elseif matches then
            local uri_scheme = lower(matches[1])
            if uri_scheme == "https" or uri_scheme == "http" then
              service_scheme = uri_scheme
              service_host   = lower(matches[2])
            end
            --[[ TODO: check if these make sense here?
            elseif uri_scheme == "wss" then
              service_scheme = "https"
              service_host   = lower(matches[2])
            elseif uri_scheme == "ws" then
              service_scheme = "http"
              service_host   = lower(matches[2])
            end
            --]]
          end
        end

        -- 2. try to find information from a host header
        if not service_host then
          local http_host = var.http_host
          if http_host then
            service_scheme = scheme
            service_host   = lower(http_host)
          end
        end

        -- 3. split host to host and port
        if service_host then
          -- remove possible userinfo
          local pos = find(service_host, "@", 1, true)
          if pos then
            service_host = sub(service_host, pos + 1)
          end

          pos = find(service_host, ":", 2, true)
          if pos then
            service_port = sub(service_host, pos + 1)
            service_host = sub(service_host, 1, pos - 1)

            local found, _, err = re_find(service_port, [[[1-9]{1}\d{0,4}$]], "adjo")
            if err then
              log(WARN, "pcre runtime error when matching a port number: ", err)

            elseif found then
              service_port = tonumber(service_port, 10)
              if not service_port or service_port > 65535 then
                service_scheme = nil
                service_host   = nil
                service_port   = nil
              end

            else
              service_scheme = nil
              service_host   = nil
              service_port   = nil
            end
          end
        end

        -- 4. use known defaults
        if service_host and not service_port then
          if service_scheme == "http" then
            service_port = 80
          elseif service_scheme == "https" then
            service_port = 443
          else
            service_port = port
          end
        end

        -- 5. fall-back to server address
        if not service_host then
          service_scheme = scheme
          service_host   = var.server_addr
          service_port   = port
        end

        match_t.upstream_scheme = service_scheme
        upstream_url_t.scheme = service_scheme -- for completeness
        upstream_url_t.type = utils.hostname_type(service_host)
        upstream_url_t.host = service_host
        upstream_url_t.port = service_port
      end

      balancer_prepare(ctx, match_t.upstream_scheme,
                       upstream_url_t.type,
                       upstream_url_t.host,
                       upstream_url_t.port,
                       service, route)

      ctx.router_matches = match_t.matches

      -- `uri` is the URI with which to call upstream, as returned by the
      --       router, which might have truncated it (`strip_uri`).
      -- `host` is the original header to be preserved if set.
      var.upstream_scheme = match_t.upstream_scheme -- COMPAT: pdk
      var.upstream_uri    = match_t.upstream_uri
      var.upstream_host   = match_t.upstream_host

      -- Keep-Alive and WebSocket Protocol Upgrade Headers
      if var.http_upgrade and lower(var.http_upgrade) == "websocket" then
        var.upstream_connection = "upgrade"
        var.upstream_upgrade    = "websocket"

      else
        var.upstream_connection = "keep-alive"
      end

      -- X-Forwarded-* Headers
      local http_x_forwarded_for = var.http_x_forwarded_for
      if http_x_forwarded_for then
        var.upstream_x_forwarded_for = http_x_forwarded_for .. ", " ..
                                       realip_remote_addr

      else
        var.upstream_x_forwarded_for = var.remote_addr
      end

      var.upstream_x_forwarded_proto = forwarded_proto
      var.upstream_x_forwarded_host  = forwarded_host
      var.upstream_x_forwarded_port  = forwarded_port

      local err
      ctx.workspaces, err = workspaces.resolve_ws_scope(ctx, route.protocols and route)
      ctx.log_request_workspaces = ctx.workspaces
      if err then
        ngx.log(ngx.ERR, "failed to retrieve workspace for the request (reason: "
                         .. tostring(err) .. ")")

        return kong.response.exit(500, { message = "An unexpected error occurred"})
      end

      -- At this point, the router and `balancer_setup_stage1` have been
      -- executed; detect requests that need to be redirected from `proxy_pass`
      -- to `grpc_pass`. After redirection, this function will return early
      if service and var.kong_proxy_mode == "http" then
        if service.protocol == "grpc" then
          return ngx.exec("@grpc")
        end

        if service.protocol == "grpcs" then
          return ngx.exec("@grpcs")
        end
      end
    end,
    -- Only executed if the `router` module found a route and allows nginx to proxy it.
    after = function(ctx)
      do
        -- Nginx's behavior when proxying a request with an empty querystring
        -- `/foo?` is to keep `$is_args` an empty string, hence effectively
        -- stripping the empty querystring.
        -- We overcome this behavior with our own logic, to preserve user
        -- desired semantics.
        local upstream_uri = var.upstream_uri

        if var.is_args == "?" or sub(var.request_uri, -1) == "?" then
          var.upstream_uri = upstream_uri .. "?" .. (var.args or "")
        end
      end

      local balancer_data = ctx.balancer_data
      balancer_data.scheme = var.upstream_scheme -- COMPAT: pdk

      local ok, err, errcode = balancer_execute(ctx)
      if not ok then
        local body = utils.get_default_exit_body(errcode, err)
        return kong.response.exit(errcode, body)
      end

      var.upstream_scheme = balancer_data.scheme

      do
        -- set the upstream host header if not `preserve_host`
        local upstream_host = var.upstream_host

        if not upstream_host or upstream_host == "" then
          upstream_host = balancer_data.hostname

          local upstream_scheme = var.upstream_scheme
          if upstream_scheme == "http"  and balancer_data.port ~= 80 or
             upstream_scheme == "https" and balancer_data.port ~= 443
          then
            upstream_host = upstream_host .. ":" .. balancer_data.port
          end

          var.upstream_host = upstream_host
        end
      end

      -- clear hop-by-hop request headers:
      for _, header_name in csv(var.http_connection) do
        -- some of these are already handled by the proxy module,
        -- proxy-authorization being an exception that is handled
        -- below with special semantics.
        if header_name ~= "proxy-authorization" then
          clear_header(header_name)
        end
      end

      -- add te header only when client requests trailers (proxy removes it)
      for _, header_name in csv(var.http_te) do
        if header_name == "trailers" then
          var.upstream_te = "trailers"
          break
        end
      end

      if var.http_proxy then
        clear_header("Proxy")
      end

      if var.http_proxy_connection then
        clear_header("Proxy-Connection")
      end

      -- clear the proxy-authorization header only in case the plugin didn't
      -- specify it, assuming that the plugin didn't specify the same value.
      local proxy_authorization = var.http_proxy_authorization
      if proxy_authorization and
         proxy_authorization == var.http_proxy_authorization then
        clear_header("Proxy-Authorization")
      end
    end
  },
  header_filter = {
    before = function(ctx)
      if not ctx.KONG_PROXIED then
        return
      end

      -- clear hop-by-hop response headers:
      for _, header_name in csv(var.upstream_http_connection) do
        header[header_name] = nil
      end

      if var.upstream_http_upgrade and
         lower(var.upstream_http_upgrade) ~= lower(var.upstream_upgrade) then
        header["Upgrade"] = nil
      end

      if var.upstream_http_proxy_authenticate then
        header["Proxy-Authenticate"] = nil
      end

      -- remove trailer response header when client didn't ask for them
      if var.upstream_te == "" and var.upstream_http_trailer then
        header["Trailer"] = nil
      end

      local upstream_status_header = constants.HEADERS.UPSTREAM_STATUS
      if singletons.configuration.enabled_headers[upstream_status_header] then
        header[upstream_status_header] = tonumber(sub(var.upstream_status or "", -3))
        if not header[upstream_status_header] then
          log(ERR, "failed to set ", upstream_status_header, " header")
        end
      end

      local hash_cookie = ctx.balancer_data.hash_cookie
      if not hash_cookie then
        return
      end

      local cookie = ck:new()
      local ok, err = cookie:set(hash_cookie)

      if not ok then
        log(WARN, "failed to set the cookie for hash-based load balancing: ", err,
                      " (key=", hash_cookie.key,
                      ", path=", hash_cookie.path, ")")
      end
    end,
    after = function(ctx)
      local enabled_headers = kong.configuration.enabled_headers
      if ctx.KONG_PROXIED then
        if enabled_headers[constants.HEADERS.UPSTREAM_LATENCY] then
          header[constants.HEADERS.UPSTREAM_LATENCY] = ctx.KONG_WAITING_TIME
        end

        if enabled_headers[constants.HEADERS.PROXY_LATENCY] then
          header[constants.HEADERS.PROXY_LATENCY] = ctx.KONG_PROXY_LATENCY
        end

        if enabled_headers[constants.HEADERS.VIA] then
          header[constants.HEADERS.VIA] = server_header
        end

      else
        if enabled_headers[constants.HEADERS.RESPONSE_LATENCY] then
          header[constants.HEADERS.RESPONSE_LATENCY] = ctx.KONG_RESPONSE_LATENCY
        end

        if enabled_headers[constants.HEADERS.SERVER] then
          header[constants.HEADERS.SERVER] = server_header

        else
          header[constants.HEADERS.SERVER] = nil
        end
      end
    end
  },
  log = {
    after = function(ctx)
      update_lua_mem()

      if kong.configuration.anonymous_reports then
        reports.log()
      end

      if not ctx.KONG_PROXIED then
        return
      end

      -- If response was produced by an upstream (ie, not by a Kong plugin)
      -- Report HTTP status for health checks
      local balancer_data = ctx.balancer_data
      if balancer_data and balancer_data.balancer and balancer_data.ip then
        local status = ngx.status
        if status == 504 then
          balancer_data.balancer.report_timeout(balancer_data.balancer_handle)
        else
          balancer_data.balancer.report_http_status(
            balancer_data.balancer_handle, status)
        end
        -- release the handle, so the balancer can update its statistics
        balancer_data.balancer_handle:release()
      end

      tracing.flush()
    end
  }
}
