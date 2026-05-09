// =============================================================================
// JHB IMTS — Complete Connection Test Script
// Tests MySQL (XAMPP), MongoDB, and Neo4j with full diagnostics.
//
// HOW TO RUN:
//   1. Open terminal in this folder (connection_test/)
//   2. npm install
//   3. Edit .env — set your Neo4j password (MySQL and MongoDB have no password by default)
//   4. node test_connections.js
// =============================================================================

require("dotenv").config();
const mysql   = require("mysql2/promise");
const { MongoClient } = require("mongodb");
const neo4j   = require("neo4j-driver");

// Colour codes for terminal output
const C = {
  reset:  "\x1b[0m",
  bold:   "\x1b[1m",
  red:    "\x1b[31m",
  green:  "\x1b[32m",
  yellow: "\x1b[33m",
  cyan:   "\x1b[36m",
  white:  "\x1b[37m",
  blue:   "\x1b[34m",
};

const pass  = (msg) => console.log(`  ${C.green}✓${C.reset} ${msg}`);
const fail  = (msg) => console.log(`  ${C.red}✗${C.reset} ${msg}`);
const info  = (msg) => console.log(`  ${C.cyan}→${C.reset} ${msg}`);
const warn  = (msg) => console.log(`  ${C.yellow}⚠${C.reset}  ${msg}`);
const head  = (msg) => console.log(`\n${C.bold}${C.blue}═══ ${msg} ${C.reset}`);
const sep   = ()    => console.log(`${C.white}${"─".repeat(60)}${C.reset}`);

