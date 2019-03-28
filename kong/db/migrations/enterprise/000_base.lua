local utils = require "kong.tools.utils"
local fmt = string.format
local function seed_rbac_data()
  local res = {}
  local def_ws_id = '00000000-0000-0000-0000-000000000000'
  local roles = {
    {
      utils.uuid(), "read-only", 'Read access to all endpoints, across all workspaces',
      {"(%s, '*', '*', 1, FALSE)"}
    },
    { utils.uuid(), "admin", 'Full access to all endpoints, across all workspaces—except RBAC Admin API',
      {"(%s, '*', '*', 15, FALSE);",
       "(%s, '*', '/rbac/*', 15, TRUE);",
       "(%s, '*', '/rbac/*/*', 15, TRUE);",
       "(%s, '*', '/rbac/*/*/*', 15, TRUE);",
       "(%s, '*', '/rbac/*/*/*/*', 15, TRUE);",
       "(%s, '*', '/rbac/*/*/*/*/*', 15, TRUE);",
      },
    },
    { utils.uuid(), "super-admin", 'Full access to all endpoints, across all workspaces',
      {"(%s, '*', '*', 15, FALSE)"}
    }
  }

  for _, role in ipairs(roles) do
    table.insert(res,
      fmt("INSERT into rbac_roles(id, name, comment) VALUES(%s, 'default:%s', '%s')",
        role[1] , role[2], role[3]))
    table.insert(res,
      fmt("INSERT INTO workspace_entities(workspace_id, workspace_name, entity_id, entity_type, unique_field_name, unique_field_value) VALUES(%s, 'default', '%s', 'rbac_roles', 'id', '%s')", def_ws_id, role[1], role[1]))
    table.insert(res,
      fmt("INSERT INTO workspace_entities(workspace_id, workspace_name, entity_id, entity_type, unique_field_name, unique_field_value) VALUES(%s, 'default', '%s', 'rbac_roles', 'name', '%s')", def_ws_id, role[1], role[2]))

    for _, endpoint in ipairs(role[4]) do
      table.insert(res,
        fmt(
          fmt("INSERT INTO rbac_role_endpoints(role_id, workspace, endpoint, actions, negative) VALUES %s;", endpoint),
        role[1]))
    end
  end
  return table.concat(res, ";")
end

