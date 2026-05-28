// =============================================================================
// CITY OF JOHANNESBURG
// Infrastructure Maintenance Tracking System (IMTS)
// =============================================================================
// Phase 4: Neo4j Graph Database Layer
// Language: Cypher
// Tool: Neo4j Browser (http://localhost:7474) or cypher-shell
// Neo4j Version: 5.x Community or Enterprise
//
// Depends on: Phase 1 (MySQL) and Phase 3 (MongoDB) must be seeded first.
//             All mysql_asset_id values in this file match Phase 1 seed data.
//
// EXECUTION: Run each section sequentially in Neo4j Browser.
//            Paste one section at a time. Each section is self-contained.
//            The SECTION SEPARATOR comments tell you where to split.
//
// SECTION MAP:
//   Section 0:  Graph model explanation and schema design rationale
//   Section 1:  Constraints and indexes (run first — schema layer)
//   Section 2:  Node creation — all 7 label types
//   Section 3:  Relationship creation — all 9 relationship types
//   Section 4:  Cypher query library — 8 operational queries
//   Section 5:  Verification and graph health checks
//
// WHY NEO4J — THE CORE ARGUMENT:
//   A burst water pipe at a junction does not just affect that pipe.
//   It affects every connected pipe, the roads above them, the pump station
//   feeding them, and the districts those pipes serve. In MySQL, finding this
//   chain requires recursive CTEs with unknown depth. In MongoDB, there is no
//   JOIN at all. In Neo4j, the query is:
//     MATCH (a:Asset {mysql_asset_id: 1})-[:CONNECTS_TO*1..6]->(b:Asset)
//     RETURN b
//   Three lines. Any depth. Any topology. That is the case for a graph database.
//
// GA9 — INDEPENDENT LEARNING ANNOTATION:
//   Graph databases require unlearning relational thinking. Rows become nodes.
//   Foreign keys become relationships. JOINs become traversals. This mental
//   shift is one of the most significant adaptability exercises in modern
//   database education. Each section below explicitly maps the relational
//   concept to its graph equivalent so the transition is traceable.
// =============================================================================


// =============================================================================
// SECTION 0: GRAPH MODEL — NODE LABELS AND RELATIONSHIP TYPES
// =============================================================================
//
// NODE LABELS (7 types):
// ┌─────────────────────┬──────────────────────────────────────────────────────┐
// │ Label               │ Represents                                           │
// ├─────────────────────┼──────────────────────────────────────────────────────┤
// │ Asset               │ Physical infrastructure item (pipe, light, road)     │
// │ District            │ CoJ administrative region                            │
// │ AssetType           │ Category of infrastructure                           │
// │ MaintenanceRequest  │ Fault report linked to an asset                      │
// │ WorkOrder           │ Operational task derived from a request              │
// │ Technician          │ Maintenance staff member                             │
// │ FailureEvent        │ Recorded asset failure / anomaly event               │
// └─────────────────────┴──────────────────────────────────────────────────────┘
//
// RELATIONSHIP TYPES (9 types):
// ┌────────────────────┬────────────────┬───────────────┬──────────────────────┐
// │ Relationship       │ From           │ To            │ Meaning              │
// ├────────────────────┼────────────────┼───────────────┼──────────────────────┤
// │ CONNECTS_TO        │ Asset          │ Asset         │ Physical network link │
// │ FEEDS_INTO         │ Asset          │ Asset         │ Upstream→downstream  │
// │ DEPENDS_ON         │ Asset          │ Asset         │ Operational dependency│
// │ ADJACENT_TO        │ Asset          │ Asset         │ Geographic proximity  │
// │ LOCATED_IN         │ Asset          │ District      │ Administrative zone  │
// │ OF_TYPE            │ Asset          │ AssetType     │ Category membership  │
// │ REPORTED_FOR       │ MaintenanceReq │ Asset         │ Fault targets asset  │
// │ RESOLVES           │ WorkOrder      │ MaintenanceReq│ Order closes request │
// │ ASSIGNED_TO        │ WorkOrder      │ Technician    │ Staff assignment     │
// │ CAUSED_BY          │ FailureEvent   │ Asset         │ Failure root cause   │
// │ TRIGGERED_REQUEST  │ FailureEvent   │ MaintenanceReq│ Failure → report     │
// └────────────────────┴────────────────┴───────────────┴──────────────────────┘
//
// GA9 — Interest & Curiosity:
//   Neo4j's property graph model was formalised in the openCypher specification
//   (now GQL — ISO/IEC 39075:2024, the first international graph query language
//   standard). Understanding Neo4j means understanding GQL, which will be to
//   graph databases what SQL is to relational databases.
// =============================================================================


// =============================================================================
// SECTION 1: CONSTRAINTS AND INDEXES
// Run this section FIRST — constraints must exist before nodes are created.
//
// In Neo4j, a UNIQUE constraint automatically creates an index.
// Additional indexes are created separately for non-unique lookup properties.
//
// GA9 — Staying Current: Neo4j 5.x uses the unified CREATE CONSTRAINT syntax.
//   The older CREATE INDEX ON :Label(property) syntax from Neo4j 3.x is
//   deprecated. Always check the version-specific documentation — a common
//   mistake in student projects is copying 3.x syntax into a 5.x environment.
// =============================================================================

// --- Node uniqueness constraints ---

// Each node label gets a unique constraint on its primary business identifier.
// This is the Neo4j equivalent of a PRIMARY KEY constraint in MySQL.

CREATE CONSTRAINT uq_asset_mysql_id IF NOT EXISTS
FOR (a:Asset)
REQUIRE a.mysql_asset_id IS UNIQUE;

CREATE CONSTRAINT uq_district_id IF NOT EXISTS
FOR (d:District)
REQUIRE d.mysql_district_id IS UNIQUE;

CREATE CONSTRAINT uq_asset_type_id IF NOT EXISTS
FOR (at:AssetType)
REQUIRE at.mysql_asset_type_id IS UNIQUE;

CREATE CONSTRAINT uq_request_id IF NOT EXISTS
FOR (r:MaintenanceRequest)
REQUIRE r.mysql_request_id IS UNIQUE;

CREATE CONSTRAINT uq_work_order_id IF NOT EXISTS
FOR (w:WorkOrder)
REQUIRE w.mysql_work_order_id IS UNIQUE;

CREATE CONSTRAINT uq_technician_emp_no IF NOT EXISTS
FOR (t:Technician)
REQUIRE t.employee_number IS UNIQUE;

CREATE CONSTRAINT uq_failure_event_id IF NOT EXISTS
FOR (f:FailureEvent)
REQUIRE f.event_id IS UNIQUE;

// --- Additional lookup indexes (non-unique) ---

// Asset lookups by asset_code, status, and condition
CREATE INDEX idx_asset_code IF NOT EXISTS FOR (a:Asset) ON (a.asset_code);
CREATE INDEX idx_asset_status IF NOT EXISTS FOR (a:Asset) ON (a.status);
CREATE INDEX idx_asset_condition IF NOT EXISTS FOR (a:Asset) ON (a.condition_rating);
CREATE INDEX idx_asset_type_code IF NOT EXISTS FOR (a:Asset) ON (a.asset_type_code);

// Request lookups by status and priority — used by dashboard queries
CREATE INDEX idx_request_status IF NOT EXISTS FOR (r:MaintenanceRequest) ON (r.status);
CREATE INDEX idx_request_priority IF NOT EXISTS FOR (r:MaintenanceRequest) ON (r.priority);

// Work order lookups by status and SLA breach flag
CREATE INDEX idx_wo_status IF NOT EXISTS FOR (w:WorkOrder) ON (w.status);
CREATE INDEX idx_wo_sla_breached IF NOT EXISTS FOR (w:WorkOrder) ON (w.sla_breached);

// Failure event severity — used in cascade analysis
CREATE INDEX idx_failure_severity IF NOT EXISTS FOR (f:FailureEvent) ON (f.severity);

// =============================================================================
// END SECTION 1 — Paste above block, execute, then continue with Section 2
// =============================================================================


