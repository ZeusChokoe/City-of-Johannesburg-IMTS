// server.js Group 19 IMTS API
require("dotenv").config();
const express = require("express");
const helmet  = require("helmet");
const cors    = require("cors");
const morgan  = require("morgan");
const { mysql_db, mongo_db, neo4j_db } = require("./config/db");
const { limiter, errorHandler, notFound } = require("./middleware");
const routes  = require("./routes");

const app  = express();
const PORT = process.env.PORT || 3000;
const VER  = process.env.API_VERSION || "v1";

app.use(helmet({ crossOriginEmbedderPolicy: false }));
app.use(cors({ origin: "*", methods: ["GET","POST","PATCH","DELETE","OPTIONS"] }));
app.use(morgan(process.env.LOG_LEVEL || "dev"));
app.use(express.json({ limit: "1mb" }));
app.use(express.urlencoded({ extended: false }));
app.use(limiter);

app.use("/api/" + VER, routes);
app.use(notFound);
app.use(errorHandler);

const start = async () => {
  console.log("\n=== Group 19 City of Johannesburg IMTS API ===");
  console.log("Connecting to databases...\n");

  const results = { mysql: false, mongodb: false, neo4j: false };

  // Try each DB independently partial start is better than no start
  await mysql_db.connect().then(() => { results.mysql = true; }).catch(e => {
    console.warn("[MySQL]   WARNING: " + e.message);
    console.warn("[MySQL]   API will start but MySQL endpoints will fail until MySQL is running.\n");
  });

  await mongo_db.connect().then(() => { results.mongodb = true; }).catch(e => {
    console.warn("[MongoDB] WARNING: " + e.message);
    console.warn("[MongoDB] API will start but MongoDB endpoints will fail until MongoDB is running.\n");
  });

  await neo4j_db.connect().then(() => { results.neo4j = true; }).catch(e => {
    console.warn("[Neo4j]   WARNING: " + e.message);
    console.warn("[Neo4j]   API will start but Neo4j endpoints will fail until Neo4j is running.\n");
  });

  const connected = Object.values(results).filter(Boolean).length;
  console.log("\nDatabase status: " + connected + "/3 connected");
  Object.entries(results).forEach(([k,v]) => console.log("  " + (v ? "✓" : "✗") + " " + k));

  app.listen(PORT, () => {
    console.log("\nAPI running → http://localhost:" + PORT + "/api/" + VER);
    console.log("Status page → http://localhost:" + PORT + "/api/" + VER + "/status");
    console.log("Dashboard  → open dashboard/index.html in your browser\n");
  });
};

const shutdown = async (sig) => {
  console.log("\n[" + sig + "] Shutting down...");
  await Promise.allSettled([mysql_db.disconnect(), mongo_db.disconnect(), neo4j_db.disconnect()]);
  console.log("Done."); process.exit(0);
};
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT",  () => shutdown("SIGINT"));

start();
module.exports = app;
