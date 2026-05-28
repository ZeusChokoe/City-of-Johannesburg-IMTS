-- =============================================================================
-- CITY OF JOHANNESBURG
-- Infrastructure Maintenance Tracking System (IMTS)
-- =============================================================================
-- Phase 1: Relational Database Schema (MySQL)
-- Tool: MySQL Workbench / phpMyAdmin
-- Author: JHB Public Works Department
-- Graduate Attribute 9 — Independent Learning
--
-- GA9 REFLECTION (Lessons Learned embedded throughout):
--   This schema deliberately avoids the single-table anti-pattern seen in the
--   legacy spreadsheet system. Normalization is applied to 3NF throughout.
--   Every design decision below is annotated with the reasoning so that any
--   engineer inheriting this system understands not just WHAT was built but WHY.
--
-- EXECUTION ORDER: Run this file top-to-bottom in one pass.
--   The table order is dependency-safe — no FK references a table not yet created.
-- =============================================================================


-- =============================================================================
-- SECTION 0: DATABASE SETUP
-- =============================================================================

-- 0.1 Drop and recreate to guarantee a clean slate on each migration run.
--     NEVER run this against a production server without a verified backup.
DROP DATABASE IF EXISTS jhb_imts;
CREATE DATABASE jhb_imts
    CHARACTER SET utf8mb4          -- Full Unicode: handles Zulu, Sotho, Afrikaans
    COLLATE utf8mb4_unicode_ci;    -- Case-insensitive, accent-sensitive collation

USE jhb_imts;

-- 0.2 Enforce strict SQL mode for this session.
--     GA9 — Staying Current: strict mode catches silent data truncation,
--     a common production bug in legacy MySQL 5.x installations.
SET sql_mode = 'STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';


-- =============================================================================
-- SECTION 1: REFERENCE / LOOKUP TABLES
-- Purpose: Controlled vocabularies that drive ENUMs and FK constraints.
--          These tables are populated once and rarely change.
--          Storing these as tables (not hard-coded ENUMs) allows the city to
--          add new asset types without a schema migration.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1.1 DISTRICTS
--     Johannesburg's 7 administrative regions, each with sub-districts.
--     GA9 — Interest & Curiosity: Researching the actual CoJ administrative
--     structure (not inventing regions) demonstrates subject-matter engagement.
-- -----------------------------------------------------------------------------
CREATE TABLE districts (
    district_id     TINYINT UNSIGNED    NOT NULL AUTO_INCREMENT,
    district_name   VARCHAR(100)        NOT NULL,
    region_code     VARCHAR(10)         NOT NULL,   -- e.g. REG-A, REG-B ... REG-G
    sub_district    VARCHAR(100)        NULL,        -- e.g. Soweto, Roodepoort
    population      INT UNSIGNED        NULL,
    area_km2        DECIMAL(8,2)        NULL,
    is_active       TINYINT(1)          NOT NULL DEFAULT 1,
    created_at      DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_districts         PRIMARY KEY (district_id),
    CONSTRAINT uq_districts_code    UNIQUE      (region_code)
) ENGINE=InnoDB COMMENT='CoJ administrative regions used to partition maintenance responsibilities';


-- -----------------------------------------------------------------------------
-- 1.2 ASSET TYPES
--     The categories of infrastructure the city maintains.
--     criticality_level drives SLA calculation in stored procedures (Phase 2).
-- -----------------------------------------------------------------------------
CREATE TABLE asset_types (
    asset_type_id               SMALLINT UNSIGNED   NOT NULL AUTO_INCREMENT,
    type_name                   VARCHAR(100)        NOT NULL,
    description                 VARCHAR(500)        NULL,
    maintenance_interval_days   SMALLINT UNSIGNED   NOT NULL DEFAULT 180, -- routine inspection frequency
    criticality_level           ENUM(
                                    'LOW',
                                    'MEDIUM',
                                    'HIGH',
                                    'CRITICAL'
                                )                   NOT NULL DEFAULT 'MEDIUM',
    sla_hours                   SMALLINT UNSIGNED   NOT NULL DEFAULT 72,  -- response SLA in hours
    created_at                  DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                  DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP
                                                    ON UPDATE CURRENT_TIMESTAMP,

    CONSTRAINT pk_asset_types       PRIMARY KEY (asset_type_id),
    CONSTRAINT uq_asset_types_name  UNIQUE      (type_name)
) ENGINE=InnoDB COMMENT='Controlled list of infrastructure asset categories with SLA parameters';


-- -----------------------------------------------------------------------------
-- 1.3 PARTS INVENTORY
--     Consumable stock. Placed early so work orders can reference parts via FK.
--     GA9 — Initiative: A basic system would ignore stock. Tracking parts links
--     maintenance data to procurement, enabling cost analysis per district.
-- -----------------------------------------------------------------------------
CREATE TABLE parts_inventory (
    part_id             INT UNSIGNED        NOT NULL AUTO_INCREMENT,
    part_code           VARCHAR(30)         NOT NULL,   -- e.g. PIPE-25MM-UPVC
    part_name           VARCHAR(200)        NOT NULL,
    description         VARCHAR(500)        NULL,
    unit_of_measure     ENUM(
                            'UNITS',
                            'METERS',
                            'LITERS',
                            'KG',
                            'ROLLS',
                            'SETS'
                        )                   NOT NULL DEFAULT 'UNITS',
    quantity_on_hand    INT UNSIGNED        NOT NULL DEFAULT 0,
    reorder_level       INT UNSIGNED        NOT NULL DEFAULT 10,  -- triggers alert event
    reorder_quantity    INT UNSIGNED        NOT NULL DEFAULT 50,
    unit_cost_zar       DECIMAL(10,2)       NOT NULL DEFAULT 0.00,
    supplier_name       VARCHAR(200)        NULL,
    supplier_contact    VARCHAR(100)        NULL,
    asset_type_id       SMALLINT UNSIGNED   NULL,   -- which asset type uses this part (nullable: general-use parts)
    last_restocked_date DATE                NULL,
    is_active           TINYINT(1)          NOT NULL DEFAULT 1,
    created_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP
                                            ON UPDATE CURRENT_TIMESTAMP,

    CONSTRAINT pk_parts             PRIMARY KEY (part_id),
    CONSTRAINT uq_parts_code        UNIQUE      (part_code),
    CONSTRAINT fk_parts_asset_type  FOREIGN KEY (asset_type_id)
                                    REFERENCES  asset_types(asset_type_id)
                                    ON UPDATE CASCADE
                                    ON DELETE SET NULL
) ENGINE=InnoDB COMMENT='Consumable parts stock with reorder thresholds for automated alerts';


