// =============================================================================
// config/db.js
// Database connection managers for MySQL, MongoDB, and Neo4j.
//
// DESIGN DECISION: Connection pooling for all three engines.
//   MySQL2: built-in pool via createPool()
//   MongoDB: native driver pool via MongoClient
//   Neo4j:  driver-level connection pool via neo4j.driver()
//
// Each engine exports:
//   connect()    — establishes and verifies the connection
//   getClient()  — returns the live connection/pool for queries
//   disconnect() — graceful shutdown (called on SIGTERM/SIGINT)
//
// GA9 — Staying Current: Connection pooling prevents the "thundering herd"
//   problem where 200 simultaneous API requests each open and close a
//   dedicated database connection. A pool keeps N connections warm and
//   queues requests that exceed the pool size. This is standard in every
//   production database driver — understanding it transfers to any stack.
// =============================================================================

require("dotenv").config();
const mysql     = require("mysql2/promise");
const { MongoClient } = require("mongodb");
const neo4j     = require("neo4j-driver");


// =============================================================================
// MYSQL CONNECTION POOL
// =============================================================================
let mysqlPool = null;

const mysql_db = {

  connect: async () => {
    try {
      mysqlPool = mysql.createPool({
        host:               process.env.MYSQL_HOST     || "localhost",
        port:               parseInt(process.env.MYSQL_PORT) || 3306,
        database:           process.env.MYSQL_DATABASE || "group19GA",
        user:               process.env.MYSQL_USER,
        password:           process.env.MYSQL_PASSWORD,
        connectionLimit:    parseInt(process.env.MYSQL_POOL_SIZE) || 10,
        connectTimeout:     parseInt(process.env.MYSQL_CONNECT_TIMEOUT) || 10000,
        waitForConnections: true,
        queueLimit:         0,
        // Enforce strict mode matches Phase 1 schema setting
        timezone:           "Z",
        dateStrings:        false,
      });

      // Verify connectivity with a lightweight ping
      const conn = await mysqlPool.getConnection();
      await conn.ping();
      conn.release();
      console.log("[MySQL]   Connected — pool size:", process.env.MYSQL_POOL_SIZE || 10);
    } catch (err) {
      console.error("[MySQL]   Connection failed:", err.message);
      throw err;
    }
  },

  getPool: () => {
    if (!mysqlPool) throw new Error("MySQL pool not initialised. Call connect() first.");
    return mysqlPool;
  },

  // Executes a stored procedure. Returns [rows, fields].
  // Usage: await mysql_db.callProcedure("sp_generate_district_report", [districtId])
  callProcedure: async (procedureName, params = []) => {
    const placeholders = params.map(() => "?").join(", ");
    const sql = `CALL ${procedureName}(${placeholders})`;
    const [results] = await mysqlPool.execute(sql, params);
    // MySQL stored procedures return results as array of result sets.
    // The first element is the row data; the last is the OkPacket.
    return Array.isArray(results[0]) ? results[0] : results;
  },

  // Executes a stored procedure with OUT parameters.
  // MySQL2 does not support OUT params directly — we use session variables.
  callProcedureWithOuts: async (sql, inParams, outVarNames) => {
    const conn = await mysqlPool.getConnection();
    try {
      await conn.beginTransaction();
      await conn.execute(sql, inParams);
      const selectOut = `SELECT ${outVarNames.map(v => `@${v} AS ${v}`).join(", ")}`;
      const [rows] = await conn.execute(selectOut);
      await conn.commit();
      return rows[0];
    } catch (err) {
      await conn.rollback();
      throw err;
    } finally {
      conn.release();
    }
  },

  disconnect: async () => {
    if (mysqlPool) {
      await mysqlPool.end();
      console.log("[MySQL]   Pool closed.");
    }
  },
};


// =============================================================================
// MONGODB CLIENT
// =============================================================================
let mongoClient = null;
let mongoDb     = null;

