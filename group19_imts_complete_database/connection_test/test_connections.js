// Group 19 IMTS — Connection Test
// Usage: npm install && node test_connections.js
require("dotenv").config();
const mysql = require("mysql2/promise");
const { MongoClient } = require("mongodb");
const neo4j = require("neo4j-driver");

const G = { r:"\x1b[31m", g:"\x1b[32m", y:"\x1b[33m", c:"\x1b[36m", b:"\x1b[34m", w:"\x1b[1m", x:"\x1b[0m" };
const pass = m => console.log("  " + G.g + "✓" + G.x + " " + m);
const fail = m => console.log("  " + G.r + "✗" + G.x + " " + m);
const info = m => console.log("  " + G.c + "→" + G.x + " " + m);
const warn = m => console.log("  " + G.y + "⚠" + G.x + "  " + m);
const head = m => console.log("\n" + G.w + G.b + "═══ " + m + " " + G.x);
const sep  = () => console.log("─".repeat(60));

async function testMySQL() {
  head("TEST 1: MySQL / XAMPP → database: group19");
  sep();
  let pool;
  try {
    pool = mysql.createPool({ host: process.env.MYSQL_HOST||"127.0.0.1", port: parseInt(process.env.MYSQL_PORT)||3306, user: process.env.MYSQL_USER||"root", password: process.env.MYSQL_PASSWORD||"", connectTimeout: 6000, connectionLimit: 2 });
    const c = await pool.getConnection(); await c.ping(); c.release();
    pass("MySQL server reachable");
    const [[v]] = await pool.execute("SELECT VERSION() AS ver");
    pass("MySQL version: " + v.ver);
    const [[db]] = await pool.execute("SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME=?", [process.env.MYSQL_DATABASE||"group19"]);
    if (db) {
      pass("Database 'group19' EXISTS");
      await pool.execute("USE " + (process.env.MYSQL_DATABASE||"group19"));
      const [tables] = await pool.execute("SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=?", [process.env.MYSQL_DATABASE||"group19"]);
      tables.length >= 11 ? pass("All " + tables.length + " tables present") : warn(tables.length + " tables (expected 11) — run group19_schema.sql");
      const [[o]] = await pool.execute("SELECT (SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA=? AND ROUTINE_TYPE='FUNCTION') AS f,(SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA=? AND ROUTINE_TYPE='PROCEDURE') AS p,(SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA=?) AS t,(SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA=?) AS e", [process.env.MYSQL_DATABASE||"group19",process.env.MYSQL_DATABASE||"group19",process.env.MYSQL_DATABASE||"group19",process.env.MYSQL_DATABASE||"group19"]);
      o.f>=5?pass("Functions: "+o.f):warn("Functions: "+o.f+" (need 5) — run group19_logic.sql");
      o.p>=6?pass("Procedures: "+o.p):warn("Procedures: "+o.p+" (need 6) — run group19_logic.sql");
      o.t>=8?pass("Triggers: "+o.t):warn("Triggers: "+o.t+" (need 8) — run group19_logic.sql");
      o.e>=4?pass("Events: "+o.e):warn("Events: "+o.e+" (need 4) — run group19_logic.sql");
      const [[s]] = await pool.execute("SELECT (SELECT COUNT(*) FROM districts) AS d,(SELECT COUNT(*) FROM assets) AS a,(SELECT COUNT(*) FROM maintenance_requests) AS r FROM dual").catch(()=>[[{}]]);
      if (s && s.d >= 7) pass("Seed data OK — Districts:" + s.d + " Assets:" + s.a + " Requests:" + s.r);
      else warn("Seed data missing — re-run group19_schema.sql");
    } else {
      fail("Database 'group19' NOT FOUND");
      warn("Fix: phpMyAdmin → Import → run phase1_mysql/group19_schema.sql");
    }
  } catch(e) {
    fail("MySQL FAILED: " + e.message);
    if (e.code==="ECONNREFUSED") warn("Fix: Open XAMPP Control Panel → START MySQL");
    else if (e.code==="ER_ACCESS_DENIED_ERROR") warn("Fix: Check MYSQL_USER/MYSQL_PASSWORD in .env");
    else warn("Error code: " + (e.code||"unknown"));
  } finally { if(pool) await pool.end(); }
}