// =============================================================================
// SECTION 2: NODE CREATION
//
// CREATE vs MERGE:
//   We use MERGE throughout — it creates the node if it does not exist,
//   or matches the existing node if it does. This makes the script idempotent:
//   safe to run multiple times without creating duplicates.
//   MERGE is the Neo4j equivalent of MySQL's INSERT ... ON DUPLICATE KEY UPDATE.
//
// GA9 — Adaptability: Idempotent data loading scripts are a DevOps best
//   practice. A script that errors on re-run is a deployment liability.
//   MERGE solves this in Neo4j the same way upsert patterns solve it in
//   every other database engine.
// =============================================================================

// --- 2.1 District nodes ---
// 7 CoJ administrative districts, mirroring MySQL districts table exactly.

MERGE (d1:District {mysql_district_id: 1})
SET d1.name = "Johannesburg Central",
    d1.region_code = "REG-F",
    d1.sub_district = "Inner City",
    d1.population = 450000,
    d1.area_km2 = 178.00;

MERGE (d2:District {mysql_district_id: 2})
SET d2.name = "Northcliff/Rosebank",
    d2.region_code = "REG-B",
    d2.sub_district = "Sandton",
    d2.population = 620000,
    d2.area_km2 = 292.00;

MERGE (d3:District {mysql_district_id: 3})
SET d3.name = "Roodepoort",
    d3.region_code = "REG-C",
    d3.sub_district = "Roodepoort Central",
    d3.population = 480000,
    d3.area_km2 = 341.00;

MERGE (d4:District {mysql_district_id: 4})
SET d4.name = "Doornkop/Soweto",
    d4.region_code = "REG-D",
    d4.sub_district = "Soweto",
    d4.population = 1300000,
    d4.area_km2 = 200.00;

MERGE (d5:District {mysql_district_id: 5})
SET d5.name = "Midrand",
    d5.region_code = "REG-A",
    d5.sub_district = "Midrand",
    d5.population = 390000,
    d5.area_km2 = 298.00;

MERGE (d6:District {mysql_district_id: 6})
SET d6.name = "Orange Farm",
    d6.region_code = "REG-G",
    d6.sub_district = "Ennerdale / Orange Farm",
    d6.population = 430000,
    d6.area_km2 = 162.00;

MERGE (d7:District {mysql_district_id: 7})
SET d7.name = "Alexandra/Marlboro",
    d7.region_code = "REG-E",
    d7.sub_district = "Alexandra",
    d7.population = 340000,
    d7.area_km2 = 30.00;


// --- 2.2 AssetType nodes ---
// 10 infrastructure categories — reference nodes for graph traversal filtering.

MERGE (at1:AssetType {mysql_asset_type_id: 1})
SET at1.name = "Water Distribution Pipe",
    at1.criticality = "CRITICAL",
    at1.sla_hours = 4;

MERGE (at2:AssetType {mysql_asset_type_id: 2})
SET at2.name = "Pothole",
    at2.criticality = "HIGH",
    at2.sla_hours = 24;

MERGE (at3:AssetType {mysql_asset_type_id: 3})
SET at3.name = "Streetlight",
    at3.criticality = "MEDIUM",
    at3.sla_hours = 48;

MERGE (at4:AssetType {mysql_asset_type_id: 4})
SET at4.name = "Sewer Main",
    at4.criticality = "CRITICAL",
    at4.sla_hours = 8;

MERGE (at5:AssetType {mysql_asset_type_id: 5})
SET at5.name = "Road Surface",
    at5.criticality = "MEDIUM",
    at5.sla_hours = 72;

MERGE (at6:AssetType {mysql_asset_type_id: 6})
SET at6.name = "Storm Water Drain",
    at6.criticality = "HIGH",
    at6.sla_hours = 24;

MERGE (at7:AssetType {mysql_asset_type_id: 7})
SET at7.name = "Electrical Substation",
    at7.criticality = "CRITICAL",
    at7.sla_hours = 2;

MERGE (at8:AssetType {mysql_asset_type_id: 8})
SET at8.name = "Bridge Structure",
    at8.criticality = "CRITICAL",
    at8.sla_hours = 6;

MERGE (at9:AssetType {mysql_asset_type_id: 9})
SET at9.name = "Traffic Signal",
    at9.criticality = "HIGH",
    at9.sla_hours = 12;

MERGE (at10:AssetType {mysql_asset_type_id: 10})
SET at10.name = "Water Pump Station",
    at10.criticality = "CRITICAL",
    at10.sla_hours = 4;


// --- 2.3 Asset nodes ---
// 10 physical assets from Phase 1 MySQL seed data.
// Additional nodes added here to model the water network topology —
// pipe junctions and extended network segments not in the MySQL seed
// but essential to demonstrate graph traversal at meaningful depth.
//
// GA9 — Interest & Curiosity: Real network topology data for Johannesburg's
//   water infrastructure is held by Johannesburg Water SOC. A production
//   implementation would import this via the Johannesburg Water GIS shapefile
//   exports. Knowing that GIS shapefiles can be converted to Neo4j nodes via
//   the neo4j-contrib/spatial library is the kind of domain-specific research
//   that GA9 rewards.

// Phase 1 MySQL assets (mysql_asset_id 1–10)
MERGE (a1:Asset {mysql_asset_id: 1})
SET a1.asset_code = "JHB-WP-00001",
    a1.name = "Commissioner St Main Water Pipe",
    a1.asset_type_code = "WATER_PIPE",
    a1.status = "OPERATIONAL",
    a1.condition_rating = 6,
    a1.latitude = -26.2041,
    a1.longitude = 28.0473,
    a1.district_id = 1,
    a1.pipe_diameter_mm = 50,
    a1.material = "UPVC",
    a1.installation_year = 2005,
    a1.replacement_cost_zar = 280000.00;

MERGE (a2:Asset {mysql_asset_id: 2})
SET a2.asset_code = "JHB-PH-00001",
    a2.name = "Pothole — Klipspruit Valley Rd",
    a2.asset_type_code = "POTHOLE",
    a2.status = "DEGRADED",
    a2.condition_rating = 3,
    a2.latitude = -26.2622,
    a2.longitude = 27.8690,
    a2.district_id = 4,
    a2.replacement_cost_zar = 18000.00;

MERGE (a3:Asset {mysql_asset_id: 3})
SET a3.asset_code = "JHB-SL-00001",
    a3.name = "Streetlight — Sandton Dr Node 14",
    a3.asset_type_code = "STREETLIGHT",
    a3.status = "OPERATIONAL",
    a3.condition_rating = 8,
    a3.latitude = -26.1075,
    a3.longitude = 28.0567,
    a3.district_id = 2,
    a3.wattage = 70,
    a3.lamp_type = "LED",
    a3.replacement_cost_zar = 12500.00;

MERGE (a4:Asset {mysql_asset_id: 4})
SET a4.asset_code = "JHB-SW-00001",
    a4.name = "Jeppe St Sewer Main Section 7",
    a4.asset_type_code = "SEWER_MAIN",
    a4.status = "OPERATIONAL",
    a4.condition_rating = 5,
    a4.latitude = -26.2058,
    a4.longitude = 28.0499,
    a4.district_id = 1,
    a4.pipe_diameter_mm = 375,
    a4.material = "HOBAS",
    a4.replacement_cost_zar = 950000.00;

MERGE (a5:Asset {mysql_asset_id: 5})
SET a5.asset_code = "JHB-RS-00001",
    a5.name = "Ontdekkers Rd Surface — Km 4.2",
    a5.asset_type_code = "ROAD_SURFACE",
    a5.status = "OPERATIONAL",
    a5.condition_rating = 7,
    a5.latitude = -26.1758,
    a5.longitude = 27.9200,
    a5.district_id = 3,
    a5.replacement_cost_zar = 420000.00;

MERGE (a6:Asset {mysql_asset_id: 6})
SET a6.asset_code = "JHB-TS-00001",
    a6.name = "Traffic Signal — Rissik & Jeppe",
    a6.asset_type_code = "TRAFFIC_SIGNAL",
    a6.status = "OPERATIONAL",
    a6.condition_rating = 9,
    a6.latitude = -26.2048,
    a6.longitude = 28.0443,
    a6.district_id = 1,
    a6.replacement_cost_zar = 95000.00;