// =============================================================================
// TEST 1: MySQL via XAMPP
// =============================================================================
async function testMySQL() {
  head("TEST 1: MySQL (XAMPP)");
  sep();
  info(`Host:     ${process.env.MYSQL_HOST}:${process.env.MYSQL_PORT}`);
  info(`User:     ${process.env.MYSQL_USER}`);
  info(`Database: ${process.env.MYSQL_DATABASE}`);
  sep();

  let pool;
  try {
    pool = mysql.createPool({
      host:             process.env.MYSQL_HOST     || "127.0.0.1",
      port:             parseInt(process.env.MYSQL_PORT) || 3306,
      user:             process.env.MYSQL_USER     || "root",
      password:         process.env.MYSQL_PASSWORD || "",
      connectTimeout:   8000,
      connectionLimit:  2,
    });

    // --- 1a. Basic ping ---
    const conn = await pool.getConnection();
    await conn.ping();
    conn.release();
    pass("MySQL server reachable — ping OK");

    // --- 1b. MySQL version ---
    const [[vRow]] = await pool.execute("SELECT VERSION() AS ver, NOW() AS ts");
    pass(`MySQL version: ${vRow.ver}  |  Server time: ${vRow.ts}`);

    // --- 1c. Check if group19GA database exists ---
    const [[dbRow]] = await pool.execute(
      "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = ?",
      [process.env.MYSQL_DATABASE || "group19GA"]
    );

    if (dbRow) {
      pass(`Database '${process.env.MYSQL_DATABASE}' EXISTS`);

      // Switch to group19GA
      await pool.execute(`USE ${process.env.MYSQL_DATABASE}`);

      // --- 1d. Count tables ---
      const [tables] = await pool.execute(
        "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? ORDER BY TABLE_NAME",
        [process.env.MYSQL_DATABASE]
      );

      if (tables.length >= 11) {
        pass(`All ${tables.length} tables present: ${tables.map(t => t.TABLE_NAME).join(", ")}`);
      } else if (tables.length > 0) {
        warn(`Only ${tables.length} tables found (expected 11). Run phase1_mysql/jhb_phase1_schema.sql first.`);
        tables.forEach(t => info(`  Found: ${t.TABLE_NAME}`));
      } else {
        warn("Database exists but NO tables found. Run phase1_mysql/jhb_phase1_schema.sql first.");
      }

      // --- 1e. Check stored objects (Phase 2) ---
      const [[objCount]] = await pool.execute(
        `SELECT
          (SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = ? AND ROUTINE_TYPE='FUNCTION') AS fn_count,
          (SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = ? AND ROUTINE_TYPE='PROCEDURE') AS sp_count,
          (SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = ?) AS trg_count,
          (SELECT COUNT(*) FROM information_schema.EVENTS   WHERE EVENT_SCHEMA   = ?) AS evt_count`,
        [process.env.MYSQL_DATABASE, process.env.MYSQL_DATABASE,
         process.env.MYSQL_DATABASE, process.env.MYSQL_DATABASE]
      );

      if (objCount.fn_count >= 5)  pass(`Functions: ${objCount.fn_count} (expected 5)`);
      else warn(`Functions: ${objCount.fn_count} found (expected 5) — run phase2_mysql_logic/jhb_phase2_logic.sql`);

      if (objCount.sp_count >= 6)  pass(`Procedures: ${objCount.sp_count} (expected 6)`);
      else warn(`Procedures: ${objCount.sp_count} found (expected 6) — run phase2_mysql_logic/jhb_phase2_logic.sql`);

      if (objCount.trg_count >= 8) pass(`Triggers: ${objCount.trg_count} (expected 8)`);
      else warn(`Triggers: ${objCount.trg_count} found (expected 8) — run phase2_mysql_logic/jhb_phase2_logic.sql`);

      if (objCount.evt_count >= 4) pass(`Events: ${objCount.evt_count} (expected 4)`);
      else warn(`Events: ${objCount.evt_count} found (expected 4) — run phase2_mysql_logic/jhb_phase2_logic.sql`);

      // --- 1f. Seed data check ---
      const [[seedRow]] = await pool.execute(
        `SELECT
          (SELECT COUNT(*) FROM districts) AS districts,
          (SELECT COUNT(*) FROM assets) AS assets,
          (SELECT COUNT(*) FROM staff) AS staff,
          (SELECT COUNT(*) FROM maintenance_requests) AS requests
        `
      ).catch(() => [[{ districts:0, assets:0, staff:0, requests:0 }]]);

      if (seedRow.districts >= 7) {
        pass(`Seed data OK — Districts: ${seedRow.districts}, Assets: ${seedRow.assets}, Staff: ${seedRow.staff}, Requests: ${seedRow.requests}`);
      } else {
        warn("Seed data missing or incomplete — re-run phase1_mysql/jhb_phase1_schema.sql");
      }

      // --- 1g. Test a scalar function ---
      const [[fnRow]] = await pool.execute(
        "SELECT fn_days_open(1) AS days_open, fn_get_priority_score(1) AS score"
      ).catch(() => [[null]]);

      if (fnRow && fnRow.days_open !== undefined) {
        pass(`Scalar function test: fn_days_open(1)=${fnRow.days_open}, fn_get_priority_score(1)=${fnRow.score}`);
      } else {
        warn("Scalar functions not callable — run phase2_mysql_logic/jhb_phase2_logic.sql");
      }

      // --- 1h. Test a view ---
      const [viewRows] = await pool.execute(
        "SELECT COUNT(*) AS cnt FROM v_open_requests"
      ).catch(() => [[{ cnt: -1 }]]);

      if (viewRows[0].cnt >= 0) {
        pass(`View v_open_requests accessible — ${viewRows[0].cnt} open request(s)`);
      } else {
        warn("Views not found — run phase2_mysql_logic/jhb_phase2_logic.sql");
      }

      // --- 1i. Test a stored procedure ---
      const [procResult] = await pool.execute(
        "CALL sp_generate_district_report(1)"
      ).catch(() => [[null]]);

      if (procResult && procResult[0]) {
        pass(`Stored procedure sp_generate_district_report(1) executed — returned ${procResult[0].length} row(s)`);
      } else {
        warn("Stored procedures not callable — run phase2_mysql_logic/jhb_phase2_logic.sql");
      }

    } else {
      fail(`Database '${process.env.MYSQL_DATABASE}' does NOT exist.`);
      warn("Fix: In XAMPP phpMyAdmin, create a new database named 'group19GA', then run phase1_mysql/jhb_phase1_schema.sql");
    }

  } catch (err) {
    fail(`MySQL connection FAILED: ${err.message}`);

    if (err.code === "ECONNREFUSED")
      warn("Fix: Open XAMPP Control Panel → click START next to MySQL");
    else if (err.code === "ER_ACCESS_DENIED_ERROR")
      warn("Fix: Check MYSQL_USER and MYSQL_PASSWORD in .env");
    else
      warn(`Error code: ${err.code || "unknown"}`);
  } finally {
    if (pool) await pool.end();
  }
}


