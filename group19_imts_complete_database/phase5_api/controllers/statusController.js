// ============================================================
// controllers/statusController.js
// Detailed status endpoint consumed by the HTML dashboard.
// Returns per-service health, counts, and live stats.
// ============================================================
const { mysql_db, mongo_db, neo4j_db } = require("../config/db");

const getDetailedStatus = async (req, res) => {
  const result = {
    api:     { status: "OK", uptime_s: Math.floor(process.uptime()), version: process.env.API_VERSION || "v1", node: process.version },
    mysql:   { status: "DISCONNECTED", database: process.env.MYSQL_DATABASE || "group19",   host: process.env.MYSQL_HOST || "127.0.0.1", port: 3306 },
    mongodb: { status: "DISCONNECTED", database: process.env.MONGO_DATABASE || "group19_mongo", host: "127.0.0.1", port: 27017 },
    neo4j:   { status: "DISCONNECTED", database: process.env.NEO4J_DATABASE || "neo4j",     host: "127.0.0.1", port: 7687 },
    timestamp: new Date().toISOString(),
  };

  // ── MySQL ──
  try {
    const pool = mysql_db.getPool();
    const [[v]]  = await pool.execute("SELECT VERSION() AS ver, NOW() AS ts");
    const [[c]]  = await pool.execute(
      "SELECT (SELECT COUNT(*) FROM districts) AS districts," +
      "(SELECT COUNT(*) FROM assets) AS assets," +
      "(SELECT COUNT(*) FROM maintenance_requests) AS requests," +
      "(SELECT COUNT(*) FROM work_orders) AS work_orders," +
      "(SELECT COUNT(*) FROM staff) AS staff," +
      "(SELECT COUNT(*) FROM parts_inventory) AS parts"
    ).catch(() => [[{}]]);
    const [[obj]] = await pool.execute(
      "SELECT (SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA=? AND ROUTINE_TYPE='FUNCTION') AS fns," +
      "(SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA=? AND ROUTINE_TYPE='PROCEDURE') AS procs," +
      "(SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA=?) AS triggers," +
      "(SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA=?) AS events",
      [result.mysql.database, result.mysql.database, result.mysql.database, result.mysql.database]
    ).catch(() => [[{}]]);
    result.mysql = {
      ...result.mysql,
      status:    "CONNECTED",
      version:   v.ver,
      server_time: v.ts,
      tables:    { districts: c.districts||0, assets: c.assets||0, requests: c.requests||0, work_orders: c.work_orders||0, staff: c.staff||0, parts: c.parts||0 },
      objects:   { functions: obj.fns||0, procedures: obj.procs||0, triggers: obj.triggers||0, events: obj.events||0 },
    };
  } catch (e) {
    result.mysql.error   = e.message;
    result.mysql.hint    = e.code === "ECONNREFUSED" ? "Start MySQL in XAMPP Control Panel" :
                           e.code === "ER_ACCESS_DENIED_ERROR" ? "Check MYSQL_USER / MYSQL_PASSWORD in .env" :
                           e.code === "ER_BAD_DB_ERROR" ? "Run phase1_mysql/group19_schema.sql first" : e.code;
  }

  // ── MongoDB ──
  try {
    const db   = mongo_db.getDb();
    const cols  = await db.listCollections().toArray();
    const colNames = cols.map(c => c.name);
    const counts = {};
    for (const n of ["maintenance_logs","sensor_readings","media_attachments","field_reports","audit_events"]) {
      counts[n] = colNames.includes(n) ? await db.collection(n).countDocuments() : 0;
    }
    const anomalies = colNames.includes("sensor_readings")
      ? await db.collection("sensor_readings").countDocuments({ is_anomaly: true }) : 0;
    result.mongodb = {
      ...result.mongodb,
      status:     "CONNECTED",
      collections: colNames.length,
      collection_names: colNames,
      documents:  counts,
      anomaly_readings: anomalies,
    };
  } catch (e) {
    result.mongodb.error = e.message;
    result.mongodb.hint  = e.message.includes("ECONNREFUSED") ? "Start MongoDB service (mongod)" :
                           e.message.includes("Authentication") ? "Check MONGO_URI credentials" : e.message;
  }

  // ── Neo4j ──
  try {
    const rows = await neo4j_db.read("MATCH (n) RETURN labels(n)[0] AS label, count(n) AS count ORDER BY count DESC LIMIT 10");
    const rels  = await neo4j_db.read("MATCH ()-[r]->() RETURN type(r) AS type, count(r) AS cnt ORDER BY cnt DESC");
    const nodeTotal = rows.reduce((s, r) => s + (r.count || 0), 0);
    const relTotal  = rels.reduce((s, r) => s + (r.cnt || 0), 0);
    result.neo4j = {
      ...result.neo4j,
      status:       "CONNECTED",
      total_nodes:  nodeTotal,
      total_relationships: relTotal,
      node_labels:  rows,
      relationship_types: rels,
    };
  } catch (e) {
    result.neo4j.error = e.message;
    result.neo4j.hint  = e.message.includes("ECONNREFUSED") || e.message.includes("ServiceUnavailable")
      ? "Open Neo4j Desktop and START your database"
      : e.message.includes("Unauthorized") || e.message.includes("authentication")
      ? "Set NEO4J_PASSWORD in .env to your Neo4j database password"
      : e.message;
  }

  const all = [result.mysql.status, result.mongodb.status, result.neo4j.status];
  result.overall = all.every(s => s === "CONNECTED") ? "ALL_CONNECTED" :
                   all.some(s  => s === "CONNECTED") ? "PARTIAL" : "ALL_DISCONNECTED";

  res.json(result);
};

module.exports = { getDetailedStatus };
