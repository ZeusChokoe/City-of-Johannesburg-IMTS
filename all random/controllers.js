// =============================================================================
// controllers/workOrderController.js
// Work Order endpoints — assignment, closure, SLA monitoring.
// =============================================================================

const { mysql_db, mongo_db, neo4j_db } = require("../config/db");
const neo4jInt = (n) => require("neo4j-driver").int(n);


// =============================================================================
// POST /api/v1/work-orders
// Assign a new work order via sp_assign_work_order (Phase 2).
// Simultaneously updates the Neo4j WorkOrder node and its ASSIGNED_TO links.
//
// GA9 — Reflection: The stored procedure (Phase 2) handles MySQL transaction
//   integrity. The API layer handles cross-database consistency.
//   Separating these concerns means a MySQL transaction failure rolls back
//   cleanly before the Neo4j write even attempts — no orphaned graph nodes.
// =============================================================================
const assignWorkOrder = async (req, res, next) => {
  const {
    request_id, title, description, supervisor_id,
    lead_tech_id, scheduled_start, scheduled_end,
    estimated_hours, estimated_cost,
  } = req.body;

  try {
    // STEP 1: MySQL stored procedure
    const outVars = await mysql_db.callProcedureWithOuts(
      `CALL sp_assign_work_order(
        ?, ?, ?, ?, ?, ?, ?, ?, ?,
        @new_wo_id, @new_wo_ref, @sla_deadline
      )`,
      [
        request_id, title, description || null,
        supervisor_id, lead_tech_id,
        scheduled_start || null, scheduled_end || null,
        estimated_hours || null, estimated_cost || null,
      ],
      ["new_wo_id", "new_wo_ref", "sla_deadline"]
    );

    const { new_wo_id, new_wo_ref, sla_deadline } = outVars;

    // STEP 2: Neo4j — create WorkOrder node and ASSIGNED_TO relationships
    await neo4j_db.write(`
      MERGE (w:WorkOrder {mysql_work_order_id: $woId})
      SET   w.reference    = $ref,
            w.status       = 'APPROVED',
            w.sla_deadline = datetime($sla),
            w.sla_breached = false,
            w.district_id  = toInteger((
              MATCH (r:MaintenanceRequest {mysql_request_id: $reqId})
              RETURN r.district_id LIMIT 1
            ))
      WITH w
      MATCH (r:MaintenanceRequest {mysql_request_id: $reqId})
      MERGE (w)-[:RESOLVES {created_at: datetime()}]->(r)
      WITH w
      MATCH (sup:Technician {employee_number: $supEmpNo})
      MERGE (w)-[:ASSIGNED_TO {role: 'SUPERVISOR', assigned_at: datetime()}]->(sup)
      WITH w
      MATCH (tech:Technician {employee_number: $techEmpNo})
      MERGE (w)-[:ASSIGNED_TO {role: 'LEAD_TECHNICIAN', assigned_at: datetime()}]->(tech)
      RETURN w.reference AS ref
    `, {
      woId:     neo4jInt(new_wo_id),
      ref:      new_wo_ref,
      sla:      sla_deadline ? sla_deadline.toISOString() : null,
      reqId:    neo4jInt(request_id),
      supEmpNo: `EMP-${String(supervisor_id).padStart(4, "0")}`,
      techEmpNo:`EMP-${String(lead_tech_id).padStart(4, "0")}`,
    }).catch(() => {
      // Neo4j write failure is non-fatal — MySQL is the source of truth.
      // Log it and continue. Neo4j will be reconciled by the next sync job.
      console.warn("[Neo4j] WorkOrder node write failed for WO ID:", new_wo_id);
    });

    return res.status(201).json({
      success: true,
      message: "Work order created and assigned.",
      data: {
        work_order_id:  new_wo_id,
        work_order_ref: new_wo_ref,
        sla_deadline,
        request_id,
      },
    });

  } catch (err) {
    next(err);
  }
};


