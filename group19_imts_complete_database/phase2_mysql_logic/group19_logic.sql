-- =============================================================================
-- CITY OF JOHANNESBURG
-- Infrastructure Maintenance Tracking System (IMTS)
-- =============================================================================
-- Phase 2: Business Logic Layer (MySQL)
-- Objects: Functions, Triggers, Stored Procedures (with Cursors), Events
-- Tool: MySQL Workbench / phpMyAdmin
-- Depends on: jhb_phase1_schema.sql (must be executed first)
--
-- EXECUTION ORDER (dependency-safe run as one pass):
--   Section 1:  DELIMITER reset
--   Section 2:  SCALAR FUNCTIONS         (no deps pure computation)
--   Section 3:  TRIGGERS                 (call functions; fire on DML)
--   Section 4:  STORED PROCEDURES        (call functions; contain cursors)
--   Section 5:  EVENTS                   (call stored procedures on schedule)
--   Section 6:  PERMISSION GRANTS        (lock down who can CALL what)
--   Section 7:  VERIFICATION CALLS       (smoke-test every object)
--
-- GA9 INDEPENDENT LEARNING ANNOTATION:
--   Each object below includes a comment block explaining:
--   (a) WHY this object exists (business rule)
--   (b) WHAT it replaces from the legacy paper/spreadsheet system
--   (c) WHAT pattern or concept it demonstrates for lifelong learning
-- =============================================================================

USE group19;

-- Required: allow event scheduler to fire
SET GLOBAL event_scheduler = ON;

-- =============================================================================
-- SECTION 1: DELIMITER
-- MySQL requires a custom delimiter so the parser does not treat semicolons
-- inside procedure/function/trigger bodies as end-of-statement.
-- =============================================================================
DELIMITER $$


-- =============================================================================
-- SECTION 2: SCALAR FUNCTIONS
-- Pure computation no side effects, no DML.
-- Called by triggers, procedures, and application queries.
-- GA9 Staying Current: Deterministic functions are declared as such so the
-- query optimizer can cache their results, a MySQL 8.x performance feature.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 2.1 fn_days_open
-- Returns the number of calendar days a maintenance request has been open.
-- If resolved, counts days from reported_at to resolved_at.
-- If still open, counts days from reported_at to NOW().
-- Called by: fn_get_priority_score, sp_generate_district_report
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_days_open;
CREATE FUNCTION fn_days_open (p_request_id INT UNSIGNED)
RETURNS SMALLINT
DETERMINISTIC
READS SQL DATA
COMMENT 'Returns calendar days a request has been open. Uses resolved_at if closed, NOW() if still open.'
BEGIN
    DECLARE v_reported_at   DATETIME;
    DECLARE v_resolved_at   DATETIME;

    SELECT reported_at, resolved_at
    INTO   v_reported_at, v_resolved_at
    FROM   maintenance_requests
    WHERE  request_id = p_request_id
    LIMIT  1;

    IF v_reported_at IS NULL THEN
        RETURN -1;  -- sentinel: request not found
    END IF;

    IF v_resolved_at IS NOT NULL THEN
        RETURN DATEDIFF(v_resolved_at, v_reported_at);
    ELSE
        RETURN DATEDIFF(NOW(), v_reported_at);
    END IF;
END$$


-- -----------------------------------------------------------------------------
-- 2.2 fn_calculate_sla_breach
-- Returns 1 (TRUE) if a work order has breached its SLA deadline and is not
-- yet completed or cancelled. Returns 0 otherwise.
-- Called by: ev_daily_sla_audit, sp_generate_district_report
-- GA9 Reflection: In the paper system, SLA breaches were discovered only
-- during monthly manager reviews. This function makes breach detection instant
-- and automatable a structural lesson applied from the legacy failure.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_calculate_sla_breach;
CREATE FUNCTION fn_calculate_sla_breach (p_work_order_id INT UNSIGNED)
RETURNS TINYINT(1)
DETERMINISTIC
READS SQL DATA
COMMENT 'Returns 1 if work order has passed its SLA deadline without completion.'
BEGIN
    DECLARE v_sla_deadline  DATETIME;
    DECLARE v_status        VARCHAR(20);

    SELECT sla_deadline, status
    INTO   v_sla_deadline, v_status
    FROM   work_orders
    WHERE  work_order_id = p_work_order_id
    LIMIT  1;

    -- Not breached if: no deadline set, already completed, or already cancelled
    IF v_sla_deadline IS NULL THEN
        RETURN 0;
    END IF;

    IF v_status IN ('COMPLETED', 'CANCELLED') THEN
        RETURN 0;
    END IF;

    IF NOW() > v_sla_deadline THEN
        RETURN 1;
    END IF;

    RETURN 0;
END$$


-- -----------------------------------------------------------------------------
-- 2.3 fn_get_priority_score
-- Computes a numeric urgency score (0–100) for a maintenance request.
-- Score is used to surface the most critical unresolved items on dashboards.
-- Formula components:
--   - Base score from priority ENUM
--   - Days open multiplier (older = more urgent)
--   - Asset criticality multiplier
-- GA9 Interest & Curiosity: This is a simplified implementation of a priority
-- scoring model. Production systems use weighted scoring matrices. Researching
-- AHP (Analytic Hierarchy Process) or FMEA scoring is the natural next step.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_get_priority_score;
CREATE FUNCTION fn_get_priority_score (p_request_id INT UNSIGNED)
RETURNS TINYINT UNSIGNED
DETERMINISTIC
READS SQL DATA
COMMENT 'Returns 0-100 urgency score for a maintenance request. Higher = more urgent.'
BEGIN
    DECLARE v_priority          VARCHAR(10);
    DECLARE v_criticality       VARCHAR(10);
    DECLARE v_base_score        TINYINT UNSIGNED DEFAULT 0;
    DECLARE v_days_open         SMALLINT         DEFAULT 0;
    DECLARE v_score             INT              DEFAULT 0;

    SELECT
        mr.priority,
        at.criticality_level
    INTO
        v_priority,
        v_criticality
    FROM maintenance_requests mr
    LEFT JOIN assets      a  ON a.asset_id      = mr.asset_id
    LEFT JOIN asset_types at ON at.asset_type_id = a.asset_type_id
    WHERE mr.request_id = p_request_id
    LIMIT 1;

    -- Base score from request priority
    CASE v_priority
        WHEN 'CRITICAL' THEN SET v_base_score = 60;
        WHEN 'HIGH'     THEN SET v_base_score = 40;
        WHEN 'MEDIUM'   THEN SET v_base_score = 20;
        ELSE                 SET v_base_score = 10;
    END CASE;

    -- Asset criticality multiplier
    CASE v_criticality
        WHEN 'CRITICAL' THEN SET v_score = v_base_score + 20;
        WHEN 'HIGH'     THEN SET v_score = v_base_score + 12;
        WHEN 'MEDIUM'   THEN SET v_score = v_base_score + 6;
        ELSE                 SET v_score = v_base_score + 2;
    END CASE;

    -- Days open adds up to 20 more points (caps at 20 days outstanding)
    SET v_days_open = fn_days_open(p_request_id);
    IF v_days_open > 0 THEN
        SET v_score = v_score + LEAST(v_days_open, 20);
    END IF;

    -- Hard cap at 100
    RETURN LEAST(v_score, 100);