MERGE (a7:Asset {mysql_asset_id: 7})
SET a7.asset_code = "JHB-ES-00001",
    a7.name = "Midrand Substation Alpha",
    a7.asset_type_code = "ELECTRICAL_SUBSTATION",
    a7.status = "OPERATIONAL",
    a7.condition_rating = 8,
    a7.latitude = -25.9989,
    a7.longitude = 28.1286,
    a7.district_id = 5,
    a7.capacity_kva = 5000,
    a7.replacement_cost_zar = 4200000.00;

MERGE (a8:Asset {mysql_asset_id: 8})
SET a8.asset_code = "JHB-WP-00002",
    a8.name = "Vilakazi St Water Pipe Section 3",
    a8.asset_type_code = "WATER_PIPE",
    a8.status = "DEGRADED",
    a8.condition_rating = 4,
    a8.latitude = -26.2540,
    a8.longitude = 27.8590,
    a8.district_id = 4,
    a8.pipe_diameter_mm = 100,
    a8.material = "ASBESTOS_CEMENT",
    a8.installation_year = 2003,
    a8.replacement_cost_zar = 195000.00;

MERGE (a9:Asset {mysql_asset_id: 9})
SET a9.asset_code = "JHB-SD-00001",
    a9.name = "Alexandra Drain — 3rd Ave",
    a9.asset_type_code = "STORM_DRAIN",
    a9.status = "DEGRADED",
    a9.condition_rating = 5,
    a9.latitude = -26.1025,
    a9.longitude = 28.0913,
    a9.district_id = 7,
    a9.replacement_cost_zar = 380000.00;

MERGE (a10:Asset {mysql_asset_id: 10})
SET a10.asset_code = "JHB-PS-00001",
    a10.name = "Braamfontein Water Pump Station",
    a10.asset_type_code = "PUMP_STATION",
    a10.status = "OPERATIONAL",
    a10.condition_rating = 7,
    a10.latitude = -26.1929,
    a10.longitude = 28.0314,
    a10.district_id = 1,
    a10.pump_count = 3,
    a10.max_flow_lpm = 4500,
    a10.replacement_cost_zar = 1800000.00;

// Extended network nodes — water pipe junctions and additional segments
// These model the actual network topology for meaningful graph traversal.
// mysql_asset_id > 100 = graph-only nodes not yet in MySQL.

MERGE (a11:Asset {mysql_asset_id: 101})
SET a11.asset_code = "JHB-WJ-00001",
    a11.name = "Water Junction — Commissioner/Plein St",
    a11.asset_type_code = "WATER_JUNCTION",
    a11.status = "OPERATIONAL",
    a11.condition_rating = 7,
    a11.latitude = -26.2038,
    a11.longitude = 28.0490,
    a11.district_id = 1,
    a11.junction_type = "T_JUNCTION",
    a11.pipe_count = 3;

MERGE (a12:Asset {mysql_asset_id: 102})
SET a12.asset_code = "JHB-WP-00003",
    a12.name = "Plein St Water Pipe Section 2",
    a12.asset_type_code = "WATER_PIPE",
    a12.status = "OPERATIONAL",
    a12.condition_rating = 6,
    a12.latitude = -26.2028,
    a12.longitude = 28.0510,
    a12.district_id = 1,
    a12.pipe_diameter_mm = 50,
    a12.material = "UPVC",
    a12.replacement_cost_zar = 185000.00;

MERGE (a13:Asset {mysql_asset_id: 103})
SET a13.asset_code = "JHB-WP-00004",
    a13.name = "End St Water Pipe Section 1",
    a13.asset_type_code = "WATER_PIPE",
    a13.status = "OPERATIONAL",
    a13.condition_rating = 8,
    a13.latitude = -26.2055,
    a13.longitude = 28.0455,
    a13.district_id = 1,
    a13.pipe_diameter_mm = 50,
    a13.material = "UPVC",
    a13.replacement_cost_zar = 210000.00;

MERGE (a14:Asset {mysql_asset_id: 104})
SET a14.asset_code = "JHB-WJ-00002",
    a14.name = "Water Junction — End/Jeppe St",
    a14.asset_type_code = "WATER_JUNCTION",
    a14.status = "OPERATIONAL",
    a14.condition_rating = 6,
    a14.latitude = -26.2060,
    a14.longitude = 28.0462,
    a14.district_id = 1,
    a14.junction_type = "CROSS_JUNCTION",
    a14.pipe_count = 4;

MERGE (a15:Asset {mysql_asset_id: 105})
SET a15.asset_code = "JHB-WP-00005",
    a15.name = "Jeppe St Water Pipe Section 4",
    a15.asset_type_code = "WATER_PIPE",
    a15.status = "OPERATIONAL",
    a15.condition_rating = 7,
    a15.latitude = -26.2063,
    a15.longitude = 28.0481,
    a15.district_id = 1,
    a15.pipe_diameter_mm = 75,
    a15.material = "UPVC",
    a15.replacement_cost_zar = 340000.00;

MERGE (a16:Asset {mysql_asset_id: 106})
SET a16.asset_code = "JHB-SL-00002",
    a16.name = "Streetlight — Commissioner St Node 7",
    a16.asset_type_code = "STREETLIGHT",
    a16.status = "OPERATIONAL",
    a16.condition_rating = 7,
    a16.latitude = -26.2044,
    a16.longitude = 28.0468,
    a16.district_id = 1,
    a16.wattage = 70,
    a16.lamp_type = "LED",
    a16.replacement_cost_zar = 12500.00;

MERGE (a17:Asset {mysql_asset_id: 107})
SET a17.asset_code = "JHB-RS-00002",
    a17.name = "Commissioner St Road Surface — Km 1.1",
    a17.asset_type_code = "ROAD_SURFACE",
    a17.status = "DEGRADED",
    a17.condition_rating = 4,
    a17.latitude = -26.2042,
    a17.longitude = 28.0470,
    a17.district_id = 1,
    a17.replacement_cost_zar = 380000.00;

MERGE (a18:Asset {mysql_asset_id: 108})
SET a18.asset_code = "JHB-WP-00006",
    a18.name = "Vilakazi St Feed Pipe Section 2",
    a18.asset_type_code = "WATER_PIPE",
    a18.status = "OPERATIONAL",
    a18.condition_rating = 6,
    a18.latitude = -26.2530,
    a18.longitude = 27.8570,
    a18.district_id = 4,
    a18.pipe_diameter_mm = 150,
    a18.material = "DI",
    a18.replacement_cost_zar = 520000.00;


// --- 2.4 MaintenanceRequest nodes ---

MERGE (r1:MaintenanceRequest {mysql_request_id: 1})
SET r1.reference = "MR-2025-00001",
    r1.category = "BURST_PIPE",
    r1.priority = "CRITICAL",
    r1.status = "IN_PROGRESS",
    r1.reported_at = datetime("2025-01-15T07:32:00Z"),
    r1.description = "Significant water gushing from Commissioner St near End St intersection.",
    r1.district_id = 1;

MERGE (r2:MaintenanceRequest {mysql_request_id: 2})
SET r2.reference = "MR-2025-00002",
    r2.category = "POTHOLE",
    r2.priority = "HIGH",
    r2.status = "ASSIGNED",
    r2.reported_at = datetime("2025-01-16T11:05:00Z"),
    r2.description = "Large pothole on Klipspruit Valley Road.",
    r2.district_id = 4;

MERGE (r3:MaintenanceRequest {mysql_request_id: 3})
SET r3.reference = "MR-2025-00003",
    r3.category = "FAULTY_STREETLIGHT",
    r3.priority = "MEDIUM",
    r3.status = "SUBMITTED",
    r3.reported_at = datetime("2025-01-17T20:18:00Z"),
    r3.description = "Streetlight Sandton Drive Node 14 off for 5 nights.",
    r3.district_id = 2;

MERGE (r4:MaintenanceRequest {mysql_request_id: 4})
SET r4.reference = "MR-2025-00004",
    r4.category = "SEWER_BLOCKAGE",
    r4.priority = "HIGH",
    r4.status = "UNDER_REVIEW",
    r4.reported_at = datetime("2025-01-18T09:00:00Z"),
    r4.description = "Storm drain Alexandra 3rd Ave completely blocked.",
    r4.district_id = 7;