const mongo_db = {

  connect: async () => {
    try {
      mongoClient = new MongoClient(process.env.MONGO_URI || "mongodb://localhost:27017", {
        maxPoolSize: parseInt(process.env.MONGO_POOL_SIZE) || 10,
        serverSelectionTimeoutMS: 5000,
        connectTimeoutMS:         10000,
      });

      await mongoClient.connect();
      mongoDb = mongoClient.db(process.env.MONGO_DATABASE || "group19GA_mongo");

      // Ping to verify
      await mongoDb.command({ ping: 1 });
      console.log("[MongoDB] Connected — database:", process.env.MONGO_DATABASE || "group19GA_mongo");
    } catch (err) {
      console.error("[MongoDB] Connection failed:", err.message);
      throw err;
    }
  },

  getDb: () => {
    if (!mongoDb) throw new Error("MongoDB not initialised. Call connect() first.");
    return mongoDb;
  },

  // Shorthand to get a specific collection
  collection: (name) => {
    if (!mongoDb) throw new Error("MongoDB not initialised.");
    return mongoDb.collection(name);
  },

  disconnect: async () => {
    if (mongoClient) {
      await mongoClient.close();
      console.log("[MongoDB] Connection closed.");
    }
  },
};


// =============================================================================
// NEO4J DRIVER
// =============================================================================
let neo4jDriver  = null;
let neo4jSession = null;

const neo4j_db = {

  connect: async () => {
    try {
      neo4jDriver = neo4j.driver(
        process.env.NEO4J_URI      || "bolt://localhost:7687",
        neo4j.auth.basic(
          process.env.NEO4J_USER   || "neo4j",
          process.env.NEO4J_PASSWORD
        ),
        {
          maxConnectionPoolSize: parseInt(process.env.NEO4J_MAX_CONNECTION_POOL) || 50,
          connectionAcquisitionTimeout: 10000,
          logging: neo4j.logging.console(process.env.NODE_ENV === "development" ? "warn" : "error"),
        }
      );

      // Verify connectivity
      await neo4jDriver.verifyConnectivity();
      console.log("[Neo4j]   Connected — URI:", process.env.NEO4J_URI || "bolt://localhost:7687");
    } catch (err) {
      console.error("[Neo4j]   Connection failed:", err.message);
      throw err;
    }
  },

  // Opens a new session for each query — sessions are lightweight in Neo4j 5.x
  getSession: () => {
    if (!neo4jDriver) throw new Error("Neo4j driver not initialised. Call connect() first.");
    return neo4jDriver.session({
      database:      process.env.NEO4J_DATABASE || "neo4j",
      defaultAccessMode: neo4j.session.READ,
    });
  },

  // Convenience: run a read query, return records as plain JS objects
  read: async (cypher, params = {}) => {
    const session = neo4j_db.getSession();
    try {
      const result = await session.run(cypher, params);
      return result.records.map(record => {
        const obj = {};
        record.keys.forEach(key => {
          const val = record.get(key);
          // Convert Neo4j Integer objects to JS numbers
          obj[key] = neo4j.isInt(val) ? val.toNumber() : val;
        });
        return obj;
      });
    } finally {
      await session.close();
    }
  },

  // Convenience: run a write query with WRITE access mode
  write: async (cypher, params = {}) => {
    const session = neo4jDriver.session({
      database:          process.env.NEO4J_DATABASE || "neo4j",
      defaultAccessMode: neo4j.session.WRITE,
    });
    try {
      const result = await session.run(cypher, params);
      return result.records.map(record => {
        const obj = {};
        record.keys.forEach(key => {
          const val = record.get(key);
          obj[key] = neo4j.isInt(val) ? val.toNumber() : val;
        });
        return obj;
      });
    } finally {
      await session.close();
    }
  },

  disconnect: async () => {
    if (neo4jDriver) {
      await neo4jDriver.close();
      console.log("[Neo4j]   Driver closed.");
    }
  },
};


module.exports = { mysql_db, mongo_db, neo4j_db };