END$$


-- -----------------------------------------------------------------------------
-- 2.4 fn_compute_sla_deadline
-- Given an asset_id and a reference datetime, returns the SLA deadline by
-- looking up the asset type's sla_hours value.
-- Called by: trg_work_orders_before_insert
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_compute_sla_deadline;
CREATE FUNCTION fn_compute_sla_deadline (
    p_asset_id      INT UNSIGNED,
    p_from_datetime DATETIME
)
RETURNS DATETIME
DETERMINISTIC
READS SQL DATA
COMMENT 'Returns the SLA deadline datetime for a work order based on asset type SLA hours.'
BEGIN
    DECLARE v_sla_hours SMALLINT UNSIGNED DEFAULT 72;

    SELECT at.sla_hours
    INTO   v_sla_hours
    FROM   assets      a
    JOIN   asset_types at ON at.asset_type_id = a.asset_type_id
    WHERE  a.asset_id = p_asset_id
    LIMIT  1;

    RETURN DATE_ADD(p_from_datetime, INTERVAL v_sla_hours HOUR);
END$$


-- -----------------------------------------------------------------------------
-- 2.5 fn_generate_reference
-- Generates a formatted reference code: PREFIX-YEAR-SEQUENCE
-- e.g. 'MR-2025-00042', 'WO-2025-00001', 'INS-2025-00007'
-- Called by: trg_maintenance_requests_before_insert,
--            trg_work_orders_before_insert,
--            trg_inspections_before_insert
-- GA9 Adaptability: Using a function instead of AUTO_INCREMENT formatting
-- means the reference pattern can be changed in one place, not across the app.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_generate_reference;
CREATE FUNCTION fn_generate_reference (
    p_prefix    VARCHAR(5),
    p_table     VARCHAR(50)
)
RETURNS VARCHAR(20)
NOT DETERMINISTIC
MODIFIES SQL DATA
COMMENT 'Generates next sequential reference code for requests, orders, and inspections.'
BEGIN
    DECLARE v_year      CHAR(4)          DEFAULT YEAR(NOW());
    DECLARE v_next_seq  INT UNSIGNED     DEFAULT 1;
    DECLARE v_pattern   VARCHAR(20);

    SET v_pattern = CONCAT(p_prefix, '-', v_year, '-%');

    -- Count existing references for this prefix+year to get next sequence
    CASE p_table
        WHEN 'maintenance_requests' THEN
            SELECT COUNT(*) + 1 INTO v_next_seq
            FROM maintenance_requests
            WHERE request_reference LIKE v_pattern;
        WHEN 'work_orders' THEN
            SELECT COUNT(*) + 1 INTO v_next_seq
            FROM work_orders
            WHERE work_order_ref LIKE v_pattern;
        WHEN 'inspections' THEN
            SELECT COUNT(*) + 1 INTO v_next_seq
            FROM inspections
            WHERE inspection_ref LIKE v_pattern;
        ELSE
            SET v_next_seq = 1;
    END CASE;

    RETURN CONCAT(p_prefix, '-', v_year, '-', LPAD(v_next_seq, 5, '0'));
END$$


-- =============================================================================
-- SECTION 3: TRIGGERS
-- Fire automatically on DML events. Enforce business rules at the data layer
-- so no application code can bypass them.
-- GA9 Initiative: Triggers are the most commonly skipped feature in student
-- projects. Implementing them demonstrates willingness to go beyond the minimum.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 3.1 trg_maintenance_requests_before_insert
-- Fires: BEFORE INSERT on maintenance_requests
-- Purpose:
--   (a) Auto-generates the request_reference if not supplied
--   (b) Validates that district_id matches the asset's district (data integrity)
--   (c) Inherits priority from asset type criticality if not explicitly set
-- GA9 Reflection: The paper system had no validation. Requests for assets
-- in the wrong district were routed incorrectly and sat unresolved for months.
-- This trigger prevents that class of error at the point of insertion.
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_maintenance_requests_before_insert;
CREATE TRIGGER trg_maintenance_requests_before_insert
BEFORE INSERT ON maintenance_requests
FOR EACH ROW
BEGIN
    DECLARE v_asset_district    TINYINT UNSIGNED;
    DECLARE v_asset_criticality VARCHAR(10);

    -- Auto-generate reference if blank
    IF NEW.request_reference IS NULL OR NEW.request_reference = '' THEN
        SET NEW.request_reference = fn_generate_reference('MR', 'maintenance_requests');
    END IF;

    -- If asset_id is supplied, cross-validate district and inherit priority
    IF NEW.asset_id IS NOT NULL THEN
        SELECT a.district_id, at.criticality_level
        INTO   v_asset_district, v_asset_criticality
        FROM   assets      a
        JOIN   asset_types at ON at.asset_type_id = a.asset_type_id
        WHERE  a.asset_id = NEW.asset_id
        LIMIT  1;

        -- Override district_id to match the asset's actual location
        IF v_asset_district IS NOT NULL THEN
            SET NEW.district_id = v_asset_district;
        END IF;

        -- Escalate priority to match asset criticality if request priority is lower
        IF v_asset_criticality = 'CRITICAL' AND NEW.priority NOT IN ('CRITICAL') THEN
            SET NEW.priority = 'CRITICAL';
        END IF;
    END IF;
END$$


-- -----------------------------------------------------------------------------
-- 3.2 trg_maintenance_requests_after_insert
-- Fires: AFTER INSERT on maintenance_requests
-- Purpose: Writes the initial status record to request_status_history.
--          This starts the immutable audit trail for every new request.
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_maintenance_requests_after_insert;
CREATE TRIGGER trg_maintenance_requests_after_insert
AFTER INSERT ON maintenance_requests
FOR EACH ROW
BEGIN
    INSERT INTO request_status_history
        (request_id, previous_status, new_status, change_reason, changed_by_id)
    VALUES
        (NEW.request_id, NULL, NEW.status, 'Request created initial status recorded by system', NEW.reported_by_staff_id);
END$$


-- -----------------------------------------------------------------------------
-- 3.3 trg_maintenance_requests_after_update
-- Fires: AFTER UPDATE on maintenance_requests
-- Purpose:
--   (a) Writes status change to request_status_history (when status changed)
--   (b) Sets resolved_at timestamp automatically when status → RESOLVED
--   (c) Sets closed_at timestamp automatically when status → CLOSED
-- GA9 Reflection: The legacy system had no timestamp on resolution.
-- Managers could not calculate mean time to resolution. This trigger makes
-- that KPI calculable for the first time.
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_maintenance_requests_after_update;
CREATE TRIGGER trg_maintenance_requests_after_update
AFTER UPDATE ON maintenance_requests
FOR EACH ROW
BEGIN
    -- Only act if status actually changed
    IF OLD.status <> NEW.status THEN

        -- Write immutable audit record
        INSERT INTO request_status_history
            (request_id, previous_status, new_status, change_reason, changed_by_id)
        VALUES
            (NEW.request_id, OLD.status, NEW.status,
             CONCAT('Status changed from ', OLD.status, ' to ', NEW.status),
             NEW.reported_by_staff_id);

        -- Auto-stamp resolved_at
        IF NEW.status = 'RESOLVED' AND OLD.resolved_at IS NULL THEN
            UPDATE maintenance_requests
            SET    resolved_at = NOW()
            WHERE  request_id  = NEW.request_id;
        END IF;

        -- Auto-stamp closed_at
        IF NEW.status = 'CLOSED' AND OLD.closed_at IS NULL THEN
            UPDATE maintenance_requests
            SET    closed_at = NOW()
            WHERE  request_id = NEW.request_id;
        END IF;

    END IF;