MERGE (r5:MaintenanceRequest {mysql_request_id: 5})
SET r5.reference = "MR-2025-00005",
    r5.category = "BURST_PIPE",
    r5.priority = "HIGH",
    r5.status = "SUBMITTED",
    r5.reported_at = datetime("2025-01-18T14:45:00Z"),
    r5.description = "IoT: Water pressure drop on Vilakazi St pipe.",
    r5.district_id = 4;


// --- 2.5 WorkOrder nodes ---

MERGE (w1:WorkOrder {mysql_work_order_id: 1})
SET w1.reference = "WO-2025-00001",
    w1.title = "Emergency repair — Commissioner St burst water main",
    w1.priority = "CRITICAL",
    w1.status = "IN_PROGRESS",
    w1.sla_deadline = datetime("2025-01-15T11:32:00Z"),
    w1.sla_breached = true,
    w1.estimated_cost_zar = 45000.00,
    w1.district_id = 1;

MERGE (w2:WorkOrder {mysql_work_order_id: 2})
SET w2.reference = "WO-2025-00002",
    w2.title = "Pothole patching — Klipspruit Valley Rd",
    w2.priority = "HIGH",
    w2.status = "DISPATCHED",
    w2.sla_deadline = datetime("2025-01-17T11:05:00Z"),
    w2.sla_breached = true,
    w2.estimated_cost_zar = 12000.00,
    w2.district_id = 4;


// --- 2.6 Technician nodes ---

MERGE (t1:Technician {employee_number: "EMP-0001"})
SET t1.name = "Sipho Nkosi",
    t1.role = "MANAGER",
    t1.specialization = "GENERAL",
    t1.district_id = 1;

MERGE (t2:Technician {employee_number: "EMP-0002"})
SET t2.name = "Zanele Dlamini",
    t2.role = "SUPERVISOR",
    t2.specialization = "WATER",
    t2.district_id = 1;

MERGE (t3:Technician {employee_number: "EMP-0003"})
SET t3.name = "Thabo Molefe",
    t3.role = "TECHNICIAN",
    t3.specialization = "WATER",
    t3.district_id = 1;

MERGE (t4:Technician {employee_number: "EMP-0004"})
SET t4.name = "Lerato Mokoena",
    t4.role = "TECHNICIAN",
    t4.specialization = "ROADS",
    t4.district_id = 2;

MERGE (t5:Technician {employee_number: "EMP-0005"})
SET t5.name = "Bongani Zulu",
    t5.role = "TECHNICIAN",
    t5.specialization = "ELECTRICAL",
    t5.district_id = 3;

MERGE (t6:Technician {employee_number: "EMP-0006"})
SET t6.name = "Nomsa Sithole",
    t6.role = "INSPECTOR",
    t6.specialization = "GENERAL",
    t6.district_id = 4;

MERGE (t7:Technician {employee_number: "EMP-0007"})
SET t7.name = "Kagiso Motsepe",
    t7.role = "SUPERVISOR",
    t7.specialization = "ROADS",
    t7.district_id = 4;


// --- 2.7 FailureEvent nodes ---

MERGE (f1:FailureEvent {event_id: "FE-2025-001"})
SET f1.event_type = "BURST_PIPE",
    f1.severity = "CRITICAL",
    f1.occurred_at = datetime("2025-01-15T07:30:00Z"),
    f1.detected_by = "PUBLIC_REPORT",
    f1.description = "50mm UPVC pipe split seam failure — Commissioner/End St junction",
    f1.estimated_water_loss_litres = 30600,
    f1.properties_affected = 14,
    f1.road_affected = true;

MERGE (f2:FailureEvent {event_id: "FE-2025-002"})
SET f2.event_type = "PRESSURE_ANOMALY",
    f2.severity = "HIGH",
    f2.occurred_at = datetime("2025-01-18T14:45:00Z"),
    f2.detected_by = "IOT_SENSOR",
    f2.description = "Water pressure drop 12% over 200m — Vilakazi St pipe",
    f2.sensor_device_id = "SENSOR-WP-002";

MERGE (f3:FailureEvent {event_id: "FE-2025-003"})
SET f3.event_type = "LAMP_FAILURE",
    f3.severity = "MEDIUM",
    f3.occurred_at = datetime("2025-01-12T19:00:00Z"),
    f3.detected_by = "IOT_SENSOR",
    f3.description = "LED driver board failure — Sandton Drive Node 14",
    f3.fault_code = "E-07";

// =============================================================================
// END SECTION 2 — Execute above block, then continue with Section 3
// =============================================================================


// =============================================================================
// SECTION 3: RELATIONSHIP CREATION
//
// MERGE on relationships uses the full pattern: (a)-[r:TYPE]->(b)
// Properties on relationships are set with SET after MATCH.
// We MATCH nodes first, then MERGE the relationship — this is safer than
// chaining MERGE because it raises a clear error if a node is missing.
//
// GA9 — Reflection: In the MySQL system, relationships are implicit in FK
//   columns. In Neo4j, relationships are explicit first-class citizens with
//   their own properties. The shift from "asset_id column" to "CONNECTS_TO
//   relationship with properties" is the core lesson of graph databases.
//   Recognising this pattern is what allows adaptation to other graph
//   technologies: GraphQL schemas, RDF triples, knowledge graphs.
// =============================================================================

// --- 3.1 LOCATED_IN relationships (Asset → District) ---

MATCH (a:Asset {mysql_asset_id: 1}), (d:District {mysql_district_id: 1})
MERGE (a)-[:LOCATED_IN]->(d);

MATCH (a:Asset {mysql_asset_id: 2}), (d:District {mysql_district_id: 4})
MERGE (a)-[:LOCATED_IN]->(d);

MATCH (a:Asset {mysql_asset_id: 3}), (d:District {mysql_district_id: 2})
MERGE (a)-[:LOCATED_IN]->(d);

MATCH (a:Asset {mysql_asset_id: 4}), (d:District {mysql_district_id: 1})
MERGE (a)-[:LOCATED_IN]->(d);

MATCH (a:Asset {mysql_asset_id: 5}), (d:District {mysql_district_id: 3})
MERGE (a)-[:LOCATED_IN]->(d);

MATCH (a:Asset {mysql_asset_id: 6}), (d:District {mysql_district_id: 1})
MERGE (a)-[:LOCATED_IN]->(d);

MATCH (a:Asset {mysql_asset_id: 7}), (d:District {mysql_district_id: 5})
MERGE (a)-[:LOCATED_IN]->(d);

MATCH (a:Asset {mysql_asset_id: 8}), (d:District {mysql_district_id: 4})
MERGE (a)-[:LOCATED_IN]->(d);

MATCH (a:Asset {mysql_asset_id: 9}), (d:District {mysql_district_id: 7})
MERGE (a)-[:LOCATED_IN]->(d);

MATCH (a:Asset {mysql_asset_id: 10}), (d:District {mysql_district_id: 1})
MERGE (a)-[:LOCATED_IN]->(d);

MATCH (a:Asset {mysql_asset_id: 101}), (d:District {mysql_district_id: 1})
MERGE (a)-[:LOCATED_IN]->(d);

MATCH (a:Asset {mysql_asset_id: 102}), (d:District {mysql_district_id: 1})
MERGE (a)-[:LOCATED_IN]->(d);

MATCH (a:Asset {mysql_asset_id: 103}), (d:District {mysql_district_id: 1})
MERGE (a)-[:LOCATED_IN]->(d);

MATCH (a:Asset {mysql_asset_id: 104}), (d:District {mysql_district_id: 1})
MERGE (a)-[:LOCATED_IN]->(d);

MATCH (a:Asset {mysql_asset_id: 105}), (d:District {mysql_district_id: 1})
MERGE (a)-[:LOCATED_IN]->(d);

MATCH (a:Asset {mysql_asset_id: 106}), (d:District {mysql_district_id: 1})
MERGE (a)-[:LOCATED_IN]->(d);