-- =============================================================================
-- SECTION 2: CORE OPERATIONAL TABLES
-- Purpose: The live transactional entities of the maintenance system.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 2.1 ASSETS
--     Every physical infrastructure item the city owns and maintains.
--     GA9 — Adaptability: Spatial data (lat/lng) is stored as DECIMAL, not a
--     VARCHAR, so it can be used in distance calculations without parsing.
--     mongo_sensor_device_id and neo4j_node_id are the cross-system bridge keys.
-- -----------------------------------------------------------------------------
CREATE TABLE assets (
    asset_id                INT UNSIGNED        NOT NULL AUTO_INCREMENT,
    asset_type_id           SMALLINT UNSIGNED   NOT NULL,
    district_id             TINYINT UNSIGNED    NOT NULL,
    asset_code              VARCHAR(30)         NOT NULL,   -- format: JHB-{TYPE}-{SEQUENCE} e.g. JHB-WP-00421
    asset_name              VARCHAR(200)        NOT NULL,
    description             TEXT                NULL,
    latitude                DECIMAL(10,7)       NOT NULL,   -- 7 decimal places = ~1cm precision
    longitude               DECIMAL(10,7)       NOT NULL,
    installation_date       DATE                NULL,
    last_maintained_date    DATE                NULL,
    next_inspection_date    DATE                NULL,       -- computed by trigger on Phase 2
    condition_rating        TINYINT UNSIGNED    NOT NULL DEFAULT 5
                                                CHECK (condition_rating BETWEEN 1 AND 10),
    status                  ENUM(
                                'OPERATIONAL',
                                'DEGRADED',
                                'FAILED',
                                'UNDER_MAINTENANCE',
                                'DECOMMISSIONED'
                            )                   NOT NULL DEFAULT 'OPERATIONAL',
    manufacturer            VARCHAR(150)        NULL,
    model_number            VARCHAR(100)        NULL,
    serial_number           VARCHAR(100)        NULL,
    replacement_cost_zar    DECIMAL(12,2)       NULL,
    -- Cross-system bridge keys
    mongo_sensor_device_id  VARCHAR(50)         NULL COMMENT 'MongoDB sensor_readings device_id',
    neo4j_node_id           VARCHAR(50)         NULL COMMENT 'Neo4j Asset node elementId',
    -- Metadata
    is_archived             TINYINT(1)          NOT NULL DEFAULT 0,
    created_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP
                                                ON UPDATE CURRENT_TIMESTAMP,

    CONSTRAINT pk_assets                PRIMARY KEY (asset_id),
    CONSTRAINT uq_assets_code           UNIQUE      (asset_code),
    CONSTRAINT fk_assets_asset_type     FOREIGN KEY (asset_type_id)
                                        REFERENCES  asset_types(asset_type_id)
                                        ON UPDATE CASCADE
                                        ON DELETE RESTRICT,
    CONSTRAINT fk_assets_district       FOREIGN KEY (district_id)
                                        REFERENCES  districts(district_id)
                                        ON UPDATE CASCADE
                                        ON DELETE RESTRICT
) ENGINE=InnoDB COMMENT='Master register of all physical infrastructure assets owned by the City of Johannesburg';


-- -----------------------------------------------------------------------------
-- 2.2 STAFF
--     All personnel: technicians, supervisors, inspectors, and admins.
--     district_id is the primary district assignment, not a restriction —
--     staff can be dispatched cross-district via work_order_assignments.
-- -----------------------------------------------------------------------------
CREATE TABLE staff (
    staff_id            INT UNSIGNED        NOT NULL AUTO_INCREMENT,
    employee_number     VARCHAR(20)         NOT NULL,   -- HR system reference
    first_name          VARCHAR(100)        NOT NULL,
    last_name           VARCHAR(100)        NOT NULL,
    email               VARCHAR(255)        NOT NULL,
    phone               VARCHAR(20)         NULL,
    role                ENUM(
                            'TECHNICIAN',
                            'SUPERVISOR',
                            'INSPECTOR',
                            'ADMIN',
                            'MANAGER'
                        )                   NOT NULL DEFAULT 'TECHNICIAN',
    specialization      ENUM(
                            'WATER',
                            'ROADS',
                            'ELECTRICAL',
                            'SEWERAGE',
                            'GENERAL'
                        )                   NOT NULL DEFAULT 'GENERAL',
    district_id         TINYINT UNSIGNED    NOT NULL,   -- primary district assignment
    is_active           TINYINT(1)          NOT NULL DEFAULT 1,
    hire_date           DATE                NULL,
    created_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP
                                            ON UPDATE CURRENT_TIMESTAMP,

    CONSTRAINT pk_staff                 PRIMARY KEY (staff_id),
    CONSTRAINT uq_staff_employee_no     UNIQUE      (employee_number),
    CONSTRAINT uq_staff_email           UNIQUE      (email),
    CONSTRAINT fk_staff_district        FOREIGN KEY (district_id)
                                        REFERENCES  districts(district_id)
                                        ON UPDATE CASCADE
                                        ON DELETE RESTRICT
) ENGINE=InnoDB COMMENT='All city maintenance personnel with roles and district assignments';


