// =============================================================================
// controllers/requestController.js
// Maintenance Request endpoints — the highest-traffic integration point.
//
// Every endpoint in this controller demonstrates polyglot persistence:
//   MySQL  → authoritative structured data, stored procedure calls
//   MongoDB→ rich operational logs, unstructured field data
//   Neo4j  → relationship traversal, impact analysis
//
// GA9 — INDEPENDENT LEARNING ANNOTATION:
//   The pattern used throughout this controller is called the "application-side
//   join" or "data aggregation at the service layer". It is the standard
//   approach in microservice and polyglot architectures. The alternative —
//   trying to JOIN across databases — does not exist at the database layer.
//   Understanding why this is an acceptable tradeoff (eventual consistency,
//   read performance, schema flexibility) requires reading beyond textbooks:
//   Martin Fowler's "NoSQL Distilled" and the CAP theorem papers are the
//   correct next sources.
// =============================================================================

const { mysql_db, mongo_db, neo4j_db } = require("../config/db");
const { ObjectId } = require("mongodb");


// =============================================================================
// POST /api/v1/requests
// Submit a new maintenance request.
//
// Integration flow:
//   1. MySQL  → call sp_submit_maintenance_request() — creates the record,
//               returns request_id and reference via OUT vars
//   2. MongoDB→ insert a maintenance_log document with full field data
//   3. Neo4j  → create/link MaintenanceRequest node to Asset node
//   4. MySQL  → update the request with the MongoDB document _id
//
// This four-step write sequence is the core polyglot insert pattern.
// Each database receives the data it is best suited to store.
// =============================================================================
const submitRequest = async (req, res, next) => {
  const {
    asset_id, district_id,
    reported_by_name, reported_by_phone, reported_by_email,
    reported_by_staff_id, description, category,
    latitude, longitude, priority,
  } = req.body;

  let newRequestId  = null;
  let requestRef    = null;
  let mongoLogId    = null;

  try {
    // -------------------------------------------------------------------------
    // STEP 1: MySQL — call stored procedure (Phase 2)
    // Uses session variable pattern for OUT parameters.
    // -------------------------------------------------------------------------
    const outVars = await mysql_db.callProcedureWithOuts(
      `CALL sp_submit_maintenance_request(
        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        @new_request_id, @request_reference
      )`,
      [
        asset_id || null, district_id,
        reported_by_name || null, reported_by_phone || null,
        reported_by_email || null, reported_by_staff_id || null,
        description, category, latitude || null, longitude || null,
        priority || "MEDIUM",
      ],
      ["new_request_id", "request_reference"]
    );

    newRequestId = outVars.new_request_id;
    requestRef   = outVars.request_reference;

    if (!newRequestId) {
      const err = new Error("Stored procedure did not return a request ID.");
      err.status = 500;
      throw err;
    }

    // -------------------------------------------------------------------------
    // STEP 2: MongoDB — create maintenance log document
    // Stores the rich unstructured field data that MySQL does not hold.
    // -------------------------------------------------------------------------
    const logDoc = {
      mysql_request_id:            newRequestId,
      mysql_work_order_id:         null,        // no work order yet
      mysql_asset_id:              asset_id || null,
      asset_type_code:             mapCategoryToAssetType(category),
      district_id:                 district_id,
      technician_employee_number:  reported_by_staff_id ? `EMP-${String(reported_by_staff_id).padStart(4, "0")}` : "PUBLIC",
      log_type:                    "ARRIVAL",   // represents the initial report
      logged_at:                   new Date(),
      location: (latitude && longitude) ? {
        type:        "Point",
        coordinates: [parseFloat(longitude), parseFloat(latitude)],
      } : null,
      notes:       description,
      photos:      [],
      tools_used:  [],
      asset_readings: {},
      source:      reported_by_staff_id ? "STAFF_REPORT" : "PUBLIC_REPORT",
    };

    const mongoResult = await mongo_db.collection("maintenance_logs").insertOne(logDoc);
    mongoLogId = mongoResult.insertedId.toString();

    // -------------------------------------------------------------------------
    // STEP 3: Neo4j — create MaintenanceRequest node and link to Asset
    // -------------------------------------------------------------------------
    const cypher = `
      MERGE (r:MaintenanceRequest {mysql_request_id: $requestId})
      SET   r.reference   = $reference,
            r.category    = $category,
            r.priority    = $priority,
            r.status      = 'SUBMITTED',
            r.reported_at = datetime()
      WITH r
      OPTIONAL MATCH (a:Asset {mysql_asset_id: $assetId})
      FOREACH (_ IN CASE WHEN a IS NOT NULL THEN [1] ELSE [] END |
        MERGE (r)-[:REPORTED_FOR {reported_at: datetime()}]->(a)
      )
      RETURN r.reference AS ref
    `;
    await neo4j_db.write(cypher, {
      requestId: neo4jInt(newRequestId),
      reference: requestRef,
      category,
      priority:  priority || "MEDIUM",
      assetId:   asset_id ? neo4jInt(asset_id) : null,
    });

    // -------------------------------------------------------------------------
    // STEP 4: MySQL — store the MongoDB _id as the cross-system reference
    // -------------------------------------------------------------------------
    const pool = mysql_db.getPool();
    await pool.execute(
      "UPDATE maintenance_requests SET mongo_log_id = ? WHERE request_id = ?",
      [mongoLogId, newRequestId]
    );

    // -------------------------------------------------------------------------
    // RESPONSE
    // -------------------------------------------------------------------------
    return res.status(201).json({
      success:   true,
      message:   "Maintenance request submitted successfully.",
      data: {
        request_id:        newRequestId,
        request_reference: requestRef,
        mongo_log_id:      mongoLogId,
        status:            "SUBMITTED",
      },
    });

  } catch (err) {
    // Attempt cleanup: if MySQL succeeded but MongoDB/Neo4j failed,
    // mark the MySQL record as CANCELLED to avoid orphaned records.
    if (newRequestId && !mongoLogId) {
      try {
        const pool = mysql_db.getPool();
        await pool.execute(
          "UPDATE maintenance_requests SET status = 'CANCELLED' WHERE request_id = ?",
          [newRequestId]
        );
      } catch (_) { /* best-effort cleanup */ }
    }
    next(err);
  }
};


