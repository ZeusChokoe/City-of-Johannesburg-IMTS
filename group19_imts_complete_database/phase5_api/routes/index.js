// routes/index.js Group 19 IMTS (full)
const { Router } = require("express");
const { body, param, query } = require("express-validator");
const { handleValidation } = require("../middleware");
const requestCtrl  = require("../controllers/requestController");
const { getDetailedStatus } = require("../controllers/statusController");
const dbMgr        = require("../controllers/dbManagerController");
const { mysql_db, mongo_db, neo4j_db } = require("../config/db");
const router = Router();

// ── Health ────────────────────────────────────────────────────
router.get("/health", (req, res) => {
  res.json({ success: true, service: "Group 19 IMTS API", version: process.env.API_VERSION || "v1", uptime_s: Math.floor(process.uptime()), timestamp: new Date().toISOString() });
});
router.get("/health/deep", async (req, res) => {
  const r = {}; let ok = true;
  for (const [n, fn] of [
    ["mysql",   async () => { await mysql_db.getPool().execute("SELECT 1"); return true; }],
    ["mongodb", async () => { await mongo_db.getDb().command({ ping:1 }); return true; }],
    ["neo4j",   async () => { await neo4j_db.read("RETURN 1 AS ok"); return true; }],
  ]) { try { r[n] = await fn() ? "OK" : "FAIL"; } catch { r[n] = "UNREACHABLE"; ok = false; } }
  res.status(ok ? 200 : 503).json({ success: ok, databases: r });
});

// ── Dashboard status ──────────────────────────────────────────
router.get("/status", getDetailedStatus);

// ── Maintenance Requests ──────────────────────────────────────
router.post("/requests",
  [body("district_id").isInt({min:1}), body("description").isLength({min:10}),
   body("category").isIn(["BURST_PIPE","POTHOLE","FAULTY_STREETLIGHT","SEWER_BLOCKAGE","ROAD_SURFACE_DAMAGE","ELECTRICAL_FAULT","STRUCTURAL_DAMAGE","OTHER"]),
   body("priority").optional().isIn(["LOW","MEDIUM","HIGH","CRITICAL"])],
  handleValidation, requestCtrl.submitRequest);
router.get("/requests",     requestCtrl.listRequests);
router.get("/requests/:id", [param("id").isInt({min:1})], handleValidation, requestCtrl.getRequest);
router.get("/requests/:id/impact", [param("id").isInt({min:1})], handleValidation, requestCtrl.getImpactAnalysis);

// ── Assets ────────────────────────────────────────────────────
router.get("/assets/:id", [param("id").isInt({min:1})], handleValidation, async (req, res, next) => {
  try {
    const id = parseInt(req.params.id);
    const neo4jInt = require("neo4j-driver").int;
    const [[rows], sensors, graph] = await Promise.all([
      mysql_db.getPool().execute("SELECT a.*, d.district_name, at.type_name, at.criticality_level FROM assets a JOIN districts d ON d.district_id=a.district_id JOIN asset_types at ON at.asset_type_id=a.asset_type_id WHERE a.asset_id=?", [id]),
      mongo_db.collection("sensor_readings").aggregate([{$match:{mysql_asset_id:id}},{$sort:{recorded_at:-1}},{$group:{_id:"$sensor_type",latest:{$first:"$reading_value"},unit:{$first:"$unit_of_measure"},is_anomaly:{$first:"$is_anomaly"}}}]).toArray().catch(()=>[]),
      neo4j_db.read("MATCH (a:Asset {mysql_asset_id:$id})-[r]-(n:Asset) RETURN type(r) AS rel, n.asset_code AS code, n.name AS name, n.status AS status LIMIT 10", {id:neo4jInt(id)}).catch(()=>[]),
    ]);
    if (!rows||!rows[0]) return res.status(404).json({success:false,error:"Asset not found."});
    res.json({success:true,data:{...rows[0],sensor_readings:sensors,network:graph}});
  } catch(e){next(e);}
});

// ── Reports ───────────────────────────────────────────────────
router.get("/reports/district/:id", [param("id").isInt({min:1})], handleValidation, async (req, res, next) => {
  try {
    const id = parseInt(req.params.id);
    const neo4jInt = require("neo4j-driver").int;
    const [report, logCount, [stock]] = await Promise.all([
      mysql_db.callProcedure("sp_generate_district_report", [id]),
      mongo_db.collection("maintenance_logs").countDocuments({district_id:id,logged_at:{$gte:new Date(new Date().getFullYear(),new Date().getMonth(),1)}}).catch(()=>0),
      mysql_db.getPool().execute("SELECT * FROM v_low_stock_alerts LIMIT 10").catch(()=>[[]]),
    ]);
    res.json({success:true,district_id:id,report:{open_work_orders:report,field_logs_this_month:logCount,low_stock_alerts:stock}});
  } catch(e){next(e);}
});
router.get("/reports/asset-conditions", async (req,res,next)=>{ try{const[r]=await mysql_db.getPool().execute("SELECT * FROM v_asset_condition_by_district ORDER BY avg_condition_rating ASC");res.json({success:true,data:r});}catch(e){next(e);}});
router.get("/reports/sla-breaches",     async (req,res,next)=>{ try{const[r]=await mysql_db.getPool().execute("SELECT * FROM v_sla_breached_orders ORDER BY hours_overdue DESC LIMIT 50");res.json({success:true,count:r.length,data:r});}catch(e){next(e);}});
router.get("/reports/stock-alerts",     async (req,res,next)=>{ try{const[r]=await mysql_db.getPool().execute("SELECT * FROM v_low_stock_alerts");res.json({success:true,count:r.length,data:r});}catch(e){next(e);}});

// ═══════════════════════════════════════════════════════════════
// DATABASE MANAGER ROUTES (for HTML database manager)
// ═══════════════════════════════════════════════════════════════

// ── MySQL Manager ─────────────────────────────────────────────
router.get("/db/mysql/tables",              dbMgr.mysqlListTables);
router.get("/db/mysql/table/:table/columns",dbMgr.mysqlGetColumns);
router.get("/db/mysql/table/:table/rows",   dbMgr.mysqlGetRows);
router.post("/db/mysql/table/:table/rows",  dbMgr.mysqlInsertRow);
router.put("/db/mysql/table/:table/rows/:id",  dbMgr.mysqlUpdateRow);
router.delete("/db/mysql/table/:table/rows/:id",dbMgr.mysqlDeleteRow);
router.post("/db/mysql/query",              dbMgr.mysqlRunQuery);

// ── MongoDB Manager ───────────────────────────────────────────
router.get("/db/mongo/collections",                    dbMgr.mongoListCollections);
router.get("/db/mongo/collection/:collection/docs",    dbMgr.mongoGetDocuments);
router.get("/db/mongo/collection/:collection/docs/:id",dbMgr.mongoGetDocument);
router.put("/db/mongo/collection/:collection/docs/:id",dbMgr.mongoUpdateDocument);
router.delete("/db/mongo/collection/:collection/docs/:id",dbMgr.mongoDeleteDocument);

// ── Neo4j Manager ─────────────────────────────────────────────
router.get("/db/neo4j/nodes",  dbMgr.neo4jBrowseNodes);
router.post("/db/neo4j/query", dbMgr.neo4jRunQuery);

module.exports = router;