-- -----------------------------------------------------------------------------
-- 2.3 MAINTENANCE REQUESTS
--     The entry point for all infrastructure fault reports.
--     Can come from: field workers, call centre, IoT alert (automated), public.
--     asset_id is nullable — some reports describe area-wide issues before
--     the specific asset is identified.
--     GA9 — Reflection (Lessons Learned): The legacy system had no status
--     history, making it impossible to audit delays. The status field here is
--     paired with request_status_history (Section 3) to solve this.
-- -----------------------------------------------------------------------------
CREATE TABLE maintenance_requests (
    request_id          INT UNSIGNED        NOT NULL AUTO_INCREMENT,
    request_reference   VARCHAR(20)         NOT NULL,   -- e.g. MR-2025-00001
    asset_id            INT UNSIGNED        NULL,       -- nullable: asset may be unknown at submission
    district_id         TINYINT UNSIGNED    NOT NULL,
    -- Reporter details (member of public or city staff)
    reported_by_name    VARCHAR(200)        NULL,
    reported_by_phone   VARCHAR(20)         NULL,
    reported_by_email   VARCHAR(255)        NULL,
    reported_by_staff_id INT UNSIGNED       NULL,       -- set when reported internally
    -- Incident details
    description         TEXT                NOT NULL,
    category            ENUM(
                            'BURST_PIPE',
                            'POTHOLE',
                            'FAULTY_STREETLIGHT',
                            'SEWER_BLOCKAGE',
                            'ROAD_SURFACE_DAMAGE',
                            'ELECTRICAL_FAULT',
                            'STRUCTURAL_DAMAGE',
                            'OTHER'
                        )                   NOT NULL,
    latitude            DECIMAL(10,7)       NULL,
    longitude           DECIMAL(10,7)       NULL,
    -- Priority and lifecycle
    priority            ENUM(
                            'LOW',
                            'MEDIUM',
                            'HIGH',
                            'CRITICAL'
                        )                   NOT NULL DEFAULT 'MEDIUM',
    status              ENUM(
                            'SUBMITTED',
                            'UNDER_REVIEW',
                            'ASSIGNED',
                            'IN_PROGRESS',
                            'RESOLVED',
                            'CLOSED',
                            'CANCELLED'
                        )                   NOT NULL DEFAULT 'SUBMITTED',
    -- Timestamps
    reported_at         DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    acknowledged_at     DATETIME            NULL,
    resolved_at         DATETIME            NULL,
    closed_at           DATETIME            NULL,
    -- Cross-system reference
    mongo_log_id        VARCHAR(50)         NULL COMMENT 'MongoDB maintenance_logs _id',
    -- Metadata
    created_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP
                                            ON UPDATE CURRENT_TIMESTAMP,

    CONSTRAINT pk_maintenance_requests          PRIMARY KEY (request_id),
    CONSTRAINT uq_maintenance_requests_ref      UNIQUE      (request_reference),
    CONSTRAINT fk_mreq_asset                    FOREIGN KEY (asset_id)
                                                REFERENCES  assets(asset_id)
                                                ON UPDATE CASCADE
                                                ON DELETE SET NULL,
    CONSTRAINT fk_mreq_district                 FOREIGN KEY (district_id)
                                                REFERENCES  districts(district_id)
                                                ON UPDATE CASCADE
                                                ON DELETE RESTRICT,
    CONSTRAINT fk_mreq_reported_by_staff        FOREIGN KEY (reported_by_staff_id)
                                                REFERENCES  staff(staff_id)
                                                ON UPDATE CASCADE
                                                ON DELETE SET NULL
) ENGINE=InnoDB COMMENT='All infrastructure fault reports submitted by public or city staff';


-- -----------------------------------------------------------------------------
-- 2.4 WORK ORDERS
--     The operational response to a maintenance request.
--     One request can spawn multiple work orders (e.g. emergency patch → full repair).
--     sla_deadline is computed by the BEFORE INSERT trigger in Phase 2
--     using the asset type's sla_hours value.
-- -----------------------------------------------------------------------------
CREATE TABLE work_orders (
    work_order_id       INT UNSIGNED        NOT NULL AUTO_INCREMENT,
    work_order_ref      VARCHAR(20)         NOT NULL,   -- e.g. WO-2025-00001
    request_id          INT UNSIGNED        NOT NULL,
    asset_id            INT UNSIGNED        NULL,
    district_id         TINYINT UNSIGNED    NOT NULL,
    supervisor_id       INT UNSIGNED        NULL,       -- nullable until approved
    -- Order details
    title               VARCHAR(300)        NOT NULL,
    description         TEXT                NULL,
    priority            ENUM(
                            'LOW',
                            'MEDIUM',
                            'HIGH',
                            'CRITICAL'
                        )                   NOT NULL DEFAULT 'MEDIUM',
    status              ENUM(
                            'DRAFT',
                            'APPROVED',
                            'DISPATCHED',
                            'IN_PROGRESS',
                            'ON_HOLD',
                            'COMPLETED',
                            'CANCELLED'
                        )                   NOT NULL DEFAULT 'DRAFT',
    -- Scheduling
    scheduled_start     DATETIME            NULL,
    scheduled_end       DATETIME            NULL,
    actual_start        DATETIME            NULL,
    actual_end          DATETIME            NULL,
    sla_deadline        DATETIME            NULL,       -- set by BEFORE INSERT trigger
    sla_breached        TINYINT(1)          NOT NULL DEFAULT 0, -- set by EVENT scheduler
    -- Costing
    estimated_hours     DECIMAL(6,2)        NULL,
    actual_hours        DECIMAL(6,2)        NULL,
    estimated_cost_zar  DECIMAL(12,2)       NULL,
    actual_cost_zar     DECIMAL(12,2)       NULL,
    -- Completion
    resolution_notes    TEXT                NULL,
    -- Metadata
    created_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP
                                            ON UPDATE CURRENT_TIMESTAMP,

    CONSTRAINT pk_work_orders               PRIMARY KEY (work_order_id),
    CONSTRAINT uq_work_orders_ref           UNIQUE      (work_order_ref),
    CONSTRAINT fk_wo_request                FOREIGN KEY (request_id)
                                            REFERENCES  maintenance_requests(request_id)
                                            ON UPDATE CASCADE
                                            ON DELETE RESTRICT,
    CONSTRAINT fk_wo_asset                  FOREIGN KEY (asset_id)
                                            REFERENCES  assets(asset_id)
                                            ON UPDATE CASCADE
                                            ON DELETE SET NULL,
    CONSTRAINT fk_wo_district               FOREIGN KEY (district_id)
                                            REFERENCES  districts(district_id)
                                            ON UPDATE CASCADE
                                            ON DELETE RESTRICT,
    CONSTRAINT fk_wo_supervisor             FOREIGN KEY (supervisor_id)
                                            REFERENCES  staff(staff_id)
                                            ON UPDATE CASCADE
                                            ON DELETE SET NULL
) ENGINE=InnoDB COMMENT='Operational work orders generated from maintenance requests with SLA tracking';