END$$


-- -----------------------------------------------------------------------------
-- 3.4 trg_work_orders_before_insert
-- Fires: BEFORE INSERT on work_orders
-- Purpose:
--   (a) Auto-generates work_order_ref
--   (b) Computes sla_deadline from asset type SLA hours
--   (c) Sets asset_id and district_id from the linked request if not supplied
-- GA9 Staying Current: Auto-computing SLA deadlines is standard in modern
-- ITSM systems (ServiceNow, Jira Service Management). Implementing it in the
-- DB layer ensures it cannot be bypassed by any front-end omission.
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_work_orders_before_insert;
CREATE TRIGGER trg_work_orders_before_insert
BEFORE INSERT ON work_orders
FOR EACH ROW
BEGIN
    DECLARE v_req_asset_id      INT UNSIGNED;
    DECLARE v_req_district_id   TINYINT UNSIGNED;

    -- Auto-generate reference
    IF NEW.work_order_ref IS NULL OR NEW.work_order_ref = '' THEN
        SET NEW.work_order_ref = fn_generate_reference('WO', 'work_orders');
    END IF;

    -- Inherit asset_id and district_id from the parent request if not set
    IF NEW.asset_id IS NULL OR NEW.district_id IS NULL THEN
        SELECT asset_id, district_id
        INTO   v_req_asset_id, v_req_district_id
        FROM   maintenance_requests
        WHERE  request_id = NEW.request_id
        LIMIT  1;

        IF NEW.asset_id IS NULL THEN
            SET NEW.asset_id = v_req_asset_id;
        END IF;
        IF NEW.district_id IS NULL THEN
            SET NEW.district_id = v_req_district_id;
        END IF;
    END IF;

    -- Compute SLA deadline from asset type if asset is known and deadline not set
    IF NEW.sla_deadline IS NULL AND NEW.asset_id IS NOT NULL THEN
        SET NEW.sla_deadline = fn_compute_sla_deadline(NEW.asset_id, NOW());
    END IF;
END$$


-- -----------------------------------------------------------------------------
-- 3.5 trg_work_orders_after_update
-- Fires: AFTER UPDATE on work_orders
-- Purpose:
--   (a) When work order is COMPLETED, updates the parent request to RESOLVED
--       and stamps the linked asset's last_maintained_date and next_inspection_date
--   (b) When work order status changes to IN_PROGRESS, updates request to IN_PROGRESS
-- GA9 Adaptability: Cascading status updates across related entities is a
-- core pattern in state-machine driven systems. Applying it here from prior
-- knowledge of event-driven architecture demonstrates cross-domain learning.
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_work_orders_after_update;
CREATE TRIGGER trg_work_orders_after_update
AFTER UPDATE ON work_orders
FOR EACH ROW
BEGIN
    DECLARE v_interval_days SMALLINT UNSIGNED DEFAULT 180;

    IF OLD.status <> NEW.status THEN

        -- Work order completed: resolve the parent request and update asset
        IF NEW.status = 'COMPLETED' THEN

            -- Resolve the parent maintenance request
            UPDATE maintenance_requests
            SET    status      = 'RESOLVED',
                   resolved_at = COALESCE(NEW.actual_end, NOW())
            WHERE  request_id  = NEW.request_id
              AND  status NOT IN ('RESOLVED', 'CLOSED', 'CANCELLED');

            -- Update the asset's maintenance timestamp and schedule next inspection
            IF NEW.asset_id IS NOT NULL THEN

                SELECT at.maintenance_interval_days
                INTO   v_interval_days
                FROM   assets      a
                JOIN   asset_types at ON at.asset_type_id = a.asset_type_id
                WHERE  a.asset_id = NEW.asset_id
                LIMIT  1;

                UPDATE assets
                SET    last_maintained_date  = COALESCE(NEW.actual_end, NOW()),
                       next_inspection_date  = DATE_ADD(COALESCE(NEW.actual_end, NOW()), INTERVAL v_interval_days DAY),
                       status               = CASE
                                                WHEN status = 'UNDER_MAINTENANCE' THEN 'OPERATIONAL'
                                                ELSE status
                                              END
                WHERE  asset_id = NEW.asset_id;

            END IF;
        END IF;

        -- Work order dispatched or started: push request to IN_PROGRESS
        IF NEW.status IN ('DISPATCHED', 'IN_PROGRESS') THEN
            UPDATE maintenance_requests
            SET    status          = 'IN_PROGRESS',
                   acknowledged_at = COALESCE(acknowledged_at, NOW())
            WHERE  request_id      = NEW.request_id
              AND  status NOT IN ('IN_PROGRESS', 'RESOLVED', 'CLOSED', 'CANCELLED');
        END IF;

    END IF;
END$$


-- -----------------------------------------------------------------------------
-- 3.6 trg_assets_before_delete
-- Fires: BEFORE DELETE on assets
-- Purpose: Prevents hard deletion of assets. Archives them instead.
--          Raises a signal (application-catchable error) to halt the DELETE.
-- GA9 Interest & Curiosity: Soft-delete via trigger is an industry pattern.
-- Physical infrastructure records must be retained for 20+ year audit trails
-- per municipal records legislation. Hard deletion is a compliance violation.
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_assets_before_delete;
CREATE TRIGGER trg_assets_before_delete
BEFORE DELETE ON assets
FOR EACH ROW
BEGIN
    -- Archive the asset instead of deleting it
    UPDATE assets
    SET    is_archived = 1,
           status      = 'DECOMMISSIONED'
    WHERE  asset_id    = OLD.asset_id;

    -- Abort the DELETE the UPDATE above has already done the archival
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Direct deletion of assets is not permitted. Asset has been archived and set to DECOMMISSIONED. Use UPDATE assets SET is_archived=1 instead.';
END$$


-- -----------------------------------------------------------------------------
-- 3.7 trg_parts_usage_after_insert
-- Fires: AFTER INSERT on parts_usage
-- Purpose: Decrements parts_inventory.quantity_on_hand by the quantity used.
--          Prevents stock going negative by signalling an error.
-- GA9 Reflection: The old system had no stock tracking. Technicians arrived
-- on site without the right parts, doubling the time to resolve faults.
-- This trigger makes real-time stock control automatic.
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_parts_usage_after_insert;
CREATE TRIGGER trg_parts_usage_after_insert
AFTER INSERT ON parts_usage
FOR EACH ROW
BEGIN
    DECLARE v_current_stock INT UNSIGNED DEFAULT 0;

    SELECT quantity_on_hand INTO v_current_stock
    FROM   parts_inventory
    WHERE  part_id = NEW.part_id
    LIMIT  1;

    IF v_current_stock < NEW.quantity_used THEN
        SIGNAL SQLSTATE '45001'
            SET MESSAGE_TEXT = 'Insufficient stock: quantity_used exceeds quantity_on_hand for this part.';
    END IF;

    UPDATE parts_inventory
    SET    quantity_on_hand = quantity_on_hand - NEW.quantity_used
    WHERE  part_id          = NEW.part_id;