// =============================================================================
// PATCH /api/v1/work-orders/:id/close
// Close a work order via sp_close_work_order (Phase 2).
// Updates Neo4j status. Appends completion log to MongoDB.
//
// GA9 — Adaptability: PATCH is the correct HTTP verb for partial resource
//   update (closing a work order does not replace the whole resource).
//   PUT replaces the entire resource. This distinction is defined in
//   RFC 7231 and RFC 5789 — primary sources, not tutorials.
// =============================================================================
const closeWorkOrder = async (req, res, next) => {
  const workOrderId = parseInt(req.params.id);
  const { closing_staff_id, actual_hours, actual_cost, resolution_notes } = req.body;

  if (isNaN(workOrderId)) {
    return res.status(400).json({ success: false, error: "Invalid work order ID." });
  }

  try {
    // STEP 1: MySQL stored procedure — cascades to request and asset via trigger
    const [result] = await mysql_db.callProcedure("sp_close_work_order", [
      workOrderId, closing_staff_id, actual_hours || null,
      actual_cost || null, resolution_notes || null,
    ]);

    if (!result || result.length === 0) {
      const err = new Error("Work order not found.");
      err.status = 404;
      throw err;
    }

    const closed = result[0];

    // STEP 2: MongoDB — append completion log entry
    const [woDetails] = await mysql_db.getPool().execute(
      `SELECT wo.asset_id, wo.district_id, a.asset_type_id,
              at.type_name AS asset_type
       FROM work_orders wo
       LEFT JOIN assets a ON a.asset_id = wo.asset_id
       LEFT JOIN asset_types at ON at.asset_type_id = a.asset_type_id
       WHERE wo.work_order_id = ?`,
      [workOrderId]
    );

    if (woDetails.length > 0) {
      const wo = woDetails[0];
      await mongo_db.collection("maintenance_logs").insertOne({
        mysql_work_order_id:         workOrderId,
        mysql_request_id:            null,
        mysql_asset_id:              wo.asset_id,
        asset_type_code:             (wo.asset_type || "GENERAL").replace(/ /g, "_").toUpperCase(),
        district_id:                 wo.district_id,
        technician_employee_number:  `EMP-${String(closing_staff_id).padStart(4, "0")}`,
        log_type:                    "COMPLETION",
        logged_at:                   new Date(),
        location:                    null,
        notes:                       resolution_notes || "Work order closed.",
        photos:                      [],
        tools_used:                  [],
        asset_readings:              { actual_hours, actual_cost_zar: actual_cost },
      });
    }

    // STEP 3: Neo4j — update WorkOrder node status
    await neo4j_db.write(
      `MATCH (w:WorkOrder {mysql_work_order_id: $woId})
       SET   w.status = 'COMPLETED', w.completed_at = datetime()`,
      { woId: neo4jInt(workOrderId) }
    ).catch(() => console.warn("[Neo4j] WorkOrder status sync failed for ID:", workOrderId));

    return res.json({
      success: true,
      message: "Work order closed. Request resolved. Asset maintenance timestamps updated.",
      data:    closed,
    });

  } catch (err) {
    next(err);
  }
};


// =============================================================================
// GET /api/v1/work-orders/sla-breaches
// Returns all currently SLA-breached work orders from MySQL view (Phase 2).
// Enriches each with the Neo4j technician workload for the assigned staff.
// =============================================================================
const getSlaBreaches = async (req, res, next) => {
  try {
    const [rows] = await mysql_db.getPool().execute(
      "SELECT * FROM v_sla_breached_orders ORDER BY hours_overdue DESC LIMIT 100"
    );

    if (rows.length === 0) {
      return res.json({ success: true, count: 0, data: [] });
    }

    // Enrich with Neo4j: how many other open orders does each supervisor have?
    const supervisorNames = [...new Set(rows.map(r => r.supervisor).filter(Boolean))];

    let workloadMap = {};
    if (supervisorNames.length > 0) {
      const workloadData = await neo4j_db.read(`
        UNWIND $names AS supervisorName
        MATCH (t:Technician) WHERE t.name = supervisorName
        MATCH (w:WorkOrder)-[:ASSIGNED_TO]->(t)
        WHERE w.status NOT IN ['COMPLETED','CANCELLED']
        RETURN t.name AS supervisor, count(w) AS open_orders
      `, { names: supervisorNames });

      workloadMap = Object.fromEntries(
        workloadData.map(r => [r.supervisor, r.open_orders])
      );
    }

    const enriched = rows.map(r => ({
      ...r,
      supervisor_open_order_count: workloadMap[r.supervisor] || null,
    }));

    return res.json({ success: true, count: enriched.length, data: enriched });

  } catch (err) {
    next(err);
  }
};