// =============================================================================
// GET /api/v1/requests/:id
// Fetch a single maintenance request — merged from all three databases.
//
// Integration flow:
//   1. MySQL  → structured request record + work order summary
//   2. MongoDB→ maintenance logs for this request
//   3. Neo4j  → graph neighbourhood: what other assets are connected to
//               the reported asset, and are any also degraded?
//
// GA9 — Adaptability: The response merges three result sets in application
//   memory. This is the "API Composition" pattern from microservices
//   architecture (Richardson, "Microservices Patterns", Chapter 4).
//   The same pattern is used by any API gateway that aggregates multiple
//   downstream services — understanding it here transfers directly to
//   AWS API Gateway, Kong, and Netflix Zuul.
// =============================================================================
const getRequest = async (req, res, next) => {
  const requestId = parseInt(req.params.id);
  if (isNaN(requestId)) {
    return res.status(400).json({ success: false, error: "Invalid request ID." });
  }

  try {
    // -------------------------------------------------------------------------
    // Run all three database queries in parallel — they are independent.
    // Promise.all() gives us concurrent I/O, not sequential. Total latency =
    // max(mysqlLatency, mongoLatency, neo4jLatency) not their sum.
    // GA9 — Staying Current: Promise.all() is the non-blocking equivalent of
    //   parallel query execution. In a synchronous language this would require
    //   threads. Node.js achieves this with a single thread via the event loop.
    // -------------------------------------------------------------------------
    const [mysqlResult, mongoLogs, graphData] = await Promise.all([

      // MySQL: request + work orders + status history
      mysql_db.getPool().execute(`
        SELECT
          mr.*,
          d.district_name,
          a.asset_code,
          a.asset_name,
          a.condition_rating   AS asset_condition,
          at.type_name         AS asset_type_name,
          at.criticality_level AS asset_criticality,
          fn_days_open(mr.request_id)          AS days_open,
          fn_get_priority_score(mr.request_id) AS urgency_score
        FROM maintenance_requests mr
        JOIN  districts  d  ON d.district_id   = mr.district_id
        LEFT JOIN assets  a  ON a.asset_id      = mr.asset_id
        LEFT JOIN asset_types at ON at.asset_type_id = a.asset_type_id
        WHERE mr.request_id = ?
      `, [requestId]),

      // MongoDB: all logs for this request, newest first
      mongo_db.collection("maintenance_logs")
        .find(
          { mysql_request_id: requestId },
          { projection: { log_type: 1, logged_at: 1, notes: 1, asset_readings: 1, technician_employee_number: 1 } }
        )
        .sort({ logged_at: -1 })
        .toArray(),

      // Neo4j: assets connected to the reported asset (impact neighbourhood)
      neo4j_db.read(`
        MATCH (r:MaintenanceRequest {mysql_request_id: $requestId})
              -[:REPORTED_FOR]->(source:Asset)
              -[:CONNECTS_TO|DEPENDS_ON|ADJACENT_TO*1..3]-(neighbour:Asset)
        WHERE neighbour.mysql_asset_id <> source.mysql_asset_id
        RETURN DISTINCT
          neighbour.asset_code       AS asset_code,
          neighbour.name             AS name,
          neighbour.asset_type_code  AS type,
          neighbour.condition_rating AS condition,
          neighbour.status           AS status
        ORDER BY neighbour.condition_rating ASC
        LIMIT 10
      `, { requestId: neo4jInt(requestId) }),
    ]);

    const [rows] = mysqlResult;
    if (!rows || rows.length === 0) {
      return res.status(404).json({ success: false, error: `Request ID ${requestId} not found.` });
    }

    const request = rows[0];

    // -------------------------------------------------------------------------
    // APPLICATION-SIDE MERGE: combine all three sources into one response
    // -------------------------------------------------------------------------
    return res.json({
      success: true,
      data: {
        // MySQL structured data
        request_id:        request.request_id,
        reference:         request.request_reference,
        category:          request.category,
        priority:          request.priority,
        status:            request.status,
        description:       request.description,
        reported_at:       request.reported_at,
        resolved_at:       request.resolved_at,
        days_open:         request.days_open,
        urgency_score:     request.urgency_score,
        district:          request.district_name,
        asset: request.asset_code ? {
          code:        request.asset_code,
          name:        request.asset_name,
          type:        request.asset_type_name,
          criticality: request.asset_criticality,
          condition:   request.asset_condition,
        } : null,
        // MongoDB operational logs
        field_logs:        mongoLogs,
        // Neo4j network context
        network_neighbours: graphData,
      },
    });

  } catch (err) {
    next(err);
  }
};


