# City of Johannesburg IMTS
## Graduate Attribute 9 — Independent Learning: Reflection Document

---

## 1. Interest and Curiosity
*Inclination and ability to explore a subject in pursuit of knowledge.*

This project was not delivered by selecting one database engine and applying
familiar techniques. The problem was examined until the correct tools emerged
from the requirements — not from habit.

The CoJ's infrastructure is a network of interdependent physical assets.
That observation led to researching graph theory and Neo4j's property graph
model, a topic absent from the standard database curriculum. Discovering that
the openCypher specification had been formalised as ISO/IEC GQL (the first
international graph query language standard) confirmed that graph databases
are not a niche technology — they are becoming a SQL-equivalent standard.
That is a finding worth pursuing.

The MongoDB schema validation section demonstrates the same curiosity. The
$jsonSchema validator mirrors JSON Schema Draft 4, which is also the
foundation of OpenAPI 3.0 specs and TypeScript type definitions. Recognising
that the same mental model transfers across tooling boundaries — from MongoDB
validation to REST API documentation to frontend type safety — is the product
of following a thread of interest across domain boundaries, not staying within
the assigned textbook.

**Evidence in the codebase:** The `asset_readings` embedded sub-document in
MongoDB maintenance_logs has a deliberately variable schema per asset type.
A burst pipe log has pressure readings; a streetlight log has current draws.
This design decision was not in any prescribed reading — it emerged from
asking "what data does a water pipe technician actually capture that a
streetlight technician does not?"

---

## 2. Initiative
*Inclination and ability to explore additional opportunities for learning.*

The assignment specified eight tools. This system uses all eight and adds a
ninth: a production-grade Node.js REST API integration layer that was not
listed in the tool set but was architecturally necessary. Without it, the
three databases remain three isolated islands — the polyglot persistence model
only works when a coordination layer connects them.

Several additions went beyond the minimum:

**Security analytics in MongoDB (Phase 3, Query 4.6):** Logging failed login
attempts, detecting brute-force patterns by IP address, and flagging locked
accounts was not part of the brief. It was added because any system that
holds municipal infrastructure data is a security target, and a monitoring
system without security telemetry is incomplete. This required independently
learning about SIEM patterns and South Africa's POPIA compliance requirements
for audit log retention (7-year TTL index on the audit_events collection).

**phpMyAdmin privilege design at column level (Phase 6):** The analyst role
was granted SELECT on specific columns of the staff table — not the whole
table — to exclude email and phone fields. This reflects POPIA's field-level
access control requirement, which was researched independently and applied
to the privilege grant syntax.

**The centrality risk score (Phase 4, Query 4.8):** Computing a simplified
degree centrality metric for infrastructure assets — weighting downstream
dependencies more heavily than lateral connections — was not asked for. It
was included because the question "which asset is most dangerous to let
degrade?" has a computable answer in graph theory, and that answer is more
useful than a subjective condition rating alone. The annotation notes that
the next learning step is the Neo4j Graph Data Science library's
betweenness.stream() algorithm — a concrete forward pointer for continued
independent study.

---

## 3. Adaptability to New Situations
*Ability to apply prior knowledge, skills, and behaviours to new situations.*

**From software architecture to database design:** The DEPENDS_ON relationship
in Neo4j models a directed dependency graph. The same conceptual structure
appears in npm package dependency trees, CI/CD pipeline DAGs, and
microservice dependency maps. Recognising this pattern in a new domain
(physical infrastructure) and applying the graph model to it is the
definition of cross-domain knowledge transfer.

**From ITSM to municipal maintenance:** The SLA breach detection system
(MySQL EVENT + fn_calculate_sla_breach function) mirrors the escalation
logic in ITIL-aligned service desks like ServiceNow. The pattern — define a
deadline, measure against it continuously, escalate automatically — was
adapted from software service management to physical infrastructure
maintenance, where the "incidents" are burst pipes and the "SLA" is the
city's public commitment to respond within 4 hours to CRITICAL water failures.

**From ERP to parts inventory:** The point-in-time price snapshot in the
parts_usage table (unit_cost_at_time_zar stores the price at the moment of
use, not the current price) is a standard ERP pattern for historical cost
accuracy. Applying it to a municipal maintenance context — where the cost of
a 25mm UPVC pipe changes with the rand/dollar exchange rate — required
recognising the pattern and adapting it to a new data domain.

**From JavaScript promises to database concurrency:** The Promise.all()
pattern in the REST API controllers runs MySQL, MongoDB, and Neo4j queries
in parallel. The total API response latency equals the slowest query, not the
sum of all queries. This applies the event-loop concurrency model from
Node.js to a database integration problem — a direct transfer of prior
knowledge to a new architectural context.

---

## 4. Staying Current
*Engaged in staying current in the chosen field.*

The following technology choices reflect current (not legacy) practice:

**MySQL 8.x strict mode and utf8mb4:** The schema is set to STRICT_TRANS_TABLES
and uses utf8mb4 with unicode_ci collation. This is the MySQL 8.x standard.
South African municipal systems must store names in Zulu, Sotho, Afrikaans,
and English — utf8mb4 handles all of them. Systems still running utf8 (the
MySQL misnomer for a 3-byte UTF-8 subset) silently corrupt multilingual data.

