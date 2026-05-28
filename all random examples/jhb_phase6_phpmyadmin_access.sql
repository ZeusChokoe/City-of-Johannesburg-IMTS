-- =============================================================================
-- CITY OF JOHANNESBURG — IMTS
-- phpMyAdmin Access Control and MySQL User Privilege Configuration
-- =============================================================================
-- Tool: phpMyAdmin (https://www.phpmyadmin.net) / MySQL Workbench
-- Purpose: Define four role-based MySQL users that control exactly what
--          each role can do when accessing jhb_imts through phpMyAdmin
--          or the REST API.
--
-- ROLE ARCHITECTURE:
--   jhb_api_user       — REST API service account (application layer)
--   jhb_dba            — Database administrator (full schema control)
--   jhb_analyst        — Read-only reporting and dashboard queries
--   jhb_supervisor     — Read + call procedures (no raw DML)
--
-- EXECUTION: Run as MySQL root.
--   mysql -u root -p < jhb_phase6_phpmyadmin_access.sql
--
-- GA9 — INDEPENDENT LEARNING:
--   The principle of least privilege (PoLP) requires every user to have
--   only the permissions needed for their role — no more. This is a core
--   principle in ISO 27001, POPIA (South Africa's data protection act),
--   and CIS MySQL Benchmark. Applying it here means learning security
--   frameworks beyond database textbooks.
-- =============================================================================

USE mysql;

-- =============================================================================
-- SECTION 1: DROP EXISTING USERS (idempotent reset)
-- =============================================================================
DROP USER IF EXISTS 'jhb_api_user'@'localhost';
DROP USER IF EXISTS 'jhb_api_user'@'%';
DROP USER IF EXISTS 'jhb_dba'@'localhost';
DROP USER IF EXISTS 'jhb_analyst'@'localhost';
DROP USER IF EXISTS 'jhb_analyst'@'%';
DROP USER IF EXISTS 'jhb_supervisor'@'localhost';
DROP USER IF EXISTS 'jhb_supervisor'@'%';

FLUSH PRIVILEGES;


-- =============================================================================
-- SECTION 2: USER CREATION
--
-- IMPORTANT: Replace all placeholder passwords with strong secrets before
--            deploying. Minimum 20 characters, mixed case, digits, symbols.
--            Use a secrets manager (HashiCorp Vault, AWS Secrets Manager)
--            in production — never hardcode passwords in SQL files.
-- =============================================================================

-- 2.1 API Service Account
-- Used by the Node.js REST API (Phase 5 — config/db.js).
-- Connects from the application server only (localhost in single-server
-- deployment; replace with application server IP in multi-server setup).
-- GA9 — Staying Current: Service accounts have no interactive login.
--   They should be rotated on a schedule (90-day rotation is the CIS benchmark).
CREATE USER 'jhb_api_user'@'localhost'
    IDENTIFIED WITH caching_sha2_password BY 'REPLACE_WITH_STRONG_API_PASSWORD'
    PASSWORD EXPIRE INTERVAL 90 DAY
    FAILED_LOGIN_ATTEMPTS 5
    PASSWORD_LOCK_TIME 30
    COMMENT 'REST API service account — jhb-imts-api Node.js process';

-- 2.2 DBA Account
-- Full control for the database administrator.
-- Only accessible from localhost — never exposed externally.
CREATE USER 'jhb_dba'@'localhost'
    IDENTIFIED WITH caching_sha2_password BY 'REPLACE_WITH_STRONG_DBA_PASSWORD'
    PASSWORD EXPIRE INTERVAL 60 DAY
    FAILED_LOGIN_ATTEMPTS 3
    PASSWORD_LOCK_TIME UNBOUNDED
    COMMENT 'DBA account — full schema management access';

-- 2.3 Analyst / Read-Only Account
-- Used by phpMyAdmin for dashboard and reporting queries.
-- No INSERT, UPDATE, DELETE, or DDL.
-- Can connect from the phpMyAdmin server (% = any host for phpMyAdmin use).
CREATE USER 'jhb_analyst'@'%'
    IDENTIFIED WITH caching_sha2_password BY 'REPLACE_WITH_STRONG_ANALYST_PASSWORD'
    PASSWORD EXPIRE INTERVAL 90 DAY
    FAILED_LOGIN_ATTEMPTS 5
    PASSWORD_LOCK_TIME 30
    COMMENT 'Read-only analyst — phpMyAdmin dashboard and report queries';

-- 2.4 Supervisor Account
-- Read access + ability to call stored procedures.
-- Cannot issue raw DML — all writes go through stored procedures.
-- GA9 — Adaptability: Granting EXECUTE on procedures but not raw DML is
--   the database-layer implementation of the "command pattern" from
--   software architecture. The procedure is the command; the user
--   cannot bypass it. The same pattern appears in API gateway designs.
CREATE USER 'jhb_supervisor'@'%'
    IDENTIFIED WITH caching_sha2_password BY 'REPLACE_WITH_STRONG_SUPERVISOR_PASSWORD'
    PASSWORD EXPIRE INTERVAL 90 DAY
    FAILED_LOGIN_ATTEMPTS 5
    PASSWORD_LOCK_TIME 30
    COMMENT 'Supervisor account — read + stored procedure execution';


-- =============================================================================
-- SECTION 3: PRIVILEGE GRANTS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3.1 API Service Account — full DML on operational tables, no DDL
-- Needs SELECT, INSERT, UPDATE, DELETE on all tables.
-- Needs EXECUTE to call stored procedures.
-- No CREATE, DROP, ALTER, INDEX — schema changes are DBA-only.
-- -----------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE
    ON jhb_imts.*
    TO 'jhb_api_user'@'localhost';

GRANT EXECUTE
    ON jhb_imts.*
    TO 'jhb_api_user'@'localhost';

-- API also needs to call scalar functions
GRANT EXECUTE
    ON FUNCTION jhb_imts.fn_days_open
    TO 'jhb_api_user'@'localhost';

GRANT EXECUTE
    ON FUNCTION jhb_imts.fn_calculate_sla_breach
    TO 'jhb_api_user'@'localhost';

GRANT EXECUTE
    ON FUNCTION jhb_imts.fn_get_priority_score
    TO 'jhb_api_user'@'localhost';

GRANT EXECUTE
    ON FUNCTION jhb_imts.fn_compute_sla_deadline
    TO 'jhb_api_user'@'localhost';

GRANT EXECUTE
    ON FUNCTION jhb_imts.fn_generate_reference
    TO 'jhb_api_user'@'localhost';


-- -----------------------------------------------------------------------------
-- 3.2 DBA — all privileges on jhb_imts, with GRANT OPTION
-- Can grant/revoke privileges for other users on this database.
-- Cannot access mysql system tables or other databases.
-- -----------------------------------------------------------------------------
GRANT ALL PRIVILEGES
    ON jhb_imts.*
    TO 'jhb_dba'@'localhost'
    WITH GRANT OPTION;

-- DBA can also manage the event scheduler for this database
GRANT EVENT
    ON jhb_imts.*
    TO 'jhb_dba'@'localhost';

-- DBA needs RELOAD to flush privileges after user changes
GRANT RELOAD
    ON *.*
    TO 'jhb_dba'@'localhost';


-- -----------------------------------------------------------------------------
-- 3.3 Analyst — SELECT only on tables and views, EXECUTE on report functions
-- Cannot see request_status_history (contains PII in change_reason column).
-- Cannot see staff.email or staff.phone (PII — POPIA compliance).
-- GA9 — Staying Current: Column-level privilege grants are the SQL
--   implementation of field-level access control — the same concept
--   used in row-level security (RLS) in PostgreSQL and Power BI.
-- -----------------------------------------------------------------------------

-- Grant SELECT on all tables EXCEPT sensitive ones
GRANT SELECT ON jhb_imts.districts          TO 'jhb_analyst'@'%';
GRANT SELECT ON jhb_imts.asset_types        TO 'jhb_analyst'@'%';
GRANT SELECT ON jhb_imts.assets             TO 'jhb_analyst'@'%';
GRANT SELECT ON jhb_imts.maintenance_requests TO 'jhb_analyst'@'%';
GRANT SELECT ON jhb_imts.work_orders        TO 'jhb_analyst'@'%';
GRANT SELECT ON jhb_imts.work_order_assignments TO 'jhb_analyst'@'%';
GRANT SELECT ON jhb_imts.parts_inventory    TO 'jhb_analyst'@'%';
GRANT SELECT ON jhb_imts.parts_usage        TO 'jhb_analyst'@'%';
GRANT SELECT ON jhb_imts.inspections        TO 'jhb_analyst'@'%';

-- Analyst can see staff but NOT PII columns (name is OK, email/phone are not)
GRANT SELECT (staff_id, employee_number, first_name, last_name,
              role, specialization, district_id, is_active, hire_date)
    ON jhb_imts.staff
    TO 'jhb_analyst'@'%';

-- Analyst can query all views (views enforce the column restrictions above)
GRANT SELECT ON jhb_imts.v_open_requests             TO 'jhb_analyst'@'%';
GRANT SELECT ON jhb_imts.v_sla_breached_orders       TO 'jhb_analyst'@'%';
GRANT SELECT ON jhb_imts.v_low_stock_alerts          TO 'jhb_analyst'@'%';
GRANT SELECT ON jhb_imts.v_asset_condition_by_district TO 'jhb_analyst'@'%';
GRANT SELECT ON jhb_imts.v_request_audit_trail       TO 'jhb_analyst'@'%';

-- Analyst can call reporting functions
GRANT EXECUTE ON FUNCTION jhb_imts.fn_days_open            TO 'jhb_analyst'@'%';
GRANT EXECUTE ON FUNCTION jhb_imts.fn_get_priority_score   TO 'jhb_analyst'@'%';
GRANT EXECUTE ON FUNCTION jhb_imts.fn_calculate_sla_breach TO 'jhb_analyst'@'%';

-- Analyst can call the district report procedure (read-only cursor procedure)
GRANT EXECUTE ON PROCEDURE jhb_imts.sp_generate_district_report TO 'jhb_analyst'@'%';


-- -----------------------------------------------------------------------------
-- 3.4 Supervisor — SELECT on operational tables + EXECUTE on procedures
-- Can submit requests, assign orders, close orders — via procedures only.
-- Cannot directly INSERT/UPDATE/DELETE any table.
-- -----------------------------------------------------------------------------
GRANT SELECT ON jhb_imts.*                  TO 'jhb_supervisor'@'%';

-- Supervisors call these procedures in daily operations
GRANT EXECUTE ON PROCEDURE jhb_imts.sp_submit_maintenance_request TO 'jhb_supervisor'@'%';
GRANT EXECUTE ON PROCEDURE jhb_imts.sp_assign_work_order          TO 'jhb_supervisor'@'%';
GRANT EXECUTE ON PROCEDURE jhb_imts.sp_close_work_order           TO 'jhb_supervisor'@'%';
GRANT EXECUTE ON PROCEDURE jhb_imts.sp_generate_district_report   TO 'jhb_supervisor'@'%';

-- Supervisors can use all scalar functions for their dashboards
GRANT EXECUTE ON FUNCTION jhb_imts.fn_days_open            TO 'jhb_supervisor'@'%';
GRANT EXECUTE ON FUNCTION jhb_imts.fn_calculate_sla_breach TO 'jhb_supervisor'@'%';
GRANT EXECUTE ON FUNCTION jhb_imts.fn_get_priority_score   TO 'jhb_supervisor'@'%';
GRANT EXECUTE ON FUNCTION jhb_imts.fn_compute_sla_deadline TO 'jhb_supervisor'@'%';

FLUSH PRIVILEGES;


-- =============================================================================
-- SECTION 4: PHPMYADMIN SECURITY CONFIGURATION SQL
--
-- These settings harden the MySQL server for phpMyAdmin access.
-- Run as root. Each setting is annotated with the security reason.
-- GA9 — Staying Current: These settings align with the CIS MySQL 8.0
--   Community Server Benchmark v1.0.0 (2022). Cross-referencing database
--   configuration against published security benchmarks is standard
--   practice in enterprise and government deployments.
-- =============================================================================

-- 4.1 Disable remote root login (root should only connect locally)
-- phpMyAdmin should connect as jhb_analyst or jhb_supervisor, not root.
UPDATE mysql.user
SET    host = 'localhost'
WHERE  user = 'root'
  AND  host = '%';

-- 4.2 Remove anonymous accounts (created by default in some MySQL installs)
DELETE FROM mysql.user WHERE user = '';

-- 4.3 Remove the test database (security baseline — no guest-accessible DB)
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE db = 'test' OR db = 'test\\_%';

FLUSH PRIVILEGES;

-- 4.4 Verify the accounts were created correctly
SELECT
    user                        AS username,
    host,
    account_locked              AS locked,
    password_expired            AS pwd_expired,
    password_lifetime           AS pwd_lifetime_days,
    failed_login_attempts       AS max_failures
FROM mysql.user
WHERE user IN ('jhb_api_user','jhb_dba','jhb_analyst','jhb_supervisor')
ORDER BY user;

-- 4.5 Confirm privilege grants
SHOW GRANTS FOR 'jhb_api_user'@'localhost';
SHOW GRANTS FOR 'jhb_dba'@'localhost';
SHOW GRANTS FOR 'jhb_analyst'@'%';
SHOW GRANTS FOR 'jhb_supervisor'@'%';


-- =============================================================================
-- SECTION 5: PHPMYADMIN RECOMMENDED my.cnf SETTINGS
-- These are comments — apply these in /etc/mysql/my.cnf or my.ini (Windows).
--
-- [mysqld]
-- # Disable LOAD DATA LOCAL INFILE — prevents client-side file read attacks
-- local_infile = 0
--
-- # Require SSL for all remote connections (phpMyAdmin server ↔ MySQL)
-- require_secure_transport = ON
--
-- # Slow query log — capture queries > 2s for phpMyAdmin performance review
-- slow_query_log = 1
-- long_query_time = 2
-- slow_query_log_file = /var/log/mysql/jhb-slow.log
--
-- # Binary logging for point-in-time recovery
-- log_bin = /var/log/mysql/jhb-binlog
-- binlog_format = ROW
-- expire_logs_days = 14
--
-- # General query log (disable in production — high I/O; enable for debugging)
-- general_log = 0
-- general_log_file = /var/log/mysql/jhb-general.log
--
-- # Max connections — match the API pool size + DBA + analyst sessions
-- max_connections = 150
--
-- # Disable symbolic links (privilege escalation vector)
-- symbolic-links = 0
-- =============================================================================


-- =============================================================================
-- SECTION 6: PHPMYADMIN CONFIG.INC.PHP RECOMMENDED SETTINGS
-- Apply these in /etc/phpmyadmin/config.inc.php or config.inc.php.
-- These are SQL comments describing the PHP configuration.
--
-- $cfg['Servers'][$i]['auth_type']   = 'cookie';   // login form, not HTTP auth
-- $cfg['Servers'][$i]['AllowRoot']   = false;       // block root login via UI
-- $cfg['Servers'][$i]['AllowNoPassword'] = false;   // require passwords always
-- $cfg['LoginCookieValidity']        = 1440;        // 24-minute session timeout
-- $cfg['Servers'][$i]['ssl']         = true;        // enforce TLS to MySQL
-- $cfg['blowfish_secret'] = 'REPLACE_WITH_32_CHAR_RANDOM_STRING'; // cookie encryption
-- $cfg['Servers'][$i]['hide_db']     = '(information_schema|performance_schema|mysql|sys)';
-- // Hides system databases from analyst/supervisor views in phpMyAdmin UI
-- =============================================================================


-- =============================================================================
-- SECTION 7: VERIFICATION QUERIES
-- Run these in phpMyAdmin as jhb_analyst to confirm privilege boundaries.
-- =============================================================================

-- 7.1 Analyst should be able to query views
SELECT * FROM v_open_requests LIMIT 5;
SELECT * FROM v_sla_breached_orders LIMIT 5;
SELECT * FROM v_low_stock_alerts;

-- 7.2 Analyst should NOT be able to see staff email (expect error)
-- SELECT email FROM staff;  -- UNCOMMENT to test — expect: Access denied

-- 7.3 Analyst should NOT be able to INSERT (expect error)
-- INSERT INTO districts (district_name, region_code) VALUES ('Test', 'REG-Z');
-- UNCOMMENT to test — expect: Access denied

-- 7.4 Supervisor should be able to call sp_generate_district_report
CALL sp_generate_district_report(1);

-- 7.5 Supervisor should NOT be able to call sp_escalate_stale_requests
-- CALL sp_escalate_stale_requests(5);  -- UNCOMMENT to test — expect: Access denied

-- =============================================================================
-- END OF PHPMYADMIN ACCESS CONTROL CONFIGURATION
-- =============================================================================
