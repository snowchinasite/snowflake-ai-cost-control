-- ============================================================
-- Wrapper UDFs - Replace direct AI function calls
-- These UDFs enforce single-query token limits and support
-- exemption tokens for approved large requests.
-- ============================================================

USE ROLE AI_COST_CONTROL_ADMIN;
USE DATABASE AI_COST_CONTROL;
USE SCHEMA ADMIN;

-- safe_ai_complete: Wrapper for AI_COMPLETE
CREATE OR REPLACE FUNCTION safe_ai_complete(
    model VARCHAR,
    prompt VARCHAR,
    exemption_token VARCHAR DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
  CASE
    WHEN AI_COUNT_TOKENS('ai_complete', model, prompt) <= 
      (SELECT COALESCE(MAX(single_query_limit), 1000000) 
       FROM AI_COST_CONTROL.ADMIN.ai_user_budget 
       WHERE user_name = CURRENT_USER())
    THEN
      AI_COMPLETE(model, prompt)
    WHEN exemption_token IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM AI_COST_CONTROL.ADMIN.ai_exemption_tokens
        WHERE token_id = exemption_token
          AND user_name = CURRENT_USER()
          AND used = FALSE
          AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP())
      )
    THEN
      AI_COMPLETE(model, prompt)
    ELSE
      'ERROR: Token estimate (' || AI_COUNT_TOKENS('ai_complete', model, prompt)::VARCHAR 
      || ') exceeds your single-query limit. Apply for an exemption token via the admin portal.'
  END
$$;

-- safe_ai_complete with options (for max_tokens, temperature, etc.)
CREATE OR REPLACE FUNCTION safe_ai_complete_with_options(
    model VARCHAR,
    prompt VARCHAR,
    options OBJECT,
    exemption_token VARCHAR DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
  CASE
    WHEN AI_COUNT_TOKENS('ai_complete', model, prompt) <= 
      (SELECT COALESCE(MAX(single_query_limit), 1000000) 
       FROM AI_COST_CONTROL.ADMIN.ai_user_budget 
       WHERE user_name = CURRENT_USER())
    THEN
      AI_COMPLETE(model, prompt, options)
    WHEN exemption_token IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM AI_COST_CONTROL.ADMIN.ai_exemption_tokens
        WHERE token_id = exemption_token
          AND user_name = CURRENT_USER()
          AND used = FALSE
          AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP())
      )
    THEN
      AI_COMPLETE(model, prompt, options)
    ELSE
      'ERROR: Token estimate (' || AI_COUNT_TOKENS('ai_complete', model, prompt)::VARCHAR 
      || ') exceeds your single-query limit. Apply for an exemption token via the admin portal.'
  END
$$;

-- safe_ai_extract: Wrapper for AI_EXTRACT
CREATE OR REPLACE FUNCTION safe_ai_extract(
    input_text VARCHAR,
    instructions VARCHAR,
    exemption_token VARCHAR DEFAULT NULL
)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
  CASE
    WHEN AI_COUNT_TOKENS('ai_extract', input_text) <=
      (SELECT COALESCE(MAX(single_query_limit), 1000000) 
       FROM AI_COST_CONTROL.ADMIN.ai_user_budget 
       WHERE user_name = CURRENT_USER())
    THEN
      AI_EXTRACT(input_text, instructions)
    WHEN exemption_token IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM AI_COST_CONTROL.ADMIN.ai_exemption_tokens
        WHERE token_id = exemption_token
          AND user_name = CURRENT_USER()
          AND used = FALSE
          AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP())
      )
    THEN
      AI_EXTRACT(input_text, instructions)
    ELSE
      TO_VARIANT('ERROR: Token estimate exceeds single-query limit.')
  END
$$;

-- safe_ai_classify: Wrapper for AI_CLASSIFY
CREATE OR REPLACE FUNCTION safe_ai_classify(
    input_text VARCHAR,
    categories ARRAY,
    exemption_token VARCHAR DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
  CASE
    WHEN AI_COUNT_TOKENS('ai_classify', input_text, categories) <=
      (SELECT COALESCE(MAX(single_query_limit), 1000000) 
       FROM AI_COST_CONTROL.ADMIN.ai_user_budget 
       WHERE user_name = CURRENT_USER())
    THEN
      AI_CLASSIFY(input_text, categories)
    WHEN exemption_token IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM AI_COST_CONTROL.ADMIN.ai_exemption_tokens
        WHERE token_id = exemption_token
          AND user_name = CURRENT_USER()
          AND used = FALSE
          AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP())
      )
    THEN
      AI_CLASSIFY(input_text, categories)
    ELSE
      'ERROR: Token estimate exceeds single-query limit.'
  END
$$;

-- safe_ai_sentiment: Wrapper for AI_SENTIMENT
CREATE OR REPLACE FUNCTION safe_ai_sentiment(
    input_text VARCHAR
)
RETURNS FLOAT
LANGUAGE SQL
AS
$$
  AI_SENTIMENT(input_text)
$$;

-- Grant UDF usage to PUBLIC (or specific roles)
-- Adjust this based on your access model
-- GRANT USAGE ON FUNCTION safe_ai_complete(VARCHAR, VARCHAR, VARCHAR) TO ROLE PUBLIC;
-- GRANT USAGE ON FUNCTION safe_ai_extract(VARCHAR, VARCHAR, VARCHAR) TO ROLE PUBLIC;
-- GRANT USAGE ON FUNCTION safe_ai_classify(VARCHAR, ARRAY, VARCHAR) TO ROLE PUBLIC;
-- GRANT USAGE ON FUNCTION safe_ai_sentiment(VARCHAR) TO ROLE PUBLIC;