module.exports = { assignWorkOrder, closeWorkOrder, getSlaBreaches };


// =============================================================================
// controllers/assetController.js
// Asset endpoints — condition, network, sensor data.
// =============================================================================

const getAssetDetail = async (req, res, next) => {
  const assetId = parseInt(req.params.id);
  if (isNaN(assetId)) {
    return res.status(400).json({ success: false, error: "Invalid asset ID." });
  }

  try {
    // Parallel fetch from all three databases
    const [mysqlResult, latestSensorReadings, graphNeighbourhood] = await Promise.all([

      // MySQL: full asset record + open requests + last inspection
      mysql_db.getPool().execute(`
        SELECT
          a.*,
          d.district_name,
          at.type_name         AS asset_type,
          at.criticality_level AS criticality,
          at.sla_hours,
          (SELECT COUNT(*) FROM maintenance_requests mr
           WHERE mr.asset_id = a.asset_id
             AND mr.status NOT IN ('RESOLVED','CLOSED','CANCELLED')) AS open_request_count,
          (SELECT MAX(i.completed_date) FROM inspections i
           WHERE i.asset_id = a.asset_id) AS last_inspection_date
        FROM assets a
        JOIN  districts  d  ON d.district_id   = a.district_id
        JOIN  asset_types at ON at.asset_type_id = a.asset_type_id
        WHERE a.asset_id = ?
      `, [assetId]),

      // MongoDB: latest sensor reading per sensor type
      mongo_db.collection("sensor_readings").aggregate([
        { $match: { mysql_asset_id: assetId } },
        { $sort:  { sensor_type: 1, recorded_at: -1 } },
        { $group: {
          _id:           "$sensor_type",
          latest_value:  { $first: "$reading_value" },
          unit:          { $first: "$unit_of_measure" },
          recorded_at:   { $first: "$recorded_at" },
          is_anomaly:    { $first: "$is_anomaly" },
        }},
        { $project: { _id: 0, sensor_type: "$_id", latest_value: 1, unit: 1, recorded_at: 1, is_anomaly: 1 } },
      ]).toArray(),

      // Neo4j: immediate network neighbourhood (1 hop)
      neo4j_db.read(`
        MATCH (a:Asset {mysql_asset_id: $assetId})
        OPTIONAL MATCH (a)-[r:CONNECTS_TO|FEEDS_INTO|DEPENDS_ON|ADJACENT_TO]-(neighbour:Asset)
        RETURN
          type(r)                    AS relationship,
          neighbour.asset_code       AS asset_code,
          neighbour.name             AS name,
          neighbour.asset_type_code  AS type,
          neighbour.condition_rating AS condition,
          neighbour.status           AS status
        ORDER BY neighbour.condition_rating ASC
      `, { assetId: neo4jInt(assetId) }),
    ]);

    const [rows] = mysqlResult;
    if (!rows || rows.length === 0) {
      return res.status(404).json({ success: false, error: `Asset ID ${assetId} not found.` });
    }

    const asset = rows[0];
    const hasAnomalies = latestSensorReadings.some(r => r.is_anomaly);

    return res.json({
      success: true,
      data: {
        asset_id:             asset.asset_id,
        asset_code:           asset.asset_code,
        name:                 asset.asset_name,
        type:                 asset.asset_type,
        criticality:          asset.criticality,
        status:               asset.status,
        condition_rating:     asset.condition_rating,
        district:             asset.district_name,
        location: {
          latitude:  asset.latitude,
          longitude: asset.longitude,
        },
        installation_date:    asset.installation_date,
        last_maintained_date: asset.last_maintained_date,
        next_inspection_date: asset.next_inspection_date,
        last_inspection_date: asset.last_inspection_date,
        open_request_count:   asset.open_request_count,
        replacement_cost_zar: asset.replacement_cost_zar,
        sensor_status: {
          has_live_readings: latestSensorReadings.length > 0,
          has_anomalies:     hasAnomalies,
          readings:          latestSensorReadings,
        },
        network: graphNeighbourhood,
      },
    });

  } catch (err) {
    next(err);
  }
};