MATCH (a:Asset {mysql_asset_id: 107}), (d:District {mysql_district_id: 1})
MERGE (a)-[:LOCATED_IN]->(d);

MATCH (a:Asset {mysql_asset_id: 108}), (d:District {mysql_district_id: 4})
MERGE (a)-[:LOCATED_IN]->(d);


// --- 3.2 OF_TYPE relationships (Asset → AssetType) ---

MATCH (a:Asset {mysql_asset_id: 1}),  (at:AssetType {mysql_asset_type_id: 1}) MERGE (a)-[:OF_TYPE]->(at);
MATCH (a:Asset {mysql_asset_id: 2}),  (at:AssetType {mysql_asset_type_id: 2}) MERGE (a)-[:OF_TYPE]->(at);
MATCH (a:Asset {mysql_asset_id: 3}),  (at:AssetType {mysql_asset_type_id: 3}) MERGE (a)-[:OF_TYPE]->(at);
MATCH (a:Asset {mysql_asset_id: 4}),  (at:AssetType {mysql_asset_type_id: 4}) MERGE (a)-[:OF_TYPE]->(at);
MATCH (a:Asset {mysql_asset_id: 5}),  (at:AssetType {mysql_asset_type_id: 5}) MERGE (a)-[:OF_TYPE]->(at);
MATCH (a:Asset {mysql_asset_id: 6}),  (at:AssetType {mysql_asset_type_id: 9}) MERGE (a)-[:OF_TYPE]->(at);
MATCH (a:Asset {mysql_asset_id: 7}),  (at:AssetType {mysql_asset_type_id: 7}) MERGE (a)-[:OF_TYPE]->(at);
MATCH (a:Asset {mysql_asset_id: 8}),  (at:AssetType {mysql_asset_type_id: 1}) MERGE (a)-[:OF_TYPE]->(at);
MATCH (a:Asset {mysql_asset_id: 9}),  (at:AssetType {mysql_asset_type_id: 6}) MERGE (a)-[:OF_TYPE]->(at);
MATCH (a:Asset {mysql_asset_id: 10}), (at:AssetType {mysql_asset_type_id: 10}) MERGE (a)-[:OF_TYPE]->(at);
MATCH (a:Asset {mysql_asset_id: 101}),(at:AssetType {mysql_asset_type_id: 1}) MERGE (a)-[:OF_TYPE]->(at);
MATCH (a:Asset {mysql_asset_id: 102}),(at:AssetType {mysql_asset_type_id: 1}) MERGE (a)-[:OF_TYPE]->(at);
MATCH (a:Asset {mysql_asset_id: 103}),(at:AssetType {mysql_asset_type_id: 1}) MERGE (a)-[:OF_TYPE]->(at);
MATCH (a:Asset {mysql_asset_id: 104}),(at:AssetType {mysql_asset_type_id: 1}) MERGE (a)-[:OF_TYPE]->(at);
MATCH (a:Asset {mysql_asset_id: 105}),(at:AssetType {mysql_asset_type_id: 1}) MERGE (a)-[:OF_TYPE]->(at);
MATCH (a:Asset {mysql_asset_id: 106}),(at:AssetType {mysql_asset_type_id: 3}) MERGE (a)-[:OF_TYPE]->(at);
MATCH (a:Asset {mysql_asset_id: 107}),(at:AssetType {mysql_asset_type_id: 5}) MERGE (a)-[:OF_TYPE]->(at);
MATCH (a:Asset {mysql_asset_id: 108}),(at:AssetType {mysql_asset_type_id: 1}) MERGE (a)-[:OF_TYPE]->(at);


// --- 3.3 FEEDS_INTO relationships (upstream → downstream water flow) ---
// Models the actual direction of water flow through the Braamfontein network.
// GA9 — Interest & Curiosity: Flow direction in water networks is determined
//   by topographic elevation and pump pressure. Modelling this correctly
//   requires understanding hydraulic engineering concepts.

MATCH (ps:Asset {mysql_asset_id: 10}), (a1:Asset {mysql_asset_id: 1})
MERGE (ps)-[:FEEDS_INTO {flow_direction: "PUMP_TO_MAIN", pressure_bar: 4.2}]->(a1);

MATCH (a1:Asset {mysql_asset_id: 1}), (j1:Asset {mysql_asset_id: 101})
MERGE (a1)-[:FEEDS_INTO {flow_direction: "WEST_TO_EAST", pressure_bar: 4.0}]->(j1);

MATCH (j1:Asset {mysql_asset_id: 101}), (a12:Asset {mysql_asset_id: 102})
MERGE (j1)-[:FEEDS_INTO {flow_direction: "JUNCTION_NORTH", pressure_bar: 3.9}]->(a12);

MATCH (j1:Asset {mysql_asset_id: 101}), (a13:Asset {mysql_asset_id: 103})
MERGE (j1)-[:FEEDS_INTO {flow_direction: "JUNCTION_SOUTH", pressure_bar: 3.9}]->(a13);

MATCH (a13:Asset {mysql_asset_id: 103}), (j2:Asset {mysql_asset_id: 104})
MERGE (a13)-[:FEEDS_INTO {flow_direction: "NORTH_TO_SOUTH", pressure_bar: 3.7}]->(j2);

MATCH (j2:Asset {mysql_asset_id: 104}), (a15:Asset {mysql_asset_id: 105})
MERGE (j2)-[:FEEDS_INTO {flow_direction: "JUNCTION_EAST", pressure_bar: 3.6}]->(a15);

MATCH (a18:Asset {mysql_asset_id: 108}), (a8:Asset {mysql_asset_id: 8})
MERGE (a18)-[:FEEDS_INTO {flow_direction: "MAIN_TO_SECTION", pressure_bar: 3.8}]->(a8);


// --- 3.4 CONNECTS_TO relationships (bidirectional physical network links) ---
// Used for undirected traversal: "what is reachable from this asset?"
// We create both directions to allow traversal without direction constraint.

MATCH (a1:Asset {mysql_asset_id: 1}),   (j1:Asset {mysql_asset_id: 101})
MERGE (a1)-[:CONNECTS_TO {distance_m: 85, connection_type: "INLINE"}]->(j1)
MERGE (j1)-[:CONNECTS_TO {distance_m: 85, connection_type: "INLINE"}]->(a1);

MATCH (j1:Asset {mysql_asset_id: 101}), (a12:Asset {mysql_asset_id: 102})
MERGE (j1)-[:CONNECTS_TO {distance_m: 120, connection_type: "BRANCH"}]->(a12)
MERGE (a12)-[:CONNECTS_TO {distance_m: 120, connection_type: "BRANCH"}]->(j1);

MATCH (j1:Asset {mysql_asset_id: 101}), (a13:Asset {mysql_asset_id: 103})
MERGE (j1)-[:CONNECTS_TO {distance_m: 95,  connection_type: "BRANCH"}]->(a13)
MERGE (a13)-[:CONNECTS_TO {distance_m: 95,  connection_type: "BRANCH"}]->(j1);

MATCH (a13:Asset {mysql_asset_id: 103}), (j2:Asset {mysql_asset_id: 104})
MERGE (a13)-[:CONNECTS_TO {distance_m: 110, connection_type: "INLINE"}]->(j2)
MERGE (j2)-[:CONNECTS_TO {distance_m: 110, connection_type: "INLINE"}]->(a13);

MATCH (j2:Asset {mysql_asset_id: 104}), (a15:Asset {mysql_asset_id: 105})
MERGE (j2)-[:CONNECTS_TO {distance_m: 200, connection_type: "BRANCH"}]->(a15)
MERGE (a15)-[:CONNECTS_TO {distance_m: 200, connection_type: "BRANCH"}]->(j2);

MATCH (j2:Asset {mysql_asset_id: 104}), (a4:Asset {mysql_asset_id: 4})
MERGE (j2)-[:CONNECTS_TO {distance_m: 55, connection_type: "CROSS_SERVICE"}]->(a4)
MERGE (a4)-[:CONNECTS_TO {distance_m: 55, connection_type: "CROSS_SERVICE"}]->(j2);