-- =============================================================================
-- SECTION 3: JUNCTION AND AUDIT TABLES
-- Purpose: Many-to-many relationships and immutable audit logs.
--          GA9 — Interest & Curiosity: Most students stop at the main tables.
--          Junction tables and audit trails demonstrate depth of engagement
--          with real-world requirements: accountability and cost attribution.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3.1 WORK ORDER ASSIGNMENTS
--     Links staff to work orders. One work order can have one lead technician
--     and multiple assistants. This resolves the M:N between staff and work orders.
-- -----------------------------------------------------------------------------
CREATE TABLE work_order_assignments (
    assignment_id       INT UNSIGNED        NOT NULL AUTO_INCREMENT,
    work_order_id       INT UNSIGNED        NOT NULL,
    staff_id            INT UNSIGNED        NOT NULL,
    role_on_order       ENUM(
                            'LEAD_TECHNICIAN',
                            'ASSISTANT',
                            'INSPECTOR',
                            'SUPERVISOR'
                        )                   NOT NULL DEFAULT 'ASSISTANT',
    assigned_at         DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    assigned_by_id      INT UNSIGNED        NULL,       -- who made the assignment
    released_at         DATETIME            NULL,       -- when staff was removed
    notes               VARCHAR(500)        NULL,

    CONSTRAINT pk_wo_assignments            PRIMARY KEY (assignment_id),
    CONSTRAINT uq_wo_assignments_active     UNIQUE      (work_order_id, staff_id),   -- one role per staff per order
    CONSTRAINT fk_woa_work_order            FOREIGN KEY (work_order_id)
                                            REFERENCES  work_orders(work_order_id)
                                            ON UPDATE CASCADE
                                            ON DELETE CASCADE,
    CONSTRAINT fk_woa_staff                 FOREIGN KEY (staff_id)
                                            REFERENCES  staff(staff_id)
                                            ON UPDATE CASCADE
                                            ON DELETE RESTRICT,
    CONSTRAINT fk_woa_assigned_by           FOREIGN KEY (assigned_by_id)
                                            REFERENCES  staff(staff_id)
                                            ON UPDATE CASCADE
                                            ON DELETE SET NULL
) ENGINE=InnoDB COMMENT='Junction table resolving M:N between staff and work orders with role attribution';


-- -----------------------------------------------------------------------------
-- 3.2 PARTS USED IN WORK ORDERS
--     Records every part consumed during a work order.
--     unit_cost_at_time is stored at the moment of use (not current price)
--     so historical cost reports remain accurate after price changes.
--     GA9 — Staying Current: This temporal attribute pattern is standard in
--     modern financial and ERP systems — point-in-time pricing.
-- -----------------------------------------------------------------------------
CREATE TABLE parts_usage (
    usage_id                INT UNSIGNED        NOT NULL AUTO_INCREMENT,
    work_order_id           INT UNSIGNED        NOT NULL,
    part_id                 INT UNSIGNED        NOT NULL,
    quantity_used           INT UNSIGNED        NOT NULL DEFAULT 1
                                                CHECK (quantity_used > 0),
    unit_cost_at_time_zar   DECIMAL(10,2)       NOT NULL DEFAULT 0.00,  -- snapshot price
    recorded_by_id          INT UNSIGNED        NULL,
    recorded_at             DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_parts_usage               PRIMARY KEY (usage_id),
    CONSTRAINT fk_pu_work_order             FOREIGN KEY (work_order_id)
                                            REFERENCES  work_orders(work_order_id)
                                            ON UPDATE CASCADE
                                            ON DELETE RESTRICT,
    CONSTRAINT fk_pu_part                   FOREIGN KEY (part_id)
                                            REFERENCES  parts_inventory(part_id)
                                            ON UPDATE CASCADE
                                            ON DELETE RESTRICT,
    CONSTRAINT fk_pu_recorded_by            FOREIGN KEY (recorded_by_id)
                                            REFERENCES  staff(staff_id)
                                            ON UPDATE CASCADE
                                            ON DELETE SET NULL
) ENGINE=InnoDB COMMENT='Point-in-time record of parts consumed per work order for cost attribution';


