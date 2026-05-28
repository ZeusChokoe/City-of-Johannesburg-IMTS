// ============================================================
// config/db.js GROUP 19 IMTS
// Database connection managers: MySQL, MongoDB, Neo4j
// ============================================================
require("dotenv").config();
const mysql           = require("mysql2/promise");
const { MongoClient } = require("mongodb");
const neo4j           = require("neo4j-driver");

let mysqlPool = null;
const mysql_db = {
  connect: async () => {
    mysqlPool = mysql.createPool({
      host: process.env.MYSQL_HOST || "127.0.0.1",
      port: parseInt(process.env.MYSQL_PORT) || 3306,
      database: process.env.MYSQL_DATABASE || "group19",
      user: process.env.MYSQL_USER || "root",
      password: process.env.MYSQL_PASSWORD || "",
      connectionLimit: parseInt(process.env.MYSQL_POOL_SIZE) || 10,
      connectTimeout: 10000,
      waitForConnections: true,
      timezone: "Z",
    });
    const conn = await mysqlPool.getConnection();
    await conn.ping();
    conn.release();
    console.log("[MySQL]   Connected -> database: group19");
  },
  getPool: () => { if (!mysqlPool) throw new Error("MySQL pool not initialised."); return mysqlPool; },
  callProcedure: async (name, params = []) => {
    const ph = params.map(() => "?").join(", ");
    const [r] = await mysqlPool.execute("CALL " + name + "(" + ph + ")", params);
    return Array.isArray(r[0]) ? r[0] : r;
  },
  callProcedureWithOuts: async (sql, inParams, outVarNames) => {
    const conn = await mysqlPool.getConnection();
    try {
      await conn.beginTransaction();
      await conn.execute(sql, inParams);
      const [rows] = await conn.execute("SELECT " + outVarNames.map(v => "@" + v + " AS " + v).join(", "));
      await conn.commit();
      return rows[0];
    } catch (e) { await conn.rollback(); throw e; }
    finally { conn.release(); }
  },
  disconnect: async () => { if (mysqlPool) await mysqlPool.end(); },
};

let mongoClient = null, mongoDb = null;
const mongo_db = {
  connect: async () => {
    mongoClient = new MongoClient(process.env.MONGO_URI || "mongodb://127.0.0.1:27017", {
      maxPoolSize: parseInt(process.env.MONGO_POOL_SIZE) || 10,
      serverSelectionTimeoutMS: 5000,
    });
    await mongoClient.connect();
    mongoDb = mongoClient.db(process.env.MONGO_DATABASE || "group19_mongo");
    await mongoDb.command({ ping: 1 });
    console.log("[MongoDB] Connected -> database: group19_mongo");
  },
  getDb: () => { if (!mongoDb) throw new Error("MongoDB not initialised."); return mongoDb; },
  collection: (n) => { if (!mongoDb) throw new Error("MongoDB not initialised."); return mongoDb.collection(n); },
  disconnect: async () => { if (mongoClient) await mongoClient.close(); },
};

let neo4jDriver = null;
const neo4j_db = {
  connect: async () => {
    neo4jDriver = neo4j.driver(
      process.env.NEO4J_URI || "bolt://127.0.0.1:7687",
      neo4j.auth.basic(process.env.NEO4J_USER || "neo4j", process.env.NEO4J_PASSWORD || ""),
      { maxConnectionPoolSize: 50 }
    );
    await neo4jDriver.verifyConnectivity();
    console.log("[Neo4j]   Connected -> " + (process.env.NEO4J_URI || "bolt://127.0.0.1:7687"));
  },
  getSession: () => {
    if (!neo4jDriver) throw new Error("Neo4j driver not initialised.");
    return neo4jDriver.session({ database: process.env.NEO4J_DATABASE || "neo4j", defaultAccessMode: neo4j.session.READ });
  },
  read: async (cypher, params = {}) => {
    const s = neo4j_db.getSession();
    try {
      const result = await s.run(cypher, params);
      return result.records.map(rec => {
        const obj = {};
        rec.keys.forEach(k => { const v = rec.get(k); obj[k] = neo4j.isInt(v) ? v.toNumber() : v; });
        return obj;
      });
    } finally { await s.close(); }
  },
  write: async (cypher, params = {}) => {
    const s = neo4jDriver.session({ database: process.env.NEO4J_DATABASE || "neo4j", defaultAccessMode: neo4j.session.WRITE });
    try {
      const result = await s.run(cypher, params);
      return result.records.map(rec => {
        const obj = {};
        rec.keys.forEach(k => { const v = rec.get(k); obj[k] = neo4j.isInt(v) ? v.toNumber() : v; });
        return obj;
      });
    } finally { await s.close(); }
  },
  disconnect: async () => { if (neo4jDriver) await neo4jDriver.close(); },
};

module.exports = { mysql_db, mongo_db, neo4j_db };
