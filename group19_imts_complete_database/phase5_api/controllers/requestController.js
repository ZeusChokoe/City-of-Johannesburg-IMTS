// controllers/requestController.js — Group 19 IMTS
const { mysql_db, mongo_db, neo4j_db } = require("../config/db");
const neo4jInt = (n) => require("neo4j-driver").int(n);

const listRequests = async (req, res, next) => {
  const { district_id, priority, category, limit = 50, offset = 0 } = req.query;
  try {
    let sql = "SELECT * FROM v_open_requests WHERE 1=1";
    const params = [];
    if (priority) { sql += " AND priority = ?"; params.push(priority.toUpperCase()); }
    if (category) { sql += " AND category = ?"; params.push(category.toUpperCase()); }
    sql += " ORDER BY urgency_score DESC LIMIT " + parseInt(limit) + " OFFSET " + parseInt(offset);
    const [rows] = await mysql_db.getPool().execute(sql, params);
    res.json({ success: true, count: rows.length, data: rows });
  } catch (e) { next(e); }
};

const getRequest = async (req, res, next) => {
  const id = parseInt(req.params.id);
  if (isNaN(id)) return res.status(400).json({ success: false, error: "Invalid ID." });
  try {
    const [[rows], logs, graph] = await Promise.all([
      mysql_db.getPool().execute(
        "SELECT mr.*, d.district_name, a.asset_code, a.asset_name, fn_days_open(mr.request_id) AS days_open, fn_get_priority_score(mr.request_id) AS urgency_score " +
        "FROM maintenance_requests mr JOIN districts d ON d.district_id=mr.district_id LEFT JOIN assets a ON a.asset_id=mr.asset_id WHERE mr.request_id=?", [id]
      ),
      mongo_db.collection("maintenance_logs").find({ mysql_request_id: id }).sort({ logged_at: -1 }).limit(10).toArray(),
      neo4j_db.read(
        "MATCH (r:MaintenanceRequest {mysql_request_id:$id})-[:REPORTED_FOR]->(a:Asset)-[:CONNECTS_TO|DEPENDS_ON*1..2]-(n:Asset) " +
        "RETURN DISTINCT n.asset_code AS code, n.name AS name, n.condition_rating AS condition, n.status AS status LIMIT 8",
        { id: neo4jInt(id) }
      ).catch(() => []),
    ]);
    if (!rows || !rows[0]) return res.status(404).json({ success: false, error: "Request " + id + " not found." });
    const r = rows[0];
    res.json({ success: true, data: { ...r, field_logs: logs, network_neighbours: graph } });
  } catch (e) { next(e); }
};

const getImpactAnalysis = async (req, res, next) => {
  const id = parseInt(req.params.id);
  if (isNaN(id)) return res.status(400).json({ success: false, error: "Invalid ID." });
  try {
    const data = await neo4j_db.read(
      "MATCH (r:MaintenanceRequest {mysql_request_id:$id})-[:REPORTED_FOR]->(src:Asset) " +
      "MATCH path=(src)-[:CONNECTS_TO|FEEDS_INTO*1..6]->(a:Asset) WHERE a.mysql_asset_id<>src.mysql_asset_id " +
      "WITH a, min(length(path)) AS hops OPTIONAL MATCH (a)-[:LOCATED_IN]->(d:District) " +
      "RETURN a.asset_code AS code, a.name AS name, a.asset_type_code AS type, a.condition_rating AS condition, a.status AS status, d.name AS district, hops ORDER BY hops, a.condition_rating",
      { id: neo4jInt(id) }
    ).catch(() => []);
    res.json({ success: true, request_id: id, total_affected: data.length, data });
  } catch (e) { next(e); }
};

const submitRequest = async (req, res, next) => {
  const { asset_id, district_id, reported_by_name, reported_by_phone, description, category, latitude, longitude, priority } = req.body;
  try {
    const out = await mysql_db.callProcedureWithOuts(
      "CALL sp_submit_maintenance_request(?,?,?,?,?,?,?,?,?,?,?,@new_request_id,@request_reference)",
      [asset_id||null, district_id, reported_by_name||null, reported_by_phone||null, null, null, description, category, latitude||null, longitude||null, priority||"MEDIUM"],
      ["new_request_id","request_reference"]
    );
    await mongo_db.collection("maintenance_logs").insertOne({
      mysql_request_id: out.new_request_id, mysql_work_order_id: null, mysql_asset_id: asset_id||null,
      asset_type_code: "GENERAL", district_id, technician_employee_number: "PUBLIC",
      log_type: "ARRIVAL", logged_at: new Date(), notes: description, photos: [], tools_used: [], asset_readings: {},
    }).catch(() => {});
    res.status(201).json({ success: true, data: { request_id: out.new_request_id, reference: out.request_reference } });
  } catch (e) { next(e); }
};

module.exports = { listRequests, getRequest, getImpactAnalysis, submitRequest };