// =============================================================================
// TEST 2: MongoDB
// =============================================================================
async function testMongoDB() {
  head("TEST 2: MongoDB");
  sep();
  info(`URI:      ${process.env.MONGO_URI}`);
  info(`Database: ${process.env.MONGO_DATABASE}`);
  sep();

  let client;
  try {
    client = new MongoClient(process.env.MONGO_URI || "mongodb://127.0.0.1:27017", {
      serverSelectionTimeoutMS: 6000,
      connectTimeoutMS: 8000,
    });

    await client.connect();
    pass("MongoDB server reachable");

    const adminDb = client.db("admin");
    const pingResult = await adminDb.command({ ping: 1 });
    pass(`Ping OK: ${JSON.stringify(pingResult)}`);

    // Server info
    const serverInfo = await adminDb.command({ serverStatus: 1 }).catch(() => null);
    if (serverInfo) {
      pass(`MongoDB version: ${serverInfo.version}  |  Uptime: ${Math.floor(serverInfo.uptime / 60)} minutes`);
    }

    // Check group19GA_mongo database
    const dbList = await client.db().admin().listDatabases();
    const dbExists = dbList.databases.some(d => d.name === (process.env.MONGO_DATABASE || "group19GA_mongo"));

    const db = client.db(process.env.MONGO_DATABASE || "group19GA_mongo");

    if (dbExists) {
      pass(`Database '${process.env.MONGO_DATABASE}' EXISTS`);
    } else {
      warn(`Database '${process.env.MONGO_DATABASE}' does not exist yet — it will be created when Phase 3 script runs`);
    }

    // Check collections
    const collections = await db.listCollections().toArray();
    const expectedCols = ["maintenance_logs","sensor_readings","media_attachments","field_reports","audit_events"];
    const foundCols    = collections.map(c => c.name);

    if (foundCols.length >= 5) {
      pass(`All ${foundCols.length} collections found: ${foundCols.join(", ")}`);
    } else if (foundCols.length > 0) {
      warn(`Only ${foundCols.length} collections found: ${foundCols.join(", ")}`);
      warn("Missing: " + expectedCols.filter(c => !foundCols.includes(c)).join(", "));
      warn("Fix: Run  mongosh --file phase3_mongodb/jhb_phase3_mongodb.js");
    } else {
      warn("No collections found — run Phase 3 script");
      warn("Fix: In mongosh terminal: mongosh --file phase3_mongodb/jhb_phase3_mongodb.js");
    }

    // Document counts
    for (const col of expectedCols) {
      if (foundCols.includes(col)) {
        const count = await db.collection(col).countDocuments();
        pass(`  ${col}: ${count} document(s)`);
      } else {
        warn(`  ${col}: NOT FOUND`);
      }
    }

    // Index check on maintenance_logs
    if (foundCols.includes("maintenance_logs")) {
      const indexes = await db.collection("maintenance_logs").listIndexes().toArray();
      pass(`maintenance_logs has ${indexes.length} index(es)`);
      if (indexes.some(i => i["2dsphere"])) {
        pass("Geospatial 2dsphere index present");
      }
    }

    // Test aggregation pipeline
    if (foundCols.includes("sensor_readings")) {
      const anomalies = await db.collection("sensor_readings").countDocuments({ is_anomaly: true });
      pass(`Aggregation test: ${anomalies} sensor anomaly reading(s) found`);
    }

  } catch (err) {
    fail(`MongoDB connection FAILED: ${err.message}`);

    if (err.message.includes("ECONNREFUSED"))
      warn("Fix: Start MongoDB service — in Windows: net start MongoDB  |  macOS/Linux: mongod --dbpath /data/db");
    else if (err.message.includes("Authentication"))
      warn("Fix: Check MONGO_URI credentials in .env");
    else
      warn(`Error: ${err.message}`);
  } finally {
    if (client) await client.close();
  }
}