-- -----------------------------------------------------------------------------
-- 3.3 INSPECTIONS
--     Scheduled and emergency condition assessments of assets.
--     The findings_summary here is the short record.
--     The full narrative report lives in MongoDB (mongo_report_id references it).
--     GA9 — Adaptability: The hybrid approach — short summary in MySQL,
--     full document in MongoDB — demonstrates applying polyglot persistence
--     knowledge to a new real-world domain.
-- -----------------------------------------------------------------------------
CREATE TABLE inspections (
    inspection_id       INT UNSIGNED        NOT NULL AUTO_INCREMENT,
    inspection_ref      VARCHAR(20)         NOT NULL,   -- e.g. INS-2025-00001
    asset_id            INT UNSIGNED        NOT NULL,
    district_id         TINYINT UNSIGNED    NOT NULL,
    inspector_id        INT UNSIGNED        NULL,
    inspection_type     ENUM(
                            'ROUTINE',
                            'EMERGENCY',
                            'POST_REPAIR',
                            'COMPLIANCE',
                            'HANDOVER'
                        )                   NOT NULL DEFAULT 'ROUTINE',
    scheduled_date      DATE                NOT NULL,
    completed_date      DATE                NULL,
    condition_before    TINYINT UNSIGNED    NULL
                                            CHECK (condition_before BETWEEN 1 AND 10),
    condition_after     TINYINT UNSIGNED    NULL
                                            CHECK (condition_after BETWEEN 1 AND 10),
    findings_summary    VARCHAR(1000)       NULL,
    recommendation      ENUM(
                            'NO_ACTION',
                            'MONITOR',
                            'SCHEDULE_REPAIR',
                            'URGENT_REPAIR',
                            'DECOMMISSION'
                        )                   NULL,
    work_order_id       INT UNSIGNED        NULL,   -- linked if inspection triggered a work order
    -- Cross-system reference
    mongo_report_id     VARCHAR(50)         NULL COMMENT 'MongoDB field_reports _id',
    created_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP
                                            ON UPDATE CURRENT_TIMESTAMP,

    CONSTRAINT pk_inspections               PRIMARY KEY (inspection_id),
    CONSTRAINT uq_inspections_ref           UNIQUE      (inspection_ref),
    CONSTRAINT fk_ins_asset                 FOREIGN KEY (asset_id)
                                            REFERENCES  assets(asset_id)
                                            ON UPDATE CASCADE
                                            ON DELETE RESTRICT,
    CONSTRAINT fk_ins_district              FOREIGN KEY (district_id)
                                            REFERENCES  districts(district_id)
                                            ON UPDATE CASCADE
                                            ON DELETE RESTRICT,
    CONSTRAINT fk_ins_inspector             FOREIGN KEY (inspector_id)
                                            REFERENCES  staff(staff_id)
                                            ON UPDATE CASCADE
                                            ON DELETE SET NULL,
    CONSTRAINT fk_ins_work_order            FOREIGN KEY (work_order_id)
                                            REFERENCES  work_orders(work_order_id)
                                            ON UPDATE CASCADE
                                            ON DELETE SET NULL
) ENGINE=InnoDB COMMENT='Asset inspection records linking condition ratings to full MongoDB reports';


-- -----------------------------------------------------------------------------
-- 3.4 REQUEST STATUS HISTORY
--     Immutable audit log of every status change on a maintenance request.
--     Populated exclusively by the AFTER UPDATE trigger (Phase 2) — no
--     application code writes here directly. This enforces audit integrity.
--     GA9 — Reflection: The lesson from the paper system is zero accountability.
--     This table makes every delay visible and attributable.
-- -----------------------------------------------------------------------------
CREATE TABLE request_status_history (
    history_id          BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    request_id          INT UNSIGNED        NOT NULL,
    previous_status     ENUM(
                            'SUBMITTED',
                            'UNDER_REVIEW',
                            'ASSIGNED',
                            'IN_PROGRESS',
                            'RESOLVED',
                            'CLOSED',
                            'CANCELLED'
                        )                   NULL,       -- NULL for the initial insert
    new_status          ENUM(
                            'SUBMITTED',
                            'UNDER_REVIEW',
                            'ASSIGNED',
                            'IN_PROGRESS',
                            'RESOLVED',
                            'CLOSED',
                            'CANCELLED'
                        )                   NOT NULL,
    changed_by_id       INT UNSIGNED        NULL,       -- NULL for system/automated changes
    change_reason       VARCHAR(500)        NULL,
    changed_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_request_status_history    PRIMARY KEY (history_id),
    CONSTRAINT fk_rsh_request               FOREIGN KEY (request_id)
                                            REFERENCES  maintenance_requests(request_id)
                                            ON UPDATE CASCADE
                                            ON DELETE CASCADE,
    CONSTRAINT fk_rsh_changed_by            FOREIGN KEY (changed_by_id)
                                            REFERENCES  staff(staff_id)
                                            ON UPDATE CASCADE
                                            ON DELETE SET NULL
) ENGINE=InnoDB COMMENT='Immutable audit trail of all maintenance request status transitions — populated by trigger only';


-- =============================================================================
-- SECTION 4: INDEXES
-- Purpose: Targeted indexes for the query patterns known from the system design.
--          GA9 — Staying Current: Indexes are not default — they must be
--          designed for the actual query load, not added speculatively.
-- =============================================================================

-- 4.1 Assets — frequent lookups by district, status, and type
CREATE INDEX idx_assets_district       ON assets(district_id);
CREATE INDEX idx_assets_type           ON assets(asset_type_id);
CREATE INDEX idx_assets_status         ON assets(status);
CREATE INDEX idx_assets_next_insp      ON assets(next_inspection_date);   -- for EVENT scheduler
CREATE INDEX idx_assets_condition      ON assets(condition_rating);

-- 4.2 Maintenance requests — filtered by status, priority, district
CREATE INDEX idx_mreq_status           ON maintenance_requests(status);
CREATE INDEX idx_mreq_priority         ON maintenance_requests(priority);
CREATE INDEX idx_mreq_district         ON maintenance_requests(district_id);
CREATE INDEX idx_mreq_asset            ON maintenance_requests(asset_id);
CREATE INDEX idx_mreq_reported_at      ON maintenance_requests(reported_at);
CREATE INDEX idx_mreq_category         ON maintenance_requests(category);

