-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local migrate_path = require "kong.db.migrations.migrate_path_280_300"

local pairs  = pairs
local ipairs = ipairs
local null   = ngx.null

return function(tbl, version)
  if not tbl or not (version == "1.1" or version == "2.1") then
    return
  end

  local routes = tbl.routes

  if not routes then
    -- no need to migrate
    return
  end

  for _, route in pairs(routes) do
    local paths = route.paths
    if not paths or paths == null then
      -- no need to migrate
      goto continue
    end

    for idx, path in ipairs(paths) do
      paths[idx] = migrate_path(path)
    end

    ::continue::
  end
end
