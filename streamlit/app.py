import streamlit as st
from snowflake.snowpark.context import get_active_session

session = get_active_session()

st.set_page_config(page_title="AI Cost Control", page_icon="🛡️", layout="wide")
st.title("AI SQL Cost Control Portal")

current_user = session.sql("SELECT CURRENT_USER()").collect()[0][0]
user_role = session.sql("SELECT CURRENT_ROLE()").collect()[0][0]

is_admin = user_role in ('ACCOUNTADMIN', 'AI_COST_CONTROL_ADMIN')

if is_admin:
    tab1, tab2, tab3 = st.tabs(["My Usage", "Approval Queue", "User Management"])
else:
    tab1, tab2 = st.tabs(["My Usage", "Request Quota"])
    tab3 = None

# Tab 1: My Usage
with tab1:
    st.subheader(f"Usage Summary - {current_user}")

    usage = session.sql(f"""
        SELECT 
            COALESCE(SUM(token_count), 0) as daily_tokens,
            COUNT(*) as query_count
        FROM SNOWFLAKE.ACCOUNT_USAGE.AI_FUNCTIONS_USAGE_HISTORY
        WHERE user_name = '{current_user}'
          AND start_time >= CURRENT_DATE()
    """).collect()

    budget = session.sql(f"""
        SELECT daily_token_limit, single_query_limit
        FROM AI_COST_CONTROL.ADMIN.ai_user_budget
        WHERE user_name = '{current_user}'
    """).collect()

    col1, col2, col3 = st.columns(3)

    daily_used = usage[0][0] if usage else 0
    daily_limit = budget[0][0] if budget else 5000000

    col1.metric("Today's Token Usage", f"{daily_used:,.0f}")
    col2.metric("Daily Limit", f"{daily_limit:,.0f}")
    col3.metric("Remaining", f"{max(0, daily_limit - daily_used):,.0f}")

    pct = min(100, (daily_used / daily_limit * 100)) if daily_limit > 0 else 0
    st.progress(pct / 100)

    if pct >= 100:
        st.error("⚠️ Daily quota exceeded. Your AI SQL access has been suspended.")
    elif pct >= 80:
        st.warning("⚠️ You've used over 80% of your daily quota.")

# Tab 2: Request Quota / Approval Queue
if is_admin:
    with tab2:
        st.subheader("Pending Approval Requests")

        pending = session.sql("""
            SELECT request_id, user_name, request_type, requested_amount, reason, created_at
            FROM AI_COST_CONTROL.ADMIN.ai_quota_requests
            WHERE status = 'PENDING'
            ORDER BY created_at ASC
        """).to_pandas()

        if pending.empty:
            st.info("No pending requests.")
        else:
            for _, row in pending.iterrows():
                with st.expander(f"🔔 {row['USER_NAME']} - {row['REQUEST_TYPE']} ({row['CREATED_AT']})"):
                    st.write(f"**Requested Amount:** {row['REQUESTED_AMOUNT']:,.0f} tokens")
                    st.write(f"**Reason:** {row['REASON']}")

                    col_a, col_b = st.columns(2)
                    approved_amount = col_a.number_input(
                        "Approved Amount", 
                        value=int(row['REQUESTED_AMOUNT'] * 2),
                        key=f"amt_{row['REQUEST_ID']}"
                    )

                    if col_a.button("✅ Approve", key=f"approve_{row['REQUEST_ID']}"):
                        session.sql(f"""
                            UPDATE AI_COST_CONTROL.ADMIN.ai_quota_requests
                            SET status = 'APPROVED', 
                                approved_by = '{current_user}',
                                approved_amount = {approved_amount},
                                resolved_at = CURRENT_TIMESTAMP()
                            WHERE request_id = '{row['REQUEST_ID']}'
                        """).collect()

                        if row['REQUEST_TYPE'] == 'EXEMPTION_TOKEN':
                            session.sql(f"""
                                INSERT INTO AI_COST_CONTROL.ADMIN.ai_exemption_tokens 
                                  (user_name, max_tokens)
                                VALUES ('{row['USER_NAME']}', {approved_amount})
                            """).collect()

                        st.success(f"Approved for {row['USER_NAME']}")
                        st.rerun()

                    if col_b.button("❌ Deny", key=f"deny_{row['REQUEST_ID']}"):
                        session.sql(f"""
                            UPDATE AI_COST_CONTROL.ADMIN.ai_quota_requests
                            SET status = 'DENIED',
                                approved_by = '{current_user}',
                                resolved_at = CURRENT_TIMESTAMP()
                            WHERE request_id = '{row['REQUEST_ID']}'
                        """).collect()
                        st.warning(f"Denied request from {row['USER_NAME']}")
                        st.rerun()
else:
    with tab2:
        st.subheader("Request Quota Increase")

        request_type = st.radio("Request Type", ["Daily Quota Increase", "Single Large Query (Exemption Token)"])

        if request_type == "Daily Quota Increase":
            amount = st.number_input("Additional tokens needed", min_value=100000, value=2000000, step=500000)
        else:
            amount = st.number_input("Estimated tokens for this query", min_value=100000, value=5000000, step=1000000)
            st.info("💡 Admin will typically approve 2x your estimate to cover output tokens.")

        reason = st.text_area("Reason for request")

        if st.button("Submit Request"):
            if not reason:
                st.error("Please provide a reason.")
            else:
                req_type = 'DAILY_QUOTA' if request_type == "Daily Quota Increase" else 'EXEMPTION_TOKEN'
                session.sql(f"""
                    INSERT INTO AI_COST_CONTROL.ADMIN.ai_quota_requests 
                      (user_name, request_type, requested_amount, reason)
                    VALUES ('{current_user}', '{req_type}', {amount}, '{reason}')
                """).collect()
                st.success("✅ Request submitted. Admin will be notified.")

# Tab 3: User Management (admin only)
if is_admin and tab3:
    with tab3:
        st.subheader("User Budget Management")

        users = session.sql("""
            SELECT user_name, daily_token_limit, single_query_limit, is_exempt, updated_at
            FROM AI_COST_CONTROL.ADMIN.ai_user_budget
            ORDER BY user_name
        """).to_pandas()

        st.dataframe(users, use_container_width=True)

        st.subheader("Active Exemption Tokens")
        tokens = session.sql("""
            SELECT token_id, user_name, max_tokens, used, created_at, expires_at
            FROM AI_COST_CONTROL.ADMIN.ai_exemption_tokens
            WHERE used = FALSE AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP())
            ORDER BY created_at DESC
        """).to_pandas()

        if tokens.empty:
            st.info("No active exemption tokens.")
        else:
            st.dataframe(tokens, use_container_width=True)

        st.subheader("Revocation Log")
        logs = session.sql("""
            SELECT user_name, revoked_at, restored_at, reason
            FROM AI_COST_CONTROL.ADMIN.ai_revoke_log
            ORDER BY revoked_at DESC
            LIMIT 50
        """).to_pandas()
        st.dataframe(logs, use_container_width=True)
