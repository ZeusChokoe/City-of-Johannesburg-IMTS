// =============================================================
// controllers/dbManagerController.js Group 19 IMTS
// Database Manager API: browse, edit, insert, delete across
// MySQL, MongoDB, and Neo4j from the HTML database manager.
// =============================================================
const { mysql_db, mongo_db, neo4j_db } = require("../config/db");
const { ObjectId } = require("mongodb");

// ─────────────────────────────────────────────────────────────
// MYSQL list all tables with row counts and columns
// ─────────────────────────────────────────────────────────────
const mysqlListTables = async (req, res, next) => {
  try {
    const db = process.env.MYSQL_DATABASE || "group19";
    const [tables] = await mysql_db.getPool().execute(
      `SELECT t.TABLE_NAME AS name,
              t.TABLE_ROWS AS approx_rows,
              t.TABLE_COMMENT AS comment,
              t.ENGINE AS engine,
              t.CREATE_TIME AS created
       FROM information_schema.TABLES t
       WHERE t.TABLE_SCHEMA = ?
       ORDER BY t.TABLE_NAME`, [db]
    );
    res.json({ success: true, database: db, tables });
  } catch (e) { next(e); }
};

// ─────────────────────────────────────────────────────────────
// MYSQL get columns for a table
// ─────────────────────────────────────────────────────────────
const mysqlGetColumns = async (req, res, next) => {
  try {
    const db    = process.env.MYSQL_DATABASE || "group19";
    const table = req.params.table;
    if (!isValidIdentifier(table)) return res.status(400).json({ success: false, error: "Invalid table name." });
    const [cols] = await mysql_db.getPool().execute(
      `SELECT COLUMN_NAME, DATA_TYPE, COLUMN_TYPE, IS_NULLABLE,
              COLUMN_KEY, COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT
       FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
       ORDER BY ORDINAL_POSITION`, [db, table]
    );
    if (!cols.length) return res.status(404).json({ success: false, error: "Table not found." });
    res.json({ success: true, table, columns: cols });
  } catch (e) { next(e); }
};

// ─────────────────────────────────────────────────────────────
// MYSQL get paginated rows from a table
// ─────────────────────────────────────────────────────────────
const mysqlGetRows = async (req, res, next) => {
  try {
    const table  = req.params.table;
    const limit  = Math.min(parseInt(req.query.limit)  || 50, 200);
    const offset = parseInt(req.query.offset) || 0;
    const search = req.query.search || "";
    const order  = req.query.order_by || "";
    const dir    = req.query.dir === "DESC" ? "DESC" : "ASC";

    if (!isValidIdentifier(table)) return res.status(400).json({ success: false, error: "Invalid table name." });

    // Get column names to build search clause
    const db = process.env.MYSQL_DATABASE || "group19";
    const [cols] = await mysql_db.getPool().execute(
      `SELECT COLUMN_NAME, DATA_TYPE FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA=? AND TABLE_NAME=? ORDER BY ORDINAL_POSITION`, [db, table]
    );
    if (!cols.length) return res.status(404).json({ success: false, error: "Table not found." });

    // Build query safely
    let sql = `SELECT * FROM \`${table}\``;
    const params = [];

    if (search) {
      const textCols = cols.filter(c => ["varchar","text","char","enum","tinytext","mediumtext"].includes(c.DATA_TYPE));
      if (textCols.length) {
        const clauses = textCols.slice(0, 5).map(c => `\`${c.COLUMN_NAME}\` LIKE ?`);
        sql += " WHERE " + clauses.join(" OR ");
        textCols.slice(0, 5).forEach(() => params.push("%" + search + "%"));
      }
    }

    const orderCol = order && isValidIdentifier(order) ? order : cols[0].COLUMN_NAME;
    sql += ` ORDER BY \`${orderCol}\` ${dir} LIMIT ${limit} OFFSET ${offset}`;

    const [rows]    = await mysql_db.getPool().execute(sql, params);
    const [[count]] = await mysql_db.getPool().execute(
      `SELECT COUNT(*) AS total FROM \`${table}\`` + (search && params.length ? sql.split("WHERE")[1].split("ORDER")[0] ? " WHERE " + sql.split("WHERE")[1].split("ORDER")[0] : "" : ""),
      search && params.length ? params : []
    ).catch(async () => {
      const [[c]] = await mysql_db.getPool().execute(`SELECT COUNT(*) AS total FROM \`${table}\``);
      return [[c]];
    });

    res.json({ success: true, table, total: count.total, limit, offset, columns: cols.map(c => c.COLUMN_NAME), rows });
  } catch (e) { next(e); }
};