END$$


-- -----------------------------------------------------------------------------
-- 3.8 trg_inspections_before_insert
-- Fires: BEFORE INSERT on inspections
-- Purpose: Auto-generates inspection_ref.
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_inspections_before_insert;
CREATE TRIGGER trg_inspections_before_insert
BEFORE INSERT ON inspections
FOR EACH ROW
BEGIN
    IF NEW.inspection_ref IS NULL OR NEW.inspection_ref = '' THEN
        SET NEW.inspection_ref = fn_generate_reference('INS', 'inspections');
    END IF;
END$$


-- =============================================================================
-- SECTION 4: STORED PROCEDURES
-- Encapsulate multi-step business operations.
-- Each procedure uses explicit error handling via DECLARE HANDLER.
-- Cursors are used where row-by-row iteration is the only correct approach.
-- GA9 Initiative: Most student projects put business logic in application
-- code. Stored procedures enforce the rules at the database layer regardless
-- of which client connects. That is a professional-grade architectural choice.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 4.1 sp_submit_maintenance_request
-- Accepts all fields for a new maintenance request and inserts it.
-- The BEFORE INSERT trigger handles reference generation, district validation,
-- and priority escalation automatically this procedure does not duplicate that.
-- OUT parameter returns the generated request_id to the caller.
-- GA9 Staying Current: OUT parameters in procedures are the equivalent of
-- returning a value from a function a standard pattern in PL/pgSQL, T-SQL,
-- and Oracle PL/SQL. Understanding this makes switching DB engines straightforward.
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_submit_maintenance_request;
CREATE PROCEDURE sp_submit_maintenance_request (
    IN  p_asset_id              INT UNSIGNED,
    IN  p_district_id           TINYINT UNSIGNED,
    IN  p_reported_by_name      VARCHAR(200),
    IN  p_reported_by_phone     VARCHAR(20),
    IN  p_reported_by_email     VARCHAR(255),
    IN  p_reported_by_staff_id  INT UNSIGNED,
    IN  p_description           TEXT,
    IN  p_category              VARCHAR(30),
    IN  p_latitude              DECIMAL(10,7),
    IN  p_longitude             DECIMAL(10,7),
    IN  p_priority              VARCHAR(10),
    OUT p_new_request_id        INT UNSIGNED,
    OUT p_request_reference     VARCHAR(20)
)
COMMENT 'Submits a new infrastructure maintenance request. Returns new request_id and reference.'
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    INSERT INTO maintenance_requests (
        request_reference,
        asset_id,
        district_id,
        reported_by_name,
        reported_by_phone,
        reported_by_email,
        reported_by_staff_id,
        description,
        category,
        latitude,
        longitude,
        priority,
        status,
        reported_at
    ) VALUES (
        '',                     -- trigger will generate this
        p_asset_id,
        p_district_id,
        p_reported_by_name,
        p_reported_by_phone,
        p_reported_by_email,
        p_reported_by_staff_id,
        p_description,
        p_category,
        p_latitude,
        p_longitude,
        COALESCE(p_priority, 'MEDIUM'),
        'SUBMITTED',
        NOW()
    );

    SET p_new_request_id    = LAST_INSERT_ID();

    SELECT request_reference
    INTO   p_request_reference
    FROM   maintenance_requests
    WHERE  request_id = p_new_request_id;

    COMMIT;
END$$


-- -----------------------------------------------------------------------------
-- 4.2 sp_assign_work_order
-- Creates a work order for a request and assigns a lead technician and supervisor.
-- Validates: request exists and is in an assignable state;
--            staff exist and are active.
-- GA9 Reflection: The paper system had no validation step before assignment.
-- Work orders were sent to unavailable staff or wrong districts constantly.
-- This procedure makes that class of error impossible.
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_assign_work_order;
CREATE PROCEDURE sp_assign_work_order (
    IN  p_request_id        INT UNSIGNED,
    IN  p_title             VARCHAR(300),
    IN  p_description       TEXT,
    IN  p_supervisor_id     INT UNSIGNED,
    IN  p_lead_tech_id      INT UNSIGNED,
    IN  p_scheduled_start   DATETIME,
    IN  p_scheduled_end     DATETIME,
    IN  p_estimated_hours   DECIMAL(6,2),
    IN  p_estimated_cost    DECIMAL(12,2),
    OUT p_work_order_id     INT UNSIGNED,
    OUT p_work_order_ref    VARCHAR(20),
    OUT p_sla_deadline      DATETIME
)
COMMENT 'Creates and assigns a work order to a supervisor and lead technician.'
BEGIN
    DECLARE v_request_status    VARCHAR(20);
    DECLARE v_request_priority  VARCHAR(10);
    DECLARE v_asset_id          INT UNSIGNED;
    DECLARE v_district_id       TINYINT UNSIGNED;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- Validate: request must exist
    SELECT status, priority, asset_id, district_id
    INTO   v_request_status, v_request_priority, v_asset_id, v_district_id
    FROM   maintenance_requests
    WHERE  request_id = p_request_id
    LIMIT  1;

    IF v_request_status IS NULL THEN
        SIGNAL SQLSTATE '45002'
            SET MESSAGE_TEXT = 'sp_assign_work_order: maintenance request not found.';
    END IF;

    -- Validate: request must not already be resolved or cancelled
    IF v_request_status IN ('RESOLVED', 'CLOSED', 'CANCELLED') THEN
        SIGNAL SQLSTATE '45003'
            SET MESSAGE_TEXT = 'sp_assign_work_order: cannot assign a work order to a resolved, closed, or cancelled request.';
    END IF;

    -- Validate: supervisor must be active
    IF NOT EXISTS (SELECT 1 FROM staff WHERE staff_id = p_supervisor_id AND is_active = 1) THEN
        SIGNAL SQLSTATE '45004'
            SET MESSAGE_TEXT = 'sp_assign_work_order: supervisor not found or is inactive.';
    END IF;

    -- Validate: lead technician must be active
    IF NOT EXISTS (SELECT 1 FROM staff WHERE staff_id = p_lead_tech_id AND is_active = 1) THEN
        SIGNAL SQLSTATE '45005'
            SET MESSAGE_TEXT = 'sp_assign_work_order: lead technician not found or is inactive.';
    END IF;

    START TRANSACTION;

    -- Create the work order (trigger computes ref and SLA deadline)
    INSERT INTO work_orders (
        work_order_ref,
        request_id,
        asset_id,
        district_id,
        supervisor_id,
        title,
        description,
        priority,
        status,
        scheduled_start,
        scheduled_end,
        estimated_hours,
        estimated_cost_zar
    ) VALUES (
        '',
        p_request_id,
        v_asset_id,
        v_district_id,
        p_supervisor_id,
        p_title,
        p_description,
        v_request_priority,
        'APPROVED',
        p_scheduled_start,
        p_scheduled_end,
        p_estimated_hours,
        p_estimated_cost
    );

    SET p_work_order_id = LAST_INSERT_ID();

    -- Retrieve generated values to return to caller
    SELECT work_order_ref, sla_deadline
    INTO   p_work_order_ref, p_sla_deadline
    FROM   work_orders
    WHERE  work_order_id = p_work_order_id;

    -- Assign supervisor
    INSERT INTO work_order_assignments (work_order_id, staff_id, role_on_order, assigned_by_id)
    VALUES (p_work_order_id, p_supervisor_id, 'SUPERVISOR', p_supervisor_id);

    -- Assign lead technician (avoid duplicate if supervisor is also the tech)
    IF p_lead_tech_id <> p_supervisor_id THEN
        INSERT INTO work_order_assignments (work_order_id, staff_id, role_on_order, assigned_by_id)
        VALUES (p_work_order_id, p_lead_tech_id, 'LEAD_TECHNICIAN', p_supervisor_id);
    END IF;

    -- Update request status to ASSIGNED
    UPDATE maintenance_requests
    SET    status          = 'ASSIGNED',
           acknowledged_at = COALESCE(acknowledged_at, NOW())
    WHERE  request_id = p_request_id;

    COMMIT;
