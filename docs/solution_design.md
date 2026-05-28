# Snowflake AI SQL Cost Control Solution

## 1. 背景与问题

- 客户使用 Cortex AI Functions (AI SQL) 时，credits 消耗快速增长且难以预测
- 部分用户缺乏最佳实践意识（如对大数据集直接调用 AI 函数），导致意外高额消耗
- 现有 Snowflake 原生能力无法实现"实时拦截"或"事前审批"
- 需要一套机制：在不影响日常开发体验的前提下，控制不合理消耗

---

## 2. 方案目标

| 目标 | 说明 |
|------|------|
| 不割裂开发体验 | 用户日常在 Worksheet/IDE 中正常使用 AI SQL，写法几乎不变 |
| 事前拦截 | 单条大请求在执行前被预估和拦截，防止巨额消耗 |
| 自动熔断 | 日累计消耗达到上限后自动停止 AI SQL 权限 |
| 按需加额 | 超限用户可申请临时额度，审批通过后自动恢复 |
| 可观测 | 管理员可查看每用户消耗趋势和异常 |
| 低维护成本 | 全部基于 Snowflake 原生组件，无需外部基础设施 |

---

## 3. 整体架构

### 3.1 设计理念

本方案采用 **"事前预检 + 自动熔断 + 按需加额"** 的三层控制机制：

| 控制层 | 作用 | 时机 | 解决的问题 |
|--------|------|------|-----------|
| **L1 - 事前预检** | Wrapper UDF 内置 token 预估，单条超限直接拒绝 | 查询执行前 | 防止单条巨额查询（如百万行 AI_COMPLETE） |
| **L2 - 日额度熔断** | Task 监控 per-user 日消耗，超限自动 Revoke UDF USAGE 权限 | 查询执行后（周期检测） | 防止累计消耗失控 |
| **L3 - 审批加额** | 用户申请 → 管理员审批 → 自动恢复权限并加额 | 被熔断后 | 保障合理的大额需求不被永久阻断 |

**核心机制说明：**

- **封装替代原生调用**：用户不直接使用原生 AI Functions（权限被收回），改为使用管理员封装的 Wrapper UDF。UDF 函数签名与原生几乎一致，用户 SQL 写法仅函数名不同
- **事前预检**：Wrapper UDF 内部先调用 `AI_COUNT_TOKENS` 预估本次请求的 token 消耗，超过单条上限（如 100 万 token）直接拒绝，不执行不计费
- **单条豁免机制**：对于确实需要执行的大请求，用户可申请一次性豁免 Token，在调用时作为可选参数传入，UDF 验证通过后放行（用完即失效）
- **用户身份校验**：UDF 内部通过 `CURRENT_USER()` 校验调用者身份，确保豁免 Token 只能被绑定的用户本人使用
- **权限分离**：UDF 以 Owner's Rights 运行（owner 有 AI Functions 权限），用户数据权限由外层 SQL 的 caller role 控制，计费记录在调用者名下
- **自动熔断**：后台 Task 持续监控 ACCOUNT_USAGE 中每用户的日消耗总量，触达预设限额后自动 Revoke 用户对 Wrapper UDF 的 USAGE 权限
- **按需加额**：被熔断的用户可通过 Streamlit 申请临时额度，审批通过后 Task 自动恢复权限
- **弹性额度**：加额仅作用于当日，次日自动恢复基线

**方案优点：**

| 优点 | 说明 |
|------|------|
| **事前拦截** | 单条超大请求在执行前即被阻止，避免不可逆的巨额消耗 |
| **开发体验一致** | SQL 写法仅函数名变化（`AI_COMPLETE` → `safe_ai_complete`），无需改变开发流程 |
| **数据权限不绕过** | 外层 SQL 仍走 caller 自身的数据权限，UDF 内部不访问用户表 |
| **自动化运维** | 熔断和恢复完全由 Task 自动执行，日常无需人工干预 |
| **灵活可控** | 不同用户/角色可设不同额度和单条上限，生产 service account 可豁免 |
| **成本可预测** | 单条上限 + 日总量上限双重封顶，杜绝失控场景 |
| **合理放行** | 审批加额机制确保真正需要的大额消耗不被永久阻断 |
| **全栈原生** | 全部基于 Snowflake 组件（UDF、Task、Table、Alert、Streamlit），无外部依赖 |
| **可审计** | token 预估、消耗记录、熔断事件、审批历史全部可追溯 |

