// =============================================================================
// routes/index.js
// Central route registry — maps HTTP verbs + paths to controllers.
//
// Route design follows REST conventions:
//   GET    /resource        → list
//   GET    /resource/:id   → single record
//   POST   /resource        → create
//   PATCH  /resource/:id   → partial update
//   DELETE /resource/:id   → remove (not implemented — assets use archival)
//
// Validation chains use express-validator.
// handleValidation middleware fires after the chain and before the controller.
//
// GA9 — Staying Current: express-validator mirrors the HTML5 constraint
//   validation API and JSON Schema vocabulary. The same mental model applies
//   to Joi, Zod, Yup, and class-validator. Learning one transfers to all.
// =============================================================================

const { Router } = require("express");
const { body, param, query } = require("express-validator");
const { handleValidation }   = require("../middleware");

const requestCtrl  = require("../controllers/requestController");
const { assetController, reportController, assignWorkOrder,
        closeWorkOrder, getSlaBreaches } = (() => {
  const c = require("../controllers/controllers");
  return {
    assetController:  c.assetController,
    reportController: c.reportController,
    assignWorkOrder:  c.assignWorkOrder  || require("../controllers/controllers").assignWorkOrder,
    closeWorkOrder:   c.closeWorkOrder   || require("../controllers/controllers").closeWorkOrder,
    getSlaBreaches:   c.getSlaBreaches   || require("../controllers/controllers").getSlaBreaches,
  };
})();

// Re-export the work order controller functions directly
const woCtrl = require("../controllers/controllers");

const router = Router();


// =============================================================================
// HEALTH CHECK
// GET /api/v1/health
// Returns 200 if the API process is running. Does not probe databases.
// Use /api/v1/health/deep for full DB connectivity check.
// =============================================================================
router.get("/health", (req, res) => {
  res.json({
    success:  true,
    service:  "JHB IMTS API",
    version:  process.env.API_VERSION || "v1",
    env:      process.env.NODE_ENV,
    uptime_s: Math.floor(process.uptime()),
    timestamp: new Date().toISOString(),
  });
});

router.get("/health/deep", async (req, res, next) => {
  const { mysql_db, mongo_db, neo4j_db } = require("../config/db");
  const results = {};
  const checks  = [
    ["mysql",   async () => { const [r] = await mysql_db.getPool().execute("SELECT 1 AS ok"); return r[0].ok === 1; }],
    ["mongodb", async () => { await mongo_db.getDb().command({ ping: 1 }); return true; }],
    ["neo4j",   async () => { await neo4j_db.read("RETURN 1 AS ok"); return true; }],
  ];
  let allOk = true;
  for (const [name, fn] of checks) {
    try   { results[name] = await fn() ? "OK" : "FAIL"; }
    catch { results[name] = "UNREACHABLE"; allOk = false; }
  }
  res.status(allOk ? 200 : 503).json({ success: allOk, databases: results });
});


// =============================================================================
// MAINTENANCE REQUEST ROUTES
// =============================================================================

// POST /api/v1/requests — submit a new fault report
router.post("/requests",
  [
    body("district_id").isInt({ min: 1 }).withMessage("district_id must be a positive integer"),
    body("description").isLength({ min: 10, max: 5000 }).withMessage("description must be 10–5000 characters"),
    body("category").isIn([
      "BURST_PIPE","POTHOLE","FAULTY_STREETLIGHT","SEWER_BLOCKAGE",
      "ROAD_SURFACE_DAMAGE","ELECTRICAL_FAULT","STRUCTURAL_DAMAGE","OTHER",
    ]).withMessage("Invalid category"),
    body("priority").optional().isIn(["LOW","MEDIUM","HIGH","CRITICAL"]),
    body("asset_id").optional({ nullable: true }).isInt({ min: 1 }),
    body("latitude").optional({ nullable: true }).isFloat({ min: -35, max: -22 })
      .withMessage("latitude must be a valid South African coordinate"),
    body("longitude").optional({ nullable: true }).isFloat({ min: 16, max: 33 })
      .withMessage("longitude must be a valid South African coordinate"),
    body("reported_by_email").optional({ nullable: true }).isEmail(),
    body("reported_by_phone").optional({ nullable: true })
      .matches(/^\+27[0-9]{9}$/).withMessage("Phone must be in +27XXXXXXXXX format"),
  ],
  handleValidation,
  requestCtrl.submitRequest
);