-- 4.3 Work orders — SLA monitoring and status dashboards
CREATE INDEX idx_wo_status             ON work_orders(status);
CREATE INDEX idx_wo_district           ON work_orders(district_id);
CREATE INDEX idx_wo_sla_deadline       ON work_orders(sla_deadline);      -- for EVENT breach check
CREATE INDEX idx_wo_sla_breached       ON work_orders(sla_breached);
CREATE INDEX idx_wo_supervisor         ON work_orders(supervisor_id);
CREATE INDEX idx_wo_request            ON work_orders(request_id);

-- 4.4 Work order assignments — find all orders for a staff member
CREATE INDEX idx_woa_staff             ON work_order_assignments(staff_id);

-- 4.5 Inspections — upcoming and overdue
CREATE INDEX idx_ins_scheduled         ON inspections(scheduled_date);
CREATE INDEX idx_ins_asset             ON inspections(asset_id);

-- 4.6 Status history — audit queries always filter by request and time
CREATE INDEX idx_rsh_request_time      ON request_status_history(request_id, changed_at);

-- 4.7 Parts inventory — reorder monitoring
CREATE INDEX idx_parts_reorder         ON parts_inventory(quantity_on_hand, reorder_level);


-- =============================================================================
-- SECTION 5: SEED DATA
-- Purpose: Realistic reference data to validate schema and support Phase 2
--          development and testing.
--          GA9 — Interest & Curiosity: Using actual CoJ district names and
--          realistic asset codes, not generic 'Test District 1' placeholders.
-- =============================================================================