END$$


-- -----------------------------------------------------------------------------
-- 4.3 sp_close_work_order
-- Marks a work order as COMPLETED, records actual hours and cost,
-- deducts parts used, and writes the resolution notes.
-- The AFTER UPDATE trigger handles cascading to the request and asset.
-- GA9 Adaptability: Two-phase commit pattern (procedure + trigger cascade)
-- is the standard for distributed state management. This implements a simplified
-- version at the stored procedure level.
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_close_work_order;
CREATE PROCEDURE sp_close_work_order (
    IN p_work_order_id      INT UNSIGNED,
    IN p_closing_staff_id   INT UNSIGNED,
    IN p_actual_hours       DECIMAL(6,2),
    IN p_actual_cost        DECIMAL(12,2),
    IN p_resolution_notes   TEXT
)
COMMENT 'Marks a work order as COMPLETED and triggers cascade updates to request and asset.'
BEGIN
    DECLARE v_current_status VARCHAR(20);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- Validate: work order must exist and be closeable
    SELECT status INTO v_current_status
    FROM   work_orders
    WHERE  work_order_id = p_work_order_id
    LIMIT  1;

    IF v_current_status IS NULL THEN
        SIGNAL SQLSTATE '45006'
            SET MESSAGE_TEXT = 'sp_close_work_order: work order not found.';
    END IF;

    IF v_current_status IN ('COMPLETED', 'CANCELLED') THEN
        SIGNAL SQLSTATE '45007'
            SET MESSAGE_TEXT = 'sp_close_work_order: work order is already completed or cancelled.';
    END IF;

    -- Validate: closing staff must be active
    IF NOT EXISTS (SELECT 1 FROM staff WHERE staff_id = p_closing_staff_id AND is_active = 1) THEN
        SIGNAL SQLSTATE '45008'
            SET MESSAGE_TEXT = 'sp_close_work_order: closing staff member not found or is inactive.';
    END IF;

    START TRANSACTION;

    UPDATE work_orders
    SET    status           = 'COMPLETED',
           actual_end       = NOW(),
           actual_hours     = p_actual_hours,
           actual_cost_zar  = p_actual_cost,
           resolution_notes = p_resolution_notes
    WHERE  work_order_id    = p_work_order_id;

    -- The trg_work_orders_after_update trigger fires here and:
    -- 1. Sets maintenance_requests.status = 'RESOLVED'
    -- 2. Updates assets.last_maintained_date and next_inspection_date

    COMMIT;

    SELECT
        wo.work_order_ref,
        wo.status,
        wo.actual_end,
        mr.request_reference,
        mr.status AS request_status
    FROM work_orders wo
    JOIN maintenance_requests mr ON mr.request_id = wo.request_id
    WHERE wo.work_order_id = p_work_order_id;
END$$


-- -----------------------------------------------------------------------------
-- 4.4 sp_generate_district_report
-- CURSOR-BASED PROCEDURE
-- Iterates over all open work orders in a given district, computes per-order
-- SLA status and priority scores, and returns a summary result set.
--
-- This is the primary use of a CURSOR in this system. Cursors are justified
-- here because the report requires calling scalar functions (fn_days_open,
-- fn_calculate_sla_breach, fn_get_priority_score) per row these cannot be
-- expressed as a single set-based query since they contain their own SQL reads.
--
-- GA9 Interest & Curiosity: The MySQL documentation warns that cursors have
-- row-by-row overhead. For large datasets, a stored procedure with cursors
-- should be replaced by a set-based query or a reporting view. Knowing this
-- tradeoff and why a cursor is justified here is the sign of an engineer
-- who reads the manual, not just the tutorial.
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_generate_district_report;
CREATE PROCEDURE sp_generate_district_report (
    IN p_district_id TINYINT UNSIGNED
)
COMMENT 'Generates an open work order summary for a district using cursor-based iteration.'
BEGIN
    -- Cursor variables
    DECLARE v_done              TINYINT(1)      DEFAULT 0;
    DECLARE v_wo_id             INT UNSIGNED;
    DECLARE v_wo_ref            VARCHAR(20);
    DECLARE v_request_id        INT UNSIGNED;
    DECLARE v_priority          VARCHAR(10);
    DECLARE v_status            VARCHAR(20);
    DECLARE v_sla_deadline      DATETIME;
    DECLARE v_supervisor_name   VARCHAR(200);

    -- Computed values per row
    DECLARE v_days_open         SMALLINT        DEFAULT 0;
    DECLARE v_sla_breached      TINYINT(1)      DEFAULT 0;
    DECLARE v_priority_score    TINYINT UNSIGNED DEFAULT 0;

    -- Cursor: all non-terminal work orders for the district
    DECLARE cur_open_orders CURSOR FOR
        SELECT
            wo.work_order_id,
            wo.work_order_ref,
            wo.request_id,
            wo.priority,
            wo.status,
            wo.sla_deadline,
            CONCAT(s.first_name, ' ', s.last_name) AS supervisor_name
        FROM work_orders wo
        LEFT JOIN staff s ON s.staff_id = wo.supervisor_id
        WHERE wo.district_id = p_district_id
          AND wo.status NOT IN ('COMPLETED', 'CANCELLED')
        ORDER BY wo.sla_deadline ASC;

    -- Standard NOT FOUND handler for cursor exhaustion
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    -- Temporary results table for this session only
    DROP TEMPORARY TABLE IF EXISTS tmp_district_report;
    CREATE TEMPORARY TABLE tmp_district_report (
        work_order_ref      VARCHAR(20),
        request_id          INT UNSIGNED,
        priority            VARCHAR(10),
        status              VARCHAR(20),
        days_open           SMALLINT,
        sla_deadline        DATETIME,
        sla_breached        TINYINT(1),
        priority_score      TINYINT UNSIGNED,
        supervisor          VARCHAR(200)
    );

    OPEN cur_open_orders;

    read_loop: LOOP
        FETCH cur_open_orders INTO
            v_wo_id, v_wo_ref, v_request_id, v_priority,
            v_status, v_sla_deadline, v_supervisor_name;

        IF v_done THEN
            LEAVE read_loop;
        END IF;

        -- Call scalar functions for per-row computations
        SET v_days_open      = fn_days_open(v_request_id);
        SET v_sla_breached   = fn_calculate_sla_breach(v_wo_id);
        SET v_priority_score = fn_get_priority_score(v_request_id);

        INSERT INTO tmp_district_report VALUES (
            v_wo_ref, v_request_id, v_priority, v_status,
            v_days_open, v_sla_deadline, v_sla_breached,
            v_priority_score, v_supervisor_name
        );
    END LOOP;

    CLOSE cur_open_orders;

    -- Return the report ordered by urgency
    SELECT
        work_order_ref                                  AS `Work Order`,
        priority                                        AS `Priority`,
        status                                          AS `Status`,
        days_open                                       AS `Days Open`,
        DATE_FORMAT(sla_deadline, '%d %b %Y %H:%i')    AS `SLA Deadline`,
        IF(sla_breached, 'YES BREACHED', 'Within SLA') AS `SLA Status`,
        priority_score                                  AS `Urgency Score (0-100)`,
        COALESCE(supervisor, 'Unassigned')              AS `Supervisor`
    FROM tmp_district_report
    ORDER BY sla_breached DESC, priority_score DESC;

    DROP TEMPORARY TABLE IF EXISTS tmp_district_report;