### 3.2 架构图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           用户正常开发                                     │
│             (Snowsight Worksheet / IDE / Stored Proc / Streamlit)         │
│                                                                           │
│   SELECT safe_ai_complete('mistral-large2', col) FROM my_table;           │
│          ↑ 函数名替换，其余写法完全不变                                      │
│          ↑ 外层 SQL 走用户自身的数据权限（caller role）                       │
└──────────────────────────────┬────────────────────────────────────────────┘
                               │ 调用 Wrapper UDF
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    L1 - 事前预检 (Wrapper UDF)                             │
│                         Owner's Rights                                    │
│                                                                           │
│   ┌─────────────────────────────────────────────────────────────────┐    │
│   │  Step 1: AI_COUNT_TOKENS 预估本次 token 消耗                      │    │
│   │  Step 2: 预估值 > 单条上限？                                       │    │
│   │           ├─ YES → 是否携带有效 exemption_token？                  │    │
│   │           │         ├─ YES → 校验 token 归属 CURRENT_USER()       │    │
│   │           │         │         且未使用 → 放行执行，标记 token 已用  │    │
│   │           │         └─ NO  → 返回错误信息，不执行（0 token 消耗）  │    │
│   │           └─ NO  → 调用原生 AI Function，返回结果                  │    │
│   └─────────────────────────────────────────────────────────────────┘    │
│                                                                           │
│   · UDF 内部不访问任何用户表（仅处理传入的文本值）                           │
│   · AI 执行权限来自 UDF owner                                             │
│   · 计费记录在 CURRENT_USER()（调用者）名下                                │
└──────────────────────────────┬────────────────────────────────────────────┘
                               │ 通过预检 → 执行 AI Function
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                       Snowflake AI Functions                              │
│               (AI_COMPLETE, AI_EXTRACT, AI_CLASSIFY 等)                   │
└──────────────────────────────┬────────────────────────────────────────────┘
                               │ 消耗自动记录
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│               ACCOUNT_USAGE.AI_FUNCTIONS_USAGE_HISTORY                    │
│                     （Snowflake 原生 Usage 视图）                           │
└──────────────────────────────┬────────────────────────────────────────────┘
                               │
                ┌──────────────┴──────────────┐
                ▼                              ▼
┌────────────────────────────┐    ┌──────────────────────────────────────┐
│  L2 - 日额度熔断 Task (15min) │    │           异常告警 Alert                │
│                            │    │   (1h 内消耗 > 日均 3x → 通知管理员)   │
│  检测：用户日已用 > 日限额   │    └──────────────────────────────────────┘
│  动作：REVOKE UDF USAGE    │
│        (下一条 AI SQL 失败) │
└─────────────┬──────────────┘
              │ 超限 → 用户被熔断
              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     L3 - 审批加额流程                                      │
│                                                                           │
│  ┌───────────────┐      ┌─────────────────┐      ┌────────────────────┐ │
│  │  用户自助申请   │ ───→ │  通知推送         │ ───→ │   管理员审批        │ │
│  │  (Streamlit)  │      │  (Email/Slack)  │      │   (Streamlit)      │ │
│  │               │      │                 │      │                    │ │
│  │  · 查看当日消耗│      │  · 申请人信息    │      │  · Approve / Deny  │ │
│  │  · 选择加额额度│      │  · 申请额度      │      │  · 调整额度        │ │
│  │  · 填写理由   │      │  · 申请理由      │      │                    │ │
│  └───────────────┘      └─────────────────┘      └─────────┬──────────┘ │
└──────────────────────────────────────────────────────────── ┼────────────┘
                                                              │ 审批通过
                                                              ▼
                                                ┌──────────────────────────┐
                                                │   恢复 Task (5min)        │
                                                │                          │
                                                │   检测：APPROVED 记录     │
                                                │   动作：GRANT Role        │
                                                │         + 更新当日额度    │
                                                └──────────────────────────┘
                                                              │
                                                              ▼
                                                   用户权限恢复，继续开发