// =============================================================================
// GET /api/v1/requests
// List open requests from the MySQL view (v_open_requests from Phase 2).
// Supports ?district_id=, ?priority=, ?category= query params.
// =============================================================================
const listRequests = async (req, res, next) => {
  const { district_id, priority, category, limit = 50, offset = 0 } = req.query;

  try {
    let sql    = "SELECT * FROM v_open_requests WHERE 1=1";
    const params = [];

    if (district_id) { sql += " AND district_name = (SELECT district_name FROM districts WHERE district_id = ?)"; params.push(district_id); }
    if (priority)    { sql += " AND priority = ?"; params.push(priority.toUpperCase()); }
    if (category)    { sql += " AND category = ?"; params.push(category.toUpperCase()); }

    sql += " ORDER BY urgency_score DESC, reported_at ASC";
    sql += ` LIMIT ${parseInt(limit)} OFFSET ${parseInt(offset)}`;

    const [rows] = await mysql_db.getPool().execute(sql, params);

    return res.json({
      success: true,
      count:   rows.length,
      data:    rows,
    });
  } catch (err) {
    next(err);
  }
};


// =============================================================================
// GET /api/v1/requests/:id/impact
// Graph-only endpoint: traverses the Neo4j network from the reported asset
// and returns the full failure cascade up to 6 hops.
// This is the endpoint that powers the "Impact Map" dashboard panel.
//
// GA9 — Interest & Curiosity: This query cannot be expressed in MySQL or
//   MongoDB. It is the definitive justification for Neo4j in this architecture.
//   Without the graph database, answering "what else fails if this pipe bursts?"
//   requires application-layer recursion with unbounded complexity.
// =============================================================================
const getImpactAnalysis = async (req, res, next) => {
  const requestId = parseInt(req.params.id);
  if (isNaN(requestId)) {
    return res.status(400).json({ success: false, error: "Invalid request ID." });
  }

  try {
    const cascadeResults = await neo4j_db.read(`
      MATCH (r:MaintenanceRequest {mysql_request_id: $requestId})
            -[:REPORTED_FOR]->(source:Asset)
      MATCH path = (source)-[:CONNECTS_TO|FEEDS_INTO*1..6]->(affected:Asset)
      WHERE affected.mysql_asset_id <> source.mysql_asset_id
      WITH affected,
           min(length(path))                           AS min_hops,
           collect(DISTINCT [node IN nodes(path)
                   | node.asset_code])[0]              AS shortest_path
      OPTIONAL MATCH (affected)-[:LOCATED_IN]->(d:District)
      RETURN
        affected.asset_code        AS asset_code,
        affected.name              AS name,
        affected.asset_type_code   AS type,
        affected.condition_rating  AS condition,
        affected.status            AS status,
        d.name                     AS district,
        min_hops                   AS hops_from_failure,
        shortest_path              AS connection_path,
        affected.replacement_cost_zar AS replacement_cost_zar
      ORDER BY min_hops ASC, affected.condition_rating ASC
    `, { requestId: neo4jInt(requestId) });

    // Enrich with MySQL asset detail for any degraded/failed assets in the cascade
    const degradedIds = cascadeResults
      .filter(r => r.condition <= 5)
      .map(r => r.asset_code);

    let mysqlEnrichment = [];
    if (degradedIds.length > 0) {
      const placeholders = degradedIds.map(() => "?").join(",");
      const [rows] = await mysql_db.getPool().execute(
        `SELECT asset_code, asset_name, status, last_maintained_date, next_inspection_date
         FROM assets WHERE asset_code IN (${placeholders})`,
        degradedIds
      );
      mysqlEnrichment = rows;
    }

    const enrichmentMap = Object.fromEntries(
      mysqlEnrichment.map(r => [r.asset_code, r])
    );

    const enriched = cascadeResults.map(r => ({
      ...r,
      mysql_detail: enrichmentMap[r.asset_code] || null,
    }));

    return res.json({
      success:       true,
      request_id:    requestId,
      total_affected: cascadeResults.length,
      critical_count: cascadeResults.filter(r => r.condition <= 4).length,
      data:          enriched,
    });

  } catch (err) {
    next(err);
  }
};


// =============================================================================
// HELPERS
// =============================================================================

// Neo4j requires its own Integer type for integer parameters
const neo4jInt = (n) => require("neo4j-driver").int(n);

// Maps request category to an asset_type_code for the MongoDB log document
const mapCategoryToAssetType = (category) => {
  const map = {
    BURST_PIPE:          "WATER_PIPE",
    POTHOLE:             "POTHOLE",
    FAULTY_STREETLIGHT:  "STREETLIGHT",
    SEWER_BLOCKAGE:      "SEWER_MAIN",
    ROAD_SURFACE_DAMAGE: "ROAD_SURFACE",
    ELECTRICAL_FAULT:    "ELECTRICAL_SUBSTATION",
    STRUCTURAL_DAMAGE:   "BRIDGE",
    OTHER:               "GENERAL",
  };
  return map[category] || "GENERAL";
};


module.exports = { submitRequest, getRequest, listRequests, getImpactAnalysis };