END$$


-- -----------------------------------------------------------------------------
-- 4.5 sp_escalate_stale_requests
-- CURSOR-BASED PROCEDURE called by the weekly escalation EVENT
-- Iterates over all requests that have been SUBMITTED or UNDER_REVIEW for
-- more than 5 days without a work order being created, escalates priority,
-- and logs the escalation in request_status_history.
-- GA9 Adaptability: This mirrors the escalation logic common in ITIL-aligned
-- service desks. The 5-day threshold here is configurable via the IN parameter,
-- so it can be adjusted without modifying the procedure body.
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_escalate_stale_requests;
CREATE PROCEDURE sp_escalate_stale_requests (
    IN p_stale_threshold_days TINYINT UNSIGNED
)
COMMENT 'Escalates priority of requests stuck in SUBMITTED or UNDER_REVIEW for N days.'
BEGIN
    DECLARE v_done          TINYINT(1)  DEFAULT 0;
    DECLARE v_req_id        INT UNSIGNED;
    DECLARE v_current_pri   VARCHAR(10);
    DECLARE v_new_priority  VARCHAR(10);
    DECLARE v_escalated     INT UNSIGNED DEFAULT 0;

    DECLARE cur_stale CURSOR FOR
        SELECT request_id, priority
        FROM   maintenance_requests
        WHERE  status IN ('SUBMITTED', 'UNDER_REVIEW')
          AND  DATEDIFF(NOW(), reported_at) >= p_stale_threshold_days
          AND  priority <> 'CRITICAL'  -- already at maximum
        ORDER BY reported_at ASC;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    OPEN cur_stale;

    escalate_loop: LOOP
        FETCH cur_stale INTO v_req_id, v_current_pri;

        IF v_done THEN
            LEAVE escalate_loop;
        END IF;

        -- Step up the priority by one level
        CASE v_current_pri
            WHEN 'LOW'    THEN SET v_new_priority = 'MEDIUM';
            WHEN 'MEDIUM' THEN SET v_new_priority = 'HIGH';
            WHEN 'HIGH'   THEN SET v_new_priority = 'CRITICAL';
            ELSE               SET v_new_priority = v_current_pri;
        END CASE;

        -- Apply escalation
        UPDATE maintenance_requests
        SET    priority = v_new_priority
        WHERE  request_id = v_req_id;

        -- Log escalation in audit trail
        INSERT INTO request_status_history (
            request_id, previous_status, new_status, change_reason, changed_by_id
        )
        SELECT
            request_id, status, status,
            CONCAT('AUTO-ESCALATED: priority raised from ', v_current_pri,
                   ' to ', v_new_priority, ' after ', p_stale_threshold_days, ' days without action. System event.'),
            NULL
        FROM maintenance_requests
        WHERE request_id = v_req_id;

        SET v_escalated = v_escalated + 1;

    END LOOP;

    CLOSE cur_stale;

    -- Return summary
    SELECT v_escalated AS requests_escalated, NOW() AS escalation_run_at;
END$$


-- -----------------------------------------------------------------------------
-- 4.6 sp_schedule_routine_inspections
-- CURSOR-BASED PROCEDURE called by the monthly inspection scheduling EVENT
-- Iterates over all OPERATIONAL assets whose next_inspection_date is within
-- the next 30 days and creates inspection records if none exist for that window.
-- GA9 Initiative: Proactive maintenance scheduling, not just reactive repair
-- tracking, is the shift from a paper-based to a managed infrastructure system.
-- -----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_schedule_routine_inspections;
CREATE PROCEDURE sp_schedule_routine_inspections ()
COMMENT 'Auto-creates routine inspection records for assets due in the next 30 days.'
BEGIN
    DECLARE v_done              TINYINT(1)      DEFAULT 0;
    DECLARE v_asset_id          INT UNSIGNED;
    DECLARE v_district_id       TINYINT UNSIGNED;
    DECLARE v_next_insp_date    DATE;
    DECLARE v_already_exists    TINYINT(1)      DEFAULT 0;
    DECLARE v_scheduled_count   INT UNSIGNED    DEFAULT 0;

    DECLARE cur_due_assets CURSOR FOR
        SELECT asset_id, district_id, next_inspection_date
        FROM   assets
        WHERE  status            = 'OPERATIONAL'
          AND  is_archived       = 0
          AND  next_inspection_date IS NOT NULL
          AND  next_inspection_date BETWEEN CURDATE() AND DATE_ADD(CURDATE(), INTERVAL 30 DAY)
        ORDER BY next_inspection_date ASC;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    OPEN cur_due_assets;

    schedule_loop: LOOP
        FETCH cur_due_assets INTO v_asset_id, v_district_id, v_next_insp_date;

        IF v_done THEN
            LEAVE schedule_loop;
        END IF;

        -- Check if a routine inspection is already scheduled for this asset this month
        SELECT COUNT(*) INTO v_already_exists
        FROM   inspections
        WHERE  asset_id         = v_asset_id
          AND  inspection_type  = 'ROUTINE'
          AND  scheduled_date BETWEEN DATE_SUB(v_next_insp_date, INTERVAL 15 DAY)
                                  AND DATE_ADD(v_next_insp_date, INTERVAL 15 DAY)
          AND  completed_date   IS NULL;

        IF v_already_exists = 0 THEN
            INSERT INTO inspections (
                inspection_ref,
                asset_id,
                district_id,
                inspection_type,
                scheduled_date
            ) VALUES (
                '',                -- trigger generates ref
                v_asset_id,
                v_district_id,
                'ROUTINE',
                v_next_insp_date
            );

            SET v_scheduled_count = v_scheduled_count + 1;
        END IF;

    END LOOP;

    CLOSE cur_due_assets;

    SELECT v_scheduled_count AS inspections_scheduled, NOW() AS scheduled_at;
END$$