// GET /api/v1/requests — list open requests
router.get("/requests",
  [
    query("district_id").optional().isInt({ min: 1 }),
    query("priority").optional().isIn(["LOW","MEDIUM","HIGH","CRITICAL"]),
    query("category").optional().isString(),
    query("limit").optional().isInt({ min: 1, max: 200 }),
    query("offset").optional().isInt({ min: 0 }),
  ],
  handleValidation,
  requestCtrl.listRequests
);

// GET /api/v1/requests/:id — single request merged from all three DBs
router.get("/requests/:id",
  [param("id").isInt({ min: 1 }).withMessage("id must be a positive integer")],
  handleValidation,
  requestCtrl.getRequest
);

// GET /api/v1/requests/:id/impact — Neo4j failure cascade analysis
router.get("/requests/:id/impact",
  [param("id").isInt({ min: 1 })],
  handleValidation,
  requestCtrl.getImpactAnalysis
);


// =============================================================================
// WORK ORDER ROUTES
// =============================================================================

// POST /api/v1/work-orders — create and assign a work order
router.post("/work-orders",
  [
    body("request_id").isInt({ min: 1 }).withMessage("request_id is required"),
    body("title").isLength({ min: 5, max: 300 }).withMessage("title must be 5–300 characters"),
    body("supervisor_id").isInt({ min: 1 }).withMessage("supervisor_id is required"),
    body("lead_tech_id").isInt({ min: 1 }).withMessage("lead_tech_id is required"),
    body("estimated_hours").optional().isFloat({ min: 0.5, max: 999 }),
    body("estimated_cost").optional().isFloat({ min: 0 }),
    body("scheduled_start").optional().isISO8601().withMessage("scheduled_start must be ISO 8601 datetime"),
    body("scheduled_end").optional().isISO8601(),
  ],
  handleValidation,
  woCtrl.assignWorkOrder
);

// PATCH /api/v1/work-orders/:id/close — close a work order
router.patch("/work-orders/:id/close",
  [
    param("id").isInt({ min: 1 }),
    body("closing_staff_id").isInt({ min: 1 }).withMessage("closing_staff_id is required"),
    body("actual_hours").optional().isFloat({ min: 0 }),
    body("actual_cost").optional().isFloat({ min: 0 }),
    body("resolution_notes").optional().isLength({ max: 5000 }),
  ],
  handleValidation,
  woCtrl.closeWorkOrder
);

// GET /api/v1/work-orders/sla-breaches — breached orders dashboard
router.get("/work-orders/sla-breaches", woCtrl.getSlaBreaches);


// =============================================================================
// ASSET ROUTES
// =============================================================================

// GET /api/v1/assets/:id — full asset detail merged from all three DBs
router.get("/assets/:id",
  [param("id").isInt({ min: 1 })],
  handleValidation,
  requestCtrl.assetController
    ? requestCtrl.assetController.getAssetDetail
    : woCtrl.assetController.getAssetDetail
);

// GET /api/v1/assets/:id/risk — Neo4j centrality risk score
router.get("/assets/:id/risk",
  [param("id").isInt({ min: 1 })],
  handleValidation,
  woCtrl.assetController
    ? woCtrl.assetController.getAssetRisk
    : (req, res) => res.json({ message: "Asset risk endpoint" })
);


// =============================================================================
// REPORT ROUTES
// =============================================================================

// GET /api/v1/reports/district/:id — cursor-based district report
router.get("/reports/district/:id",
  [param("id").isInt({ min: 1 })],
  handleValidation,
  woCtrl.reportController.getDistrictReport
);

// GET /api/v1/reports/audit/:requestId — merged audit timeline
router.get("/reports/audit/:requestId",
  [param("requestId").isInt({ min: 1 })],
  handleValidation,
  woCtrl.reportController.getAuditTrail
);

// GET /api/v1/reports/asset-conditions — district condition summary view
router.get("/reports/asset-conditions", async (req, res, next) => {
  try {
    const { mysql_db } = require("../config/db");
    const [rows] = await mysql_db.getPool().execute(
      "SELECT * FROM v_asset_condition_by_district ORDER BY avg_condition_rating ASC"
    );
    res.json({ success: true, data: rows });
  } catch (err) { next(err); }
});

// GET /api/v1/reports/stock-alerts — low inventory alert view
router.get("/reports/stock-alerts", async (req, res, next) => {
  try {
    const { mysql_db } = require("../config/db");
    const [rows] = await mysql_db.getPool().execute(
      "SELECT * FROM v_low_stock_alerts"
    );
    res.json({ success: true, count: rows.length, data: rows });
  } catch (err) { next(err); }
});

module.exports = router;
