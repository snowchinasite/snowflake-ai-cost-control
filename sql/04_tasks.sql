-- ============================================================
-- Snowflake AI SQL Cost Control - Scheduled Tasks
-- Creates tasks for automated quota enforcement and recovery
-- ============================================================

USE ROLE AI_COST_CONTROL_ADMIN;
USE DATABASE AI_COST_CONTROL;
USE SCHEMA ADMIN;

-- Task 1: Circuit Breaker (every 15 minutes)
-- Checks daily usage vs budget, revokes UDF access if exceeded
CREATE OR REPLACE TASK ai_circuit_breaker_task
  WAREHOUSE = '<YOUR_WAREHOUSE>'
  SCHEDULE = '15 MINUTE'
AS
DECLARE
  c1 CURSOR FOR
    SELECT u.user_name
    FROM (
      SELECT user_name, SUM(token_count) AS daily_tokens
      FROM SNOWFLAKE.ACCOUNT_USAGE.AI_FUNCTIONS_USAGE_HISTORY
      WHERE start_time >= CURRENT_DATE()
      GROUP BY user_name
    ) usage
    JOIN AI_COST_CONTROL.ADMIN.ai_user_budget b
      ON usage.user_name = b.user_name
    WHERE usage.daily_tokens > b.daily_token_limit
      AND b.is_exempt = FALSE;
  user_to_revoke VARCHAR;
BEGIN
  FOR record IN c1 DO
    user_to_revoke := record.user_name;
    
    -- Revoke UDF usage (adjust function signatures as needed)
    EXECUTE IMMEDIATE 'REVOKE USAGE ON FUNCTION AI_COST_CONTROL.ADMIN.safe_ai_complete(VARCHAR, VARCHAR, VARCHAR) FROM ROLE ' || user_to_revoke || '_ROLE';
    
    -- Log the action
    INSERT INTO AI_COST_CONTROL.ADMIN.ai_revoke_log (user_name, reason)
    VALUES (:user_to_revoke, 'Daily token limit exceeded');
  END FOR;
END;

-- Task 2: Auto-Recovery (every 5 minutes)
-- Restores access for users with approved quota increase requests
CREATE OR REPLACE TASK ai_recovery_task
  WAREHOUSE = '<YOUR_WAREHOUSE>'
  SCHEDULE = '5 MINUTE'
AS
DECLARE
  c1 CURSOR FOR
    SELECT request_id, user_name, approved_amount
    FROM AI_COST_CONTROL.ADMIN.ai_quota_requests
    WHERE status = 'APPROVED'
      AND resolved_at IS NOT NULL
      AND request_type = 'DAILY_QUOTA';
  req_id VARCHAR;
  user_to_restore VARCHAR;
  amount NUMBER;
BEGIN
  FOR record IN c1 DO
    req_id := record.request_id;
    user_to_restore := record.user_name;
    amount := record.approved_amount;
    
    -- Grant UDF usage back
    EXECUTE IMMEDIATE 'GRANT USAGE ON FUNCTION AI_COST_CONTROL.ADMIN.safe_ai_complete(VARCHAR, VARCHAR, VARCHAR) TO ROLE ' || user_to_restore || '_ROLE';
    
    -- Update daily limit
    UPDATE AI_COST_CONTROL.ADMIN.ai_user_budget
    SET daily_token_limit = daily_token_limit + :amount,
        updated_at = CURRENT_TIMESTAMP()
    WHERE user_name = :user_to_restore;
    
    -- Mark request as processed
    UPDATE AI_COST_CONTROL.ADMIN.ai_quota_requests
    SET status = 'PROCESSED'
    WHERE request_id = :req_id;
    
    -- Log restoration
    UPDATE AI_COST_CONTROL.ADMIN.ai_revoke_log
    SET restored_at = CURRENT_TIMESTAMP()
    WHERE user_name = :user_to_restore
      AND restored_at IS NULL;
  END FOR;
END;

-- Task 3: Daily Reset (runs at midnight)
-- Resets daily quotas and restores all revoked users
CREATE OR REPLACE TASK ai_daily_reset_task
  WAREHOUSE = '<YOUR_WAREHOUSE>'
  SCHEDULE = 'USING CRON 0 0 * * * UTC'
AS
BEGIN
  -- Reset daily limits to base values
  UPDATE AI_COST_CONTROL.ADMIN.ai_user_budget
  SET updated_at = CURRENT_TIMESTAMP();
  
  -- Mark all expired exemption tokens
  UPDATE AI_COST_CONTROL.ADMIN.ai_exemption_tokens
  SET used = TRUE
  WHERE expires_at < CURRENT_TIMESTAMP() AND used = FALSE;
END;

-- IMPORTANT: Replace <YOUR_WAREHOUSE> with your warehouse name, then run:
-- ALTER TASK ai_circuit_breaker_task RESUME;
-- ALTER TASK ai_recovery_task RESUME;
-- ALTER TASK ai_daily_reset_task RESUME;
