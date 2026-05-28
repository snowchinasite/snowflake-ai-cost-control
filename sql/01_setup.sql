-- ============================================================
-- Snowflake AI SQL Cost Control - Setup Script
-- Run this script as ACCOUNTADMIN to initialize the solution
-- ============================================================

-- 1. Create dedicated database and schema
CREATE DATABASE IF NOT EXISTS AI_COST_CONTROL;
CREATE SCHEMA IF NOT EXISTS AI_COST_CONTROL.ADMIN;

-- 2. Create Owner Role (holds AI Functions permission, owns UDFs)
CREATE ROLE IF NOT EXISTS AI_COST_CONTROL_ADMIN;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE AI_COST_CONTROL_ADMIN;
GRANT USAGE ON DATABASE AI_COST_CONTROL TO ROLE AI_COST_CONTROL_ADMIN;
GRANT USAGE ON SCHEMA AI_COST_CONTROL.ADMIN TO ROLE AI_COST_CONTROL_ADMIN;
GRANT CREATE FUNCTION ON SCHEMA AI_COST_CONTROL.ADMIN TO ROLE AI_COST_CONTROL_ADMIN;
GRANT CREATE TABLE ON SCHEMA AI_COST_CONTROL.ADMIN TO ROLE AI_COST_CONTROL_ADMIN;
GRANT ROLE AI_COST_CONTROL_ADMIN TO ROLE ACCOUNTADMIN;

-- 3. Revoke CORTEX_USER from PUBLIC (enforce UDF-only access)
--    WARNING: This disables direct AI function calls for ALL users.
--    Uncomment when ready to enforce.
-- REVOKE DATABASE ROLE SNOWFLAKE.CORTEX_USER FROM ROLE PUBLIC;

-- 4. Create management tables
USE ROLE AI_COST_CONTROL_ADMIN;
USE DATABASE AI_COST_CONTROL;
USE SCHEMA ADMIN;

CREATE TABLE IF NOT EXISTS ai_user_budget (
    user_name VARCHAR NOT NULL,
    daily_token_limit NUMBER DEFAULT 5000000,
    monthly_token_limit NUMBER DEFAULT 100000000,
    single_query_limit NUMBER DEFAULT 1000000,
    is_exempt BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (user_name)
);

CREATE TABLE IF NOT EXISTS ai_quota_requests (
    request_id VARCHAR DEFAULT UUID_STRING(),
    user_name VARCHAR NOT NULL,
    request_type VARCHAR NOT NULL,  -- 'DAILY_QUOTA' or 'EXEMPTION_TOKEN'
    requested_amount NUMBER,
    reason VARCHAR,
    status VARCHAR DEFAULT 'PENDING',  -- PENDING / APPROVED / DENIED
    approved_by VARCHAR,
    approved_amount NUMBER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    resolved_at TIMESTAMP,
    PRIMARY KEY (request_id)
);

CREATE TABLE IF NOT EXISTS ai_exemption_tokens (
    token_id VARCHAR DEFAULT UUID_STRING(),
    user_name VARCHAR NOT NULL,
    max_tokens NUMBER NOT NULL,
    used BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    expires_at TIMESTAMP DEFAULT DATEADD(hour, 24, CURRENT_TIMESTAMP()),
    PRIMARY KEY (token_id)
);

CREATE TABLE IF NOT EXISTS ai_revoke_log (
    user_name VARCHAR NOT NULL,
    revoked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    restored_at TIMESTAMP,
    reason VARCHAR
);
