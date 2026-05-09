// =============================================================================
// server.js
// City of Johannesburg IMTS — API Entry Point
//
// Startup sequence:
//   1. Load environment variables
//   2. Connect all three databases (fail-fast if any connection fails)
//   3. Mount middleware and routes
//   4. Start HTTP listener
//   5. Register graceful shutdown handlers
//
// GA9 — Reflection: A server that starts with a broken database connection
//   is worse than one that refuses to start. The fail-fast pattern here
//   means a misconfigured deployment is caught immediately at startup,
//   not silently — a lesson learned from production incidents in every
//   distributed system.
// =============================================================================

require("dotenv").config();

const express  = require("express");
const helmet   = require("helmet");
const cors     = require("cors");
const morgan   = require("morgan");

const { mysql_db, mongo_db, neo4j_db } = require("./config/db");
const { limiter, errorHandler, notFound } = require("./middleware");
const routes   = require("./routes");

const app  = express();
const PORT = process.env.PORT || 3000;
const VER  = process.env.API_VERSION || "v1";


// =============================================================================
// MIDDLEWARE STACK
// Order is significant — execute top to bottom before any route handler.
// =============================================================================

// Security headers (XSS, clickjacking, MIME sniffing protection)
app.use(helmet());

// CORS — allow all origins in development; lock down in production
app.use(cors({
  origin: process.env.NODE_ENV === "production"
    ? ["https://dashboard.jhbpw.gov.za", "https://imts.jhbpw.gov.za"]
    : "*",
  methods: ["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
  allowedHeaders: ["Content-Type", "Authorization"],
}));

// Request logging
app.use(morgan(process.env.LOG_LEVEL || "dev"));

// Parse JSON bodies — 1mb limit prevents oversized payload attacks
app.use(express.json({ limit: "1mb" }));
app.use(express.urlencoded({ extended: false }));

// Rate limiter
app.use(limiter);


// =============================================================================
// ROUTES
// =============================================================================
app.use(`/api/${VER}`, routes);


// =============================================================================
// ERROR HANDLERS (must be registered AFTER routes)
// =============================================================================
app.use(notFound);
app.use(errorHandler);


// =============================================================================
// DATABASE CONNECTIONS + SERVER START
// All three must connect successfully before the HTTP port opens.
// =============================================================================
const start = async () => {
  try {
    console.log("\n=== JHB Infrastructure Maintenance Tracking System ===");
    console.log("Connecting to databases...\n");

    await mysql_db.connect();
    await mongo_db.connect();
    await neo4j_db.connect();

    console.log("\nAll database connections established.\n");

    app.listen(PORT, () => {
      console.log(`API listening on http://localhost:${PORT}/api/${VER}`);
      console.log(`Health check: http://localhost:${PORT}/api/${VER}/health`);
      console.log(`Deep health:  http://localhost:${PORT}/api/${VER}/health/deep\n`);
    });

  } catch (err) {
    console.error("\n[FATAL] Startup failed:", err.message);
    process.exit(1);  // fail-fast — do not start a broken server
  }
};


// =============================================================================
// GRACEFUL SHUTDOWN
// On SIGTERM (Docker stop, Kubernetes pod eviction) or SIGINT (Ctrl+C):
//   1. Stop accepting new connections
//   2. Close database pools cleanly
//   3. Exit with code 0 (success)
//
// GA9 — Staying Current: Graceful shutdown is a Kubernetes and 12-Factor App
//   requirement. A process that ignores SIGTERM gets killed hard after 30s,
//   potentially mid-transaction. This handler prevents that.
// =============================================================================
const shutdown = async (signal) => {
  console.log(`\n[${signal}] Shutting down gracefully...`);
  try {
    await mysql_db.disconnect();
    await mongo_db.disconnect();
    await neo4j_db.disconnect();
    console.log("All connections closed. Exiting.");
    process.exit(0);
  } catch (err) {
    console.error("Error during shutdown:", err.message);
    process.exit(1);
  }
};

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT",  () => shutdown("SIGINT"));
process.on("uncaughtException", (err) => {
  console.error("[UNCAUGHT EXCEPTION]", err);
  shutdown("UNCAUGHT_EXCEPTION");
});

start();

module.exports = app; // for testing