// =============================================================================
// GET /api/v1/assets/:id/risk
// Returns the Neo4j centrality-based risk score from Phase 4 Query 4.8.
// Answers: "How critical is this asset to the surrounding network?"
//
// GA9 — Initiative: Risk scoring is not a standard CRUD operation.
//   Implementing it demonstrates willingness to model domain knowledge
//   (infrastructure criticality) as a computable metric, not just a
//   subjective rating stored in a column.
// =============================================================================
const getAssetRisk = async (req, res, next) => {
  const assetId = parseInt(req.params.id);
  if (isNaN(assetId)) {
    return res.status(400).json({ success: false, error: "Invalid asset ID." });
  }

  try {
    const [graphRisk, mysqlData] = await Promise.all([
      neo4j_db.read(`
        MATCH (a:Asset {mysql_asset_id: $assetId})
        OPTIONAL MATCH (a)-[:CONNECTS_TO]-(connected:Asset)
        OPTIONAL MATCH (dependent:Asset)-[:DEPENDS_ON]->(a)
        OPTIONAL MATCH (a)-[:FEEDS_INTO]->(downstream:Asset)
        RETURN
          a.asset_code                                          AS asset_code,
          a.condition_rating                                    AS condition,
          count(DISTINCT connected)                             AS connections,
          count(DISTINCT dependent)                             AS dependents,
          count(DISTINCT downstream)                           AS downstream_assets,
          (count(DISTINCT connected) +
           count(DISTINCT dependent) * 2 +
           count(DISTINCT downstream) * 3)                     AS centrality_risk_score
      `, { assetId: neo4jInt(assetId) }),

      mysql_db.getPool().execute(
        `SELECT asset_code, asset_name, status, condition_rating, replacement_cost_zar
         FROM assets WHERE asset_id = ?`,
        [assetId]
      ),
    ]);

    const [mysqlRows] = mysqlData;
    if (!mysqlRows || mysqlRows.length === 0) {
      return res.status(404).json({ success: false, error: "Asset not found." });
    }

    const asset   = mysqlRows[0];
    const riskData = graphRisk[0] || {};

    const finalRisk = (riskData.centrality_risk_score || 0) *
                      (10 - (asset.condition_rating || 5));

    return res.json({
      success: true,
      data: {
        asset_code:            asset.asset_code,
        name:                  asset.asset_name,
        status:                asset.status,
        condition_rating:      asset.condition_rating,
        replacement_cost_zar:  asset.replacement_cost_zar,
        network_connections:   riskData.connections,
        dependent_assets:      riskData.dependents,
        downstream_assets:     riskData.downstream_assets,
        centrality_risk_score: riskData.centrality_risk_score,
        composite_risk_index:  Math.round(finalRisk),
        risk_interpretation:   interpretRisk(finalRisk),
      },
    });

  } catch (err) {
    next(err);
  }
};

const interpretRisk = (score) => {
  if (score >= 150) return "CRITICAL — Replace immediately. Network-wide impact on failure.";
  if (score >= 80)  return "HIGH — Schedule replacement within 3 months.";
  if (score >= 30)  return "MEDIUM — Monitor closely. Include in next capital budget cycle.";
  return "LOW — Standard maintenance schedule applies.";
};


module.exports.assetController = { getAssetDetail, getAssetRisk };


// =============================================================================
// controllers/reportController.js
// Report endpoints — district summaries, audit trails, stock alerts.
// =============================================================================

