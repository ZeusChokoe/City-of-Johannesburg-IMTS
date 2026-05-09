// =============================================================================
// middleware/index.js
// Centralised middleware: error handler, request validation, rate limiter.
//
// GA9 — Staying Current: Express middleware is a chain of functions executed
//   in order before the route handler fires. The order of app.use() calls in
//   server.js determines execution sequence. Error-handling middleware (4 args)
//   must be registered LAST. This is Express-specific but the middleware
//   pipeline pattern exists in Koa, Fastify, ASP.NET Core, Django, and Laravel.
// =============================================================================

const rateLimit         = require("express-rate-limit");
const { validationResult } = require("express-validator");


// =============================================================================
// RATE LIMITER
// Prevents API abuse. 200 requests per 15-minute window per IP.
// Returns 429 Too Many Requests when exceeded.
// =============================================================================
const limiter = rateLimit({
  windowMs:        parseInt(process.env.RATE_LIMIT_WINDOW_MS) || 900000,
  max:             parseInt(process.env.RATE_LIMIT_MAX_REQUESTS) || 200,
  standardHeaders: true,   // include RateLimit-* headers in response
  legacyHeaders:   false,
  message: {
    success: false,
    error:   "Too many requests from this IP. Please retry after 15 minutes.",
  },
});


// =============================================================================
// VALIDATION RESULT HANDLER
// Placed after express-validator chains in route definitions.
// Collects validation errors and returns a structured 422 response.
//
// GA9 — Reflection: Input validation at the API boundary prevents
//   malformed data from ever reaching the databases. The legacy system
//   had no validation — a spreadsheet cell had no type enforcement.
//   This middleware ensures every field contract is checked before
//   any database query executes.
// =============================================================================
const handleValidation = (req, res, next) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) {
    return res.status(422).json({
      success: false,
      error:   "Validation failed",
      details: errors.array().map(e => ({
        field:   e.path,
        message: e.msg,
        value:   e.value,
      })),
    });
  }
  next();
};


// =============================================================================
// GLOBAL ERROR HANDLER
// Must be the last middleware registered (4 arguments = error handler in Express).
// Catches errors thrown by route handlers and controllers.
// Returns a consistent JSON error envelope regardless of error origin.
//
// Error classification:
//   MySQL errors:  err.code starts with "ER_" or err.errno exists
//   MongoDB errors: err.name === "MongoServerError"
//   Neo4j errors:  err.code starts with "Neo."
//   Validation:    err.status === 422
//   Custom signals: err.status is set explicitly in controllers
// =============================================================================
const errorHandler = (err, req, res, next) => {
  // Log full error in development; suppress stack in production
  if (process.env.NODE_ENV === "development") {
    console.error("[ERROR]", err);
  } else {
    console.error("[ERROR]", err.message || err);
  }

  // MySQL-specific errors
  if (err.errno || (err.code && err.code.startsWith("ER_"))) {
    const mysqlErrors = {
      ER_DUP_ENTRY:           { status: 409, message: "Duplicate record — this reference already exists." },
      ER_ROW_IS_REFERENCED_2: { status: 409, message: "Cannot delete — this record is referenced by other records." },
      ER_NO_REFERENCED_ROW_2: { status: 400, message: "Referenced record does not exist." },
      ER_SIGNAL_EXCEPTION:    { status: 422, message: err.sqlMessage || "Business rule violation." },
    };
    const mapped = mysqlErrors[err.code];
    if (mapped) {
      return res.status(mapped.status).json({ success: false, error: mapped.message });
    }
    return res.status(500).json({ success: false, error: "Database error.", detail: err.sqlMessage });
  }

  // MongoDB-specific errors
  if (err.name === "MongoServerError") {
    if (err.code === 121) {
      return res.status(422).json({ success: false, error: "MongoDB document validation failed.", detail: err.errInfo?.details });
    }
    return res.status(500).json({ success: false, error: "MongoDB error.", detail: err.message });
  }

  // Neo4j-specific errors
  if (err.code && err.code.startsWith("Neo.")) {
    return res.status(500).json({ success: false, error: "Graph database error.", detail: err.message });
  }

  // Explicit status set in controller (e.g. 404 not found, 422 business rule)
  if (err.status) {
    return res.status(err.status).json({ success: false, error: err.message });
  }

  // Fallback
  res.status(500).json({
    success: false,
    error:   "Internal server error.",
    detail:  process.env.NODE_ENV === "development" ? err.message : undefined,
  });
};


// =============================================================================
// 404 HANDLER — registered in server.js after all routes
// =============================================================================
const notFound = (req, res) => {
  res.status(404).json({
    success: false,
    error:   `Route not found: ${req.method} ${req.originalUrl}`,
  });
};


module.exports = { limiter, handleValidation, errorHandler, notFound };