MATCH (a10:Asset {mysql_asset_id: 10}), (a1:Asset {mysql_asset_id: 1})
MERGE (a10)-[:CONNECTS_TO {distance_m: 320, connection_type: "PUMP_MAIN"}]->(a1)
MERGE (a1)-[:CONNECTS_TO {distance_m: 320, connection_type: "PUMP_MAIN"}]->(a10);

MATCH (a18:Asset {mysql_asset_id: 108}), (a8:Asset {mysql_asset_id: 8})
MERGE (a18)-[:CONNECTS_TO {distance_m: 180, connection_type: "INLINE"}]->(a8)
MERGE (a8)-[:CONNECTS_TO  {distance_m: 180, connection_type: "INLINE"}]->(a18);


// --- 3.5 DEPENDS_ON relationships (operational dependency) ---
// Asset A depends on Asset B means: if B fails, A is directly impacted.
// GA9 — Adaptability: This relationship models a directed dependency graph —
//   the same conceptual structure used in package dependency managers
//   (npm, pip, Maven), CI/CD pipeline DAGs, and microservice dependency maps.

MATCH (a16:Asset {mysql_asset_id: 106}), (a7:Asset {mysql_asset_id: 7})
MERGE (a16)-[:DEPENDS_ON {dependency_type: "ELECTRICAL_SUPPLY", critical: true}]->(a7);

MATCH (a3:Asset {mysql_asset_id: 3}),   (a7:Asset {mysql_asset_id: 7})
MERGE (a3)-[:DEPENDS_ON  {dependency_type: "ELECTRICAL_SUPPLY", critical: true}]->(a7);

MATCH (a6:Asset {mysql_asset_id: 6}),   (a7:Asset {mysql_asset_id: 7})
MERGE (a6)-[:DEPENDS_ON  {dependency_type: "ELECTRICAL_SUPPLY", critical: true}]->(a7);

MATCH (a10:Asset {mysql_asset_id: 10}), (a7:Asset {mysql_asset_id: 7})
MERGE (a10)-[:DEPENDS_ON {dependency_type: "ELECTRICAL_SUPPLY", critical: true}]->(a7);

MATCH (a1:Asset {mysql_asset_id: 1}),   (a10:Asset {mysql_asset_id: 10})
MERGE (a1)-[:DEPENDS_ON  {dependency_type: "WATER_PRESSURE",    critical: true}]->(a10);

MATCH (a8:Asset {mysql_asset_id: 8}),   (a18:Asset {mysql_asset_id: 108})
MERGE (a8)-[:DEPENDS_ON  {dependency_type: "WATER_PRESSURE",    critical: true}]->(a18);

MATCH (a17:Asset {mysql_asset_id: 107}), (a1:Asset {mysql_asset_id: 1})
MERGE (a17)-[:DEPENDS_ON {dependency_type: "PIPE_BELOW_ROAD", critical: false}]->(a1);


// --- 3.6 ADJACENT_TO relationships (geographic proximity) ---
// Used for impact radius analysis: which assets are physically near a failure?

MATCH (a1:Asset {mysql_asset_id: 1}),  (a17:Asset {mysql_asset_id: 107})
MERGE (a1)-[:ADJACENT_TO {proximity_m: 3.0, relationship_type: "PIPE_UNDER_ROAD"}]->(a17)
MERGE (a17)-[:ADJACENT_TO {proximity_m: 3.0, relationship_type: "ROAD_OVER_PIPE"}]->(a1);

MATCH (a1:Asset {mysql_asset_id: 1}),  (a16:Asset {mysql_asset_id: 106})
MERGE (a1)-[:ADJACENT_TO {proximity_m: 12.0, relationship_type: "STREET_INFRASTRUCTURE"}]->(a16)
MERGE (a16)-[:ADJACENT_TO {proximity_m: 12.0, relationship_type: "STREET_INFRASTRUCTURE"}]->(a1);

MATCH (a1:Asset {mysql_asset_id: 1}),  (a4:Asset {mysql_asset_id: 4})
MERGE (a1)-[:ADJACENT_TO {proximity_m: 8.0, relationship_type: "PARALLEL_UTILITY"}]->(a4)
MERGE (a4)-[:ADJACENT_TO {proximity_m: 8.0, relationship_type: "PARALLEL_UTILITY"}]->(a1);

MATCH (a9:Asset {mysql_asset_id: 9}),  (a5:Asset {mysql_asset_id: 5})
MERGE (a9)-[:ADJACENT_TO {proximity_m: 25.0, relationship_type: "ROADSIDE_DRAIN"}]->(a5)
MERGE (a5)-[:ADJACENT_TO {proximity_m: 25.0, relationship_type: "ROADSIDE_DRAIN"}]->(a9);

MATCH (a8:Asset {mysql_asset_id: 8}),  (a2:Asset {mysql_asset_id: 2})
MERGE (a8)-[:ADJACENT_TO {proximity_m: 400.0, relationship_type: "SAME_ROAD_CORRIDOR"}]->(a2)
MERGE (a2)-[:ADJACENT_TO {proximity_m: 400.0, relationship_type: "SAME_ROAD_CORRIDOR"}]->(a8);


// --- 3.7 REPORTED_FOR relationships (MaintenanceRequest → Asset) ---

MATCH (r:MaintenanceRequest {mysql_request_id: 1}), (a:Asset {mysql_asset_id: 1})
MERGE (r)-[:REPORTED_FOR {reported_at: datetime("2025-01-15T07:32:00Z")}]->(a);

MATCH (r:MaintenanceRequest {mysql_request_id: 2}), (a:Asset {mysql_asset_id: 2})
MERGE (r)-[:REPORTED_FOR {reported_at: datetime("2025-01-16T11:05:00Z")}]->(a);

MATCH (r:MaintenanceRequest {mysql_request_id: 3}), (a:Asset {mysql_asset_id: 3})
MERGE (r)-[:REPORTED_FOR {reported_at: datetime("2025-01-17T20:18:00Z")}]->(a);

MATCH (r:MaintenanceRequest {mysql_request_id: 4}), (a:Asset {mysql_asset_id: 9})
MERGE (r)-[:REPORTED_FOR {reported_at: datetime("2025-01-18T09:00:00Z")}]->(a);

MATCH (r:MaintenanceRequest {mysql_request_id: 5}), (a:Asset {mysql_asset_id: 8})
MERGE (r)-[:REPORTED_FOR {reported_at: datetime("2025-01-18T14:45:00Z")}]->(a);


// --- 3.8 RESOLVES relationships (WorkOrder → MaintenanceRequest) ---

MATCH (w:WorkOrder {mysql_work_order_id: 1}), (r:MaintenanceRequest {mysql_request_id: 1})
MERGE (w)-[:RESOLVES {created_at: datetime("2025-01-15T08:45:00Z")}]->(r);

MATCH (w:WorkOrder {mysql_work_order_id: 2}), (r:MaintenanceRequest {mysql_request_id: 2})
MERGE (w)-[:RESOLVES {created_at: datetime("2025-01-16T12:00:00Z")}]->(r);


// --- 3.9 ASSIGNED_TO relationships (WorkOrder → Technician) ---

MATCH (w:WorkOrder {mysql_work_order_id: 1}), (t:Technician {employee_number: "EMP-0003"})
MERGE (w)-[:ASSIGNED_TO {role: "LEAD_TECHNICIAN", assigned_at: datetime("2025-01-15T08:50:00Z")}]->(t);

MATCH (w:WorkOrder {mysql_work_order_id: 1}), (t:Technician {employee_number: "EMP-0002"})
MERGE (w)-[:ASSIGNED_TO {role: "SUPERVISOR", assigned_at: datetime("2025-01-15T08:50:00Z")}]->(t);

MATCH (w:WorkOrder {mysql_work_order_id: 2}), (t:Technician {employee_number: "EMP-0004"})
MERGE (w)-[:ASSIGNED_TO {role: "LEAD_TECHNICIAN", assigned_at: datetime("2025-01-16T12:00:00Z")}]->(t);

MATCH (w:WorkOrder {mysql_work_order_id: 2}), (t:Technician {employee_number: "EMP-0007"})
MERGE (w)-[:ASSIGNED_TO {role: "SUPERVISOR", assigned_at: datetime("2025-01-16T12:00:00Z")}]->(t);