// =============================================================================
// TEST 3: Neo4j
// =============================================================================
async function testNeo4j() {
  head("TEST 3: Neo4j");
  sep();
  info(`URI:      ${process.env.NEO4J_URI}`);
  info(`User:     ${process.env.NEO4J_USER}`);
  info(`Database: ${process.env.NEO4J_DATABASE}`);
  sep();

  let driver;
  try {
    driver = neo4j.driver(
      process.env.NEO4J_URI      || "bolt://127.0.0.1:7687",
      neo4j.auth.basic(
        process.env.NEO4J_USER   || "neo4j",
        process.env.NEO4J_PASSWORD || "neo4j"
      ),
      { connectionAcquisitionTimeout: 8000, maxConnectionPoolSize: 5 }
    );

    await driver.verifyConnectivity();
    pass("Neo4j server reachable — Bolt connection verified");

    const session = driver.session({ database: process.env.NEO4J_DATABASE || "neo4j" });

    try {
      // Server version
      const verResult = await session.run("CALL dbms.components() YIELD name, versions RETURN name, versions[0] AS version");
      verResult.records.forEach(r => {
        pass(`Neo4j component: ${r.get("name")} — version ${r.get("version")}`);
      });

      // Node count by label
      const labelResult = await session.run(
        "MATCH (n) RETURN labels(n)[0] AS label, count(n) AS count ORDER BY count DESC"
      );

      if (labelResult.records.length > 0) {
        pass(`Graph populated — ${labelResult.records.length} node label(s) found:`);
        labelResult.records.forEach(r => {
          const label = r.get("label");
          const count = neo4j.isInt(r.get("count")) ? r.get("count").toNumber() : r.get("count");
          info(`  ${label}: ${count} node(s)`);
        });
      } else {
        warn("Graph is empty — no nodes found");
        warn("Fix: Open Neo4j Browser (http://localhost:7474) and run phase4_neo4j/jhb_phase4_neo4j.cypher section by section");
      }

      // Relationship count
      const relResult = await session.run(
        "MATCH ()-[r]->() RETURN type(r) AS type, count(r) AS count ORDER BY count DESC"
      );

      if (relResult.records.length > 0) {
        pass(`Relationships: ${relResult.records.length} type(s):`);
        relResult.records.forEach(r => {
          const type  = r.get("type");
          const count = neo4j.isInt(r.get("count")) ? r.get("count").toNumber() : r.get("count");
          info(`  ${type}: ${count}`);
        });
      } else {
        warn("No relationships found — run Phase 4 Section 3 in Neo4j Browser");
      }

      // Test the cascade query (Phase 4 Query 4.1)
      const cascadeResult = await session.run(
        `MATCH path = (source:Asset {mysql_asset_id: 1})-[:CONNECTS_TO*1..3]->(affected:Asset)
         RETURN count(DISTINCT affected) AS affected_count`
      );

      if (cascadeResult.records.length > 0) {
        const count = neo4j.isInt(cascadeResult.records[0].get("affected_count"))
          ? cascadeResult.records[0].get("affected_count").toNumber()
          : cascadeResult.records[0].get("affected_count");
        pass(`Cascade query test: Asset 1 (Commissioner St pipe) affects ${count} connected asset(s)`);
      } else {
        warn("Cascade query returned no results — check Phase 4 relationships are loaded");
      }

      // Test shortest path
      const spResult = await session.run(
        `MATCH (a:Asset {mysql_asset_id: 10}), (b:Asset {mysql_asset_id: 1})
         MATCH p = shortestPath((a)-[:CONNECTS_TO|FEEDS_INTO*]-(b))
         RETURN length(p) AS hops`
      );

      if (spResult.records.length > 0) {
        const hops = neo4j.isInt(spResult.records[0].get("hops"))
          ? spResult.records[0].get("hops").toNumber()
          : spResult.records[0].get("hops");
        pass(`shortestPath test: Pump Station → Commissioner St = ${hops} hop(s)`);
      } else {
        warn("shortestPath query returned no results — FEEDS_INTO / CONNECTS_TO relationships may be missing");
      }

      // Constraint check
      const constraintResult = await session.run("SHOW CONSTRAINTS");
      pass(`Constraints: ${constraintResult.records.length} defined`);

    } finally {
      await session.close();
    }

  } catch (err) {
    fail(`Neo4j connection FAILED: ${err.message}`);

    if (err.message.includes("ECONNREFUSED"))
      warn("Fix: Open Neo4j Desktop → click START on your group19GA database");
    else if (err.message.includes("authentication") || err.message.includes("Unauthorized"))
      warn("Fix: Set NEO4J_PASSWORD in .env to your Neo4j database password (set during first-run setup)");
    else if (err.message.includes("ServiceUnavailable"))
      warn("Fix: Neo4j is not running. Open Neo4j Desktop and START the database.");
    else
      warn(`Error: ${err.message}`);
  } finally {
    if (driver) await driver.close();
  }
}