```

### 3.3 权限与计费模型

```
┌─────────────────────────────────────────────────────────────────┐
│                        权限分离设计                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  用户 Role                        UDF Owner Role                  │
│  ┌───────────────────┐            ┌───────────────────────────┐  │
│  │ ✅ 对 my_table 的  │            │ ✅ AI_FUNCTIONS_USER_ROLE  │  │
│  │    SELECT 权限     │            │    (可调用 AI Functions)   │  │
│  │ ✅ 对 UDF 的       │            │                           │  │
│  │    USAGE 权限      │            │                           │  │
│  │ ❌ 无 AI Functions │            │                           │  │
│  │    直接调用权限     │            │                           │  │
│  └───────────────────┘            └───────────────────────────┘  │
│           │                                    │                  │
│           │ 外层 SQL 数据访问                    │ UDF 内部 AI 调用  │
│           ▼                                    ▼                  │
│  SELECT safe_ai_complete(col)     AI_COUNT_TOKENS + AI_COMPLETE   │
│  FROM my_table                                                    │
│           │                                    │                  │
│           └───────────── 计费 ─────────────────┘                  │
│                          ▼                                        │
│              记录在 CURRENT_USER()（调用者）名下                     │
└─────────────────────────────────────────────────────────────────┘
```

**用户 SQL 写法对比：**

```sql
-- 原生写法（权限已被收回，不可用）
SELECT AI_COMPLETE('mistral-large2', prompt_col) FROM my_table WHERE ...;

-- 封装后写法（唯一变化：函数名）
SELECT safe_ai_complete('mistral-large2', prompt_col) FROM my_table WHERE ...;

-- 携带豁免 Token 执行大请求（第三个参数为可选，日常不传）
SELECT safe_ai_complete('mistral-large2', prompt_col, 'exemption_token_abc123') FROM big_table;

