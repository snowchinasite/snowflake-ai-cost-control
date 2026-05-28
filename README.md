# Snowflake AI SQL Cost Control

A Snowflake-native solution for controlling AI Functions (AI SQL) credit consumption through automated quota enforcement, single-query token pre-checks, and an approval workflow.

## Problem

- Users running Cortex AI Functions can quickly consume large amounts of credits
- No native per-user real-time limit for AI SQL token consumption
- A single large query (e.g., `AI_COMPLETE` on millions of rows) can cost thousands of dollars
- No built-in approval workflow for exceptional large requests

## Solution Architecture

```
Three-Layer Control:

L1 - Pre-Check (Wrapper UDF)
    Single-query token estimation → block if too large

L2 - Daily Quota (Scheduled Task)
    Monitor per-user daily usage → revoke UDF access if exceeded

L3 - Approval Workflow (Streamlit)
    User requests quota increase → admin approves → access auto-restores
```

### How It Works

1. **Users call Wrapper UDFs** (`safe_ai_complete`) instead of native AI Functions (`AI_COMPLETE`)
2. **UDF pre-checks** token count via `AI_COUNT_TOKENS` before execution
3. **If single-query limit exceeded**: returns error (zero token consumed)
4. **If daily quota exceeded**: Task revokes UDF access automatically
5. **User requests increase** via Streamlit → admin approves → Task restores access
6. **Exemption tokens** allow one-time bypass for approved large requests

### Key Properties

| Property | Detail |
|----------|--------|
| SQL change | Function name only (`AI_COMPLETE` → `safe_ai_complete`) |
| Data permissions | Unchanged – outer SQL still uses caller's role |
| Billing | Recorded under the calling user |
| Dependencies | 100% Snowflake-native (UDF, Task, Table, Streamlit) |

## Quick Start

### 1. Setup (run as ACCOUNTADMIN)

```sql
-- Run in order:
-- sql/01_setup.sql     → Creates database, roles, tables
-- sql/02_wrapper_udfs.sql → Creates wrapper UDFs
-- sql/04_tasks.sql     → Creates scheduled tasks
-- sql/04_grant_access.sql → Grants access to user roles
```

### 2. Configure User Budgets

```sql
INSERT INTO AI_COST_CONTROL.ADMIN.ai_user_budget 
  (user_name, daily_token_limit, single_query_limit)
VALUES 
  ('ALICE', 5000000, 1000000),
  ('BOB', 10000000, 2000000);
```

### 3. Enforce UDF-Only Access

```sql
-- This disables direct AI_COMPLETE/AI_EXTRACT/etc. for all users
REVOKE DATABASE ROLE SNOWFLAKE.CORTEX_USER FROM ROLE PUBLIC;
```

### 4. Deploy Streamlit App

Upload `streamlit/app.py` to Snowflake and create a Streamlit app for the approval portal.

### 5. Enable Tasks

```sql
ALTER TASK ai_circuit_breaker_task RESUME;
ALTER TASK ai_recovery_task RESUME;
ALTER TASK ai_daily_reset_task RESUME;
```

## Usage Examples

```sql
-- Normal usage (under limit → executes normally)
SELECT safe_ai_complete('mistral-large2', prompt_col) FROM my_table;

-- Over single-query limit → returns error message
SELECT safe_ai_complete('mistral-large2', very_long_text) FROM big_table;
-- Returns: "ERROR: Token estimate (2500000) exceeds your single-query limit..."

-- With exemption token (approved large request)
SELECT safe_ai_complete('mistral-large2', long_text, 'token_abc123') FROM big_table;
```

## Project Structure

```
├── README.md
├── sql/
│   ├── 01_setup.sql          # Database, roles, tables
│   ├── 02_wrapper_udfs.sql   # Wrapper UDFs with pre-check
│   ├── 04_tasks.sql          # Scheduled enforcement tasks
│   └── 04_grant_access.sql   # Grant templates
├── streamlit/
│   └── app.py                # Approval portal UI
└── docs/
    └── solution_design.md    # Full design document
```

## Security Considerations

- **UDF Owner Role** (`AI_COST_CONTROL_ADMIN`) must not be granted to regular users
- **Audit role hierarchy** regularly: `SHOW GRANTS OF DATABASE ROLE SNOWFLAKE.CORTEX_USER`
- **Exemption tokens** are bound to specific users via `CURRENT_USER()` check
- **Expired/used tokens** are automatically rejected by the UDF

## Limitations

| Item | Note |
|------|------|
| `AI_COUNT_TOKENS` estimates input only | Output tokens unpredictable; admin should grant ~2x buffer |
| Task detection delay | ~15min interval + ACCOUNT_USAGE has ~45min latency |
| SQL UDF cannot mark token as used | Use Task to expire tokens, or accept minimal reuse risk |
| Function name change | Users must use `safe_ai_xxx` instead of `AI_XXX` |

## Requirements

- Snowflake Enterprise Edition or higher
- ACCOUNTADMIN role for initial setup
- A warehouse for task execution

## License

MIT
