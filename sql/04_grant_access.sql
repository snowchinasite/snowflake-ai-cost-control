-- ============================================================
-- Grant UDF access to user roles
-- Run this for each role that needs AI SQL access
-- ============================================================

USE ROLE ACCOUNTADMIN;

-- Replace <USER_ROLE> with actual role name
-- Replace <WAREHOUSE> with user's warehouse

-- GRANT USAGE ON DATABASE AI_COST_CONTROL TO ROLE <USER_ROLE>;
-- GRANT USAGE ON SCHEMA AI_COST_CONTROL.ADMIN TO ROLE <USER_ROLE>;
-- GRANT USAGE ON FUNCTION AI_COST_CONTROL.ADMIN.safe_ai_complete(VARCHAR, VARCHAR, VARCHAR) TO ROLE <USER_ROLE>;
-- GRANT USAGE ON FUNCTION AI_COST_CONTROL.ADMIN.safe_ai_complete_with_options(VARCHAR, VARCHAR, OBJECT, VARCHAR) TO ROLE <USER_ROLE>;
-- GRANT USAGE ON FUNCTION AI_COST_CONTROL.ADMIN.safe_ai_extract(VARCHAR, VARCHAR, VARCHAR) TO ROLE <USER_ROLE>;
-- GRANT USAGE ON FUNCTION AI_COST_CONTROL.ADMIN.safe_ai_classify(VARCHAR, ARRAY, VARCHAR) TO ROLE <USER_ROLE>;
-- GRANT USAGE ON FUNCTION AI_COST_CONTROL.ADMIN.safe_ai_sentiment(VARCHAR) TO ROLE <USER_ROLE>;

-- Register users with their daily budget
-- INSERT INTO AI_COST_CONTROL.ADMIN.ai_user_budget (user_name, daily_token_limit, single_query_limit)
-- VALUES 
--   ('USER_A', 5000000, 1000000),
--   ('USER_B', 10000000, 2000000);

-- Revoke direct AI access (enforce UDF-only)
-- REVOKE DATABASE ROLE SNOWFLAKE.CORTEX_USER FROM ROLE PUBLIC;