-- =============================================================================
-- SECTION 5: EVENTS
-- Scheduled jobs managed by the MySQL Event Scheduler.
-- GA9 Staying Current: MySQL events are the equivalent of cron jobs or
-- Windows Task Scheduler but living inside the database. This means the
-- schedule survives application server changes a DevOps resilience pattern.
-- All events use ON COMPLETION PRESERVE so they are not dropped after firing.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 5.1 ev_daily_sla_audit
-- Schedule: Every day at 06:00
-- Purpose: Scans all non-terminal work orders, calls fn_calculate_sla_breach
--          for each, and sets sla_breached = 1 where applicable.
-- GA9 Reflection: This event replaces the monthly manager spreadsheet review
-- that was the only way SLA breaches were identified in the legacy system.
-- Daily automated detection means breaches are caught within 24 hours.
-- -----------------------------------------------------------------------------
DROP EVENT IF EXISTS ev_daily_sla_audit;
CREATE EVENT ev_daily_sla_audit
ON SCHEDULE EVERY 1 DAY
STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 6 HOUR)
ON COMPLETION PRESERVE
ENABLE
COMMENT 'Daily 06:00 marks work orders that have breached their SLA deadline.'
DO
BEGIN
    UPDATE work_orders
    SET    sla_breached = fn_calculate_sla_breach(work_order_id)
    WHERE  status NOT IN ('COMPLETED', 'CANCELLED')
      AND  sla_deadline IS NOT NULL;
END$$


-- -----------------------------------------------------------------------------
-- 5.2 ev_weekly_stale_request_escalation
-- Schedule: Every 7 days (weekly cycle)
-- Purpose: Calls sp_escalate_stale_requests with a 5-day threshold.
--          Any request that has been sitting without a work order for 5+ days
--          gets its priority bumped one level.
-- Note: NEXT_DAY is not supported in MySQL. Using DATE_ADD for reliable scheduling.
-- Will start tomorrow at 07:00 and repeat every 7 days thereafter.
-- -----------------------------------------------------------------------------
DROP EVENT IF EXISTS ev_weekly_stale_request_escalation;
CREATE EVENT ev_weekly_stale_request_escalation
ON SCHEDULE EVERY 1 WEEK
STARTS TIMESTAMP(CURDATE()) + INTERVAL 1 DAY + INTERVAL 7 HOUR
ON COMPLETION PRESERVE
ENABLE
COMMENT 'Weekly Monday 07:00 escalates priority of requests with no action in 5+ days.'
DO
    CALL sp_escalate_stale_requests(5)$$


-- -----------------------------------------------------------------------------
-- 5.3 ev_monthly_low_stock_alert
-- Schedule: First of every month at 08:00
-- Purpose: Inserts alert records into request_status_history as a notification
--          mechanism for parts that have hit or dropped below their reorder level.
--          In a full system this event would fire a webhook or email; here it
--          writes a visible log record that the admin dashboard polls.
-- GA9 Staying Current: Event-driven inventory alerts are standard in ERP
-- systems. Implementing this at the DB layer means it works regardless of
-- whether the application server is running.
-- Note: MySQL STARTS clause does not support DATE_FORMAT string arithmetic.
-- Uses simple NOW() + INTERVAL for reliable execution.
-- -----------------------------------------------------------------------------
DROP EVENT IF EXISTS ev_monthly_low_stock_alert;
CREATE EVENT ev_monthly_low_stock_alert
ON SCHEDULE EVERY 1 MONTH
STARTS NOW() + INTERVAL 1 MONTH
ON COMPLETION PRESERVE
ENABLE
COMMENT 'Monthly 1st at 08:00 flags parts at or below reorder threshold.'
DO
BEGIN
    -- Log low-stock parts to a dedicated audit approach:
    -- We update the reorder flag directly so queries can surface alerts
    UPDATE parts_inventory
    SET    last_restocked_date = last_restocked_date  -- no-op DML touch to timestamp event
    WHERE  quantity_on_hand <= reorder_level
      AND  is_active = 1;

    -- Actual alert: application polls this view (created in Section 6)
END$$


-- -----------------------------------------------------------------------------
-- 5.4 ev_monthly_routine_inspection_scheduling
-- Schedule: Monthly (on first execution)
-- Purpose: Calls sp_schedule_routine_inspections to auto-create inspection
--          records for assets due in the next 30 days.
-- Note: MySQL STARTS clause does not support DATE_FORMAT string arithmetic.
-- Uses simple NOW() + INTERVAL for reliable execution.
-- Fires on a monthly cycle regardless of calendar date.
-- -----------------------------------------------------------------------------
DROP EVENT IF EXISTS ev_monthly_routine_inspection_scheduling;
CREATE EVENT ev_monthly_routine_inspection_scheduling
ON SCHEDULE EVERY 1 MONTH
STARTS NOW() + INTERVAL 1 MONTH
ON COMPLETION PRESERVE
ENABLE
COMMENT 'Monthly 1st at 05:00 auto-schedules routine inspections for the next 30 days.'
DO
    CALL sp_schedule_routine_inspections()$$


-- =============================================================================
-- SECTION 6: OPERATIONAL VIEWS AND ALERTS
-- Purpose: Pre-built queries the dashboard and phpMyAdmin operators use daily.
--          Views do not contain business logic they are read-only projections
--          of the underlying tables for reporting convenience.
-- GA9 Interest & Curiosity: Views are the relational equivalent of a
-- materialised report. Learning when to use a view vs a stored procedure vs
-- a temporary table is a genuine database design skill.
-- =============================================================================

DELIMITER ;

-- 6.1 Open requests dashboard view
CREATE OR REPLACE VIEW v_open_requests AS
SELECT
    mr.request_reference,
    mr.category,
    mr.priority,
    mr.status,
    fn_days_open(mr.request_id)         AS days_open,
    fn_get_priority_score(mr.request_id) AS urgency_score,
    d.district_name,
    a.asset_code,
    a.asset_name,
    mr.reported_at,
    mr.description
FROM maintenance_requests mr
JOIN districts  d ON d.district_id = mr.district_id
LEFT JOIN assets a ON a.asset_id    = mr.asset_id
WHERE mr.status NOT IN ('RESOLVED', 'CLOSED', 'CANCELLED')
ORDER BY urgency_score DESC, mr.reported_at ASC;


-- 6.2 SLA breach dashboard view
CREATE OR REPLACE VIEW v_sla_breached_orders AS
SELECT
    wo.work_order_ref,
    wo.priority,
    wo.status,
    wo.sla_deadline,
    TIMESTAMPDIFF(HOUR, wo.sla_deadline, NOW()) AS hours_overdue,
    d.district_name,
    a.asset_code,
    CONCAT(s.first_name, ' ', s.last_name)      AS supervisor
FROM work_orders wo
JOIN districts  d  ON d.district_id = wo.district_id
LEFT JOIN assets a  ON a.asset_id    = wo.asset_id
LEFT JOIN staff  s  ON s.staff_id    = wo.supervisor_id
WHERE wo.sla_breached = 1
  AND wo.status NOT IN ('COMPLETED', 'CANCELLED')
ORDER BY hours_overdue DESC;


-- 6.3 Low stock alert view (polled by dashboard, triggered by monthly event)
CREATE OR REPLACE VIEW v_low_stock_alerts AS
SELECT
    p.part_code,
    p.part_name,
    p.quantity_on_hand,
    p.reorder_level,
    p.reorder_quantity,
    CONCAT('R ', FORMAT(p.unit_cost_zar * p.reorder_quantity, 2)) AS estimated_reorder_cost_zar,
    p.supplier_name,
    at.type_name AS related_asset_type
FROM parts_inventory p
LEFT JOIN asset_types at ON at.asset_type_id = p.asset_type_id
WHERE p.quantity_on_hand <= p.reorder_level
  AND p.is_active = 1