async function testMongoDB() {
  head("TEST 2: MongoDB → database: group19_mongo");
  sep();
  let client;
  try {
    client = new MongoClient(process.env.MONGO_URI||"mongodb://127.0.0.1:27017", { serverSelectionTimeoutMS:5000 });
    await client.connect();
    pass("MongoDB server reachable");
    await client.db("admin").command({ ping:1 });
    pass("Ping OK");
    const db = client.db(process.env.MONGO_DATABASE||"group19_mongo");
    const cols = (await db.listCollections().toArray()).map(c=>c.name);
    const expected = ["maintenance_logs","sensor_readings","media_attachments","field_reports","audit_events"];
    cols.length>=5 ? pass("All " + cols.length + " collections found: " + cols.join(", ")) : warn("Found " + cols.length + " collections — run group19_mongodb.js");
    for (const c of expected) {
      if (cols.includes(c)) { const n = await db.collection(c).countDocuments(); pass("  " + c + ": " + n + " documents"); }
      else warn("  " + c + ": NOT FOUND");
    }
  } catch(e) {
    fail("MongoDB FAILED: " + e.message);
    if (e.message.includes("ECONNREFUSED")) warn("Fix: Start MongoDB — net start MongoDB (Windows) OR mongod (mac/Linux)");
    else warn("Error: " + e.message);
  } finally { if(client) await client.close(); }
}

async function testNeo4j() {
  head("TEST 3: Neo4j → bolt://127.0.0.1:7687");
  sep();
  let driver;
  try {
    driver = neo4j.driver(process.env.NEO4J_URI||"bolt://127.0.0.1:7687", neo4j.auth.basic(process.env.NEO4J_USER||"neo4j", process.env.NEO4J_PASSWORD||"neo4j"), { connectionAcquisitionTimeout:6000, maxConnectionPoolSize:3 });
    await driver.verifyConnectivity();
    pass("Neo4j server reachable");
    const s = driver.session({ database: process.env.NEO4J_DATABASE||"neo4j" });
    try {
      const vr = await s.run("CALL dbms.components() YIELD name, versions RETURN name, versions[0] AS v");
      vr.records.forEach(r => pass("Neo4j: " + r.get("name") + " v" + r.get("v")));
      const nr = await s.run("MATCH (n) RETURN labels(n)[0] AS l, count(n) AS c ORDER BY c DESC");
      nr.records.length > 0 ? pass("Graph populated — " + nr.records.length + " node label(s):") : warn("Graph empty — run Phase 4 Cypher in Neo4j Browser");
      nr.records.forEach(r => info("  " + r.get("l") + ": " + (neo4j.isInt(r.get("c")) ? r.get("c").toNumber() : r.get("c")) + " nodes"));
      const rr = await s.run("MATCH ()-[r]->() RETURN type(r) AS t, count(r) AS c ORDER BY c DESC LIMIT 5");
      rr.records.length > 0 ? pass("Relationships found:") : warn("No relationships — run Phase 4 Section 3");
      rr.records.forEach(r => info("  " + r.get("t") + ": " + (neo4j.isInt(r.get("c")) ? r.get("c").toNumber() : r.get("c"))));
    } finally { await s.close(); }
  } catch(e) {
    fail("Neo4j FAILED: " + e.message);
    if (e.message.includes("ECONNREFUSED")||e.message.includes("ServiceUnavailable")) warn("Fix: Open Neo4j Desktop → START your database");
    else if (e.message.includes("Unauthorized")||e.message.includes("authentication")) warn("Fix: Set NEO4J_PASSWORD in .env");
    else warn("Error: " + e.message);
  } finally { if(driver) await driver.close(); }
}

(async () => {
  console.log("\n" + G.w + "═".repeat(60) + G.x);
  console.log(G.w + "  Group 19 — JHB IMTS Connection Test" + G.x);
  console.log(G.w + "═".repeat(60) + G.x);
  console.log("  Node: " + process.version + "  |  Time: " + new Date().toLocaleString("en-ZA"));

  const results = [];
  await testMySQL().then(()=>results.push({n:"MySQL  (group19)     :3306",ok:true})).catch(()=>results.push({n:"MySQL  (group19)     :3306",ok:false}));
  await testMongoDB().then(()=>results.push({n:"MongoDB (group19_mongo):27017",ok:true})).catch(()=>results.push({n:"MongoDB (group19_mongo):27017",ok:false}));
  await testNeo4j().then(()=>results.push({n:"Neo4j               :7687",ok:true})).catch(()=>results.push({n:"Neo4j               :7687",ok:false}));

  head("SUMMARY");
  sep();
  results.forEach(r => console.log("  " + (r.ok ? G.g + "CONNECTED  " : G.r + "FAILED     ") + G.x + r.n));
  sep();
  console.log("\nOnce all three are CONNECTED, start the API:");
  console.log("  cd ../phase5_api && npm install && node server.js");
  console.log("\nThen open the dashboard:");
  console.log("  ../dashboard/index.html (open in browser)\n");
})();