// ─────────────────────────────────────────────────────────────
// MYSQL insert a row
// ─────────────────────────────────────────────────────────────
const mysqlInsertRow = async (req, res, next) => {
  try {
    const table = req.params.table;
    if (!isValidIdentifier(table)) return res.status(400).json({ success: false, error: "Invalid table name." });
    if (PROTECTED_TABLES.includes(table) && !["maintenance_requests","assets","staff"].includes(table)) {
      return res.status(403).json({ success: false, error: "Direct insert not allowed on " + table + ". Use stored procedures." });
    }
    const data = req.body;
    if (!data || !Object.keys(data).length) return res.status(400).json({ success: false, error: "No data provided." });
    const cols   = Object.keys(data).filter(k => isValidIdentifier(k));
    const vals   = cols.map(c => data[c] === "" ? null : data[c]);
    const sql    = `INSERT INTO \`${table}\` (${cols.map(c => `\`${c}\``).join(",")}) VALUES (${cols.map(() => "?").join(",")})`;
    const [result] = await mysql_db.getPool().execute(sql, vals);
    res.status(201).json({ success: true, inserted_id: result.insertId, affected: result.affectedRows });
  } catch (e) { next(e); }
};

// ─────────────────────────────────────────────────────────────
// MYSQL update a row by primary key
// ─────────────────────────────────────────────────────────────
const mysqlUpdateRow = async (req, res, next) => {
  try {
    const table = req.params.table;
    const pkVal = req.params.id;
    if (!isValidIdentifier(table)) return res.status(400).json({ success: false, error: "Invalid table name." });

    const pkCol = await getPrimaryKey(table);
    if (!pkCol) return res.status(400).json({ success: false, error: "Cannot determine primary key for " + table });

    const data = req.body;
    if (!data || !Object.keys(data).length) return res.status(400).json({ success: false, error: "No data provided." });

    const updateCols = Object.keys(data).filter(k => isValidIdentifier(k) && k !== pkCol);
    if (!updateCols.length) return res.status(400).json({ success: false, error: "No updatable columns." });

    const vals = [...updateCols.map(c => data[c] === "" ? null : data[c]), pkVal];
    const sql  = `UPDATE \`${table}\` SET ${updateCols.map(c => `\`${c}\`=?`).join(",")} WHERE \`${pkCol}\`=?`;
    const [result] = await mysql_db.getPool().execute(sql, vals);
    if (!result.affectedRows) return res.status(404).json({ success: false, error: "Row not found." });
    res.json({ success: true, affected: result.affectedRows });
  } catch (e) { next(e); }
};

// ─────────────────────────────────────────────────────────────
// MYSQL delete (or archive) a row
// ─────────────────────────────────────────────────────────────
const mysqlDeleteRow = async (req, res, next) => {
  try {
    const table = req.params.table;
    const pkVal = req.params.id;
    if (!isValidIdentifier(table)) return res.status(400).json({ success: false, error: "Invalid table name." });

    // Archive-safe tables soft delete
    const archiveTables = { assets: "is_archived", parts_inventory: "is_active", staff: "is_active" };
    if (archiveTables[table]) {
      const col = archiveTables[table];
      const val = col === "is_archived" ? 1 : 0;
      const pkCol = await getPrimaryKey(table);
      const [r] = await mysql_db.getPool().execute(`UPDATE \`${table}\` SET \`${col}\`=? WHERE \`${pkCol}\`=?`, [val, pkVal]);
      return res.json({ success: true, method: "SOFT_DELETE", column: col, affected: r.affectedRows });
    }

    // Audit table block deletion
    if (table === "request_status_history") {
      return res.status(403).json({ success: false, error: "Audit history records cannot be deleted." });
    }

    const pkCol = await getPrimaryKey(table);
    if (!pkCol) return res.status(400).json({ success: false, error: "Cannot determine primary key." });
    const [result] = await mysql_db.getPool().execute(`DELETE FROM \`${table}\` WHERE \`${pkCol}\`=?`, [pkVal]);
    if (!result.affectedRows) return res.status(404).json({ success: false, error: "Row not found." });
    res.json({ success: true, method: "HARD_DELETE", affected: result.affectedRows });
  } catch (e) { next(e); }
};

