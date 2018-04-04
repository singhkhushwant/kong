local pg_strategy = require "kong.vitals.postgres.strategy"
local dao_factory = require "kong.dao.factory"
local dao_helpers = require "spec.02-integration.03-dao.helpers"
local utils       = require "kong.tools.utils"
local fmt         = string.format
local time        = ngx.time


dao_helpers.for_each_dao(function(kong_conf)
  if kong_conf.database == "cassandra" then
    return
  end


  describe("Postgres strategy", function()
    local strategy
    local dao
    local db
    local snapshot


    setup(function()
      local opts = {
        ttl_seconds = 3600,
        ttl_minutes = 90000,
      }

      dao = assert(dao_factory.new(kong_conf))
      dao:run_migrations()

      strategy = pg_strategy.new(dao, opts)

      db  = dao.db

      -- simulate a "previous" seconds table
      assert(db:query("create table if not exists vitals_stats_seconds_2 " ..
             "(like vitals_stats_seconds including defaults including constraints including indexes)"))
    end)


    before_each(function()
      snapshot = assert:snapshot()

      assert(db:query("truncate table vitals_stats_minutes"))
      assert(db:query("truncate table vitals_stats_seconds"))
      assert(db:query("truncate table vitals_stats_seconds_2"))
      assert(db:query("truncate table vitals_node_meta"))
      assert(db:query("truncate table vitals_consumers"))
      assert(db:query("truncate table vitals_code_classes_by_cluster"))
    end)


    after_each(function()
      snapshot:revert()
    end)


    describe(":init()", function()
      it("inserts node metadata", function()

        local node_id  = utils.uuid()
        local hostname = "testhostname"

        assert(strategy:init(node_id, hostname))

        local res, _ = db:query("select * from vitals_node_meta where node_id = '{" .. node_id .. "}'")

        assert.same(1, #res)
        assert.same("testhostname", res[1].hostname)
        assert.not_nil(res[1].first_report)
        assert.same(res[1].first_report, res[1].last_report)
      end)
    end)


    describe(":insert_stats()", function()
      it("turns Lua tables into Postgres rows", function()
        stub(strategy, "current_table_name").returns("vitals_stats_seconds")

        local data = {
          { 1505964713, 0, 0, nil, nil, nil, nil, 0, 0, 0, 0, 0 },
          { 1505964714, 19, 99, 0, 120, 12, 47, 7, 7, 294, 6, 193 },
        }

        local node_id = utils.uuid()

        assert(strategy:insert_stats(data, node_id))

        local res, _ = db:query("select * from vitals_stats_seconds")

        local expected = {
          {
            at       = 1505964713,
            node_id  = node_id,
            l2_hit   = 0,
            l2_miss  = 0,
            requests = 0,
            plat_count = 0,
            plat_total = 0,
            ulat_count = 0,
            ulat_total = 0,
          },
          {
            at       = 1505964714,
            node_id  = node_id,
            l2_hit   = 19,
            l2_miss  = 99,
            plat_min = 0,
            plat_max = 120,
            ulat_min = 12,
            ulat_max = 47,
            requests = 7,
            plat_count = 7,
            plat_total = 294,
            ulat_count = 6,
            ulat_total = 193,
          },
        }
        assert.same(expected, res)

        local res, _ = db:query("select * from vitals_stats_minutes")

        local expected = {
          {
            at       = 1505964660,
            node_id  = node_id,
            l2_hit   = 19,
            l2_miss  = 99,
            plat_min = 0,
            plat_max = 120,
            ulat_min = 12,
            ulat_max = 47,
            requests = 7,
            plat_count = 7,
            plat_total = 294,
            ulat_count = 6,
            ulat_total = 193,
          }
        }

        assert.same(expected, res)
      end)

      it("records the last_report time for this node", function()
        stub(strategy, "current_table_name").returns("vitals_stats_seconds")

        local data = {
          { 1505964713, 0, 0, nil, nil, nil, nil, 0, 0, 0, 0, 0 },
          { 1505964714, 19, 99, 0, 120, 12, 47, 7, 7, 294, 6, 193 },
        }

        local node_id = utils.uuid()

        strategy:init(node_id, "testhostname")

        local report_q = "select last_report from vitals_node_meta where node_id = '{" .. node_id .. "}'"

        local res, _   = db:query(report_q)
        local orig_rep = res[1].last_report

        assert(strategy:insert_stats(data))

        local res, _  = db:query(report_q)
        local new_rep = res[1].last_report

        assert.not_same(new_rep, orig_rep)
      end)
    end)


    describe(":select_stats()", function()
      local node_1 = "20426633-55dc-4050-89ef-2382c95a611e"
      local node_2 = "8374682f-17fd-42cb-b1dc-7694d6f65ba0"

      before_each(function()
        local q, query
        local at = 1509667484

        -- add some data we can query
        local test_data = {
          { "vitals_stats_seconds", at + 1, node_1, 4, 1, 1, 10, 3, 7, 2, 2, 33, 2, 12, },
          { "vitals_stats_seconds", at + 1, node_2, 6, 2, 1, 5, 4, 4, 4, 4, 10, 4, 13, },
          { "vitals_stats_seconds", at + 2, node_1, 5, 2, 2, 20, 4, 14, 3, 3, 34, 3, 28, },
          { "vitals_stats_seconds", at + 2, node_2, 7, 3, 2, 10, 5, 8, 5, 5, 40, 4, 19, },
          { "vitals_stats_seconds", at + 3, node_1, 19, 23, "null", "null", "null", "null", 14, 0, 0, 0, 0, },

          { "vitals_stats_minutes", at + 1, node_1, 11, 21, 0, 20, 1, 9, 7, 7, 42, 6, 34, },
          { "vitals_stats_minutes", at + 2, node_1, 12, 22, 0, 40, 2, 18, 8, 8, 78, 5, 90, },
          { "vitals_stats_minutes", at + 3, node_1, 19, 23,  "null", "null", "null", "null", 14, 0, 0, 0, 0, },
          { "vitals_stats_minutes", at + 1, node_2, 3, 8, 1, 6, 6, 8, 15, 15, 76, 15, 105, },
          { "vitals_stats_minutes", at + 2, node_2, 4, 9, 2, 12, 7, 16, 16, 15, 85, 16, 44, },

          { "vitals_stats_seconds_2", at - 60, node_1, 3, 5, 7, 9, 8, 12, 6, 6, 74, 6, 102, },
          { "vitals_stats_seconds_2", at - 60, node_2, 2, 4, 6, 8, 4, 16, 17, 17, 99, 17, 231, },
        }

        q = [[
            insert into %s(at, node_id, l2_hit, l2_miss, plat_min, plat_max,
              ulat_min, ulat_max, requests, plat_count, plat_total, ulat_count, ulat_total)
            values(%d, '{%s}', %d, %d, %s, %s, %s, %s, %d, %d, %d, %d, %d)
        ]]

        for _, v in ipairs(test_data) do
          query = fmt(q, unpack(v))
          assert(db:query(query))
        end
      end)

      it("returns seconds stats for a node", function()
        stub(strategy, "table_names_for_select").returns({ "vitals_stats_seconds", "vitals_stats_seconds_2"})

        local res, err = strategy:select_stats("seconds", "node", node_1)

        assert.is_nil(err)

        local expected = {
          {
            node_id = node_1,
            at = 1509667424,
            l2_hit = 3,
            l2_miss = 5,
            plat_min = 7,
            plat_max = 9,
            ulat_min = 8,
            ulat_max = 12,
            requests = 6,
            plat_count = 6,
            plat_total = 74,
            ulat_count = 6,
            ulat_total = 102,
          }, {
            node_id = node_1,
            at = 1509667485,
            l2_hit = 4,
            l2_miss = 1,
            plat_min = 1,
            plat_max = 10,
            ulat_min = 3,
            ulat_max = 7,
            requests = 2,
            plat_count = 2,
            plat_total = 33,
            ulat_count = 2,
            ulat_total = 12,
          }, {
            node_id = node_1,
            at = 1509667486,
            l2_hit = 5,
            l2_miss = 2,
            plat_min = 2,
            plat_max = 20,
            ulat_min = 4,
            ulat_max = 14,
            requests = 3,
            plat_count = 3,
            plat_total = 34,
            ulat_count = 3,
            ulat_total = 28,
          }, {
            node_id = node_1,
            at = 1509667487,
            l2_hit = 19,
            l2_miss = 23,
            requests = 14,
            plat_count = 0,
            plat_total = 0,
            ulat_count = 0,
            ulat_total = 0,
          }
        }

        assert.same(expected, res)
      end)

      it("returns minutes stats for a node", function()
        local res, err = strategy:select_stats("minutes", "node", node_1)

        assert.is_nil(err)

        local expected = {
          {
            node_id = node_1,
            at = 1509667485,
            l2_hit = 11,
            l2_miss = 21,
            plat_min = 0,
            plat_max = 20,
            ulat_min = 1,
            ulat_max = 9,
            requests = 7,
            plat_count = 7,
            plat_total = 42,
            ulat_count = 6,
            ulat_total = 34,
          }, {
            node_id = node_1,
            at = 1509667486,
            l2_hit = 12,
            l2_miss = 22,
            plat_min = 0,
            plat_max = 40,
            ulat_min = 2,
            ulat_max = 18,
            requests = 8,
            plat_count = 8,
            plat_total = 78,
            ulat_count = 5,
            ulat_total = 90,
          }, {
            node_id = node_1,
            at = 1509667487,
            l2_hit = 19,
            l2_miss = 23,
            requests = 14,
            plat_count = 0,
            plat_total = 0,
            ulat_count = 0,
            ulat_total = 0,
          }
        }

        assert.same(expected, res)
      end)

      it("returns seconds stats for all nodes", function()
        stub(strategy, "table_names_for_select").returns({ "vitals_stats_seconds", "vitals_stats_seconds_2"})

        local res, err = strategy:select_stats("seconds", "node")

        -- we can't guarantee the sort order coming out since we can't sort
        -- by uuid. just assert we haven't left out any rows.
        assert.is_nil(err)
        assert.equals(7, #res)
      end)

      it("returns minutes stats for all nodes", function()
        local res, err = strategy:select_stats("minutes", "node")

        assert.is_nil(err)

        local expected = {
          {
            node_id = node_1,
            at = 1509667485,
            l2_hit = 11,
            l2_miss = 21,
            plat_min = 0,
            plat_max = 20,
            ulat_min = 1,
            ulat_max = 9,
            requests = 7,
            plat_count = 7,
            plat_total = 42,
            ulat_count = 6,
            ulat_total = 34,
          }, {
            node_id = node_2,
            at = 1509667485,
            l2_hit = 3,
            l2_miss = 8,
            plat_min = 1,
            plat_max = 6,
            ulat_min = 6,
            ulat_max = 8,
            requests = 15,
            plat_count = 15,
            plat_total = 76,
            ulat_count = 15,
            ulat_total = 105,
          }, {
            node_id = node_1,
            at = 1509667486,
            l2_hit = 12,
            l2_miss = 22,
            plat_min = 0,
            plat_max = 40,
            ulat_min = 2,
            ulat_max = 18,
            requests = 8,
            plat_count = 8,
            plat_total = 78,
            ulat_count = 5,
            ulat_total = 90,
          },  {
            node_id = node_2,
            at = 1509667486,
            l2_hit = 4,
            l2_miss = 9,
            plat_min = 2,
            plat_max = 12,
            ulat_min = 7,
            ulat_max = 16,
            requests = 16,
            plat_count = 15,
            plat_total = 85,
            ulat_count = 16,
            ulat_total = 44,
          }, {
            node_id = node_1,
            at = 1509667487,
            l2_hit = 19,
            l2_miss = 23,
            requests = 14,
            plat_count = 0,
            plat_total = 0,
            ulat_count = 0,
            ulat_total = 0,
          }
        }

        assert.same(expected, res)
      end)

      it("returns seconds stats for a cluster", function()
        stub(strategy, "table_names_for_select").returns({ "vitals_stats_seconds", "vitals_stats_seconds_2"})

        local res, err = strategy:select_stats("seconds", "cluster")

        assert.is_nil(err)

        local expected = {
          {
            at = 1509667424,
            node_id = 'cluster',
            l2_hit = 5,
            l2_miss = 9,
            plat_min = 6,
            plat_max = 9,
            ulat_min = 4,
            ulat_max = 16,
            requests = 23,
            plat_count = 23,
            plat_total = 173,
            ulat_count = 23,
            ulat_total = 333,
          }, {
            at = 1509667485,
            node_id = 'cluster',
            l2_hit = 10,
            l2_miss = 3,
            plat_min = 1,
            plat_max = 10,
            ulat_min = 3,
            ulat_max = 7,
            requests = 6,
            plat_count = 6,
            plat_total = 43,
            ulat_count = 6,
            ulat_total = 25,
          }, {
            at = 1509667486,
            node_id = 'cluster',
            l2_hit = 12,
            l2_miss = 5,
            plat_min = 2,
            plat_max = 20,
            ulat_min = 4,
            ulat_max = 14,
            requests = 8,
            plat_count = 8,
            plat_total = 74,
            ulat_count = 7,
            ulat_total = 47,
          }, {
            at = 1509667487,
            node_id = 'cluster',
            l2_hit = 19,
            l2_miss = 23,
            requests = 14,
            plat_count = 0,
            plat_total = 0,
            ulat_count = 0,
            ulat_total = 0,
          }
        }

        assert.same(expected, res)
      end)

      it("returns minutes stats for a cluster", function()
        local res, err = strategy:select_stats("minutes", "cluster")

        assert.is_nil(err)

        local expected = {
          {
            at = 1509667485,
            node_id = 'cluster',
            l2_hit = 14,
            l2_miss = 29,
            plat_max = 20,
            plat_min = 0,
            ulat_min = 1,
            ulat_max = 9,
            requests = 22,
            plat_count = 22,
            plat_total = 118,
            ulat_count = 21,
            ulat_total = 139,
          }, {
            at = 1509667486,
            node_id = 'cluster',
            l2_hit = 16,
            l2_miss = 31,
            plat_max = 40,
            plat_min = 0,
            ulat_min = 2,
            ulat_max = 18,
            requests = 24,
            plat_count = 23,
            plat_total = 163,
            ulat_count = 21,
            ulat_total = 134,
          }, {
            at = 1509667487,
            node_id = 'cluster',
            l2_hit = 19,
            l2_miss = 23,
            requests = 14,
            plat_count = 0,
            plat_total = 0,
            ulat_count = 0,
            ulat_total = 0,
          }
        }

        assert.same(expected, res)
      end)

      it("takes an optional timestamp range", function()
        stub(strategy, "table_names_for_select").returns({ "vitals_stats_seconds", "vitals_stats_seconds_2"})

        local res, err = strategy:select_stats("seconds", "cluster", nil, 1509667485, 1509667487)

        assert.is_nil(err)

        local expected = {
          {
            at = 1509667485,
            node_id = 'cluster',
            l2_hit = 10,
            l2_miss = 3,
            plat_min = 1,
            plat_max = 10,
            ulat_min = 3,
            ulat_max = 7,
            requests = 6,
            plat_count = 6,
            plat_total = 43,
            ulat_count = 6,
            ulat_total = 25,
          }, {
            at = 1509667486,
            node_id = 'cluster',
            l2_hit = 12,
            l2_miss = 5,
            plat_min = 2,
            plat_max = 20,
            ulat_min = 4,
            ulat_max = 14,
            requests = 8,
            plat_count = 8,
            plat_total = 74,
            ulat_count = 7,
            ulat_total = 47,
          }
        }

        assert.same(expected, res)
      end)
    end)

    describe(":select_phone_home", function()
      -- data starts 10 minutes ago
      local minute_start_at = time() - ( time() % 60 ) - 600
      local node_1 = strategy.node_id
      local node_2 = "8374682f-17fd-42cb-b1dc-7694d6f65ba0"

      before_each(function()
        -- node_1 data spanning three minutes
        local test_data_1 = {
          { minute_start_at, 0, 0, nil, nil, nil, nil, 0, 0, 0, 0, 0, },
          { minute_start_at + 61, 0, 3, 0, 11, 193, 212, 1, 11, 1, 11, 212, },
          { minute_start_at + 122, 3, 4, 1, 8, 60, 9182, 4, 4, 8, 4, 10000 },
        }

        -- node_2 data spanning two minutes
        local test_data_2 = {
          { minute_start_at + 61, 1, 5, 0, 99, 25, 144, 9, 9, 300, 8, 350, },
          { minute_start_at + 180, 1, 7, 0, 0, 13, 19, 8, 8, 0, 8, 97, },
        }

        assert(strategy:insert_stats(test_data_1, node_1))
        assert(strategy:insert_stats(test_data_2, node_2))

      end)

      it("returns stats for phone home", function()
        local res, err = strategy:select_phone_home()

        assert.is_nil(err)

        local expected = {{}}
        expected[1]["v.cdht"] = 3
        expected[1]["v.cdmt"] = 7
        expected[1]["v.lprn"] = 0
        expected[1]["v.lprx"] = 11
        expected[1]["v.lun"] = 60
        expected[1]["v.lux"] = 9182
        expected[1]["v.nt"] = 2
        expected[1]["v.lpra"] = 1
        expected[1]["v.lua"] = 681

        assert.same(expected, res)
      end)
    end)

    describe(":delete_stats()", function()
      it("validates arguments", function()
        local res, err = strategy:delete_stats()
        assert.is_nil(res)
        assert.same(err, "cutoff_times is required")

        res, err = strategy:delete_stats({})
        assert.is_nil(res)
        assert.same(err, "cutoff_times.minutes must be a number")

        res, err = strategy:delete_stats({ cutoff_times = "foo" })
        assert.is_nil(res)
        assert.same(err, "cutoff_times.minutes must be a number")
      end)

      it("deletes stale data", function()
        local node_id = utils.uuid()
        local now = time()

        local data_to_insert = {
          {now - 4000, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, },
          {now, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, },
        }

        strategy:insert_stats(data_to_insert, node_id)

        -- remove everything older than one hour
        local res, err = strategy:delete_stats({ minutes = 3600 })

        assert.same(1, res)
        assert.is_nil(err)
      end)
    end)


    describe(":insert_consumer_stats()", function()
      it("turns Lua tables into Postgres rows", function()
        local node_id = utils.uuid()
        local con1_id = utils.uuid()
        local con2_id = utils.uuid()

        strategy:init(node_id, "testhostname")

        local data_to_insert = {
          {con1_id, 1510560000, 1, 1},
          {con1_id, 1510560001, 1, 3},
          {con2_id, 1510560001, 1, 2},
        }

        assert(strategy:insert_consumer_stats(data_to_insert))

        -- force a sort order to make assertion easier
        local q = [[
            select consumer_id, node_id, extract('epoch' from at) as at,
                   duration, count from vitals_consumers
            order by at, duration, count
        ]]

        local results = db:query(q)

        local expected = {
          {
            consumer_id = con1_id,
            node_id     = node_id,
            at          = 1510560000,
            duration    = 1,
            count       = 1,
          },
          {
            consumer_id = con2_id,
            node_id     = node_id,
            at           = 1510560000,
            duration    = 60,
            count       = 2,
          },
          {
            consumer_id = con1_id,
            node_id     = node_id,
            at          = 1510560000,
            duration    = 60,
            count       = 4,
          },
          {
            consumer_id = con2_id,
            node_id     = node_id,
            at          = 1510560001,
            duration    = 1,
            count       = 2,
          },
          {
            consumer_id = con1_id,
            node_id     = node_id,
            at           = 1510560001,
            duration    = 1,
            count       = 3,
          },
        }

        assert.same(expected, results)
      end)


      it("upserts when necessary", function()
        local node_id = utils.uuid()
        local con1_id = utils.uuid()

        strategy:init(node_id, "testhostname")

        -- insert a row to upsert on
        assert(strategy:insert_consumer_stats({{ con1_id, 1510560001, 1, 1 }}))


        local data_to_insert = {
          {con1_id, 1510560003, 1, 19},
        }

        assert(strategy:insert_consumer_stats(data_to_insert))

        local q = [[
            select consumer_id, node_id, extract('epoch' from at) as at,
                   duration, count from vitals_consumers where duration = 60
        ]]

        local results = db:query(q)

        local expected = {
          {
            consumer_id = con1_id,
            node_id     = node_id,
            at          = 1510560000,
            duration    = 60,
            count       = 20,
          },
        }

        assert.same(expected, results)
      end)
    end)


    describe(":select_consumer_stats()", function()
      local node_1  = "20426633-55dc-4050-89ef-2382c95a611e"
      local node_2  = "8374682f-17fd-42cb-b1dc-7694d6f65ba0"
      local cons_id = utils.uuid()

      before_each(function()
        local q, query

        q = "insert into vitals_consumers(consumer_id, node_id, at, duration, count) " ..
            "values('%s', '%s', to_timestamp(%d), %d, %d)"

        local data_to_insert = {
          {cons_id, node_1, 1510560000, 1, 1},
          {cons_id, node_1, 1510560001, 1, 3},
          {cons_id, node_1, 1510560002, 1, 4},
          {cons_id, node_1, 1510560000, 60, 19},
          {cons_id, node_2, 1510560001, 1, 5},
          {cons_id, node_2, 1510560002, 1, 7},
          {cons_id, node_2, 1510560000, 60, 20},
          {cons_id, node_2, 1510560060, 60, 24},
        }

        for _, row in ipairs(data_to_insert) do
          query = fmt(q, unpack(row))
          assert(db:query(query))
        end

        strategy:init(node_1, "testhostname")
      end)


      it("returns seconds stats for a consumer across the cluster", function()
        local opts = {
          consumer_id = cons_id,
          node_id     = nil,
          duration    = 1,
          level       = "cluster",
        }

        local results, _ = strategy:select_consumer_stats(opts)

        local expected = {
          {
            node_id     = "cluster",
            at          = 1510560000,
            count       = 1,
          },
          {
            node_id     = "cluster",
            at          = 1510560001,
            count       = 8,
          },
          {
            node_id     = "cluster",
            at          = 1510560002,
            count       = 11,
          },
        }

        assert.same(expected, results)
      end)


      it("returns seconds stats for a consumer and all nodes", function()
        local opts = {
          consumer_id = cons_id,
          node_id     = nil,
          duration    = 1,
          level       = "node",
        }

        local results, _ = strategy:select_consumer_stats(opts)

        assert.same(5, #results)

        -- just to make it easier to assert
        table.sort(results, function(a,b)
          return a.count < b.count
        end)

        local expected = {
          {
            count = 1,
            node_id = node_1,
            at = 1510560000,
          },
          {
            count = 3,
            node_id = node_1,
            at = 1510560001,
          },
          {
            count = 4,
            node_id = node_1,
            at = 1510560002,
          },
          {
            count = 5,
            node_id = node_2,
            at = 1510560001,
          },
          {
            count = 7,
            node_id = node_2,
            at = 1510560002,
          },
        }

        assert.same(expected, results)
      end)


      it("returns seconds stats for a consumer and a node", function()
        local opts = {
          consumer_id = cons_id,
          node_id     = node_2,
          duration    = 1,
          level       = "node",
        }

        local results, _ = strategy:select_consumer_stats(opts)

        local expected = {
          {
            count = 5,
            node_id = node_2,
            at = 1510560001,
          },
          {
            count = 7,
            node_id = node_2,
            at = 1510560002,
          },
        }

        assert.same(expected, results)
      end)


      it("returns minutes stats for a consumer across the cluster", function()
        local opts = {
          consumer_id = cons_id,
          node_id     = nil,
          duration    = 60,
          level       = "cluster",
        }

        local results, _ = strategy:select_consumer_stats(opts)

        local expected = {
          {
            node_id     = "cluster",
            at          = 1510560000,
            count       = 39,
          },
          {
            node_id     = "cluster",
            at          = 1510560060,
            count       = 24,
          },
        }
        assert.same(expected, results)
      end)


      it("returns minutes stats for a consumer and all nodes", function()
        local opts = {
          consumer_id = cons_id,
          node_id     = nil,
          duration    = 60,
          level       = "node",
        }

        local results, _ = strategy:select_consumer_stats(opts)

        assert.same(3, #results)

        table.sort(results, function(a,b)
          return a.count < b.count
        end)


        local expected = {
          {
            count = 19,
            node_id = node_1,
            at = 1510560000,
          },
          {
            count = 20,
            node_id = node_2,
            at = 1510560000,
          },
          {
            count = 24,
            node_id = node_2,
            at = 1510560060,
          },
        }

        assert.same(expected, results)
      end)


      it("returns minutes stats for a consumer and a node", function()
        local opts = {
          consumer_id = cons_id,
          node_id     = node_2,
          duration    = 60,
          level       = "node",
        }

        local results, _ = strategy:select_consumer_stats(opts)

        local expected = {
          {
            count = 20,
            node_id = node_2,
            at = 1510560000,
          },
          {
            count = 24,
            node_id = node_2,
            at = 1510560060,
          },
        }

        assert.same(expected, results)
      end)
    end)


    describe(":delete_consumer_stats()", function()
      local cons_1 = "20426633-55dc-4050-89ef-2382c95a611e"
      local cons_2 = "8374682f-17fd-42cb-b1dc-7694d6f65ba0"
      local node_1 = utils.uuid()

      before_each(function()
        local q, query

        q = "insert into vitals_consumers(consumer_id, node_id, at, duration, count) " ..
            "values('%s', '%s', to_timestamp(%d), %d, %d)"

        local test_data = {
          {cons_1, node_1, 1510560000, 1, 1},
          {cons_1, node_1, 1510560001, 1, 3},
          {cons_1, node_1, 1510560002, 1, 4},
          {cons_1, node_1, 1510560000, 60, 19},
          {cons_2, node_1, 1510560001, 1, 5},
          {cons_2, node_1, 1510560002, 1, 7},
          {cons_2, node_1, 1510560000, 60, 20},
          {cons_2, node_1, 1510560060, 60, 24},
        }

        for _, row in ipairs(test_data) do
          query = fmt(q, unpack(row))
          assert(db:query(query))
        end

        strategy:init(node_1, "testhostname")
      end)


      it("cleans up consumer stats", function()
        local consumers = {
          [cons_1] = true,
          [cons_2] = true,
        }

        -- query is "<" so bump the cutoff by a second
        local cutoff_times = {
          minutes = 1510560001,
          seconds = 1510560002,
        }

        local results, _ = strategy:delete_consumer_stats(consumers, cutoff_times)

        assert.same(5, results)
      end)
    end)


    describe(":insert_status_code_classes", function()
      it("turns Lua tables into Postgres rows", function()
        local uuid = utils.uuid()

        assert(strategy:init(uuid, "testhostname"))

        local now = ngx.time()
        local minute = now - (now % 60)

        local data = {
          { 1, now, 1, 4 },
          { 2, now, 1, 1 },
          { 2, now - 1, 1, 2 },
          { 2, minute, 60, 3 },
        }

        assert(strategy:insert_status_code_classes(data))

        -- force a sort order to make assertion easier
        local q = [[
          select code_class, extract('epoch' from at) as at,
            duration, count from vitals_code_classes_by_cluster
              order by at, duration, count
        ]]

        local results = db:query(q)

        local expected = {
          {
            at         = minute,
            code_class = 2,
            count      = 3,
            duration   = 60,
          },
          {
            at         = now - 1,
            code_class = 2,
            count      = 2,
            duration   = 1,
          },
          {
            at         = now,
            code_class = 2,
            count      = 1,
            duration   = 1,
          },
          {
            at         = now,
            code_class = 1,
            count      = 4,
            duration   = 1,
          },
        }

        assert.same(expected, results)
      end)
    end)

    describe(":select_status_code_classes", function()
      -- data starts a couple minutes ago
      local start_at = time() - 90
      local start_minute = start_at - (start_at % 60)

      before_each(function()
        local test_data = {
          {4, start_at,      1, 1},
          {4, start_at + 1,  1, 3},
          {4, start_minute, 60, 4},
          {4, start_at + 60, 1, 7},
          {4, start_minute + 60, 60, 7},
          {5, start_at + 2,  1, 2},
          {5, start_minute, 60, 2},
          {5, start_at + 60, 1, 5},
          {5, start_at + 61, 1, 6},
          {5, start_at + 62, 1, 8},
          {5, start_minute + 60, 60, 19},
        }

        local q, query

        q = "insert into vitals_code_classes_by_cluster(code_class, at, duration, count) " ..
          "values('%s', to_timestamp(%d), %d, %d)"

        for _, row in ipairs(test_data) do
          query = fmt(q, unpack(row))
          assert(db:query(query))
        end
      end)

      after_each(function()
        db:query("TRUNCATE vitals_code_classes_by_cluster")
      end)

      it("returns seconds counts across the cluster", function()
        local opts = {
          duration = 1,
        }

        local results, err = strategy:select_status_code_classes(opts)
        assert.is_nil(err)

        local expected = {
          {
            node_id     = "cluster",
            code_class  = 4,
            at          = start_at,
            count       = 1,
          },
          {
            node_id     = "cluster",
            code_class  = 5,
            at          = start_at + 2,
            count       = 2,
          },
          {
            node_id     = "cluster",
            code_class  = 4,
            at          = start_at + 1,
            count       = 3,
          },
          {
            node_id     = "cluster",
            code_class  = 5,
            at          = start_at + 60,
            count       = 5,
          },
          {
            node_id     = "cluster",
            code_class  = 5,
            at          = start_at + 61,
            count       = 6,
          },
          {
            node_id     = "cluster",
            code_class  = 4,
            at          = start_at + 60,
            count       = 7,
          },
          {
            node_id     = "cluster",
            code_class  = 5,
            at          = start_at + 62,
            count       = 8,
          },
        }

        table.sort(results, function(a,b)
          return a.count < b.count
        end)

        assert.same(expected, results)
      end)


      it("returns minutes counts across the cluster", function()
        local opts = {
          duration    = 60,
          level       = "cluster",
        }

        local results, _ = strategy:select_status_code_classes(opts)

        local expected = {
          {
            node_id     = "cluster",
            code_class  = 5,
            at          = start_minute,
            count       = 2,
          },
          {
            node_id     = "cluster",
            code_class  = 4,
            at          = start_minute,
            count       = 4,
          },
          {
            node_id     = "cluster",
            code_class  = 4,
            at          = start_minute + 60,
            count       = 7,
          },
          {
            node_id     = "cluster",
            code_class  = 5,
            at          = start_minute + 60,
            count       = 19,
          },
        }

        table.sort(results, function(a,b)
          return a.count < b.count
        end)

        assert.same(expected, results)
      end)
    end)


    describe(":delete_status_code_classes", function()
      it("cleans up status code classes", function()
        local q, query

        q = "insert into vitals_code_classes_by_cluster(code_class, at, duration, count) " ..
            "values('%s', to_timestamp(%d), %d, %d)"

        local test_data = {
          {4, 1510560000, 1, 1},
          {4, 1510560001, 1, 3},
          {4, 1510560002, 1, 4},
          {4, 1510560000, 60, 19},
          {5, 1510560001, 1, 5},
          {5, 1510560002, 1, 7},
          {5, 1510560000, 60, 20},
          {5, 1510560060, 60, 24},
        }

        for _, row in ipairs(test_data) do
          query = fmt(q, unpack(row))
          assert(db:query(query))
        end

        local cutoff_times = {
          minutes = 1510560001,
          seconds = 1510560002,
        }

        local res, err = strategy:delete_status_code_classes(cutoff_times)

        assert.is_nil(err)
        assert.same(5, res)
      end)

      it("validates cutoff_times", function()
        local _, err = strategy:delete_status_code_classes("foo")
        assert.same("cutoff_times must be a table", err)

        _, err = strategy:delete_status_code_classes({ seconds = "foo" })
        assert.same("cutoff seconds must be a number", err)

        _, err = strategy:delete_status_code_classes({ seconds = 999 })
        assert.same("cutoff minutes must be a number", err)
      end)

      it("returns an error message when it fails", function()
        stub(strategy.db, "query").returns(nil, "failure!")

        local cutoff_times = {
          minutes = 1510560001,
          seconds = 1510560002,
        }

        local _, err = strategy:delete_status_code_classes(cutoff_times)

        assert.same("failed to delete code_classes. err: failure!", err)
      end)
    end)


    describe(":insert_status_codes_by_service", function()
      it("turns Lua tables into Postgres rows", function()
        local uuid = utils.uuid()

        local now    = ngx.time()
        local minute = now - (now % 60)

        local data = {
          { uuid, 404, now, 1, 4 },
          { uuid, 404, now - 1, 1, 2 },
          { uuid, 500, minute, 60, 5 },
        }

        assert(strategy:insert_status_codes_by_service(data))

        -- force a sort order to make assertion easier
        local q = [[
          select service_id, code, extract('epoch' from at) as at,
            duration, count from vitals_codes_by_service
              order by count
        ]]

        local results = db:query(q)

        local expected = {
          {
            at         = now - 1,
            code       = 404,
            count      = 2,
            duration   = 1,
            service_id = uuid,
          },
          {
            at         = now,
            code       = 404,
            count      = 4,
            duration   = 1,
            service_id = uuid,
          },
          {
            at         = minute,
            code       = 500,
            count      = 5,
            duration   = 60,
            service_id = uuid,
          },
        }

        assert.same(expected, results)
      end)
    end)


    describe(":select_status_codes_by_service", function()
      local uuid   = utils.uuid()
      local uuid_2 = utils.uuid()

      assert(strategy:init(uuid, "testhostname"))

      local now    = time()
      local minute = now - (now % 60)

      before_each(function()
        db:query("TRUNCATE vitals_codes_by_service")

        local data = {
          [{ uuid, 404, now, 1 }]       = 4,
          [{ uuid_2, 404, now, 1 }]     = 6,
          [{ uuid, 404, now - 1, 1 }]   = 2,
          [{ uuid, 500, minute, 60 }]   = 3,
          [{ uuid_2, 500, minute, 60 }] = 5,
        }

        local q, query, service_id, code, at, duration

        q = "insert into vitals_codes_by_service(service_id, code, at, duration, count) " ..
          "values('%s', '%s', to_timestamp(%d), %d, %d)"

        for k,count in pairs(data) do
          service_id, code, at, duration = unpack(k)

          query = fmt(q, service_id, code, at, duration, count)
          assert(db:query(query))
        end
      end)

      it("returns seconds counts by service", function()
        local opts = {
          duration   = 1,
          service_id = uuid,
        }

        local results, err = strategy:select_status_codes_by_service(opts)
        assert.is_nil(err)

        local expected = {
          {
            at         = now - 1,
            code       = 404,
            count      = 2,
            service_id = uuid,
          },
          {
            at         = now,
            code       = 404,
            count      = 4,
            service_id = uuid,
          },
        }

        table.sort(results, function(a,b)
          return a.count < b.count
        end)

        assert.same(expected, results)
      end)


      it("returns minutes counts by service", function()
        local opts = {
          duration   = 60,
          service_id = uuid_2,
        }

        local results, _ = strategy:select_status_codes_by_service(opts)

        local expected = {
          {
            at         = minute,
            code       = 500,
            count      = 5,
            service_id = uuid_2,
          },
        }

        table.sort(results, function(a,b)
          return a.count < b.count
        end)

        assert.same(expected, results)
      end)
    end)


    describe(":delete_status_codes", function()
      local uuid   = utils.uuid()
      local uuid_2 = utils.uuid()

      before_each(function()
        db:query("TRUNCATE vitals_codes_by_service")
      end)

      it("cleans up status codes", function()
        db:query("TRUNCATE vitals_codes_by_service")

        local data = {
          [{ uuid, 404, 1510560000, 1 }]    = 1,
          [{ uuid_2, 404, 1510560001, 1 }]  = 5,
          [{ uuid, 404, 1510560002, 1 }]    = 4,
          [{ uuid, 404, 1510560000, 60 }]   = 19,
          [{ uuid_2, 404, 1510560000, 60 }] = 14,
          [{ uuid, 500, 1510560001, 1 }]    = 5,
          [{ uuid_2, 500, 1510560002, 1 }]  = 8,
          [{ uuid, 500, 1510560000, 60 }]   = 20,
          [{ uuid, 500, 1510560060, 60 }]   = 24,
        }

        local q, query, service_id, code, at, duration

        q = "insert into vitals_codes_by_service(service_id, code, at, duration, count) " ..
          "values('%s', '%s', to_timestamp(%d), %d, %d)"

        for k,count in pairs(data) do
          service_id, code, at, duration = unpack(k)

          query = fmt(q, service_id, code, at, duration, count)
          assert(db:query(query))
        end

        local cutoff_times = {
          minutes = 1510560001,
          seconds = 1510560002,
        }

        local res, err = strategy:delete_status_codes(cutoff_times)

        assert.is_nil(err)
        assert.same(6, res)
      end)

      it("validates cutoff_times", function()
        local _, err = strategy:delete_status_codes("foo")
        assert.same("cutoff_times must be a table", err)

        _, err = strategy:delete_status_codes({ seconds = "foo" })
        assert.same("cutoff seconds must be a number", err)

        _, err = strategy:delete_status_codes({ seconds = 999 })
        assert.same("cutoff minutes must be a number", err)
      end)

      it("returns an error message when it fails", function()
        stub(strategy.db, "query").returns(nil, "failure!")

        local cutoff_times = {
          minutes = 1510560001,
          seconds = 1510560002,
        }

        local _, err = strategy:delete_status_codes(cutoff_times)

        assert.same("failed to delete codes. err: failure!", err)
      end)
    end)


    describe(":select_node_meta()", function()
      local node_id  = utils.uuid()
      local hostname = "testhostname"

      local node_id_2  = utils.uuid()
      local hostname_2 = "testhostname-2"

      after_each(function()
        assert(dao.db:query("truncate table vitals_node_meta"))
      end)

      it("retrieves node_id and hostname for a list of nodes", function()
        local data_to_insert = {
          { node_id, hostname },
          { node_id_2, hostname_2 },
        }

        local q = "insert into vitals_node_meta(node_id, hostname) " ..
                  "values('%s', '%s')"

        for _, row in ipairs(data_to_insert) do
          local query = fmt(q, unpack(row))
          assert(dao.db:query(query))
        end

        local node_ids = { node_id, node_id_2 }

        local expected = {
          {
            hostname = hostname,
            node_id = node_id
          },
          {
            hostname = hostname_2,
            node_id = node_id_2
          }
        }

        local res, _ = strategy:select_node_meta(node_ids)

        assert.same(expected, res)
      end)

      it("returns an empty table when no node ids are passed in", function()
        local res, _ = strategy:select_node_meta({})

        assert.same({}, res)
      end)
    end)
  end)
end)