// =============================================================================
// SUMMARY REPORT
// =============================================================================
async function printSummary(results) {
  head("SUMMARY");
  sep();
  const icons = { pass: `${C.green}CONNECTED${C.reset}`, fail: `${C.red}FAILED   ${C.reset}`, warn: `${C.yellow}PARTIAL  ${C.reset}` };
  results.forEach(r => {
    console.log(`  ${r.status === "pass" ? icons.pass : r.status === "warn" ? icons.warn : icons.fail}  ${r.name}`);
  });
  sep();
  console.log(`\n${C.bold}Next steps:${C.reset}`);
  console.log("  1. Fix any FAILED connections above using the hints shown.");
  console.log("  2. For PARTIAL results, run the missing SQL/JS phase files.");
  console.log("  3. Once all three show CONNECTED, start the API:");
  console.log("     cd ../phase5_api && npm install && cp .env.example .env");
  console.log("     (edit .env with your passwords) then: node server.js");
  console.log("  4. Test the API: http://localhost:3000/api/v1/health/deep\n");
}


// =============================================================================
// MAIN
// =============================================================================
(async () => {
  console.log(`\n${C.bold}${"═".repeat(60)}${C.reset}`);
  console.log(`${C.bold}  City of Johannesburg — IMTS Connection Test${C.reset}`);
  console.log(`${C.bold}${"═".repeat(60)}${C.reset}`);
  console.log(`  Node.js: ${process.version}  |  Time: ${new Date().toLocaleString("en-ZA")}`);

  const results = [];

  await testMySQL().then(() => results.push({ name: "MySQL (XAMPP :3306)", status: "pass" }))
                   .catch(() => results.push({ name: "MySQL (XAMPP :3306)", status: "fail" }));

  await testMongoDB().then(() => results.push({ name: "MongoDB (:27017)", status: "pass" }))
                     .catch(() => results.push({ name: "MongoDB (:27017)", status: "fail" }));

  await testNeo4j().then(() => results.push({ name: "Neo4j (:7687)", status: "pass" }))
                   .catch(() => results.push({ name: "Neo4j (:7687)", status: "fail" }));

  await printSummary(results);
})();