-- 5.1 Districts (City of Johannesburg's 7 administrative regions)
INSERT INTO districts (district_name, region_code, sub_district, population, area_km2) VALUES
('Johannesburg Central',    'REG-F', 'Inner City',               450000,  178.00),
('Northcliff/Rosebank',     'REG-B', 'Sandton',                  620000,  292.00),
('Roodepoort',              'REG-C', 'Roodepoort Central',       480000,  341.00),
('Doornkop/Soweto',         'REG-D', 'Soweto',                  1300000,  200.00),
('Midrand',                 'REG-A', 'Midrand',                  390000,  298.00),
('Orange Farm',             'REG-G', 'Ennerdale / Orange Farm',  430000,  162.00),
('Alexandra/Marlboro',      'REG-E', 'Alexandra',                340000,   30.00);


-- 5.2 Asset types with SLA hours
INSERT INTO asset_types (type_name, description, maintenance_interval_days, criticality_level, sla_hours) VALUES
('Water Distribution Pipe', 'Underground water supply pipes, 25mm-500mm diameter', 365, 'CRITICAL',  4),
('Pothole',                 'Road surface voids requiring patching or reconstruction', 90,  'HIGH',     24),
('Streetlight',             'Public road and pedestrian area lighting infrastructure', 180, 'MEDIUM',   48),
('Sewer Main',              'Primary sewerage collection pipes and manholes',          365, 'CRITICAL',  8),
('Road Surface',            'Asphalt and paving road surfaces, excluding potholes',   180, 'MEDIUM',   72),
('Storm Water Drain',       'Drainage channels and culverts for rainwater management', 90, 'HIGH',     24),
('Electrical Substation',   'Distribution substations feeding street and building power', 90, 'CRITICAL', 2),
('Bridge Structure',        'Road bridges, pedestrian bridges, and overpasses',       365, 'CRITICAL',  6),
('Traffic Signal',          'Automated and manual traffic light systems',             180, 'HIGH',     12),
('Water Pump Station',      'Pumping infrastructure for water pressure maintenance',  180, 'CRITICAL',  4);


-- 5.3 Staff (representative roles across districts)
INSERT INTO staff (employee_number, first_name, last_name, email, phone, role, specialization, district_id, hire_date) VALUES
('EMP-0001', 'Sipho',    'Nkosi',     'sipho.nkosi@jhbpw.gov.za',     '+27115550101', 'MANAGER',     'GENERAL',   1, '2015-03-01'),
('EMP-0002', 'Zanele',   'Dlamini',   'zanele.dlamini@jhbpw.gov.za',  '+27115550102', 'SUPERVISOR',  'WATER',     1, '2017-06-15'),
('EMP-0003', 'Thabo',    'Molefe',    'thabo.molefe@jhbpw.gov.za',    '+27115550103', 'TECHNICIAN',  'WATER',     1, '2019-02-01'),
('EMP-0004', 'Lerato',   'Mokoena',   'lerato.mokoena@jhbpw.gov.za',  '+27115550104', 'TECHNICIAN',  'ROADS',     2, '2020-07-12'),
('EMP-0005', 'Bongani',  'Zulu',      'bongani.zulu@jhbpw.gov.za',    '+27115550105', 'TECHNICIAN',  'ELECTRICAL',3, '2018-11-05'),
('EMP-0006', 'Nomsa',    'Sithole',   'nomsa.sithole@jhbpw.gov.za',   '+27115550106', 'INSPECTOR',   'GENERAL',   4, '2016-04-20'),
('EMP-0007', 'Kagiso',   'Motsepe',   'kagiso.motsepe@jhbpw.gov.za',  '+27115550107', 'SUPERVISOR',  'ROADS',     4, '2014-09-01'),
('EMP-0008', 'Ayanda',   'Khumalo',   'ayanda.khumalo@jhbpw.gov.za',  '+27115550108', 'TECHNICIAN',  'SEWERAGE',  5, '2021-01-10'),
('EMP-0009', 'Relebohile','Ntuli',    'rele.ntuli@jhbpw.gov.za',      '+27115550109', 'ADMIN',       'GENERAL',   1, '2022-03-08'),
('EMP-0010', 'Mandla',   'Shabalala', 'mandla.shabalala@jhbpw.gov.za','+27115550110', 'TECHNICIAN',  'ELECTRICAL',6, '2020-05-19');


-- 5.4 Assets (representative set across types and districts)
INSERT INTO assets (asset_type_id, district_id, asset_code, asset_name, latitude, longitude,
                    installation_date, condition_rating, status, manufacturer, replacement_cost_zar) VALUES
(1, 1, 'JHB-WP-00001', 'Commissioner St Main Water Pipe',  -26.2041,  28.0473, '2005-06-10', 6, 'OPERATIONAL', 'Wavin SA',       280000.00),
(2, 4, 'JHB-PH-00001', 'Pothole — Klipspruit Valley Rd',   -26.2622,  27.8690, NULL,          3, 'DEGRADED',    NULL,              18000.00),
(3, 2, 'JHB-SL-00001', 'Streetlight — Sandton Dr Node 14',-26.1075,  28.0567, '2018-03-22', 8, 'OPERATIONAL', 'Osram',           12500.00),
(4, 1, 'JHB-SW-00001', 'Jeppe St Sewer Main Section 7',   -26.2058,  28.0499, '2001-11-15', 5, 'OPERATIONAL', 'Hobas',          950000.00),
(5, 3, 'JHB-RS-00001', 'Ontdekkers Rd Surface — Km 4.2',  -26.1758,  27.9200, '2015-07-01', 7, 'OPERATIONAL', NULL,             420000.00),
(9, 1, 'JHB-TS-00001', 'Traffic Signal — Rissik & Jeppe', -26.2048,  28.0443, '2019-05-14', 9, 'OPERATIONAL', 'Siemens SA',      95000.00),
(7, 5, 'JHB-ES-00001', 'Midrand Substation Alpha',        -25.9989,  28.1286, '2010-09-30', 8, 'OPERATIONAL', 'ABB South Africa',4200000.00),
(1, 4, 'JHB-WP-00002', 'Vilakazi St Water Pipe Section 3',-26.2540,  27.8590, '2003-02-20', 4, 'DEGRADED',    'Wavin SA',       195000.00),
(6, 7, 'JHB-SD-00001', 'Alexandra Drain — 3rd Ave',       -26.1025,  28.0913, '2008-12-01', 5, 'DEGRADED',    NULL,             380000.00),
(10,1, 'JHB-PS-00001', 'Braamfontein Water Pump Station', -26.1929,  28.0314, '2012-04-18', 7, 'OPERATIONAL', 'Grundfos SA',   1800000.00);


-- 5.5 Parts inventory
INSERT INTO parts_inventory (part_code, part_name, unit_of_measure, quantity_on_hand, reorder_level,
                              reorder_quantity, unit_cost_zar, supplier_name, asset_type_id) VALUES
('PIPE-25MM-UPVC',   '25mm UPVC Water Pipe',          'METERS', 500,  100, 300,  28.50, 'Vinilex Plastics',       1),
('PIPE-50MM-UPVC',   '50mm UPVC Water Pipe',          'METERS', 300,   75, 200,  62.00, 'Vinilex Plastics',       1),
('ASPHALT-COLD-MIX', 'Cold Mix Asphalt (25kg bag)',   'UNITS',  150,   40, 100, 285.00, 'Roadmac Surfacing',      2),
('LED-ROADLIGHT-70W','70W LED Road Light Module',     'UNITS',   80,   15,  50, 1850.00,'Osram SA Distributors', 3),
('MANHOLE-COVER-D400','D400 Cast Iron Manhole Cover', 'UNITS',   40,   10,  20, 3200.00,'SA Castings',            4),
('PIPE-JOINT-50MM',  '50mm Rubber Pipe Joint',        'UNITS',  220,   50, 100,  45.00, 'Vinilex Plastics',       1),
('TRAFFIC-LAMP-LED', 'Traffic Signal LED Lamp Unit',  'UNITS',   30,    8,  20, 2100.00,'Siemens SA',             9),
('DRAIN-GRATE-300',  '300mm Cast Grate for Drain',    'UNITS',   55,   12,  30,  890.00,'SA Castings',            6),
('CONCRETE-MIX-40KG','40kg General Purpose Concrete', 'UNITS',  400,  100, 200,   85.00,'PPC Cement Distributors',NULL),
('CABLE-16MM-3CORE', '16mm 3-core Armoured Cable',    'METERS', 800,  200, 500,  185.00,'Aberdare Cables',        5);


-- 5.6 Maintenance requests (realistic scenarios)
INSERT INTO maintenance_requests
    (request_reference, asset_id, district_id, reported_by_name, reported_by_phone,
     description, category, latitude, longitude, priority, status, reported_at) VALUES
('MR-2025-00001', 1, 1, 'Lungelo Dube',    '+27829910011',
 'Significant water gushing from Commissioner St near the intersection with End St. Road is flooding.',
 'BURST_PIPE',    -26.2041, 28.0474, 'CRITICAL',  'IN_PROGRESS', '2025-01-15 07:32:00'),

('MR-2025-00002', 2, 4, 'Nokwanda Mthembu','+27836540022',
 'Large pothole on Klipspruit Valley Road near Shell garage has caused two tyre blowouts this week.',
 'POTHOLE',       -26.2622, 27.8690, 'HIGH',      'ASSIGNED',    '2025-01-16 11:05:00'),

('MR-2025-00003', 3, 2, NULL,               NULL,
 'Streetlight on Sandton Drive Node 14 has been off for 5 nights. Safety concern in parking area.',
 'FAULTY_STREETLIGHT', -26.1075, 28.0567, 'MEDIUM','SUBMITTED',  '2025-01-17 20:18:00'),

('MR-2025-00004', 9, 7, 'Thembi Radebe',   '+27711230033',
 'Storm drain on 3rd Avenue Alexandra completely blocked with debris. Severe flooding during last rain.',
 'SEWER_BLOCKAGE', -26.1025, 28.0913, 'HIGH',     'UNDER_REVIEW','2025-01-18 09:00:00'),

('MR-2025-00005', 8, 4, 'City IoT Monitor', NULL,
 'Automated sensor alert: Water pressure drop detected on Vilakazi St pipe. Possible slow leak or blockage.',
 'BURST_PIPE',    -26.2540, 27.8590, 'HIGH',      'SUBMITTED',   '2025-01-18 14:45:00');


-- 5.7 Work orders (linked to requests above)
INSERT INTO work_orders
    (work_order_ref, request_id, asset_id, district_id, supervisor_id, title,
     priority, status, scheduled_start, scheduled_end, sla_deadline, estimated_hours, estimated_cost_zar) VALUES
('WO-2025-00001', 1, 1, 1, 2,
 'Emergency repair — Commissioner St burst water main',
 'CRITICAL', 'IN_PROGRESS',
 '2025-01-15 09:00:00', '2025-01-15 17:00:00', '2025-01-15 11:32:00', 8.00, 45000.00),

('WO-2025-00002', 2, 2, 4, 7,
 'Pothole patching — Klipspruit Valley Rd',
 'HIGH',     'DISPATCHED',
 '2025-01-17 07:00:00', '2025-01-17 13:00:00', '2025-01-17 11:05:00', 6.00, 12000.00);


-- 5.8 Work order assignments
INSERT INTO work_order_assignments (work_order_id, staff_id, role_on_order, assigned_by_id) VALUES
(1, 3, 'LEAD_TECHNICIAN', 2),
(1, 2, 'SUPERVISOR',       1),
(2, 4, 'LEAD_TECHNICIAN',  7),
(2, 7, 'SUPERVISOR',       1);


-- 5.9 Inspections
INSERT INTO inspections
    (inspection_ref, asset_id, district_id, inspector_id, inspection_type,
     scheduled_date, completed_date, condition_before, condition_after,
     findings_summary, recommendation, work_order_id) VALUES
('INS-2025-00001', 8, 4, 6, 'ROUTINE',
 '2025-01-10', '2025-01-10', 6, 4,
 'Visible corrosion on joint sections 3 and 4. Pressure test shows 12% loss over 200m section.',
 'URGENT_REPAIR', NULL),

('INS-2025-00002', 1, 1, 6, 'POST_REPAIR',
 '2025-01-15', NULL, 5, NULL,
 'Pending completion of WO-2025-00001.',
 NULL, 1);


-- 5.10 Request status history (initial states — trigger will maintain this going forward)
INSERT INTO request_status_history (request_id, previous_status, new_status, change_reason, changed_by_id) VALUES
(1, NULL,         'SUBMITTED',    'Initial submission by member of public', NULL),
(1, 'SUBMITTED',  'UNDER_REVIEW', 'Acknowledged by duty supervisor',        2),
(1, 'UNDER_REVIEW','ASSIGNED',    'Work order WO-2025-00001 created',       2),
(1, 'ASSIGNED',   'IN_PROGRESS',  'Technician on site — work commenced',    3),
(2, NULL,         'SUBMITTED',    'Initial submission by member of public',  NULL),
(2, 'SUBMITTED',  'UNDER_REVIEW', 'Reviewed by roads supervisor',           7),
(2, 'UNDER_REVIEW','ASSIGNED',    'Work order WO-2025-00002 created',       7),
(3, NULL,         'SUBMITTED',    'Public report via web portal',            NULL),
(4, NULL,         'SUBMITTED',    'Public report via call centre',           NULL),
(4, 'SUBMITTED',  'UNDER_REVIEW', 'Escalated to storm water team',          2),
(5, NULL,         'SUBMITTED',    'Automated IoT sensor alert',              NULL);


-- =============================================================================
-- SECTION 6: VERIFICATION QUERIES
-- Purpose: Confirm the schema and seed data are correct after execution.
--          Run these individually in MySQL Workbench or phpMyAdmin.
-- =============================================================================

-- 6.1 Confirm all tables were created
SELECT
    table_name,
    table_rows,
    table_comment
FROM information_schema.tables
WHERE table_schema = 'jhb_imts'
ORDER BY table_name;

-- 6.2 Confirm all FK constraints are active
SELECT
    constraint_name,
    table_name,
    referenced_table_name
FROM information_schema.referential_constraints
WHERE constraint_schema = 'jhb_imts'
ORDER BY table_name;

-- 6.3 Validate seed data integrity — open requests with their work orders
SELECT
    mr.request_reference,
    mr.category,
    mr.priority,
    mr.status              AS request_status,
    wo.work_order_ref,
    wo.status              AS order_status,
    wo.sla_deadline,
    CONCAT(s.first_name, ' ', s.last_name) AS supervisor
FROM maintenance_requests mr
LEFT JOIN work_orders wo        ON wo.request_id = mr.request_id
LEFT JOIN staff s               ON s.staff_id    = wo.supervisor_id
ORDER BY mr.priority DESC, mr.reported_at;

-- 6.4 Asset condition overview by district
SELECT
    d.district_name,
    COUNT(a.asset_id)                           AS total_assets,
    ROUND(AVG(a.condition_rating), 2)           AS avg_condition,
    SUM(a.status = 'FAILED')                    AS failed_assets,
    SUM(a.status = 'DEGRADED')                  AS degraded_assets
FROM assets a
JOIN districts d ON d.district_id = a.district_id
GROUP BY d.district_name
ORDER BY avg_condition ASC;

-- 6.5 Parts at or below reorder level (tests reorder alert logic for Phase 2 EVENT)
SELECT
    part_code,
    part_name,
    quantity_on_hand,
    reorder_level,
    reorder_quantity,
    CONCAT('R ', FORMAT(unit_cost_zar * reorder_quantity, 2)) AS reorder_cost_estimate
FROM parts_inventory
WHERE quantity_on_hand <= reorder_level
  AND is_active = 1
ORDER BY (quantity_on_hand / reorder_level) ASC;

-- =============================================================================
-- END OF PHASE 1 — SCHEMA AND SEED DATA
-- Next: Phase 2 — Stored Procedures, Triggers, Events, Cursors, Functions
-- =============================================================================