-- 其他用法完全一致：嵌套、JOIN、子查询均支持
SELECT a.id, safe_ai_extract(a.document, 'name') 
FROM documents a 
JOIN users b ON a.user_id = b.id 
WHERE b.department = 'engineering';
```

### 3.4 关键设计决策

| 决策 | 选择 | 原因 |
|------|------|------|
| 调用方式 | Wrapper UDF 替代原生函数 | 在不改变 SQL 结构的前提下嵌入事前预检逻辑 |
| UDF 权限模型 | Owner's Rights | Caller 无 AI 权限也能通过 UDF 调用；数据权限由外层 SQL 保障 |
| 单条预检 | AI_COUNT_TOKENS | 零成本预估，超限直接拒绝不执行 |
| 控制粒度 | Per-User 而非 Per-Role | Role 可能被多人共用，无法精准控制个体 |
| 熔断方式 | Revoke UDF USAGE 而非 Kill Query | Revoke 是幂等操作，不浪费已执行的 token |
| 检测频率 | 15 分钟 | 平衡及时性和 ACCOUNT_USAGE 数据延迟 |
| 额度周期 | 日级别 | 月级粒度过粗，无法防止单日爆发；小时级过于严苛 |
| 审批方式 | 人工审批 | 保留管理者判断权，避免自动加额失去管控意义 |
| 恢复方式 | Task 自动执行 | 审批通过后无需人工操作，减少等待时间 |

---

## 4. 核心组件

### 4.1 权限基础设施

- 收回 `SNOWFLAKE.CORTEX_USER` from PUBLIC（禁止直接调用原生 AI Functions）
- 创建 `AI_FUNCTIONS_USER_ROLE`，仅授予 UDF Owner Role
- 用户仅拥有对 Wrapper UDF 的 USAGE 权限
- 通过 Grant/Revoke UDF 的 USAGE 权限实现熔断和恢复

**防止 UDF 被绕过的保障措施：**

| 措施 | 说明 |
|------|------|
| 收回 PUBLIC 的 CORTEX_USER | 所有用户默认无法直接调用 AI Functions |
| 审计 Role Hierarchy | 确保没有其他 role 通过继承关系间接拥有 CORTEX_USER 或 AI_FUNCTIONS_USER_ROLE |
| 定期审计 | 运行 `SHOW GRANTS OF DATABASE ROLE SNOWFLAKE.CORTEX_USER` 确认仅 Owner Role 持有 |
| Owner Role 专用 | UDF Owner Role（如 `AI_COST_CONTROL_ADMIN`）不纳入任何用户的 role hierarchy，仅管理员持有 |
| 监控新增 Role | 设置 Alert 监控 `GRANT` 操作，若有新 role 被授予 CORTEX_USER 立即通知 |

### 4.2 Wrapper UDF

- 封装所有常用 AI Functions（safe_ai_complete, safe_ai_extract, safe_ai_classify 等）
- 内置 `AI_COUNT_TOKENS` 预检逻辑
- Owner's Rights，owner 拥有 `AI_FUNCTIONS_USER_ROLE`
- 单条 token 上限可配置
- 支持可选参数 `exemption_token`（DEFAULT NULL），用于单次大请求豁免
- 内部通过 `CURRENT_USER()` 校验豁免 Token 是否属于当前调用者

### 4.3 豁免 Token 机制

- **用途**：当用户有合理需求执行超过单条上限的大请求时，申请一次性豁免 Token
- **申请流程**：用户通过 Streamlit 提交申请（说明预估 token 量和用途）→ 管理员审批并设定豁免额度（建议给预估值的 2 倍余量）→ 生成 Token 返回给用户
- **使用方式**：用户在调用时传入第三个可选参数
  ```sql
  SELECT safe_ai_complete('mistral-large2', col, 'token_abc123') FROM big_table;
  ```
- **安全机制**：
  - Token 绑定申请用户，UDF 内部校验 `CURRENT_USER()` 必须与 Token 归属一致
  - 一次性使用，用完即标记失效，不可复用
  - Token 存储在 `ai_exemption_tokens` 表中，含：user、token_id、max_tokens、used、created_at、expires_at
- **存储表结构**：`ai_exemption_tokens (token_id, user_name, max_tokens, used BOOLEAN, created_at, expires_at)`

### 4.4 额度管理表

- `ai_user_budget`: 每用户每日/每月基础额度
- `ai_quota_requests`: 加额申请记录（申请人、额度、审批状态、审批人、时间）
- `ai_exemption_tokens`: 单条豁免 Token 记录

### 4.5 熔断 Task

- 频率：每 15 分钟
- 逻辑：查询 `AI_FUNCTIONS_USAGE_HISTORY`，对比用户日已用 vs 日限额
- 动作：超限 → Revoke 用户对 Wrapper UDF 的 USAGE 权限

### 4.6 恢复 Task

- 频率：每 5 分钟
- 逻辑：检查 `ai_quota_requests` 中状态为 `APPROVED` 且未执行的记录
- 动作：Grant UDF USAGE 权限 + 更新当日额度

### 4.7 审批通知

- 使用 Notification Integration（Email 或 Webhook → Slack）
- 用户提交申请后自动触发通知给管理员

### 4.8 Streamlit 界面（轻量）

- **用户视角**：查看当日已用额度、提交加额申请、申请单条豁免 Token
- **管理员视角**：审批队列（日额度加额 + 单条豁免）、用户消耗排行、历史趋势

---

## 5. 用户体验流程

```
场景 A：正常使用
正常开发 ──→ 调用 safe_ai_complete() → 预检通过 → 正常返回结果

场景 B：单条请求超限
调用 safe_ai_complete() → 预检不通过（token 超单条上限）
    │
    │  ← 返回错误提示："预估 token 超过单条上限，请申请豁免 Token"
    ▼
进入 Streamlit → 申请单条豁免 Token（填写预估量 + 理由）
    │
    │  ← 管理员审批，给出豁免额度（如预估的 2 倍）
    ▼
获得 exemption_token → 重新调用：
    SELECT safe_ai_complete('model', col, 'token_abc123') FROM big_table;
    │
    │  ← UDF 校验 token 有效 + 用户匹配 → 放行
    ▼
执行完成，token 标记为已使用（不可复用）

场景 C：日累计超限
多次正常调用 → 日累计触达限额 → Task 检测后 Revoke 权限
    │
    │  ← 下一条 AI SQL 报错 "Insufficient privileges"
    ▼
进入 Streamlit → 查看消耗详情 → 提交日额度加额申请
    │
    │  ← 管理员审批通过
    ▼