// --- 3.10 CAUSED_BY and TRIGGERED_REQUEST relationships ---

MATCH (f:FailureEvent {event_id: "FE-2025-001"}), (a:Asset {mysql_asset_id: 1})
MERGE (f)-[:CAUSED_BY {confidence: "CONFIRMED", investigation_complete: true}]->(a);

MATCH (f:FailureEvent {event_id: "FE-2025-001"}), (r:MaintenanceRequest {mysql_request_id: 1})
MERGE (f)-[:TRIGGERED_REQUEST]->(r);

MATCH (f:FailureEvent {event_id: "FE-2025-002"}), (a:Asset {mysql_asset_id: 8})
MERGE (f)-[:CAUSED_BY {confidence: "PROBABLE", investigation_complete: false}]->(a);

MATCH (f:FailureEvent {event_id: "FE-2025-002"}), (r:MaintenanceRequest {mysql_request_id: 5})
MERGE (f)-[:TRIGGERED_REQUEST]->(r);

MATCH (f:FailureEvent {event_id: "FE-2025-003"}), (a:Asset {mysql_asset_id: 3})
MERGE (f)-[:CAUSED_BY {confidence: "CONFIRMED", fault_code: "E-07", investigation_complete: true}]->(a);

MATCH (f:FailureEvent {event_id: "FE-2025-003"}), (r:MaintenanceRequest {mysql_request_id: 3})
MERGE (f)-[:TRIGGERED_REQUEST]->(r);

// =============================================================================
// END SECTION 3 — Execute above block, then continue with Section 4
// =============================================================================


// =============================================================================
// SECTION 4: CYPHER QUERY LIBRARY
//
// 8 operational queries covering the core analytical use cases.
// Each query is prefixed with its business question and the GA9 attribute
// it demonstrates.
// =============================================================================


// --- QUERY 4.1: FAILURE CASCADE ANALYSIS ---
// Business question: "If the Commissioner St pipe (asset_id=1) fails completely,
//                    which other assets are at risk via CONNECTS_TO traversal?"
// GA9 — Interest & Curiosity: Variable-length path traversal (*1..6) is
//   impossible in standard SQL without a recursive CTE with depth limiting.
//   In Neo4j it is native syntax. Understanding why requires reading the
//   Cypher graph pattern matching specification — not just following examples.

MATCH path = (source:Asset {mysql_asset_id: 1})-[:CONNECTS_TO*1..6]->(affected:Asset)
WHERE affected.mysql_asset_id <> source.mysql_asset_id
WITH affected,
     length(path) AS hops,
     [node IN nodes(path) | node.asset_code] AS path_codes
RETURN
    affected.asset_code         AS affected_asset,
    affected.name               AS asset_name,
    affected.asset_type_code    AS type,
    affected.condition_rating   AS condition,
    affected.status             AS current_status,
    hops                        AS network_hops_from_failure,
    path_codes                  AS connection_path
ORDER BY hops ASC, affected.condition_rating ASC;


// --- QUERY 4.2: ELECTRICAL DEPENDENCY IMPACT ---
// Business question: "If Midrand Substation Alpha (asset_id=7) loses power,
//                    which assets immediately go offline via DEPENDS_ON?"
// GA9 — Adaptability: DEPENDS_ON traversal is the same pattern used in
//   software package vulnerability analysis (CVE propagation through
//   dependency trees) and cloud infrastructure blast radius assessment.
//   The graph pattern is domain-agnostic.

MATCH (substation:Asset {mysql_asset_id: 7})<-[:DEPENDS_ON*1..4]-(dependent:Asset)
OPTIONAL MATCH (dependent)-[:LOCATED_IN]->(d:District)
RETURN
    dependent.asset_code        AS dependent_asset,
    dependent.name              AS asset_name,
    dependent.asset_type_code   AS type,
    d.name                      AS district,
    dependent.replacement_cost_zar AS replacement_value_zar,
    dependent.status            AS current_status
ORDER BY dependent.replacement_cost_zar DESC;


// --- QUERY 4.3: SHORTEST TECHNICIAN DISPATCH ROUTE ---
// Business question: "What is the shortest network path between the
//                    Braamfontein Pump Station and the Commissioner St burst,
//                    and how many asset hops does it cross?"
// This models the pipe network route a repair team must access and isolate.
// GA9 — Staying Current: shortestPath() implements Dijkstra's algorithm
//   internally in Neo4j. Understanding this connects graph database operations
//   to algorithm theory — a foundational computer science concept with direct
//   application in GIS routing (OpenStreetMap, Google Maps API, Esri).

MATCH (pump:Asset {mysql_asset_id: 10}),
      (burst:Asset {mysql_asset_id: 1})
MATCH path = shortestPath((pump)-[:CONNECTS_TO|FEEDS_INTO*]-(burst))
RETURN
    length(path)                                                    AS total_hops,
    [node IN nodes(path) | node.asset_code]                        AS asset_sequence,
    [node IN nodes(path) | node.name]                              AS name_sequence,
    reduce(dist = 0, r IN relationships(path) |
           dist + coalesce(r.distance_m, 0))                       AS total_distance_m
;


// --- QUERY 4.4: ALL OPEN REQUESTS PER DISTRICT WITH RISK SCORE ---
// Business question: "Which districts have the highest concentration of
//                    unresolved critical and high priority requests,
//                    weighted by asset condition?"
// GA9 — Reflection: The paper system had no cross-district visibility.
//   A manager could not see that Soweto had 8 unresolved CRITICAL requests
//   while Sandton had 1. This query makes that comparison instant and objective.

MATCH (r:MaintenanceRequest)-[:REPORTED_FOR]->(a:Asset)-[:LOCATED_IN]->(d:District)
WHERE r.status NOT IN ["RESOLVED", "CLOSED", "CANCELLED"]
WITH d,
     COUNT(r) AS open_requests,
     SUM(CASE WHEN r.priority = "CRITICAL" THEN 4
              WHEN r.priority = "HIGH"     THEN 3
              WHEN r.priority = "MEDIUM"   THEN 2
              ELSE 1 END)                  AS weighted_priority_score,
     AVG(a.condition_rating)              AS avg_asset_condition,
     COLLECT(r.reference)                AS request_refs
RETURN
    d.name                              AS district,
    open_requests,
    weighted_priority_score,
    round(avg_asset_condition, 1)       AS avg_condition_rating,
    // Risk index: higher = more urgent intervention needed
    round(weighted_priority_score * (10 - avg_asset_condition), 1) AS district_risk_index,
    request_refs
ORDER BY district_risk_index DESC;


// --- QUERY 4.5: ASSET NETWORK NEIGHBOURHOOD (full neighbourhood map) ---
// Business question: "Show me every asset within 2 hops of the Vilakazi St
//                    degraded water pipe — what is the full exposure?"
// Used to build the network topology map in the Neo4j Bloom visualisation
// or Leaflet.js dashboard layer.
// GA9 — Initiative: Returning path data for visualisation requires
//   understanding how Neo4j Browser renders graph results vs table results.
//   The RETURN clause returns nodes and relationships, not rows — a completely
//   different output paradigm from SQL.

MATCH (centre:Asset {mysql_asset_id: 8})
MATCH path = (centre)-[r:CONNECTS_TO|FEEDS_INTO|DEPENDS_ON|ADJACENT_TO*1..2]-(neighbour:Asset)
RETURN centre, relationships(path), nodes(path)
LIMIT 50;


// --- QUERY 4.6: FAILURE EVENT CASCADE CHAIN ---
// Business question: "Trace the full causal chain: which failure event caused
//                    which request, which spawned which work order,
//                    and who is assigned?"
// This is the complete accountability chain for any incident — the graph
// version of the MySQL v_request_audit_trail view, but richer.
// GA9 — Reflection: The paper system had no causal chain. A burst pipe was
//   recorded as an isolated event with no link to the IoT sensor that detected
//   it, the request it spawned, or the technician who fixed it. This query
//   makes the full chain navigable in one statement.