return {
  postgres = {
    up = [[
      CREATE TABLE IF NOT EXISTS rl_counters(
        key          text,
        namespace    text,
        window_start int,
        window_size  int,
        count        int,
        PRIMARY KEY(key, namespace, window_start, window_size)
      );

      DO $$
      BEGIN
        IF (SELECT to_regclass('sync_key_idx')) IS NULL THEN
          CREATE INDEX sync_key_idx ON rl_counters(namespace, window_start);
        END IF;
      END$$;



      CREATE TABLE IF NOT EXISTS vitals_stats_hours(
          at integer,
          l2_hit integer default 0,
          l2_miss integer default 0,
          plat_min integer,
          plat_max integer,
          PRIMARY KEY (at)
      );

      CREATE TABLE IF NOT EXISTS vitals_stats_seconds(
          node_id uuid,
          at integer,
          l2_hit integer default 0,
          l2_miss integer default 0,
          plat_min integer,
          plat_max integer,
          ulat_min integer,
          ulat_max integer,
          requests integer default 0,
          plat_count int default 0,
          plat_total int default 0,
          ulat_count int default 0,
          ulat_total int default 0,
          PRIMARY KEY (node_id, at)
      );



      CREATE TABLE IF NOT EXISTS vitals_stats_minutes
      (LIKE vitals_stats_seconds INCLUDING defaults INCLUDING constraints INCLUDING indexes);



      CREATE TABLE IF NOT EXISTS vitals_node_meta(
        node_id uuid PRIMARY KEY,
        first_report timestamp without time zone,
        last_report timestamp without time zone,
        hostname text
      );



      CREATE TABLE IF NOT EXISTS vitals_code_classes_by_cluster(
        code_class int,
        at timestamp with time zone,
        duration int,
        count int,
        PRIMARY KEY (code_class, duration, at)
      );



      CREATE TABLE IF NOT EXISTS vitals_codes_by_route(
        service_id uuid,
        route_id uuid,
        code int,
        at timestamp with time zone,
        duration int,
        count int,
        PRIMARY KEY (route_id, code, duration, at)
      ) WITH (autovacuum_vacuum_scale_factor='0.01', autovacuum_analyze_scale_factor='0.01');

      CREATE INDEX IF NOT EXISTS vcbr_svc_ts_idx
      ON vitals_codes_by_route(service_id, duration, at);



      CREATE TABLE IF NOT EXISTS vitals_codes_by_consumer_route(
        consumer_id uuid,
        service_id uuid,
        route_id uuid,
        code int,
        at timestamp with time zone,
        duration int,
        count int,
        PRIMARY KEY (consumer_id, route_id, code, duration, at)
      ) WITH (autovacuum_vacuum_scale_factor='0.01', autovacuum_analyze_scale_factor='0.01');



      CREATE TABLE IF NOT EXISTS vitals_code_classes_by_workspace(
        workspace_id uuid,
        code_class int,
        at timestamp with time zone,
        duration int,
        count int,
        PRIMARY KEY (workspace_id, code_class, duration, at)
      );



      CREATE TABLE IF NOT EXISTS vitals_locks(
        key text,
        expiry timestamp with time zone,
        PRIMARY KEY(key)
      );
      INSERT INTO vitals_locks(key, expiry)
      VALUES ('delete_status_codes', NULL);



      CREATE TABLE IF NOT EXISTS workspaces (
        id  UUID                  PRIMARY KEY,
        name                      TEXT                      UNIQUE,
        comment                   TEXT,
        created_at                TIMESTAMP WITHOUT TIME ZONE DEFAULT timezone('utc'::text, ('now'::text)::timestamp(0) with time zone),
        meta                      JSON                      DEFAULT '{}'::json,
        config                    JSON                      DEFAULT '{"portal":false}'::json
      );

      INSERT INTO workspaces(id, name)
      VALUES ('00000000-0000-0000-0000-000000000000', 'default');

      CREATE TABLE IF NOT EXISTS workspace_entities(
        workspace_id uuid,
        workspace_name text,
        entity_id text,
        entity_type text,
        unique_field_name text,
        unique_field_value text,
        PRIMARY KEY(workspace_id, entity_id, unique_field_name)
      );

      DO $$
      BEGIN
        IF (SELECT to_regclass('workspace_entities_composite_idx')) IS NULL THEN
          CREATE INDEX workspace_entities_composite_idx on workspace_entities(workspace_id, entity_type, unique_field_name);
        END IF;
      END$$;


      CREATE TABLE IF NOT EXISTS workspace_entity_counters(
        workspace_id uuid REFERENCES workspaces (id) ON DELETE CASCADE,
        entity_type text,
        count int,
        PRIMARY KEY(workspace_id, entity_type)
      );


      CREATE TABLE IF NOT EXISTS rbac_users(
        id uuid PRIMARY KEY,
        name text UNIQUE NOT NULL,
        user_token text UNIQUE NOT NULL,
        user_token_ident text UNIQUE NOT NULL,
        comment text,
        enabled boolean NOT NULL,
        created_at timestamp without time zone default (CURRENT_TIMESTAMP(0) at time zone 'utc')
      );

      DO $$
      BEGIN
        IF (SELECT to_regclass('rbac_users_name_idx')) IS NULL THEN
          CREATE INDEX rbac_users_name_idx on rbac_users(name);
        END IF;
        IF (SELECT to_regclass('rbac_users_token_idx')) IS NULL THEN
          CREATE INDEX rbac_users_token_idx on rbac_users(user_token);
        END IF;
        IF (SELECT to_regclass('idx_rbac_token_ident')) IS NULL THEN
          CREATE INDEX idx_rbac_token_ident on rbac_users(user_token_ident);
        END IF;
      END$$;

      CREATE TABLE IF NOT EXISTS rbac_user_roles(
        user_id uuid NOT NULL,
        role_id uuid NOT NULL,
        PRIMARY KEY(user_id, role_id)
      );

      CREATE TABLE IF NOT EXISTS rbac_roles(
        id uuid PRIMARY KEY,
        name text UNIQUE NOT NULL,
        comment text,
        created_at timestamp without time zone default (CURRENT_TIMESTAMP(0) at time zone 'utc'),
        is_default boolean default false
      );

      CREATE INDEX IF NOT EXISTS rbac_roles_name_idx on rbac_roles(name);
      CREATE INDEX IF NOT EXISTS rbac_role_default_idx on rbac_roles(is_default);

      CREATE TABLE IF NOT EXISTS rbac_role_entities(
        role_id uuid,
        entity_id text,
        entity_type text NOT NULL,
        actions smallint NOT NULL,
        negative boolean NOT NULL,
        comment text,
        created_at timestamp without time zone default (CURRENT_TIMESTAMP(0) at time zone 'utc'),
        PRIMARY KEY(role_id, entity_id)
      );

      CREATE TABLE IF NOT EXISTS rbac_role_endpoints(
        role_id uuid,
        workspace text NOT NULL,
        endpoint text NOT NULL,
        actions smallint NOT NULL,
        comment text,
        created_at timestamp without time zone default (CURRENT_TIMESTAMP(0) at time zone 'utc'),
        negative boolean NOT NULL,
        PRIMARY KEY(role_id, workspace, endpoint)
      );



      CREATE TABLE IF NOT EXISTS files(
        id uuid PRIMARY KEY,
        auth boolean NOT NULL,
        name text UNIQUE NOT NULL,
        type text NOT NULL,
        contents text,
        created_at timestamp without time zone default (CURRENT_TIMESTAMP(0) at time zone 'utc')
      );

      CREATE INDEX IF NOT EXISTS portal_files_name_idx on files(name);



      CREATE TABLE IF NOT EXISTS consumer_statuses (
        id               int PRIMARY KEY,
        name             text NOT NULL,
        comment          text,
        created_at       timestamp without time zone DEFAULT timezone('utc'::text, ('now'::text)::timestamp(0) with time zone)
      );

      CREATE TABLE IF NOT EXISTS consumer_types (
        id               int PRIMARY KEY,
        name             text NOT NULL,
        comment          text,
        created_at       timestamp without time zone DEFAULT timezone('utc'::text, ('now'::text)::timestamp(0) with time zone)
      );

      CREATE INDEX IF NOT EXISTS consumer_statuses_names_idx
          ON consumer_statuses (name);

      CREATE INDEX IF NOT EXISTS consumer_types_name_idx
          ON consumer_types (name);

      INSERT INTO consumer_types(id, name, comment)
      VALUES (0, 'proxy', 'Default consumer, used for proxy.'),
             (1, 'developer', 'Kong Developer Portal consumer.'),
             (2, 'admin', 'Admin consumer.')
      ON CONFLICT DO NOTHING;

      ALTER TABLE consumers
        ADD COLUMN type int NOT NULL DEFAULT 0,
        ADD COLUMN email text,
        ADD COLUMN status integer,
        ADD COLUMN meta text;

      ALTER TABLE consumers ADD CONSTRAINT consumers_email_type_key UNIQUE(email, type);

      CREATE INDEX IF NOT EXISTS consumers_type_idx
          ON consumers (type);

      CREATE INDEX IF NOT EXISTS consumers_status_idx
          ON consumers (status);



      CREATE TABLE IF NOT EXISTS credentials (
        id                uuid PRIMARY KEY,
        consumer_id       uuid REFERENCES consumers (id) ON DELETE CASCADE,
        consumer_type     integer,
        plugin            text NOT NULL,
        credential_data   json,
        created_at        timestamp without time zone DEFAULT timezone('utc'::text, ('now'::text)::timestamp(0) with time zone)
      );

      CREATE INDEX IF NOT EXISTS credentials_consumer_type
        ON credentials (consumer_id);

      CREATE INDEX IF NOT EXISTS credentials_consumer_id_plugin
        ON credentials (consumer_id, plugin);



      CREATE TABLE IF NOT EXISTS consumers_rbac_users_map(
        consumer_id uuid REFERENCES consumers (id) ON DELETE CASCADE,
        user_id uuid REFERENCES rbac_users (id) ON DELETE CASCADE,
        created_at timestamp without time zone DEFAULT timezone('utc'::text, ('now'::text)::timestamp(0) with time zone),
        PRIMARY KEY (consumer_id, user_id)
      );

      CREATE TABLE IF NOT EXISTS consumer_reset_secrets(
        id uuid PRIMARY KEY,
        consumer_id uuid REFERENCES consumers (id) ON DELETE CASCADE,
        secret text,
        status integer,
        client_addr text,
        created_at timestamp without time zone default (CURRENT_TIMESTAMP(0) at time zone 'utc'),
        updated_at timestamp without time zone default (CURRENT_TIMESTAMP(0) at time zone 'utc')
      );

      CREATE INDEX IF NOT EXISTS consumer_reset_secrets_consumer_id_idx
        ON consumer_reset_secrets(consumer_id);


      CREATE TABLE IF NOT EXISTS audit_objects(
        id uuid PRIMARY KEY,
        request_id char(32),
        entity_key uuid,
        dao_name text NOT NULL,
        operation char(6) NOT NULL,
        entity text,
        rbac_user_id uuid,
        signature text,
        expire timestamp without time zone
      );

      DO $$
      BEGIN
          IF (SELECT to_regclass('idx_audit_objects_expire')) IS NULL THEN
              CREATE INDEX idx_audit_objects_expire on audit_objects(expire);
          END IF;
      END$$;

      CREATE OR REPLACE FUNCTION delete_expired_audit_objects() RETURNS trigger
          LANGUAGE plpgsql
          AS $$
      BEGIN
          DELETE FROM audit_objects WHERE expire <= NOW();
          RETURN NEW;
      END;
      $$;

      DO $$
      BEGIN
          IF NOT EXISTS(
              SELECT FROM information_schema.triggers
               WHERE event_object_table = 'audit_objects'
                 AND trigger_name = 'deleted_expired_audit_objects_trigger')
          THEN
              CREATE TRIGGER delete_expired_audit_objects_trigger
               AFTER INSERT on audit_objects
               EXECUTE PROCEDURE delete_expired_audit_objects();
          END IF;
      END;
      $$;

      CREATE TABLE IF NOT EXISTS audit_requests(
        request_id char(32) PRIMARY KEY,
        request_timestamp timestamp without time zone default (CURRENT_TIMESTAMP(3) at time zone 'utc'),
        client_ip text NOT NULL,
        path text NOT NULL,
        method text NOT NULL,
        payload text,
        status integer NOT NULL,
        rbac_user_id uuid,
        workspace uuid,
        signature text,
        expire timestamp without time zone
      );

      DO $$
      BEGIN
          IF (SELECT to_regclass('idx_audit_requests_expire')) IS NULL THEN
              CREATE INDEX idx_audit_requests_expire on audit_requests(expire);
          END IF;
      END$$;

      CREATE OR REPLACE FUNCTION delete_expired_audit_requests() RETURNS trigger
          LANGUAGE plpgsql
          AS $$
      BEGIN
          DELETE FROM audit_requests WHERE expire <= NOW();
          RETURN NEW;
      END;
      $$;

      DO $$
      BEGIN
          IF NOT EXISTS(
              SELECT FROM information_schema.triggers
               WHERE event_object_table = 'audit_requests'
                 AND trigger_name = 'deleted_expired_audit_requests_trigger')
          THEN
              CREATE TRIGGER delete_expired_audit_requests_trigger
               AFTER INSERT on audit_requests
               EXECUTE PROCEDURE delete_expired_audit_requests();
          END IF;
      END;
      $$;

      CREATE TABLE IF NOT EXISTS developers (
        id          uuid,
        created_at  timestamp,
        updated_at  timestamp,
        email text,
        status int,
        meta text,
        consumer_id  uuid references consumers (id) on delete cascade,
        PRIMARY KEY(id)
      );
-- read-only role
DO $$
DECLARE lastid uuid;
DECLARE def_ws_id uuid;
BEGIN

SELECT uuid_in(overlay(overlay(md5(random()::text || ':' || clock_timestamp()::text) placing '4' from 13) placing to_hex(floor(random()*(11-8+1) + 8)::int)::text from 17)::cstring) into lastid;
SELECT id into def_ws_id from workspaces where name = 'default';

INSERT INTO rbac_roles(id, name, comment)
VALUES (lastid, 'default:read-only', 'Read access to all endpoints, across all workspaces');

INSERT INTO workspace_entities(workspace_id, workspace_name, entity_id, entity_type, unique_field_name, unique_field_value)
VALUES (def_ws_id, 'default', lastid, 'rbac_roles', 'name', 'read-only');

INSERT INTO workspace_entities(workspace_id, workspace_name, entity_id, entity_type, unique_field_name, unique_field_value)
VALUES (def_ws_id, 'default', lastid, 'rbac_roles', 'id', lastid);


INSERT INTO rbac_role_endpoints(role_id, workspace, endpoint, actions, negative)
VALUES (lastid, '*', '*', 1, FALSE);

END $$;


-- admin role
DO $$
DECLARE lastid uuid;
DECLARE def_ws_id uuid;
BEGIN

SELECT uuid_in(overlay(overlay(md5(random()::text || ':' || clock_timestamp()::text) placing '4' from 13) placing to_hex(floor(random()*(11-8+1) + 8)::int)::text from 17)::cstring) into lastid;
SELECT id into def_ws_id from workspaces where name = 'default';

INSERT INTO rbac_roles(id, name, comment)
VALUES (lastid, 'default:admin', 'Full access to all endpoints, across all workspaces—except RBAC Admin API');

INSERT INTO workspace_entities(workspace_id, workspace_name, entity_id, entity_type, unique_field_name, unique_field_value)
VALUES (def_ws_id, 'default', lastid, 'rbac_roles', 'name', 'admin');

INSERT INTO workspace_entities(workspace_id, workspace_name, entity_id, entity_type, unique_field_name, unique_field_value)
VALUES (def_ws_id, 'default', lastid, 'rbac_roles', 'id', lastid);


INSERT INTO rbac_role_endpoints(role_id, workspace, endpoint, actions, negative)
VALUES (lastid, '*', '*', 15, FALSE);

INSERT INTO rbac_role_endpoints(role_id, workspace, endpoint, actions, negative)
VALUES (lastid, '*', '/rbac/*', 15, TRUE);

INSERT INTO rbac_role_endpoints(role_id, workspace, endpoint, actions, negative)
VALUES (lastid, '*', '/rbac/*/*', 15, TRUE);

INSERT INTO rbac_role_endpoints(role_id, workspace, endpoint, actions, negative)
VALUES (lastid, '*', '/rbac/*/*/*', 15, TRUE);

INSERT INTO rbac_role_endpoints(role_id, workspace, endpoint, actions, negative)
VALUES (lastid, '*', '/rbac/*/*/*/*', 15, TRUE);

INSERT INTO rbac_role_endpoints(role_id, workspace, endpoint, actions, negative)
VALUES (lastid, '*', '/rbac/*/*/*/*/*', 15, TRUE);
END $$;

-- super-admin role
DO $$
DECLARE lastid uuid;
DECLARE def_ws_id uuid;
BEGIN

SELECT uuid_in(overlay(overlay(md5(random()::text || ':' || clock_timestamp()::text) placing '4' from 13) placing to_hex(floor(random()*(11-8+1) + 8)::int)::text from 17)::cstring) into lastid;
SELECT id into def_ws_id from workspaces where name = 'default';

INSERT INTO rbac_roles(id, name, comment)
VALUES (lastid, 'default:super-admin', 'Full access to all endpoints, across all workspaces');

INSERT INTO workspace_entities(workspace_id, workspace_name, entity_id, entity_type, unique_field_name, unique_field_value)
VALUES (def_ws_id, 'default', lastid, 'rbac_roles', 'name', 'super-admin');

INSERT INTO workspace_entities(workspace_id, workspace_name, entity_id, entity_type, unique_field_name, unique_field_value)
VALUES (def_ws_id, 'default', lastid, 'rbac_roles', 'id', lastid);


INSERT INTO rbac_role_endpoints(role_id, workspace, endpoint, actions, negative)
VALUES (lastid, '*', '*', 15, FALSE);
END $$;

CREATE TABLE IF NOT EXISTS admins (
  id          uuid,
  created_at  timestamp,
  updated_at  timestamp,
  consumer_id  uuid references consumers (id),
  rbac_user_id  uuid references rbac_users (id),
  email text,
  status int,
  username text unique,
  custom_id text unique,
  PRIMARY KEY(id)
);
    ]]
  },
  cassandra = {
    up = [[
      CREATE TABLE IF NOT EXISTS rl_counters(
        namespace    text,
        window_start timestamp,
        window_size  int,
        key          text,
        count        counter,
        PRIMARY KEY((namespace, window_start, window_size), key)
      );

      CREATE TABLE IF NOT EXISTS vitals_stats_seconds(
        node_id uuid,
        at timestamp,
        l2_hit int,
        l2_miss int,
        plat_min int,
        plat_max int,
        ulat_min int,
        ulat_max int,
        requests int,
        plat_count int,
        plat_total int,
        ulat_count int,
        ulat_total int,
        PRIMARY KEY(node_id, at)
      ) WITH CLUSTERING ORDER BY (at DESC);

      CREATE TABLE IF NOT EXISTS vitals_stats_minutes(
        node_id uuid,
        at timestamp,
        l2_hit int,
        l2_miss int,
        plat_min int,
        plat_max int,
        ulat_min int,
        ulat_max int,
        requests int,
        plat_count int,
        plat_total int,
        ulat_count int,
        ulat_total int,
        PRIMARY KEY(node_id, at)
      ) WITH CLUSTERING ORDER BY (at DESC);

      CREATE TABLE IF NOT EXISTS vitals_node_meta(
        node_id uuid PRIMARY KEY,
        first_report timestamp,
        last_report timestamp,
        hostname text
      );

      CREATE TABLE IF NOT EXISTS vitals_consumers(
        at          timestamp,
        duration    int,
        consumer_id uuid,
        node_id     uuid,
        count       counter,
        PRIMARY KEY((consumer_id, duration), at, node_id)
      );

      CREATE TABLE IF NOT EXISTS workspaces(
        id uuid PRIMARY KEY,
        name text,
        comment text,
        created_at timestamp,
        meta text,
        config text
      );

      CREATE INDEX IF NOT EXISTS ON workspaces(name);

      INSERT INTO workspaces(id, name)
      VALUES (00000000-0000-0000-0000-000000000000, 'default');

      CREATE TABLE IF NOT EXISTS workspace_entities(
        workspace_id uuid,
        workspace_name text,
        entity_id text,
        entity_type text,
        unique_field_name text,
        unique_field_value text,
        PRIMARY KEY(workspace_id, entity_id, unique_field_name)
      );

      CREATE INDEX IF NOT EXISTS ON workspace_entities(entity_type);
      CREATE INDEX IF NOT EXISTS ON workspace_entities(unique_field_value);

      CREATE TABLE IF NOT EXISTS rbac_users(
        id uuid PRIMARY KEY,
        name text,
        user_token text,
        user_token_ident text,
        comment text,
        enabled boolean,
        created_at timestamp
      );

      CREATE INDEX IF NOT EXISTS ON rbac_users(name);
      CREATE INDEX IF NOT EXISTS ON rbac_users(user_token);
      CREATE INDEX IF NOT EXISTS ON rbac_users(user_token_ident);

      CREATE TABLE IF NOT EXISTS rbac_user_roles(
        user_id uuid,
        role_id uuid,
        PRIMARY KEY(user_id, role_id)
      );

      CREATE TABLE IF NOT EXISTS rbac_roles(
        id uuid PRIMARY KEY,
        name text,
        comment text,
        created_at timestamp,
        is_default boolean
      );

      CREATE INDEX IF NOT EXISTS ON rbac_roles(name);
      CREATE INDEX IF NOT EXISTS rbac_role_default_idx on rbac_roles(is_default);

      CREATE TABLE IF NOT EXISTS rbac_role_entities(
        role_id uuid,
        entity_id text,
        entity_type text,
        actions int,
        negative boolean,
        comment text,
        created_at timestamp,
        PRIMARY KEY(role_id, entity_id)
      );

      CREATE TABLE IF NOT EXISTS rbac_role_endpoints(
        role_id uuid,
        workspace text,
        endpoint text,
        actions int,
        negative boolean,
        comment text,
        created_at timestamp,
        PRIMARY KEY(role_id, workspace, endpoint)
      );

      CREATE TABLE IF NOT EXISTS files(
        id uuid,
        auth boolean,
        name text,
        type text,
        contents text,
        created_at timestamp,
        PRIMARY KEY (id, name)
      );

      CREATE INDEX IF NOT EXISTS ON files(name);
      CREATE INDEX IF NOT EXISTS ON files(type);

      CREATE TABLE IF NOT EXISTS vitals_code_classes_by_cluster(
        at timestamp,
        duration int,
        code_class int,
        count counter,
        PRIMARY KEY((code_class, duration), at)
      );

      CREATE TABLE IF NOT EXISTS vitals_codes_by_service(
        service_id uuid,
        code int,
        at timestamp,
        duration int,
        count counter,
        PRIMARY KEY ((service_id, duration), at, code)
      );

      CREATE TABLE IF NOT EXISTS vitals_codes_by_route(
        route_id uuid,
        code int,
        at timestamp,
        duration int,
        count counter,
        PRIMARY KEY ((route_id, duration), at, code)
      );

      CREATE TABLE IF NOT EXISTS vitals_codes_by_consumer_route(
        consumer_id uuid,
        route_id uuid,
        service_id uuid,
        code int,
        at timestamp,
        duration int,
        count counter,
        PRIMARY KEY ((consumer_id, duration), at, code, route_id, service_id)
      );

      CREATE TABLE IF NOT EXISTS consumer_statuses (
        id               int PRIMARY KEY,
        name             text,
        comment          text,
        created_at       timestamp
      );

      CREATE TABLE IF NOT EXISTS consumer_types (
        id               int PRIMARY KEY,
        name             text,
        comment          text,
        created_at       timestamp
      );

      CREATE INDEX IF NOT EXISTS consumer_statuses_names_idx ON consumer_statuses(name);
      CREATE INDEX IF NOT EXISTS consumer_types_name_idx ON consumer_types(name);

      ALTER TABLE consumers ADD type int;
      ALTER TABLE consumers ADD email text;
      ALTER TABLE consumers ADD status int;
      ALTER TABLE consumers ADD meta text;

      CREATE INDEX IF NOT EXISTS consumers_type_idx ON consumers(type);
      CREATE INDEX IF NOT EXISTS consumers_status_idx ON consumers(status);

      CREATE TABLE IF NOT EXISTS credentials (
        id                 uuid PRIMARY KEY,
        consumer_id        uuid,
        consumer_type      int,
        plugin             text,
        credential_data    text,
        created_at         timestamp
      );

      CREATE INDEX IF NOT EXISTS credentials_consumer_id ON credentials(consumer_id);
      CREATE INDEX IF NOT EXISTS credentials_plugin ON credentials(plugin);

      CREATE TABLE IF NOT EXISTS consumers_rbac_users_map(
        consumer_id uuid,
        user_id     uuid,
        created_at  timestamp,
        PRIMARY KEY(consumer_id, user_id)
      );

      INSERT INTO consumer_types(id, name, comment, created_at)
      VALUES (2, 'admin', 'Admin consumer.', dateof(now()));

      CREATE INDEX IF NOT EXISTS ON rbac_role_entities(entity_type);

      CREATE TABLE IF NOT EXISTS consumer_reset_secrets(
        id uuid PRIMARY KEY,
        consumer_id uuid,
        secret text,
        status int,
        client_addr text,
        created_at timestamp,
        updated_at timestamp
      );

      CREATE INDEX IF NOT EXISTS consumer_reset_secrets_consumer_id_idx ON consumer_reset_secrets (consumer_id);

      CREATE TABLE IF NOT EXISTS vitals_code_classes_by_workspace(
        workspace_id uuid,
        at timestamp,
        duration int,
        code_class int,
        count counter,
        PRIMARY KEY((workspace_id, duration), at, code_class)
      );

      CREATE TABLE IF NOT EXISTS audit_requests(
        request_id text,
        request_timestamp timestamp,
        client_ip text,
        path text,
        method text,
        payload text,
        status int,
        rbac_user_id uuid,
        workspace uuid,
        signature text,
        expire timestamp,
        PRIMARY KEY (request_id)
      ) WITH default_time_to_live = 2592000
         AND comment = 'Kong Admin API request audit log';

      CREATE TABLE IF NOT EXISTS audit_objects(
        id uuid,
        request_id text,
        entity_key uuid,
        dao_name text,
        operation text,
        entity text,
        rbac_user_id uuid,
        signature text,
        PRIMARY KEY (id)
      ) WITH default_time_to_live = 2592000
         AND comment = 'Kong database object audit log';

      CREATE TABLE IF NOT EXISTS workspace_entity_counters(
        workspace_id uuid,
        entity_type text,
        count counter,
        PRIMARY KEY(workspace_id, entity_type)
      );
    ]]
    .. seed_rbac_data() ..
    [[
      CREATE TABLE IF NOT EXISTS admins (
        id          uuid,
        created_at  timestamp,
        updated_at  timestamp,
        consumer_id  uuid,
        rbac_user_id  uuid,
        email text,
        status int,
        username   text,
        custom_id  text,
        PRIMARY KEY(id)
      );
      CREATE INDEX IF NOT EXISTS admins_consumer_id_idx ON admins(consumer_id);
      CREATE INDEX IF NOT EXISTS admins_rbac_user_id_idx ON admins(rbac_user_id);
      CREATE INDEX IF NOT EXISTS admins_email_idx ON admins(email);
      CREATE INDEX IF NOT EXISTS admins_username_idx ON admins(username);
      CREATE INDEX IF NOT EXISTS admins_custom_id_idx ON admins(custom_id);

      CREATE TABLE IF NOT EXISTS developers (
        id          uuid,
        created_at  timestamp,
        updated_at  timestamp,
        consumer_id  uuid,
        email text,
        status int,
        meta text,
        PRIMARY KEY(id)
      );
      CREATE INDEX IF NOT EXISTS developers_consumer_id_idx ON developers(consumer_id);
    ]]
  },
}