// ─────────────────────────────────────────────────────────────
// MYSQL run a safe custom SELECT query
// ─────────────────────────────────────────────────────────────
const mysqlRunQuery = async (req, res, next) => {
  try {
    const { sql } = req.body;
    if (!sql) return res.status(400).json({ success: false, error: "No SQL provided." });
    const trimmed = sql.trim().toUpperCase();
    // Only allow SELECT, SHOW, DESCRIBE, EXPLAIN
    if (!["SELECT","SHOW","DESCRIBE","DESC","EXPLAIN","CALL"].some(kw => trimmed.startsWith(kw))) {
      return res.status(403).json({ success: false, error: "Only SELECT, SHOW, DESCRIBE, EXPLAIN and CALL are allowed from the manager. Use stored procedures for writes." });
    }
    const start = Date.now();
    const [rows, fields] = await mysql_db.getPool().execute(sql.substring(0, 5000));
    const ms = Date.now() - start;
    const cols = fields ? fields.map(f => f.name) : [];
    res.json({ success: true, rows: rows.slice(0, 500), columns: cols, row_count: Array.isArray(rows) ? rows.length : 0, execution_ms: ms });
  } catch (e) {
    res.status(400).json({ success: false, error: e.sqlMessage || e.message });
  }
};

// ─────────────────────────────────────────────────────────────
// MONGODB list collections with stats
// ─────────────────────────────────────────────────────────────
const mongoListCollections = async (req, res, next) => {
  try {
    const db   = mongo_db.getDb();
    const cols = await db.listCollections().toArray();
    const result = [];
    for (const c of cols) {
      const count = await db.collection(c.name).countDocuments();
      const stats = await db.command({ collStats: c.name }).catch(() => ({}));
      result.push({ name: c.name, count, size_bytes: stats.size || 0, index_count: stats.nindexes || 0 });
    }
    res.json({ success: true, database: process.env.MONGO_DATABASE || "group19_mongo", collections: result });
  } catch (e) { next(e); }
};

// ─────────────────────────────────────────────────────────────
// MONGODB get documents from a collection with pagination
// ─────────────────────────────────────────────────────────────
const mongoGetDocuments = async (req, res, next) => {
  try {
    const col    = req.params.collection;
    const limit  = Math.min(parseInt(req.query.limit) || 20, 100);
    const offset = parseInt(req.query.offset) || 0;
    const search = req.query.search || "";

    const collection = mongo_db.collection(col);
    let filter = {};
    if (search) {
      filter = { $or: [
        { notes:       { $regex: search, $options: "i" } },
        { description: { $regex: search, $options: "i" } },
        { log_type:    { $regex: search, $options: "i" } },
        { event_type:  { $regex: search, $options: "i" } },
      ]};
    }

    const [docs, total] = await Promise.all([
      collection.find(filter).sort({ _id: -1 }).skip(offset).limit(limit).toArray(),
      collection.countDocuments(filter),
    ]);
    res.json({ success: true, collection: col, total, limit, offset, documents: docs });
  } catch (e) { next(e); }
};

// ─────────────────────────────────────────────────────────────
// MONGODB get a single document
// ─────────────────────────────────────────────────────────────
const mongoGetDocument = async (req, res, next) => {
  try {
    const col = req.params.collection;
    const id  = req.params.id;
    const doc = await mongo_db.collection(col).findOne({ _id: new ObjectId(id) }).catch(() => null);
    if (!doc) return res.status(404).json({ success: false, error: "Document not found." });
    res.json({ success: true, document: doc });
  } catch (e) { next(e); }
};

// ─────────────────────────────────────────────────────────────
// MONGODB update a document by _id
// ─────────────────────────────────────────────────────────────
const mongoUpdateDocument = async (req, res, next) => {
  try {
    const col  = req.params.collection;
    const id   = req.params.id;
    const data = req.body;
    delete data._id; // cannot update _id
    const result = await mongo_db.collection(col).updateOne(
      { _id: new ObjectId(id) },
      { $set: data }
    );
    if (!result.matchedCount) return res.status(404).json({ success: false, error: "Document not found." });
    res.json({ success: true, matched: result.matchedCount, modified: result.modifiedCount });
  } catch (e) { next(e); }
};