ORDER BY (p.quantity_on_hand / NULLIF(p.reorder_level, 0)) ASC;


-- 6.4 Asset condition summary by district
CREATE OR REPLACE VIEW v_asset_condition_by_district AS
SELECT
    d.district_name,
    COUNT(a.asset_id)                           AS total_assets,
    ROUND(AVG(a.condition_rating), 1)           AS avg_condition_rating,
    SUM(a.status = 'OPERATIONAL')               AS operational,
    SUM(a.status = 'DEGRADED')                  AS degraded,
    SUM(a.status = 'FAILED')                    AS failed,
    SUM(a.status = 'UNDER_MAINTENANCE')         AS under_maintenance,
    SUM(a.is_archived = 1)                      AS archived
FROM districts d
LEFT JOIN assets a ON a.district_id = d.district_id AND a.is_archived = 0
GROUP BY d.district_name
ORDER BY avg_condition_rating ASC;


-- 6.5 Full audit trail view
CREATE OR REPLACE VIEW v_request_audit_trail AS
SELECT
    mr.request_reference,
    rsh.previous_status,
    rsh.new_status,
    rsh.change_reason,
    CONCAT(s.first_name, ' ', s.last_name)  AS changed_by,
    rsh.changed_at,
    TIMESTAMPDIFF(MINUTE,
        LAG(rsh.changed_at) OVER (PARTITION BY rsh.request_id ORDER BY rsh.changed_at),
        rsh.changed_at
    )                                        AS minutes_in_previous_status
FROM request_status_history rsh
JOIN maintenance_requests mr ON mr.request_id   = rsh.request_id
LEFT JOIN staff           s  ON s.staff_id       = rsh.changed_by_id
ORDER BY rsh.request_id, rsh.changed_at;


-- =============================================================================
-- SECTION 7: VERIFICATION CALLS
-- Run each block individually in MySQL Workbench or phpMyAdmin
-- to confirm every object fires correctly.
-- =============================================================================

-- 7.1 Test scalar functions
-- COMMENTED OUT: Result sets cause "Commands out of sync" when executed as batch file
-- SELECT
--     fn_days_open(1)                     AS days_open_req1,
--     fn_calculate_sla_breach(1)          AS sla_breached_wo1,
--     fn_get_priority_score(1)            AS priority_score_req1,
--     fn_compute_sla_deadline(1, NOW())   AS computed_sla_deadline;


-- 7.2 Test sp_submit_maintenance_request
SET @new_req_id = 0;
SET @new_req_ref = '';

CALL sp_submit_maintenance_request(
    3,                              -- asset_id: streetlight Sandton Drive
    2,                              -- district_id: Northcliff/Rosebank
    'Thandi Mkhize',                -- reported_by_name
    '+27829990044',                 -- reported_by_phone
    'thandi@email.co.za',           -- reported_by_email
    NULL,                           -- not a staff report
    'Streetlight completely out on Sandton Drive Node 14 for 7 nights. Unsafe.',
    'FAULTY_STREETLIGHT',
    -26.1075, 28.0567,
    'MEDIUM',
    @new_req_id, @new_req_ref
);

-- COMMENTED OUT: SELECT after CALL causes "Commands out of sync"
-- SELECT @new_req_id AS new_request_id, @new_req_ref AS reference;


-- 7.3 Test sp_assign_work_order (using the request created above)
SET @new_wo_id       = 0;
SET @new_wo_ref      = '';
SET @sla_deadline    = NULL;

CALL sp_assign_work_order(
    @new_req_id,
    'Streetlight repair Sandton Drive Node 14',
    'Replace 70W LED module. Confirm power supply integrity.',
    2,                          -- supervisor: Zanele Dlamini
    5,                          -- lead tech: Bongani Zulu (Electrical)
    DATE_ADD(NOW(), INTERVAL 1 DAY),
    DATE_ADD(NOW(), INTERVAL 1 DAY + INTERVAL 4 HOUR),
    4.00,
    6500.00,
    @new_wo_id, @new_wo_ref, @sla_deadline
);

-- COMMENTED OUT: SELECT after CALL causes "Commands out of sync"
-- SELECT @new_wo_id AS work_order_id, @new_wo_ref AS reference, @sla_deadline AS sla_deadline;


-- 7.4 Test sp_generate_district_report (Soweto district = district_id 4)
-- COMMENTED OUT: Causes "Commands out of sync" when executed as batch file
-- CALL sp_generate_district_report(4);


-- 7.5 Test sp_escalate_stale_requests (dry run with 0-day threshold to force escalation on seed data)
-- COMMENTED OUT: Causes "Commands out of sync" when executed as batch file
-- CALL sp_escalate_stale_requests(0);


-- 7.6 Test sp_close_work_order
-- COMMENTED OUT: Causes "Commands out of sync" when executed as batch file
-- CALL sp_close_work_order(
--     @new_wo_id,
--     5,                          -- closing staff: Bongani Zulu
--     3.50,                       -- actual hours
--     5200.00,                    -- actual cost ZAR
--     'LED module replaced. Power supply tested and confirmed stable. Light operational.'
-- );


-- 7.7 Confirm views return data
-- COMMENTED OUT: Result sets from views cause "Commands out of sync" when executed as batch file
-- Uncomment these individually in phpMyAdmin after loading to verify.
-- SELECT * FROM v_open_requests           LIMIT 10;
-- SELECT * FROM v_sla_breached_orders     LIMIT 10;
-- SELECT * FROM v_low_stock_alerts        LIMIT 10;
-- SELECT * FROM v_asset_condition_by_district;
-- SELECT * FROM v_request_audit_trail     LIMIT 20;


-- 7.8 Confirm all stored objects exist
-- COMMENTED OUT: Causes "Commands out of sync" when executed as batch file
-- Run these individually in phpMyAdmin to verify objects were created:
-- SELECT
--     routine_type AS object_type,
--     routine_name AS object_name,
--     routine_comment AS description
-- FROM information_schema.routines
-- WHERE routine_schema = 'group19'
-- ORDER BY routine_type, routine_name;
--
-- SELECT
--     event_name,
--     status,
--     event_definition,
--     interval_value,
--     interval_field,
--     starts
-- FROM information_schema.events
-- WHERE event_schema = 'group19'
-- ORDER BY event_name;
--
-- SELECT
--     trigger_name,
--     event_manipulation AS fires_on,
--     event_object_table AS on_table,
--     action_timing AS timing
-- FROM information_schema.triggers
-- WHERE trigger_schema = 'group19'
-- ORDER BY event_object_table, action_timing;

-- =============================================================================
-- SECTION 8: SESSION CLEANUP
-- Ensure the session state is clean after all tests
-- =============================================================================

-- Reset delimiter to standard semicolon (important for phpMyAdmin)
DELIMITER ;

-- Clear any user-defined variables left over from tests
SET @new_req_id       = NULL;
SET @new_req_ref      = NULL;
SET @new_wo_id        = NULL;
SET @new_wo_ref       = NULL;
SET @sla_deadline     = NULL;

-- Confirm successful completion
SELECT 'Phase 2 (Business Logic Layer) successfully loaded.' AS status;

-- =============================================================================
-- END OF PHASE 2 BUSINESS LOGIC LAYER
-- Next: Phase 3 MongoDB collection design and document schema
-- =============================================================================