MATCH (f:FailureEvent)-[:CAUSED_BY]->(a:Asset)
MATCH (f)-[:TRIGGERED_REQUEST]->(r:MaintenanceRequest)
OPTIONAL MATCH (w:WorkOrder)-[:RESOLVES]->(r)
OPTIONAL MATCH (w)-[:ASSIGNED_TO]->(t:Technician)
OPTIONAL MATCH (a)-[:LOCATED_IN]->(d:District)
RETURN
    f.event_id                  AS failure_event,
    f.event_type                AS failure_type,
    f.severity                  AS severity,
    f.occurred_at               AS when_occurred,
    f.detected_by               AS detection_source,
    a.asset_code                AS failed_asset,
    a.name                      AS asset_name,
    d.name                      AS district,
    r.reference                 AS request_raised,
    r.status                    AS request_status,
    w.reference                 AS work_order_created,
    w.status                    AS work_order_status,
    w.sla_breached              AS sla_breached,
    COLLECT(DISTINCT t.name)    AS assigned_technicians
ORDER BY f.occurred_at DESC;


// --- QUERY 4.7: TECHNICIAN WORKLOAD AND SPECIALIZATION MATCH ---
// Business question: "For all current work orders, are the assigned technicians
//                    correctly specialised for the asset type they are working on?
//                    Flag any mismatches."
// GA9 — Staying Current: Skills-to-task matching is a core function of modern
//   workforce management systems (SAP HCM, Workday). Implementing it as a graph
//   query demonstrates that graph databases are not just for network topology —
//   they model human resource relationships with equal elegance.

MATCH (w:WorkOrder)-[:ASSIGNED_TO {role: "LEAD_TECHNICIAN"}]->(t:Technician)
MATCH (w)-[:RESOLVES]->(r:MaintenanceRequest)-[:REPORTED_FOR]->(a:Asset)
OPTIONAL MATCH (a)-[:OF_TYPE]->(at:AssetType)
WITH t, w, a, at,
     CASE
       WHEN a.asset_type_code IN ["WATER_PIPE","PUMP_STATION","SEWER_MAIN","WATER_JUNCTION"]
            AND t.specialization = "WATER"       THEN true
       WHEN a.asset_type_code IN ["POTHOLE","ROAD_SURFACE"]
            AND t.specialization = "ROADS"       THEN true
       WHEN a.asset_type_code IN ["STREETLIGHT","TRAFFIC_SIGNAL","ELECTRICAL_SUBSTATION"]
            AND t.specialization = "ELECTRICAL"  THEN true
       WHEN a.asset_type_code IN ["STORM_DRAIN"]
            AND t.specialization IN ["WATER","GENERAL"] THEN true
       WHEN t.specialization = "GENERAL"         THEN true
       ELSE false
     END AS specialization_match
RETURN
    w.reference                 AS work_order,
    t.name                      AS lead_technician,
    t.specialization            AS technician_specialization,
    a.asset_type_code           AS asset_type,
    at.name                     AS asset_type_name,
    specialization_match        AS correctly_specialised,
    CASE WHEN specialization_match THEN "OK"
         ELSE "MISMATCH — REVIEW ASSIGNMENT" END AS flag
ORDER BY specialization_match ASC, w.reference;


// --- QUERY 4.8: INFRASTRUCTURE RISK HEAT MAP DATA ---
// Business question: "For every asset with condition_rating <= 5, what is its
//                    network centrality — how many other assets depend on it,
//                    connect to it, or feed from it?"
// High centrality + low condition = highest priority for capital replacement.
// GA9 — Independent Learning: Network centrality is a graph theory concept
//   (betweenness centrality, degree centrality). Neo4j Graph Data Science
//   (GDS) library provides a full suite of centrality algorithms. This query
//   is a simplified degree centrality calculation that any student can extend
//   by installing the GDS plugin and calling:
//   CALL gds.betweenness.stream('asset-graph') YIELD nodeId, score
//   That extension is the next learning step — this query is the gateway.

MATCH (a:Asset)
WHERE a.condition_rating <= 5 AND a.status <> "DECOMMISSIONED"
OPTIONAL MATCH (a)-[:CONNECTS_TO]-(connected:Asset)
OPTIONAL MATCH (dependent:Asset)-[:DEPENDS_ON]->(a)
OPTIONAL MATCH (a)-[:FEEDS_INTO]->(downstream:Asset)
OPTIONAL MATCH (a)-[:LOCATED_IN]->(d:District)
WITH a, d,
     COUNT(DISTINCT connected)  AS connected_count,
     COUNT(DISTINCT dependent)  AS dependent_count,
     COUNT(DISTINCT downstream) AS downstream_count
RETURN
    a.asset_code                                        AS asset,
    a.name                                              AS asset_name,
    a.asset_type_code                                   AS type,
    a.condition_rating                                  AS condition,
    a.status                                            AS status,
    d.name                                              AS district,
    connected_count                                     AS network_connections,
    dependent_count                                     AS assets_that_depend_on_this,
    downstream_count                                    AS downstream_assets_fed,
    (connected_count + dependent_count * 2 + downstream_count * 3)
                                                        AS centrality_risk_score,
    a.replacement_cost_zar                              AS replacement_cost_zar
ORDER BY centrality_risk_score DESC, a.condition_rating ASC;

// =============================================================================
// END SECTION 4
// =============================================================================


// =============================================================================
// SECTION 5: VERIFICATION AND GRAPH HEALTH CHECKS
// =============================================================================

// --- 5.1 Graph summary ---
MATCH (n)
RETURN labels(n)[0] AS node_label, COUNT(n) AS count
ORDER BY count DESC;

// --- 5.2 Relationship type summary ---
MATCH ()-[r]->()
RETURN type(r) AS relationship_type, COUNT(r) AS count
ORDER BY count DESC;

// --- 5.3 Constraint and index listing ---
SHOW CONSTRAINTS;
SHOW INDEXES;

// --- 5.4 Orphan check: assets with no LOCATED_IN relationship ---
MATCH (a:Asset)
WHERE NOT (a)-[:LOCATED_IN]->(:District)
RETURN a.asset_code AS orphaned_asset, a.name;

// --- 5.5 Orphan check: requests with no REPORTED_FOR relationship ---
MATCH (r:MaintenanceRequest)
WHERE NOT (r)-[:REPORTED_FOR]->(:Asset)
RETURN r.reference AS unlinked_request, r.status;

// --- 5.6 Cross-system reference integrity:
//         Every Asset node should have a mysql_asset_id ---
MATCH (a:Asset)
WHERE a.mysql_asset_id IS NULL
RETURN COUNT(a) AS assets_missing_mysql_id;

// --- 5.7 Full graph visualisation query (use in Neo4j Browser) ---
// Returns the entire graph for visual inspection — suitable for small datasets.
// In Neo4j Browser, change the layout to "Force" for network topology view.
MATCH (n)-[r]->(m)
RETURN n, r, m
LIMIT 150;

// =============================================================================
// END OF PHASE 4 — NEO4J GRAPH DATABASE LAYER
// =============================================================================
// GRAPH OBJECT INVENTORY:
//   Node Labels:         7  (Asset, District, AssetType, MaintenanceRequest,
//                             WorkOrder, Technician, FailureEvent)
//   Asset nodes:        18  (10 from MySQL seed + 8 extended network)
//   Relationships:       9  types, 60+ instances
//   Cypher Queries:      8  (cascade analysis, shortest path, risk scoring,
//                             workload matching, heat map, audit chain)
//   Constraints:         7  (one per node label, unique on primary ID)
//   Indexes:            11  (lookup optimisation per query pattern)
//
// INTEGRATION POINTS WITH OTHER PHASES:
//   → MySQL (Phase 1/2): mysql_asset_id on every Asset node
//                        mysql_request_id on every MaintenanceRequest node
//                        mysql_work_order_id on every WorkOrder node
//                        employee_number on every Technician node
//   → MongoDB (Phase 3): mongo_sensor_device_id used in FailureEvent nodes
//                        event_id bridges to MongoDB audit_events collection
//
// Next: Phase 5 — REST API integration layer connecting all three engines
// =============================================================================