**MongoDB TTL indexes for data lifecycle:** The 2-year TTL index on
sensor_readings and the 7-year TTL index on audit_events implement data
lifecycle management at the database layer. This is the current standard —
not a cron job, not application-level batch deletion. The 7-year audit
retention aligns with POPIA's record-keeping requirements, which came into
full effect in 2021.

**Neo4j 5.x constraint syntax:** The CREATE CONSTRAINT IF NOT EXISTS syntax
is Neo4j 5.x. The older CREATE INDEX ON :Label(property) syntax from Neo4j
3.x is deprecated. Using current syntax demonstrates engagement with
version-specific documentation rather than copying outdated tutorials.

**Express 4.x security middleware stack:** helmet (security headers),
express-rate-limit, CORS configuration with environment-specific origin
lists, and the graceful SIGTERM shutdown handler all reflect the current
Node.js production deployment standard. The SIGTERM handler is specifically
required by Kubernetes pod eviction — a current infrastructure operations
concern.

**GQL — the emerging graph query standard:** ISO/IEC 39075:2024 (GQL) is
the first international graph query language standard, ratified in 2024.
Cypher (Neo4j's query language) was a primary influence on its design.
Understanding Cypher now means understanding the direction the graph database
field is standardising toward — equivalent to having learned SQL before
it became the universal relational standard.

---

## 5. Reflection — Lessons Learned
*Ability to reflect on experiences and apply results to subsequent situations.
Learns from successes and mistakes, and recognises limitations.*

**Lesson from the paper system:** The most important architectural decision
in this entire project was the request_status_history table. It exists because
the paper system's most catastrophic failure was not losing data — it was
having no record of when decisions were made. A burst pipe reported on a
Monday that was not fixed until Friday had no record of why. Who reviewed it?
When? Why was it not escalated Tuesday? The immutable audit trail, populated
exclusively by a trigger (no application code can bypass it), makes every
delay visible and attributable. This is a structural fix for a systemic
failure — not a feature, but an architectural response to a lesson.

**Lesson from EAV attempts:** An early design considered a single asset_data
table with key-value pairs to handle the variable attributes of different
asset types (a pipe has diameter; a streetlight has wattage). This is the
Entity-Attribute-Value anti-pattern. EAV tables are nearly impossible to
query efficiently, cannot be indexed on value, and produce incomprehensible
SQL. The correct solution — variable schema in MongoDB for unstructured asset
readings, fixed relational schema in MySQL for structured asset metadata —
emerged from recognising this failure pattern and choosing the right tool
for the data shape rather than forcing a relational solution.

**Lesson from Neo4j node design:** The initial graph model had AssetType as
a property on Asset nodes, not a separate node type. This prevented the graph
query "find all water pipes with condition below 5" from using an index —
it required a full scan. Separating AssetType into its own node label and
connecting assets with OF_TYPE relationships made type-filtered traversal
index-supported. This is a graph-specific lesson: in relational databases,
lookup tables are for normalisation; in graph databases, they are for
traversal performance.

**Recognised limitation — no distributed transaction:** The four-step write
sequence in the submitRequest API endpoint (MySQL → MongoDB → Neo4j → MySQL
update) has no distributed transaction. If the Neo4j write fails after the
MySQL and MongoDB writes succeed, the system is in a partially inconsistent
state. The mitigation is a best-effort cleanup (cancel the MySQL record) and
a comment noting that Neo4j sync can be recovered by a reconciliation job.
This is an honest recognition of a genuine distributed systems limitation
— eventual consistency between the three engines is acceptable for this
workload, but the boundary between "eventually consistent" and "permanently
inconsistent" must be managed explicitly. In a production deployment, a
message queue (RabbitMQ or Kafka) between the API and the database writes
would solve this — that is the correct next architectural step.

**Recognised limitation — cursor performance in sp_generate_district_report:**
The Phase 2 cursor-based district report procedure iterates row-by-row and
calls three scalar functions per row. For a district with 50 open work orders,
this is acceptable. For a city-wide report with 5,000 orders, it is not. The
annotation in the procedure explicitly flags this: for large datasets, the
cursor should be replaced by a set-based query or a scheduled materialised
view. Knowing when a pattern is appropriate and when it will fail at scale is
a more valuable skill than knowing the pattern alone.

---

## Summary Table — GA9 Attributes to System Components

| GA9 Attribute        | Primary Evidence                                                        |
|----------------------|-------------------------------------------------------------------------|
| Interest & Curiosity | Neo4j graph model; MongoDB variable schema; GQL standard research       |
| Initiative           | REST API layer; security audit pipeline; POPIA compliance; risk scoring |
| Adaptability         | ITSM → municipal SLA; ERP → parts inventory; JS concurrency → DB layer  |
| Staying Current      | MySQL 8.x; MongoDB TTL; Neo4j 5.x syntax; GQL; Kubernetes SIGTERM       |
| Reflection           | Audit trail design; EAV rejection; graph node separation; distributed tx |

---

*City of Johannesburg Public Works Department — IMTS*
*Database Management System — Phase 6 Documentation*