恢复 Task 检测（≤5min）→ Grant 权限 + 当日额度增加 → 继续开发
```

---

## 6. 配置参数

| 参数 | 说明 | 建议默认值 |
|------|------|-----------|
| 单条 token 上限 | 单次 AI 调用允许的最大 token 预估值 | 1,000,000 tokens |
| 基础日限额 | 每用户每日可用 token 总量 | 根据角色设定 |
| 熔断检测频率 | Task 检查周期 | 15 分钟 |
| 恢复检测频率 | 审批后恢复周期 | 5 分钟 |
| 单次加额上限 | 每次申请最大可加额度 | 管理员可配 |
| 月度总上限 | 每用户每月不可超过的硬上限 | 管理员可配 |
| 异常告警阈值 | 1小时内消耗超日均 N 倍触发告警 | 3x |

---

## 7. 技术实现清单

| # | 组件 | 类型 | 说明 |
|---|------|------|------|
| 1 | 权限重构 | SQL DDL | Revoke CORTEX_USER from PUBLIC + 创建 Owner Role |
| 2 | Wrapper UDFs | UDF | safe_ai_complete / safe_ai_extract / safe_ai_classify 等（含豁免参数） |
| 3 | ai_user_budget 表 | Table | 用户额度配置 |
| 4 | ai_quota_requests 表 | Table | 加额申请记录 |
| 5 | ai_exemption_tokens 表 | Table | 单条豁免 Token 记录 |
| 6 | 熔断 Task | Task | 定期检测 + Revoke UDF Usage |
| 7 | 恢复 Task | Task | 检测审批 + Grant UDF Usage |
| 8 | 异常告警 Alert | Alert | 短时消耗飙升 + Role 绕过监控 |
| 9 | Notification Integration | Integration | Email/Slack 通知 |
| 10 | Streamlit App | Streamlit | 申请 + 审批 + 监控界面 |

---

## 8. 扩展考虑

- **按角色差异化额度**：不同角色（开发/分析/生产）设不同基线和单条上限
- **生产 Task/Proc 豁免**：service account 可直接使用原生 AI Functions，不走 Wrapper UDF
- **消耗预估工具**：Streamlit 中嵌入 `AI_COUNT_TOKENS` 计算器，帮助用户事前评估
- **历史趋势分析**：定期聚合消耗数据，生成月度 cost report
- **与 Snowflake Budget 联动**：account 级 budget 作为最终兜底
- **UDF 版本管理**：新增 AI Functions 时只需扩展 Wrapper UDF，用户无需调整

---

## 9. 限制与注意事项

| 事项 | 说明 |
|------|------|
| 函数名变化 | 用户需使用 `safe_ai_xxx` 替代原生 `AI_XXX`，有一定迁移成本 |
| 熔断非实时 | Task 有 15min 检测间隔，期间日累计可能短暂超限 |
| Usage History 延迟 | ACCOUNT_USAGE 数据有 ~45min 延迟，熔断存在滞后 |
| UDF 维护 | 新增 AI Functions 时需同步创建对应 Wrapper UDF |
| 审批依赖人工 | 非工作时间审批可能等待较久，可考虑设置自动审批规则 |
| AI_COUNT_TOKENS 仅预估 input | `AI_COUNT_TOKENS` 只能预估 input tokens，output tokens 不可预知。建议管理员在审批豁免 Token 时给予预估值 2 倍左右的余量，以覆盖 output 消耗 |
| Owner Role 安全 | UDF Owner Role（`AI_COST_CONTROL_ADMIN`）需严格管控，不可授予普通用户或纳入用户 role hierarchy，否则用户可绕过 Wrapper UDF 直接调用 AI Functions |
| Role Hierarchy 审计 | 需定期检查是否有 role 通过继承关系间接获得 CORTEX_USER 权限，新增 role 时尤其注意 |

---

## 10. 下一步

- [ ] 确认框架后开始实现（SQL DDL + UDF + Task + Streamlit）
- [ ] 确定客户角色模型和初始额度参数
- [ ] 确定需要封装的 AI Functions 列表
- [ ] 确定通知渠道（Email / Slack / 其他）
- [ ] 确定单条 token 上限和日额度基线