// ─────────────────────────────────────────────────────────────
// MONGODB delete a document (soft-delete via is_deleted flag)
// ─────────────────────────────────────────────────────────────
const mongoDeleteDocument = async (req, res, next) => {
  try {
    const col = req.params.collection;
    const id  = req.params.id;
    // Soft delete if field exists, hard delete otherwise
    const doc = await mongo_db.collection(col).findOne({ _id: new ObjectId(id) }).catch(() => null);
    if (!doc) return res.status(404).json({ success: false, error: "Document not found." });
    if ("is_deleted" in doc) {
      await mongo_db.collection(col).updateOne({ _id: new ObjectId(id) }, { $set: { is_deleted: true } });
      return res.json({ success: true, method: "SOFT_DELETE" });
    }
    await mongo_db.collection(col).deleteOne({ _id: new ObjectId(id) });
    res.json({ success: true, method: "HARD_DELETE" });
  } catch (e) { next(e); }
};

// ─────────────────────────────────────────────────────────────
// NEO4J run a safe read Cypher query
// ─────────────────────────────────────────────────────────────
const neo4jRunQuery = async (req, res, next) => {
  try {
    const { cypher } = req.body;
    if (!cypher) return res.status(400).json({ success: false, error: "No Cypher query provided." });
    const upper = cypher.trim().toUpperCase();
    const writeKeywords = ["CREATE ","MERGE ","DELETE ","DETACH","SET ","REMOVE ","DROP "];
    if (writeKeywords.some(k => upper.includes(k))) {
      return res.status(403).json({ success: false, error: "Write operations are not allowed from the query console. Use the Phase 4 Cypher file for data loading." });
    }
    const start = Date.now();
    const rows  = await neo4j_db.read(cypher.substring(0, 2000));
    const ms    = Date.now() - start;
    res.json({ success: true, rows: rows.slice(0, 200), row_count: rows.length, execution_ms: ms });
  } catch (e) {
    res.status(400).json({ success: false, error: e.message });
  }
};

// ─────────────────────────────────────────────────────────────
// NEO4J get node labels and sample nodes
// ─────────────────────────────────────────────────────────────
const neo4jBrowseNodes = async (req, res, next) => {
  try {
    const label  = req.query.label || "";
    const limit  = Math.min(parseInt(req.query.limit) || 25, 100);
    const offset = parseInt(req.query.offset) || 0;

    const [labels, nodes] = await Promise.all([
      neo4j_db.read("MATCH (n) RETURN DISTINCT labels(n)[0] AS label, count(n) AS count ORDER BY count DESC"),
      label
        ? neo4j_db.read(`MATCH (n:\`${label}\`) RETURN n SKIP ${offset} LIMIT ${limit}`)
        : neo4j_db.read(`MATCH (n) RETURN n SKIP ${offset} LIMIT ${limit}`),
    ]);

    // Flatten node properties
    const flatNodes = nodes.map(r => {
      const n = r.n;
      if (n && n.properties) return { _labels: n.labels || [], ...n.properties };
      return r;
    });

    res.json({ success: true, labels, nodes: flatNodes, limit, offset });
  } catch (e) { next(e); }
};

// ─────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────
function isValidIdentifier(s) {
  return s && /^[a-zA-Z0-9_]+$/.test(s) && s.length <= 64;
}

const PROTECTED_TABLES = ["request_status_history"];

async function getPrimaryKey(table) {
  const db = process.env.MYSQL_DATABASE || "group19";
  const [rows] = await mysql_db.getPool().execute(
    `SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE
     WHERE TABLE_SCHEMA=? AND TABLE_NAME=? AND CONSTRAINT_NAME='PRIMARY' LIMIT 1`, [db, table]
  );
  return rows.length ? rows[0].COLUMN_NAME : null;
}

module.exports = {
  mysqlListTables, mysqlGetColumns, mysqlGetRows, mysqlInsertRow, mysqlUpdateRow, mysqlDeleteRow, mysqlRunQuery,
  mongoListCollections, mongoGetDocuments, mongoGetDocument, mongoUpdateDocument, mongoDeleteDocument,
  neo4jRunQuery, neo4jBrowseNodes,
};