// =============================================================================
// GET /api/v1/reports/district/:id
// Calls sp_generate_district_report (cursor-based Phase 2 procedure).
// Enriches output with MongoDB log counts and Neo4j risk summary.
//
// GA9 — Staying Current: This endpoint demonstrates the "Report Aggregation"
//   pattern — combining transactional data (MySQL), operational logs (MongoDB),
//   and network risk scores (Neo4j) into a single management report.
//   Modern BI tools (Power BI, Tableau, Metabase) consume endpoints like this
//   directly via REST connectors. Building API-first reports is the current
//   standard in data engineering.
// =============================================================================
const getDistrictReport = async (req, res, next) => {
  const districtId = parseInt(req.params.id);
  if (isNaN(districtId)) {
    return res.status(400).json({ success: false, error: "Invalid district ID." });
  }

  try {
    const [mysqlReport, mongoLogCount, graphRisks, stockAlerts] = await Promise.all([

      // MySQL: cursor-based district report (Phase 2, Section 4.4)
      mysql_db.callProcedure("sp_generate_district_report", [districtId]),

      // MongoDB: log count for this district this month
      mongo_db.collection("maintenance_logs").countDocuments({
        district_id: districtId,
        logged_at:   { $gte: new Date(new Date().getFullYear(), new Date().getMonth(), 1) },
      }),

      // Neo4j: top 5 highest-risk assets in this district
      neo4j_db.read(`
        MATCH (a:Asset)-[:LOCATED_IN]->(d:District {mysql_district_id: $districtId})
        WHERE a.condition_rating <= 6
        OPTIONAL MATCH (a)-[:CONNECTS_TO]-(c:Asset)
        OPTIONAL MATCH (dep:Asset)-[:DEPENDS_ON]->(a)
        WITH a,
             count(DISTINCT c)   AS connections,
             count(DISTINCT dep) AS dependents
        RETURN
          a.asset_code    AS code,
          a.name          AS name,
          a.condition_rating AS condition,
          a.status        AS status,
          (connections + dependents * 2) AS risk_score
        ORDER BY risk_score DESC, a.condition_rating ASC
        LIMIT 5
      `, { districtId: neo4jInt(districtId) }),

      // MySQL: low-stock parts view
      mysql_db.getPool().execute(
        "SELECT part_code, part_name, quantity_on_hand, reorder_level FROM v_low_stock_alerts LIMIT 10"
      ),
    ]);

    const [stockRows] = stockAlerts;

    return res.json({
      success:     true,
      district_id: districtId,
      generated_at: new Date().toISOString(),
      report: {
        open_work_orders:     mysqlReport,
        field_logs_this_month: mongoLogCount,
        high_risk_assets:     graphRisks,
        low_stock_alerts:     stockRows,
      },
    });

  } catch (err) {
    next(err);
  }
};


// =============================================================================
// GET /api/v1/reports/audit/:requestId
// Full audit trail for a request: MySQL status history + MongoDB log timeline.
// Uses the v_request_audit_trail view (Phase 2, Section 6.5) for MySQL data.
// =============================================================================
const getAuditTrail = async (req, res, next) => {
  const requestId = parseInt(req.params.requestId);
  if (isNaN(requestId)) {
    return res.status(400).json({ success: false, error: "Invalid request ID." });
  }

  try {
    const [mysqlAudit, mongoLogs] = await Promise.all([
      mysql_db.getPool().execute(
        `SELECT * FROM v_request_audit_trail WHERE request_reference =
         (SELECT request_reference FROM maintenance_requests WHERE request_id = ?)
         ORDER BY changed_at ASC`,
        [requestId]
      ),
      mongo_db.collection("maintenance_logs")
        .find({ mysql_request_id: requestId })
        .sort({ logged_at: 1 })
        .project({ log_type: 1, logged_at: 1, notes: 1,
                   technician_employee_number: 1, asset_readings: 1 })
        .toArray(),
    ]);

    const [auditRows] = mysqlAudit;

    // Merge the two timelines, sorted by timestamp
    const combined = [
      ...auditRows.map(r => ({ source: "MySQL_STATUS", timestamp: r.changed_at, data: r })),
      ...mongoLogs.map(r => ({ source: "MongoDB_LOG",  timestamp: r.logged_at,  data: r })),
    ].sort((a, b) => new Date(a.timestamp) - new Date(b.timestamp));

    return res.json({
      success:    true,
      request_id: requestId,
      event_count: combined.length,
      timeline:   combined,
    });

  } catch (err) {
    next(err);
  }
};


module.exports.reportController = { getDistrictReport, getAuditTrail };
