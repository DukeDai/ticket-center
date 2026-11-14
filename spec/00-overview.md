# 目标与范围、角色与场景、核心业务流程、基础不变量与状态机、领域事件、验收标准、变更记录

> 合同的一部分。章节：§1 · §2 · §3 · §4.1-4.2 · §5 总述与 §5.1-5.4 · §6 · §7 · §8。索引见 [`SPEC.md`](../SPEC.md)。
> 本文件是**合同**：改动这里的业务行为，必须同步改这里，并同步 `docs/ddd.md`（领域模型）与 `docs/schema-design.md`（物理模型）。

---

## 1. 目标与范围

### 1.1 一句话定义

一个面向 OTA 的**票券中台**：把来自多个 GDS / 票务平台（Ingresso、FonTicket、Goodfellows·JTB、GlobalTix、票付通…）的票券，
归一化成**一套规范商品模型**，对外以**同一套商品/价格/库存/订单模型**同时支撑 **B 端分销**与 **C 端自营**售卖。

### 1.2 为什么要做（问题陈述）

多源票券的真正难点不是「接几个 API」，而是：

| 难点 | 具体表现 | 本系统的应对 |
|---|---|---|
| 源模型异构 | 同是「景点票」，Ingresso 叫 `product/items`，GlobalTix 叫 `package/items`，票付通叫 `goods/specList`，JTB 叫 `product/departures` | **原样层 + 规范层**双层模型，源报文永不丢 |
| 同一商品多源 | 同一个香港故宫，3 个源都在卖，价格/库存/条款各不相同 | `product_mapping` 多对多映射 + `product_session_source` 场次级冗余 |
| 成本不可比 | 源币种 HKD/JPY/EUR/BRL/CNY 混杂 | `fx_rate` 快照 + 统一折算到基准币种再比价 |
| 源会挂 | 预订超时、库存被占位、接口限流 | Booking 独立聚合 + 重试/改派 + 报文归档 + 漏斗自检 |
| B/C 端诉求不同 | C 端看体验与转化，B 端看利润、账期、配额 | `channel` 隔离，上架/价格/库存/预订策略全渠道可配 |
| 历史不可复现 | 商品改名、改价、下架后，订单详情要还原当时的样子 | 明细快照 `detail_snapshot` / `pricing_snapshot` |

### 1.3 本期范围（In Scope）

- 多源接入的**领域模型与物理模型**（本阶段核心交付）
- 归一化：源商品 → 规范商品的映射与属性收敛
- 多源比价与自动选源（成本归一 → 路由排序）
- 交易链路：订单 → 预订 → 出票 → 核销 → 退款 → 结算
- 运维可观测：源健康度、履约漏斗、结算缺口、不变量自检

### 1.4 非范围（Out of Scope，本阶段明确不做）

- **C 端写侧与 Web**：C 端**只读** API 已落地（`cmd/tc-api` + `internal/capi`：
  浏览 / 变体差异 / 套餐构成 / 日历四个端点，只读读模型、不 join 主数据）；
  但**购物车 → 下单 → 支付**这一段还没开口子（**没有调用方身份**），Web 也没有
- 各 GDS 真实适配器实现（**Trip.com 分销侧已实现**；其余源需以各家接入文档为准，
  端点/请求体未公开的一律留配置模板并显式标注「待商务确认」，不编造）
- 支付渠道真实对接（只留模型与幂等位）
- 分销商多级佣金、发票税务系统对接
- 真实汇率/税务引擎（只留快照表与规则字段）

---

## 2. 角色与场景

| 角色 | 核心诉求 | 系统提供 |
|---|---|---|
| C 端买家 | 看懂、看懂价格、能下单、拿到券 | 规范商品 + 价格日历 + 场次 + 移动券 QR |
| B 端分销商 | 查价、批量下单、稳定履约、账期结算 | `channel_listing` 独立定价 + 配额 + 账期 + 结算单 |
| 运营 | 上架、改价、绑定源、处理异常单 | 上架配置 + 映射审核 + `v_order_fulfillment_gap` 漏斗 |
| 采购/BD | 对比各源成本、监控源健康 | `v_product_source_compare` + `v_supplier_sync_health` |
| 财务 | 与源对账、发现差异 | `settlement_statement/line` + `v_settlement_gap` |
| 客服 | 查一张票的下单/预订/出票全链路 | 订单→booking→voucher→redemption 单一视图 |

---

## 3. 核心业务流程

### 3.1 商品供给流（Supply）

```
源 API / 源推送
   └─> 接入层（Go：cmd/tc-connect + internal/：凭证 → 请求 → 四分类 → 重试 → 归档）
        └─> supplier_raw_payload（原文归档，可回放，落库前脱敏）
             └─> 同步落库写者（internal/sync，入口 tc-connect jobs：幂等 upsert，退役不删）
                  └─> supplier_product（源商品原样落库）
                  ├─> supplier_ticket_type（源票种）
                  ├─> supplier_variant（源变体：固定组合 SKU / 参数化售卖方案）
                  ├─> supplier_session（源场次）
                  └─> supplier_price_calendar（源成本价日历，按 源变体×规范变体×日期）
                       └─> product_mapping（归一化到规范商品）
                            └─> product（规范商品）
                                 ├─> product_variant（可售单元：人群 × 票种 × 园区范围 × 加购件）
                                 │      └─> supplier_variant_mapping（覆盖语义：谁能履约这个组合）
                                 ├─> product_session（规范场次）
                                 │      └─> product_session_source（哪些源能供这个场次）
                                 └─> ticket_type（规范票种，人群维度的锚）
```

**规范层与源层的主数据来源不同**（§5.27 第三条）：
规范层是**人工撰写的**（`product` / `product_variant` / `product_session` 是我们的商业定义，
源侧不报这个组合），源层是**从源报文机器推导出来的**（源侧报什么就是什么）。
衔接处是 `product_mapping` —— 那是**判断**，不是推导。
同步作业只做机器能做的判定：源侧报了一个我们目录里没有的东西，
它落成 `pending_review`，**不替人决定它该对应哪个商品**。

### 3.2 售前（Search / Detail）

1. 按 `channel` 找到该渠道已上架的 `channel_listing`
2. 展开规范场次 `product_session`，每个场次通过 `product_session_source` 找到可供给的源
3. 实时可用性：按 `supplier.availability_mode` 决定策略
   - `live` → 调源 API，结果写 `availability_cache`（短 TTL）
   - `pull_sync` → 读 `inventory_snapshot` 最新一条
   - `push` → 读源推送落库数据
   - `static` → 视为不限量
4. 价格：`price_calendar` 取对客售价；成本参考 `v_source_routing_candidates`
5. 多源比价：`v_source_routing_candidates` 按 `cost_base`（FX 归一后）排序，`route_rank=1` 即首选源

### 3.3 交易与履约流（Transaction → Booking → Fulfillment）

```
下单 → sales_order(created/awaiting_payment)
        └─ 支付成功 → paid
             └─ 选源路由 → 创建 booking(pending)          ← 独立聚合，不阻塞订单
                  └─ 发往源侧 → booking(requested)
                       ├─ 成功 → booking(confirmed) → 出票 voucher(issued) → 订单 confirmed/fulfilled
                       │        └─ 核销 → voucher(used) + voucher_redemption
                       ├─ 可重试失败 → booking(pending) + next_retry_at + 自动重报
                       └─ 不可重试失败 → booking(failed)
                                └─ 改派备源（product_session_source.role='fallback'）→ 新 booking
                                     └─ 全源失败 → 订单 failed / 触发自动退款与用户通知
```

**关键约束**：订单与预订是两个聚合。源的故障**不允许**回滚或阻塞订单聚合，只改变订单的履约状态。

### 3.4 结算流（Settlement）

```
已确认 booking → 按周期与源出结算单 settlement_statement
                  └─ settlement_line 逐行挂 booking
                       └─ 与账面成本比对 → discrepancy_type / discrepancy_amount
                            └─ v_settlement_gap 找「已确认但没进结算单」的漏账
```

---

### 4.1 供给与交易侧（1-20）

| # | 不变量 |
|---|---|
| 1 | 每个规范商品至少有一个 active 的源映射（无孤儿商品） |
| 2 | 同一规范商品在同一供应商下最多一个 primary 映射 |
| 3 | 场次源绑定的源商品，必须映射到该场次所属的规范商品 |
| 4 | 订单金额自洽：`total = subtotal - discount + tax` |
| 5 | 订单明细自洽：按人计价 `total = unit × qty`；按团报价 团总价来自快照（见 §4.5） |
| 6 | 订单行的 `supplier_id` 必须与其 `supplier_product` 所属供应商一致 |
| 7 | 已确认预订必须有 `external_booking_id` |
| 8 | 同一供应商下票码不得重复出票 |
| 9 | 权益消耗数不得超过发放数 |
| 10 | 对客售价必须 ≥ 采纳成本（不得亏本销售） |
| 11 | 已支付订单必须有 succeeded 状态的支付记录 |
| 12 | 已履约订单必须有交付过的凭证（issued/used/expired） |
| 13 | 映射行的 `supplier_id` 与源商品所属供应商一致 |
| 14 | 所有在用币种（非基准币种）必须有汇率快照 |
| 15 | 每个 online 状态的渠道上架，必须绑定至少一个启用的源 |
| 16 | 售价日历的采纳成本必须可追溯到具体源商品 |
| 17 | `booking.attempt_count` 不得小于实际尝试记录数 |
| 18 | 渠道内订单幂等键不得重复 |
| 19 | 可用性缓存的供应商必须存在 |
| 20 | 已出票凭证必须归属某个已确认预订 |

### 4.2 C 端展示与购买侧（21-26）

| # | 不变量 |
|---|---|
| 21 | 购物车项的库存预占数量必须与购物数量一致 |
| 22 | 活跃库存预占必须关联某个购物车或订单（不得为幽灵占库存） |
| 23 | 优惠券使用次数不得超过发放上限 |
| 24 | 订单引用的优惠券必须有对应的核销记录 |
| 25 | 要求实名的票种，持票人数必须与票数一致 |
| 26 | C 端读模型卡片的起价必须能追溯到价格日历 |

---

## 5. 状态机

### 5.1 订单 `sales_order.status`

```
created → awaiting_payment → paid → booking_pending → confirmed → fulfilled
                ↓                 ↓            ↓             ↓
             expired          failed      partially_fulfilled
                ↓                 ↓            ↓             ↓
            cancelled         cancelled    cancelled      cancelled
                                  ↓            ↓
                            refunding → refunded
                                  ↑  （退款失败时按 refunding → 原状态退回）
```

退款的入口边（`RefundRequested`）：`paid` / `booking_pending` / `confirmed` /
`partially_fulfilled` / `fulfilled` / `failed` → `refunding`。
退款的出口边：`refunding → refunded`（`OrderRefundFailed` 时按原状态退回）。
这张表的唯一来源是 `state_transition`，改流转只能改那张表。

### 5.2 预订 `booking.status`

```
pending → requested → confirmed → ticketed
   ↑         ↓
   └────── failed        （可重试 → 回 pending 并设 next_retry_at）
                 ↓
              cancelled / expired
```

### 5.3 凭证 `voucher.status`

```
pending → issued → used
   ↓        ↓
 void  ←───┴──→ expired
   ↓
 refunded
```

`issued → used` 这条边只有一条来路：核销写路径 `fn_redeem_voucher()`（见 §5.8）。
出券写 `pending → issued`，核销写 `issued → used`，两条边各归一条写路径，
谁也不越界改别人的状态。

`issued → expired` 这条边也只有一条来路：凭证过期作业 `fn_expire_vouchers()`
（见 §5.24）。核销路径**只落核销记录、不改券状态** ——
券过期了由过期作业统一改（`fn_redeem_voucher` 遇到过期券时
返回 `result='expired'`、`reason='voucher_expired'`，但不改 `voucher.status`）。

### 5.4 状态机由机制保证（2026-11-06 落地）

上面三张图以前只是文档：谁 `UPDATE sales_order SET status='fulfilled'` 都能改，
库不会拦。客诉时才发现订单从 paid 直接跳到 fulfilled，中间该出的票没出。

现在合法流转写在 `state_transition` 表里（唯一来源），由两个函数保证：

| 机制 | 做什么 | 挡住什么 |
|---|---|---|
| `fn_guard_state_transition`（函数，挂在 `trg_*_status_guard` 触发器上，BEFORE UPDATE） | 目标状态不在合法边上就报错，改不动 | 跳过中间态、无声地改状态 |
| `fn_emit_state_event`（函数，挂在 `trg_*_status_event` 触发器上，AFTER INSERT/UPDATE） | 状态一变就往 `event_outbox` 写领域事件 | 「状态改了但事件丢了」 |

表名到聚合名的映射走 `fn_aggregate_type`：`sales_order` → `order`、
`sales_order_item` → `order_item`、`booking` → `booking`、`voucher` → `voucher`。
用的是聚合名而不是表名，因为 `event_outbox.aggregate_type` 记的是领域聚合。

所以：**改状态机 = 改 `state_transition` 表 + 同步本节**，
不是去改某个 Go 分支，也不是去改某段 SQL。

## 6. 领域事件（Domain Events）

| 事件 | 触发点 | 典型订阅方 |
|---|---|---|
| `ProductMapped` | 映射新建/变更 | 定价、索引重建 |
| `PriceChanged` | 源成本或对客价变更 | 缓存失效、推送 |
| `SessionSoldOut` | 场次售罄 | 下架、通知候补 |
| `OrderPlaced` | 下单 | 风控、库存预占 |
| `OrderItemReassigned` | 明细改派（换源重定价，未收款时） | 通知客户、报价刷新 |
| `OrderConfirmed` | 预订成功 | 发券、通知 |
| `BookingRequested` | 发起预订 | 追踪 |
| `BookingConfirmed` | 源确认 | 出券 |
| `BookingFailed` | 源失败 | 改派、退款、告警 |
| `VoucherIssued` | 出票 | 短信/邮件/Lark 通知 |
| `VoucherRedeemed` | 核销 | 对账、评价邀请 |
| `RefundRequested` | 退款申请 | 财务 |
| `StatementReconciled` | 对账完成 | 财务 |

事件统一经 `event_outbox` 落库后发布，保证「状态已改但事件丢失」不发生。

**事件由触发器产生，不靠调用方记得写。** 状态机每条边上带的 `event_type`
就是这里的事件名（`state_transition.event_type`），函数 `fn_emit_state_event`
挂在 `trg_*_status_event` 触发器上，在状态变化时自动落一条到 `event_outbox`。
所以谁改的状态都一样留痕 ——
Go、psql、脚本都一样。完整清单见 `state_transition` 表。

除上表外，状态机还会发出这些事件（同样由触发器产生）：

| 事件 | 触发点 |
|---|---|
| `OrderAwaitingPayment` / `OrderPaid` / `OrderBookingPending` | 订单状态推进 |
| `OrderFailed` / `OrderCancelled` / `OrderExpired` | 订单走向失败、取消、超时 |
| `OrderFulfilled` / `OrderPartiallyFulfilled` / `OrderRefunded` | 订单履约与退款 |
| `BookingCreated` / `BookingRequested` / `BookingConfirmed` / `BookingFailed` | 预订生命周期 |
| `BookingRetryScheduled` / `BookingCancelled` / `BookingExpired` / `BookingTicketed` | 重报、取消、超时、出票 |
| `VoucherCreated` / `VoucherIssued` / `VoucherRedeemed` | 凭证生命周期 |
| `VoucherVoided` / `VoucherExpired` / `VoucherRefunded` | 凭证作废、过期、退款 |


---

## 7. 验收标准（Acceptance Criteria）

- [x] 一套可重复执行的迁移（`db/migrations/NNN_*.sql` + 迁移引擎），在空库上零错误建表
- [x] 物理模型只增不改由机制保证：已应用的迁移文件被改动，迁移引擎拒绝继续跑（内容校验和 + 账本）
- [x] 一份 `db/seed.sql`，构造 7 个异构源 / 6 个规范商品 / 10 条跨源映射 / 3 源冗余场次
- [x] 一份 `db/verify.sql`，跑通全部视图并对全部不变量逐条断言（条数见 §4）
- [x] 多源比价结果按 FX 归一后可排序，`route_rank=1` 选中成本最低源
- [x] 场次级多源冗余可查（B4 段：香港故宫同一天 3 个供给源）
- [x] 履约漏斗可识别「已付款未出票」（订单 3 `suspected_lost=t`）
- [x] 结算缺口可查（`v_settlement_gap`）
- [x] C 端列表页可直出（`v_c_listing_feed`，无额外 join）
- [x] C 端详情页内容一次聚合（`v_c_product_detail`）
- [x] C 端日历含售罄/闭馆格子（`c_product_calendar`）
- [x] 读模型漂移可检测（`v_c_readmodel_drift`，种子数据 7 张卡片全部 `drifted=f`）
- [x] 购物车→预占→结算→实名→下单→出票→核销链路模型完整
- [x] **多维组合商品可表达**：北京环球影城 8 个变体（人群 × 票种 × 园区范围 × 加购件）
- [x] **变体级路由可用**：同一商品不同变体首选源不同（老年票走 Trip.com，其余走自由行）
- [x] **覆盖语义生效**：儿童园区通票只有自由行一个候选，商品级路由视图对该商品输出 0 行
- [x] **变体级交易链路**：一单两行明细（同商品不同变体）→ 两条预订 → 两张券 → 实名采集
- [x] **无凭证集成演练**：用 Trip.com / GlobalTix 真实报文结构跑通 mapping → 路由（`scripts/mapping_dryrun.py`），演练库不变量全 PASS
- [x] **定价只有一份实现**：`fn_price_variant` 是唯一实现，种子 / 演练器 / 接入层（`tc-connect price`）全部消费它；不变量 41 逐字段比对，42 把毛利率守住
- [x] **选源与定价同源**：`fn_route_candidates` 是选源的唯一实现，路由视图与定价函数共用候选集与排序键；不变量 43 保证「定价采用的源 = 路由选中的源」
- [x] **汇率留痕可复算**：留痕日期能独立复算出同一个折算因子，同币种不留假快照（不变量 45）
- [x] **前端 POC**：`scripts/poc/index.html` 展示变体矩阵 / 覆盖语义匹配 / 变体级路由 / 模型缺口 / 不变量自检
- [x] **状态机由机制保证**：合法流转写在 `state_transition` 表里，函数 `fn_guard_state_transition`（挂在 `trg_*_status_guard` 上）挡住非法流转（改不动），`fn_emit_state_event`（挂在 `trg_*_status_event` 上）保证状态一变就落一条领域事件到 `event_outbox`；交易侧不变量 46-53 验状态可达性与订单/预订/凭证的一致性
- [x] **下单有唯一实现**：`fn_place_order`（幂等键必填、金额只取 `fn_price_variant`、明细走快照、实名按 `checkout_requirement` 收齐）；接入层 `tc-connect order place/show`；下单侧不变量 54 逐行比对明细单价与定价函数输出
- [x] **履约有唯一实现**：`fn_record_payment` / `fn_create_bookings` / `fn_request_booking` / `fn_record_booking_attempt` / `fn_complete_booking` / `fn_issue_voucher` / `fn_retry_booking` / `fn_apply_order_fulfillment`（`db/migrations/005_fulfillment.sql`）；接入层 `internal/fulfillment` + `tc-connect fulfill pay|book|request|attempt|complete|issue|retry|show`
- [x] **订单的履约状态只有一套推导**：`fn_apply_order_fulfillment` 从明细的实际出票情况推状态，调用方只报事实；履约侧不变量 55-60 把支付、预订、出券与订单状态钉在一起
- [x] **票码与持票人一一对应**：票码数与要发的张数不符当场报错；按人计价一人一券、按团报价整团一券
- [x] **预订的源场次来自绑定**：从 `product_session_source` 取，不按日期猜（不变量 59）
- [x] **退款有唯一实现**：`fn_request_refund` / `fn_approve_refund` / `fn_complete_refund`（`db/migrations/007_refund.sql`）；接入层 `internal/refund` + `tc-connect refund request|approve|complete|show`
- [x] **退款的资格与金额由事实决定**：有没有收到钱看 `sales_payment` 里成功的支付记录，不看订单状态；金额必须等于按承诺算出的应付退款额（净额）；幂等键必填，同键异内容报错
- [x] **退款承诺有唯一的执行者**：`fn_refund_policy` 读承诺、算截止点、算应付额；发起与放行各判一次（不变量 124-126）
- [x] **退款成功后事实一起改**：明细 / 凭证 / 预订 / 支付 / 订单一次改完；退款侧不变量 61-64 把住「钱退了、事实没变」
- [x] **退款失败订单能退回去**：发起时记 `previous_order_status`，失败时照它恢复；退不回去就留在 `refunding` 等人处理
- [x] **核销有唯一实现**：`fn_redeem_voucher`（`db/migrations/008_redemption.sql`）；接入层 `internal/redemption` + `tc-connect redeem scan|show`；核销侧不变量 65-68 把住「已核销必有一次成功核销、一张券最多成功一次、额度一次用尽且账对得上、核销发生在有效期内」
- [x] **重复扫码记 duplicate 不覆盖事实**：核销记录永远追加；第二次扫同一张券返回 `duplicate` 并带回第一次核销的记录 id 与时间，调用方据此对账
- [x] **核销后整单退款被挡下**：退款路径撞上「有已核销的票」时明确报错要人工处理（这条分支以前走不到，因为没有东西能把票变成 `used`）
- [x] **库存预占有唯一实现**：`fn_available_qty` / `fn_reserve_qty` / `fn_hold_inventory` / `fn_release_hold` / `fn_expire_holds`（`db/migrations/009_inventory_hold.sql`）；接入层 `internal/inventory` + `tc-connect stock show` / `tc-connect hold create|release|expire|show`；库存侧不变量 69-72 把住「卖出多少查得到、承诺与实卖对得上、可售数不许被扣两遍」
- [x] **可售数只有一个实现**：源侧快照与我们的承诺对账（`unreflected = our_sold − source_sold`），不双扣；取不到库存数据返回「不知道」而不是 0
- [x] **并发不超卖**：`fn_reserve_qty` 按源场次升序加行锁，明知不够当场报错；「不知道」不拦但把当时的可售数写进明细快照
- [x] **有效期是数据不是常量**：轴选项带 `valid_days`，`fn_variant_validity_days` 是唯一读法，出券按它算券的窗口；不变量 73-75 把住「口径不歧义、券不短于承诺、卖出去的源覆盖得住」
- [x] **异构差异可对照**：`v_variant_comparison` 一行看清两个可售单元差在哪（人群 / 轴取值 / 有效期 / 退款口径 / 可用源），`v_variant_validity` 给出有效期窗口
- [x] **异构差异走到 C 端**：`c_variant_facts` + `v_c_variant_feed` 把人群 / 轴取值 / 有效天数 / 退款口径带进读模型，请求链路不 join 主数据；读模型侧不变量 76-77 把住「读模型不与主数据分叉、日历有效期终点不被算错」
- [x] **差异可查**：接入层 `internal/variant` + `tc-connect variant compare|coverage|feed`（对照表 / 源覆盖缺口 / C 端读视图）
- [x] **异构融合方向 B（组合套餐）有模型**：`supplier_variant_composition` 记源侧配方、`product_variant_relation.quantity` 记规范侧组件数量、`v_variant_composition` 两侧并排；组合映射侧不变量 78-81 把住「成分同源、成分顶得住、两侧逐项对得上、组合不走直接映射」
- [x] **组合映射有唯一实现**：接入层 `internal/compose` + `tc-connect compose plan|apply`（源侧组合表达式 → 配方，核上规范侧组件声明与数量）；覆盖判定复用库里的 `fn_variant_covered`，不在 Go 侧重写
- [x] **组合的定价与预订**（组合的成本 = Σ 组件成本 × 数量，一次预订要带整组源 SKU）：见 §5.13。组合的成本从源侧配方算起（`fn_combo_components`），成分的源 SKU 取自配方（不重新选源 —— 重新选源会让配方变成摆设，出现「按 A 源的价格卖、按 B 源出票」）；一份订单明细 = 一份套餐，成分的履约事实挂在 `sales_order_item_source` 上；**预订按源 SKU 建**（一个源 SKU 一条预订，成分的拆分留在请求明细里 —— 参数化源的成人票与儿童票是同一个源 SKU，按成分建预订就是同一个源 SKU 订两次）；出券按成分发（各发各的张数、各按各的持票人）；超卖按源场次总需求判；整单退款把成分的事实一起改。组合售卖侧不变量 82-88 守住这七条口径

- [x] **源侧把整套套餐当一个 SKU 卖的情况**（异构融合的第三种形态）：单独声明（`supplier_variant_bundle` + `supplier_variant_bundle_part`），不推断；成本来自源侧那个整套报价（不重新路由）、预订的单位是套、入场份数是成分张数、库存扣源侧整套票种的池子、有效期由源侧声明且必须盖住成分窗口（§5.15）；不变量 95-101 守住形态唯一 / 成分对得上 / 有效期盖得住 / 成本分摊守恒 / 入场份数守恒 / 池子不跨源票种 / 需求按池子加总
- [x] **三种供给形态放在同一张表上对照**（§5.16）：`v_variant_supply_forms` 一行一个「可售单元 × 一天 × 一个渠道 × 一种形态」，把单张 / 配方 / 套装的源、成本、缺口、入场份数并排 —— 配方与套装在 `v_variant_routing_candidates` 里一行都没有（选源只建模方向 A），不另建对照表就看不见它们在卖；不变量 102-104 守住形态不消失 / 成本与定价函数一致 / 份数与 C 端构成读模型一致
- [x] **源 SKU 下架时供给形态不许缩小**（§5.17）：`fn_combo_components` / `fn_bundle_components` 把「源的可用性」从「决定这一行在不在」改成「决定这一行有没有价」，配方少一个成分不再被当成另一个套餐重新定价（收 3 份入场钱出 1 份票），套装的形态行不再整个从对照视图里消失；不变量 105-107 守住成分不消失 / 源 SKU 下架时对照视图与定价函数都不许说能供
- [x] **C 端只读 API 落地**（§5.18）：`internal/capi` + `cmd/tc-api`，四个业务端点（浏览 / 变体差异 / 套餐构成 / 日历）加一个 `GET /healthz` 探活开成 HTTP 接口；请求链路只读读模型不 join 主数据、渠道必答、金额以字符串出、有效期终点由库算、参数不合法就报错
- [x] **公开读接口只服务自营 C 端**（§5.18 第三条）：匿名接口没有调用方身份，边界画在渠道上 —— 只服务 `channel_type='b2c_own'` 且在营的渠道，B 端分销 / 企业客户 / 供应商直销一律 403，且渠道不存在与渠道不对外服务给同一个答复
- [x] **可履约源数一个口径**（§5.19）：`fn_variant_supply_source_count` 是「有几个源能供这个可售单元（这一天、这个渠道）」的唯一实现，日历格子的 `source_count` 三种形态都算得对 —— 配方与套装不再写 0（0 的意思是「一个源都供不了」，而它们明明在卖）；不变量 108 守住它
- [x] **值进 SQL 的转义从约定变成机制**（§5.26）：`internal/store` 提供 `NewSQL` / `Bind` / `BindAll` / `BindJSON` / `And` / `Or` / `Where`（绑定时转义，非标量直接报错并指路 `BindJSON`）与 `Quote`（字符串字面量）/ `QuoteIdent`（标识符）；`internal/sqllint` + `cmd/tc-lint` 扫 AST，把「值拼进 SQL 的引号位置且没经过转义」报出来，门禁挂在 `make check` 与 CI 上；`internal/capi/products.go` / `internal/migrate/migrate.go` / `internal/variant/variant.go` 三处改为走绑定机制。门禁盯带引号的位置、放过裸数值位置 —— 放过是判据宁放过不误伤的取舍，文档里写明了，真正的防线是写查询时走绑定机制
- [ ] 各源真实适配器（下一阶段，按 `docs/connector-contract.md` 实施）
- [ ] API / Web 端（读侧已落地，见 §5.18；还差 B 端管理台与 C 端购买链路的**写侧** —— 购物车 / 结算 / 下单 / 支付，以及它们依赖的调用方身份与鉴权）
- [x] **改派写路径落地**（§5.20）：`fn_reassign_order_item`（`db/migrations/024_reassign_order_item.sql`）是唯一实现 —— 改派 = 重新选源 + 重新定价（源与价都取自 `fn_price_variant`），只发生在未收款、还没预订过的单张形态上；成分行与库存预占跟着源一起走（否则就是「按 A 源的价格卖、按 B 源出票」「按新源卖、按旧源占库存」），留痕写进明细快照的 `reassignments`；接入层 `internal/reassign` + `tc-connect order reassign|stale`；改派侧不变量 109-112 守住「留痕是链、明细没被手改、已收款不许改派、成分行与明细同源」
- [x] **源侧的售卖份数区间有人读了**（§5.21）：`min_qty` / `max_qty` 是源侧的一手事实（最少成团人数 / 单笔上限），以前全库没有一处读它 —— 客户买 1 张按团价的票，系统按整团价收了 1200，源侧因为不足 6 人拒单（钱收了、票出不来）；`fn_source_quantity_limits`（唯一读法）+ `fn_qty_servable`（唯一判定）守着落单与改派两条路；份数的单位 = 源侧的售卖单位（单张按人 = 份、按团 = 人、套装 = 套、配方 = 该源 SKU 的份数），同一个源 SKU 顶多个成分时比的是**这个 SKU 的总份数**（源侧收到的是一条预订里的总份数）；区间记进明细快照的 `quantity_limits`；份数区间侧不变量 113-115 守住「留痕自相矛盾、留痕指向别的源、改派后区间没换」
- [x] **按团报价的单位价口径只有一个实现**（§5.22）：`fn_unit_amount(basis, total, quantity)` 是「总价 → 单位价」的唯一实现（按团按人分摊，按人原样）；落单、改派、待改派清单三条路都调它 —— 清单比成本时原来直接拿团成本和人均成本比（1100 ≠ 157.14），每一条按团报价的未收款明细都被误报成「成本变了」，而真去改派写路径自己返回 `no_change`，**清单说的与写路径做的不一样，清单就不可信**；团总价与团成本留在明细快照里（`group_total` / `cost_price`）；按团单位价口径侧不变量 116-118 守住「分摊口径自相矛盾、清单说变了其实没变」
- [ ] 行级退款（需要「优惠券 / 税费 / 折扣怎么摊到每一行」的分摊口径 + 源侧支持部分取消；在此之前系统对行级退款明确报错，不自己编规则）
- [x] **凭证过期作业落地**（§5.24）：`fn_expire_vouchers`（`db/migrations/028_voucher_expiry.sql`）把 `valid_to` 已过的 `issued` 券推进到 `expired`（幂等、限批、判据是券自己的 `valid_to`）；事件由 `trg_voucher_status_event` 自动落，作业不自己插；「交付过」的口径一起改成 `issued` / `used` / `expired`（`fn_delivered_voucher_statuses`）—— 不改的话，券一过期，订单的履约状态会翻成未履约、已出票的明细会变成可改派（一次交付两次出票）；作业漏跑由 `v_voucher_expiry_overdue` 看得见，不挡门禁；过期作业侧不变量 120-121 守住「过期券必须有有效期终点、必须已出票」
- [x] **作业有入口了**（§5.25）：`tc-connect jobs` 一次跑完凭证过期 / 预占过期 / 组合同步 / 读模型刷新，跑完退出；间隔不写在代码里，交给外部调度器按 cron / CronJob 调；失败非零退出让调度器重试；作业幂等靠 `UPDATE ... WHERE status = 'issued'` 的形状，不靠调度器的自觉；刷新后仍漂移非零退出（防御性断言），到期却还停在 `issued` 只报告不失败（§5.24 的「看得见但不挡门禁」）

---

## 8. 变更记录

| 日期 | 变更 | 影响 |
|---|---|---|
| 2026-11-14 | **退款承诺的执行者落地（032 + 033）**：新增 `db/migrations/032_refund_policy_enforcer.sql`：`fn_refund_policy(p_order_id)` 是退款承诺的唯一读法与执行者（纯读函数，解析这一单**实际生效**的承诺：`product.refund_policy` 与 `channel_listing.refund_policy_override` 逐字段合并；算截止点 `product_session.start_at` / `session_date` 取最早；算应付退款额 `实付 × (1 − fee_percent)`，四舍五入两位）；`fn_request_refund` / `fn_approve_refund` 各整体替换一次（发起判资格 + 校验金额，放行**重判一遍** —— 发起到放行之间时间在走，`cutoff_hours` 会被吃掉）；`sales_refund.raw_payload->'policy'` 冻进承诺快照（`refundable` / `cutoff_hours` / `fee_percent` / `expected_amount` 四个键）；不变量从 123 条扩到 126 条（124 退成功的单金额必须等于应付额、125 承诺不可退的商品不许有退成功的单、126 每一张退款单的金额都必须等于应付额），新增 `v_invariant_checks_refund_policy`；不变量 62 的「金额」这一半改为对照应付额（不再对照 `order.total`）；新增 `db/migrations/033_refund_payload_merge.sql`：`fn_complete_refund` 的 `raw_payload` 改为**合并**而不是覆盖（`raw_payload || v_callback`，合并前摘掉回调报文里的 `policy` 键）；Go 侧 `internal/refund` 只拼参数、只读结果，测试改成向库问应付额 | 承诺写在数据里、没人执行：C 端写着「可退 10% 手续费」，退款路径却按全额退，少收的钱公司自己承担，客户看到的口径与实际拿到的钱对不上。现在承诺进入写路径，且**发起与放行各判一次** —— 只判一次的话，截止点是在承诺里写着的时点，不是发起那一刻的状态。`sales_refund.amount` 的口径定死为**净额**（实退给客户的钱），有手续费承诺时它不等于订单实付 —— 差的那笔是承诺过的手续费，不是错的 |
| 2026-11-14 | **源侧兑现窗口落到列上（源侧肯兑现几天不再靠猜）**：新增 `supplier_variant.valid_days`（可空，> 0）；选源时多一条判据（源侧报了天数且短于规范侧承诺 → 这个源不进候选，源侧没报不拦）；不变量从 121 条扩到 123 条（122 卖出去的票源侧兑现窗口盖得住承诺、123 候选集里的源兑现窗口盖得住承诺）；事前事后各一条门禁，刻意互不依赖 | GlobalTix 报的是 `validityDays`（源侧肯兑现几天），`passType` 只是营销标签。归一化此前只认 `passType`，两日票的承诺落到了规范侧的轴选项上，源侧肯兑现几天没有任何地方记 —— 选源时不看它，出券时也不看它。「不知道」不等于「能兑现」，也不等于「不能兑现」：源侧没报就不拦，与硬约束 34 同一条口径 |
| 2026-11-14 | **合同与硬约束分拆成多个文件（只重组，不改业务行为）**：`SPEC.md` 从 2466 行拆成索引（50 行）+ `spec/` 下 14 个主题文件（§4 不变量小节与 §5 写路径小节**同文件**，不变量与它的口径在一起）；`AGENTS.md` 从 705 行拆成 483 行（留下「这是什么」+ 40 条硬约束），运维内容（目录 / 常用命令 / 沙箱注意 / 自检清单）移到新建的 `docs/working-notes.md`；README 的 13 处 `SPEC.md#…` 锚点改为指向 `spec/*.md`；`docs/` 下 4 个文档与 `db/seed.sql` 的 `SPEC.md §N` 引用补上文件路径 | 两个大文件都到了「一个文件什么都装」的地步：合同 2466 行、硬约束 705 行，改一处要读的东西太多，加一条规则得挤进别人的章节里。取舍写在这里：**拆分的单元是主题，不是篇幅**（一个文件一个主题，不按「多少行」切 —— 按行数切出来的文件会跨主题，下次加规则还是得找）；**§4 与 §5 的小节放同一文件**（不变量与它的口径必须挨着读，拆开就变成「规则在一个文件、门禁在另一个文件」）；**§ 号一个不改**（`§4.13` 还是 `§4.13`，引用它的地方不必改；只补文件路径，不改编号 —— 编号是给人定位用的，路径是给人点开用的，两件事）；**`SPEC.md` 保留 §4 的分组快照**（合同需要自足，但那一份只写这一处，加条时改这一处，见硬约束 37）。**已发布的迁移文件一个字没动**（`db/migrations/*.sql` 的 sha256 记在 `ops.schema_migration` 账本里，改了会被迁移引擎直接拒绝 —— 迁移文件里的 `SPEC.md §N` 注释因此保持原样，宁可留旧路径也不破账本）；不变量一条没少、一条没丢（121 条仍逐条断言） |
| 2026-11-13 | **值进 SQL 的转义从约定变成机制（§5.26）**：`internal/store` 新增 `NewSQL` / `Bind` / `BindAll` / `BindJSON` / `And` / `Or` / `Where`（绑定时转义，非标量直接报错并指路 `BindJSON`）与 `Quote`（字符串字面量）/ `QuoteIdent`（标识符）；新增 `internal/sqllint` + `cmd/tc-lint`（扫 AST，把「值拼进 SQL 的引号位置且没经过转义」报出来），门禁挂在 `make check` 与 CI 上；`internal/capi/products.go` / `internal/migrate/migrate.go` / `internal/variant/variant.go` 三处改为走绑定机制；`AGENTS.md` 硬约束 40 与 `docs/integrations.md` 第 11 条同步；**无迁移** | psql 是子进程，没有 `$1` 占位符，SQL 全是拼出来的 —— 唯一的防线是「记得调 `store.Quote`」，而「记得」是约定不是机制，约定迟早被漏掉一次，漏掉的那一次就是注入（一次注入就是一次数据泄露，而「记得转义」在被赶工的时候是第一个被省掉的）。取舍写在这里：**门禁盯带引号的位置**（`'%s'` 里插进来的值会闭合引号，是真问题），**放过裸数值位置**（`col = %s` 插进来的值不带引号，字符串内容打断不了它 —— 但它同样不是转义过的字面量，所以写查询优先用 `store.NewSQL`，它不留这个口子）；**包级常量与编译期字面量不算问题**（门禁噪音多了就没人看了，判据宁放过不误伤）。门禁会放过两种真问题，所以它是第一道不是唯一一道 —— 这是设计上的取舍，不是漏洞，文档里写明了 |
| 2026-11-13 | **作业调度落地（§5.25）**：新增 `cmd/tc-connect/cmd_jobs.go`（`tc-connect jobs`）与 `make jobs`：一次跑完凭证过期（`fn_expire_vouchers`）/ 预占过期（`fn_expire_holds`）/ 组合同步（`fn_sync_combo_calendar`）/ 读模型刷新（`fn_refresh_read_models`），再读 `v_c_readmodel_drift` 与 `v_voucher_expiry_overdue` 做读侧自检；新增 §5.25 与 §7 验收项；**无迁移**（判据与作业本体全在库里，Go 侧只拼参数、只读结果） | 上一条落地了 `fn_expire_vouchers`，但**作业在库里没人调它** —— 判据、幂等、事件全对，只要没人跑，券的状态还是停在 `issued`，那个状态洞原样存在。补作业而不补调度，是把「没人跑」从「没人知道」变成「以为有人跑」。取舍写在这里：**一次跑完就退出**（不常驻、不自己排期 —— 常驻进程要处理信号、重启、漂移、跨库切换，那是调度器的活）；**间隔不写在代码里**（写死就成了第二份口径，改的时候要改两处，改漏一处没人知道），交给系统 cron 或 k8s CronJob；**失败非零退出**，重试交给调度器；**作业幂等**靠的是「`UPDATE ... WHERE status = 'issued'`」这个形状，不是靠调度器的自觉，限批（默认 500）是同一件事的另一半；**刷新后仍漂移非零退出**（读模型刚刷新过还对不上就是硬事实 —— 这条是**防御性断言**，刷新本身就是修复机制，手改出来的漂移会被修好，所以它是最后一道防线不是常规路径）；**到期却还停在 `issued` 只报告不失败**（那是运行状态不是数据违规，§5.24 的口径是「看得见但不挡门禁」—— 让它挡住调度，会把一条告警变成一个死循环） |
| 2026-11-13 | **凭证过期作业落地（028）**：新增 `db/migrations/028_voucher_expiry.sql`：`fn_expire_vouchers(p_limit INTEGER DEFAULT 500)` 把 `valid_to` 已过的 `issued` 券推进到 `expired`（幂等、限批、按 `valid_to, id` 排序）；新增 `fn_delivered_voucher_statuses()`（`issued` / `used` / `expired` = 交付过），并把 `fn_apply_order_fulfillment` / `fn_reassign_order_item` / `fn_issue_voucher` 与诊断视图里散落的 `IN ('issued','used')` 改读这个谓词；不变量从 119 条扩到 121 条（120 过期券必须有有效期终点 / 121 过期券必须已出票）；新增 §4.27 与 §5.24；新增 `v_voucher_expiry_overdue`（作业漏跑看得见，但不挡门禁）；Go 侧 `internal/redemption` 加 `ExpireOverdue` / `ShowOverdue`，CLI 加 `tc-connect redeem expire` / `redeem overdue`；回归测试三条（推进 + 幂等 / 事件自动落 / 别的状态不动） | 008 的核销路径刻意**只落核销记录、不改券状态**（「过期只落核销记录，不改券状态 —— 券状态由过期作业统一改」）—— 那句话当时是承诺，兑现它的那一半一直缺着。缺口不是「少一个功能」，是**一个看得见的状态洞**：券的有效期过了，券的状态还停在 `issued`，两个地方说的不是同一件事（券能被扫成「过期」，券本身还说「我还是有效的、还没用过」）。更要命的是**「交付过」的口径漏了 `expired`**：库里到处用 `status IN ('issued','used')` 表示「这张票给过客户」，而 `expired` 同样表示交付过 —— 不改的话，券一过期，订单的履约状态会从 `fulfilled` 翻成未履约、已出票的明细会变成可改派（一次交付两次出票）。取舍写在这里：**交付过 = `issued` / `used` / `expired`**（`void` / `refunded` 才是「没交付」或「收回」），用一个共享谓词 `fn_delivered_voucher_statuses()` 读，不在五处各写一遍 IN 列表（抄五遍的口径，迟早有一处漏）；**作业只 UPDATE 不自己插事件**（`trg_voucher_status_event` 自动落 `VoucherExpired`，手插事件就绕过了状态机）；**作业漏跑看得见但不挡门禁**（「到期却还是 issued」是运行状态不是数据违规，堵在门禁里只会让作业跑不成；`v_voucher_expiry_overdue` 让它看得见）；**作业不碰订单状态**（`fulfillment_status` 是推导值，由 `fn_apply_order_fulfillment` 推导，作业去写它就是两份实现）。判据是**券自己的 `valid_to`**，不是订单日期、不是可售单元的承诺 —— 券的有效期窗口是发券时定下的事实 |
| 2026-11-13 | **推导出来的数不许手抄（规整第二步·续）**：把 `scripts/counts.sh` 的覆盖面补全到「库对象数」（业务表 / 视图 / 索引 / 触发器 / CHECK 约束 / 序列 / 函数，各按它自己的口径：`pg_class` / `pg_indexes` / `pg_trigger NOT tgisinternal` / `pg_constraint` / `information_schema.routines`）与「种子行数」（表清单**从 `db/seed.sql` 自己的「-- 统计」段抽出来**，种子灌了哪些表由种子自己说，脚本不另抄一份）；`AGENTS.md` / `README.md` / `docs/schema-design.md` 里手抄的库对象数与种子行数改成「见 `make counts`」；硬约束 37 补一条「标签不许含糊」 | 上一条只把「不变量 / 测试 / mock 断言」三类数收到 `make counts` 后面，但**库对象数与种子行数还散在 AGENTS.md / README.md / docs/schema-design.md 三处手抄** —— 这一类数最脆：加一个迁移就多一个视图、改一次种子就多几行，读的人得自己算才知道文档是不是旧的。这一步抓出两处真漂移：① README 写「60 视图」，027 加过一个视图，实际是 **61**（文档少写了一个，人照着文档数就以为少了一个视图）；② 「14 日历格子」这个标签在 `c_product_calendar`（9 行）与 `c_variant_calendar`（14 行）之间**含糊** —— 它挨着的数字 9 指的是 `c_product_card`，标签却能被读成另一张表。取舍写在这里：**数只数一次，文档只引用不抄**（库对象数与种子行数一起进 `make counts`）；**标签不许含糊**（标签里带上表名，不让读的人猜）；**口径写在标签后面，别换口径**（触发器用 `pg_trigger NOT tgisinternal` 是 39，`information_schema.triggers` 是 46 —— 它按事件展开，换口径就换了数） |
| 2026-11-13 | **推导出来的数不许手抄（规整第二步）**：新增 `scripts/counts.sh` + `scripts/counts.sql`（`make counts`），从各自的源头数出「不变量条数 / 各主题分组条数 / 测试函数数 / mock 断言数」；`AGENTS.md` / `README.md` / `docs/integrations.md` / `docs/connector-contract.md` / `docs/schema-design.md` 里手抄的条数一律改成「见 `make counts`」；`SPEC.md` §4 保留一份快照（合同需要自足）但注明「以视图定义为准」；`db/verify.sql` 的门禁自检从 `seq = 118` 改成按 `check_name` 定位；`AGENTS.md` 新增硬约束 37 | 上一条规整（2026-11-12）把「规则只住 SPEC 一处」定下来了，但**数**还是散在各处手抄：不变量条数在 SPEC / AGENTS / README / schema-design 各写一遍，测试条数与 mock 断言数又各有各的一份。加一天条目的那天，抄过的地方就有一处是旧的 —— 读者先信文档、再跑出另一个数，然后开始怀疑整个仓库（这是最费时间的一种不一致）。取舍写在这里：**数只数一次，文档只引用不抄**；**按编号定位的门禁不许写在文档里**（`seq` 会重排，`check_name` 跨重排稳定，`db/verify.sql` 原来那句 `seq = 118` 重排一次就静悄悄指到别的门禁上去了）。不变量一条没少、一条没丢（119 条仍逐条断言，门禁仍全绿） |
| 2026-11-13 | **预占的默认 TTL 口径落地（027）**：新增 `db/migrations/027_hold_ttl_default.sql`：`fn_hold_inventory` 整体替换一次，函数开头把 `p_ttl_seconds` 归一（`COALESCE(p_ttl_seconds, 900)`），哈希与 `expires_at` 都用归一后的值；不变量从 118 条扩到 119 条（119 落库的预占必须有确定的到期时间）；新增 §4.26 与 §5.23；Go 侧新增回归测试 `TestHoldWithoutTTLMeansDefaultTTL`；README / AGENTS.md / `docs/integrations.md` / `cmd/tc-connect` 里写死的示例日期改成 `<日期>` 占位 + 指向 `tc-connect variant feed` | `tc-connect hold create` 不带 `--ttl`（README 自己给的示例命令）**跑不通**：`ERROR: null value in column "request_hash" ... violates not-null constraint`。根因是 PostgreSQL 的 `DEFAULT` 只在**省略实参**时生效，显式传 `NULL` 拿到的是 `NULL` —— Go 侧把「没指定」编码成 `NULL`，`NULL` 顺着哈希链把 `idempotency_record.request_hash` 撑成 `NULL`，预占在写幂等记录那一步就炸。取舍写在这里：**默认值住在库里，不住在调用方**（任何调用方省略 TTL 或传 `NULL`，拿到的都是同一个 900；默认值写在调用方 = 每多一个调用方就多一份默认值，三处总有一处忘了改 —— 那是「同一份规则被抄在三处」的病在数值上复发）；**`DEFAULT` 不是归一**（凡是「参数可以不给」的函数，归一都得在函数体里显式写）；**幂等口径不变**，但不指定与指定 900 现在落同一张预占（同一个 hash），同键异内容仍当场报错 |
| 2026-11-12 | **文档规整（不改业务行为）**：`AGENTS.md` / `README.md` / `SPEC.md` / `docs/schema-design.md` / `docs/ddd.md` 与实际库对齐 —— ① 把「触发器 `fn_guard_state_transition` / `fn_emit_state_event`」的错误说法改成「函数 + 挂在 `trg_*_status_guard` / `trg_*_status_event` 触发器上」（触发器与函数是两回事，改错了会照着不存在的对象去改库）；② §1.4 非范围改写：写侧与 Web 仍未实施，但**C 端只读 API 已落地**（`cmd/tc-api`，四个业务端点 + 探活），不再写「具体 API 尚未实施」；③ §4.8 的不变量分组口径修正：套装侧 7 → 5 + 套装库存侧 2，合计仍 118（**此为 2026-11-12 当天的数**；此后 027 迁移新增不变量 119，现为 119 条）；④ §5.18 的「五个端点」改说清楚「四个业务端点 + `GET /healthz`」；⑤ 各处表 / 视图 / 索引 / 触发器 / 函数 / 种子行数与 `db/verify.sql` 分组数统一到实测值（77 业务表 + 1 迁移账本 / 60 视图 / 227 索引 / 39 触发器 / 129 函数 / 67 序列；46 组验收查询）—— **这些是 2026-11-12 当天的数**；此后 027 迁移新增 1 个视图（现 61），其余不变 | 规格与实现分叉的根源是**同一份规则被抄在三处**（SPEC 合同 / AGENTS 硬约束 / README 实测结果），改一处忘两处，读者读到的是互相矛盾的三份话。规整的原则：**规则只住 SPEC 一处**（它是合同），AGENTS.md 只留「硬约束 + 怎么做」，README 只留「怎么跑 + 实测证据」。不变量一条没少、一条没丢（118 条逐条核对过编号与语义，只改措辞） |
| 2026-11-11 | **按团报价的单位价口径落地（026）**：新增 `db/migrations/026_reassign_candidates_cost_basis.sql`：`fn_unit_amount(basis, total, quantity)` 是「总价 → 单位价」的唯一实现（按团报价按人分摊并保留两位小数，按人计价原样返回）；`fn_place_order` 与 `fn_reassign_order_item` 各整体替换一次，写路径不再自己写一遍 CASE；`v_reassign_candidates` 整体替换一次，成本与价格的比较改走同一口径；不变量从 115 条扩到 118 条（116 按团明细的单位价必须等于团总价分摊到人、117 单位成本必须等于团成本分摊到人、118 待改派清单说「成本变了」的按团明细按人均口径算也必须真的变了）；新增 §4.25 与 §5.22 | 按团报价的源价行给的是团总价 / 团成本（整团 1200 / 1100），明细里记的单位价与单位成本是分摊到人的（171.43 / 157.14）。待改派清单比售价时做了分摊、比成本时却直接拿团成本和人均成本比 —— 1100 ≠ 157.14，于是每一条按团报价的未收款明细都被说成「成本变了」；而写路径的分摊一直是对的，真去改派函数自己返回 `no_change`：**清单说的与写路径做的不一样，清单就不可信**。取舍写在这里：**总价 → 单位价只有一个实现**（写路径与读路径都调 `fn_unit_amount`，不各写一遍 CASE）；**按团的人均只是分摊，不是价**（团总价与人数不成正比，人均那一份不许拿去和按人计价的单价比）；**明细里记的是分摊后的数**，团总价与团成本留在快照里（`detail_snapshot->'group_total'` / `->'cost_price'`），对账时看的是当时的团价不是今天的；**清单与写路径必须同口径**（清单说「成本变了」，按人均口径算也必须真的变了） |
| 2026-11-11 | **源侧的售卖份数区间落地（025）**：新增 `db/migrations/025_source_quantity_limits.sql`：`fn_source_quantity_limits`（源价行上 `min_qty` / `max_qty` 的唯一读法，键是「源变体 × 规范变体 × 日期」，与定价同一把键）+ `fn_qty_servable`（接不接得住这个份数的唯一判定）；`fn_place_order` 与 `fn_reassign_order_item` 各整体替换一次，落单与改派两条路都守这条；不变量从 112 条扩到 115 条（113 明细留痕的份数必须落在留痕的区间内、114 区间留痕必须指向明细的采纳源、115 改派过的明细必须记着当前采纳源的区间）；新增 §4.24 与 §5.21 | 源价行上的「最少 6 人成团 / 单笔上限 40 份」这一对整数以前全库没有一处读它 —— 客户买 1 张按团价的票，系统按整团价收了 1200，源侧因为不足 6 人直接拒单：钱收了、票出不来。取舍写在这里：**区间是源侧的一手事实，唯一读法是一个函数**（不各写一遍比较）；**份数的单位 = 源侧的售卖单位**（单张按人 = 份、按团 = 人、套装 = 套、配方 = 该源 SKU 的份数），按团报价的团总价只在人数达标时成立 —— 1 个人不能按团价成交；**同一个源 SKU 顶多个成分时比的是这个 SKU 的总份数**（参数化源里成人与儿童是同一个 SKU，源侧收到的是一条预订里的总份数：2 份成人 + 1 份儿童 = 3 份，按成分各判各的会漏掉「合起来超上限」）；**不按份数换源**（换了源就是另一个价，而售价行没有份数维度 —— 要按份数换源得给价格加阶梯，是另一个增量）；**改派也守这条**（新源接不住这一单的份数就不改派，不许改成一个出不了票的源）；**区间记进明细快照**（源侧后来改了他的成团人数，我们这边记的是当时那一版） |
| 2026-11-11 | **改派写路径落地**：新增 `db/migrations/024_reassign_order_item.sql`：`fn_reassign_order_item(order_id, order_item_id, reason)` 是改派的唯一实现（重新选源 + 重新定价，源与价都取自 `fn_price_variant`）；新增 `v_reassign_candidates` 读侧视图（哪些明细跟当前世界对不上、差在哪）；不变量从 108 条扩到 112 条（109 留痕的最后一跳必须等于明细当前值、110 留痕的链自洽且第一跳从定价快照起、111 已收款的订单不许有改派过的明细、112 单张形态的成分行必须与明细的采纳源一致），不变量 54 随之修订（改派过的行单价等于留痕里的新单价，没改派过的行仍等于下单时的定价快照）；接入层新增 `internal/reassign` + `tc-connect order reassign|stale` | 一条明细在下单之后、支付之前跟当前的世界对不上了 —— 源侧把 SKU 下架了、报价变了、出现了更便宜的源，明细还钉在原来的源和原来的价上：按旧价卖出去的东西要么出不了票，要么按一个已经过期的价卖。取舍写在这里：**改派 = 重新选源 + 重新定价**（源与价都取自定价函数的唯一实现，不另排一次序、不另算一次钱）；**只发生在未收款时**（已成交的金额失去依据，差价退不退是业务决策）；**只对单张形态**（配方与套装的源是声明的，换源要重新声明）；**只对没预订过的明细**（预订是事实）；**成分行与库存预占跟着源走** —— 这是最容易漏的一步：明细改了而成分行没改，就是「按 A 源的价格卖、按 B 源出票」；预占没改，就是「按新源卖、按旧源占库存」。**留痕写进明细快照**，下单时的定价快照保持冻结 —— 它记的是当时报给客户的那个价 |
| 2026-11-11 | **公开读接口只服务自营 C 端**：`internal/capi` 的所有收 `channel_id` 的端点改走同一个闸门 `requireChannel` —— 只服务 `channel_type='b2c_own'` 且 `status='active'` 的渠道，其余回 403；渠道不存在与渠道不对外服务给同一个答复 | C 端读接口是匿名的 —— 没有调用方身份，边界只能画在渠道上。`channel` 表里还有 B 端分销、企业客户、供应商直销、内部运营，它们的读模型与自营 C 端在**同一个库里**，价格、币种、税费、结算各是一套：原来换个渠道号就能读到别家的目录与报价（种子里的 B2B_HK 卡片就在公开端点上），那是**跨渠道的数据泄露**，不是「参数没校验」的小问题。取舍写在这里：**匿名接口只服务自营门店**；B 端与企业渠道的读侧要走它们自己的入口（带鉴权的 B 端管理台），不是靠一个 `channel_id` 参数区分 |
| 2026-11-10 | **可履约源数一个口径**：新增 `db/migrations/023_supply_source_count.sql`：`fn_variant_supply_source_count(variant, date, channel)` 是「有几个源能供这个可售单元（这一天、这个渠道）」的唯一实现（单张按路由选出的源、配方按成分的源 SKU、套装按源侧那个整套 SKU）；`fn_refresh_read_models` 与 `fn_sync_combo_calendar` 整体替换，日历格子的 `source_count` 改走这个函数；不变量从 107 条扩到 108 条（108 日历的可履约源数必须等于供给口径算出来的源数），新增 `v_invariant_checks_supply_source_count_023` | C 端的日历格子带一个 `source_count`（「有几个源能履约这个变体」），那是给前端的关键信号：只有 1 个源的组合没有备源，源挂了要提前知道。但原来的算法只在**单张**形态上算得对 —— 配方与套装按设计没有源映射（不变量 81），于是它们的格子一律是 0。0 的意思是「一个源都供不了」，而这些组合在对照视图里明明 `can_fulfil = true`、`supplier_count = 1`、售价也摆着：**C 端读到的是一个在卖的套餐被说成没有供给**。取舍写在这里：**源数不是成分数**（2 份成人 + 1 份儿童是 3 个成分、1 个源）、**不是价格行数**（同一个源当天两行报价还是 1 个源）；单张按路由算（选源与定价同源）；日历的 `source_count`（这一天能供几个）与对照视图的 `supplier_count`（这个形态由哪几个源组成，源下架了也还数着，§5.17 刻意保留的事实）是两件事，不混 |
| 2026-11-10 | **C 端只读 API 落地**：新增 `internal/capi`（路由 / 参数校验 / 读模型查询）与 `cmd/tc-api`（起停、优雅收尾、起服前先探库）；五个端点：`GET /healthz`、`GET /api/v1/products`（浏览卡片）、`GET /api/v1/products/{id}/variants`（差异事实）、`GET /api/v1/variants/{id}/composition`（套餐由谁组成）、`GET /api/v1/variants/{id}/calendar`（日历与有效期终点）；Go 侧复用 `internal/variant` 的变体与成分读法，不另写一份查询 | 读模型与差异事实建好了，但**没有请求链路** —— 异构差异只有查库的人看得见，C 端的「两日票与单日票长得不一样」「2 成人 + 1 儿童各管几天」「哪天进不去」这些差异落不到客户端身上。现在它们有了一条只读读模型的 HTTP 通路。取舍写在这里：**写侧暂不开** —— 系统里还没有调用方身份，把下单开成匿名接口等于把订单入口暴露给任何人；读侧不需要身份，先落地 |
| 2026-11-10 | **供给形态不许因为源 SKU 下架而缩小**：新增 `db/migrations/022_supply_form_shrink_guard.sql`：`fn_combo_components` / `fn_bundle_components` 改为左连接源 SKU（源下架时成分行仍在，只是没有价）；`v_variant_supply_forms` 的单张 / 配方 / 套装三个分支都保留形态行并把缺口点名（源 SKU 已下架 / 成分的源 SKU 已下架 / 套装的源 SKU 已下架），成分残缺时成本留空；不变量从 104 条扩到 107 条（105 配方的成分不许因为源 SKU 下架而消失、106 成分的源 SKU 下架时配方套餐不许还能卖、107 套装的源 SKU 下架时套装不许还能卖），新增 `v_invariant_checks_supply_form_shrink_022`；接入层新增回归测试 `TestSupplyFormSurvivesASourceGoingOffShelf` | 源侧把 SKU 下架是事实，改不了源侧。但原来的口径是「解析成分时把下架的源整个丢掉」——配方于是静悄悄地变成了一个更小的套餐（少一个成分就按剩下的成分重新定价：收 3 份入场的钱、出 1 份票，而 C 端构成读模型还写着 3 份入场），套装的形态行则整个从对照视图里消失（「没人供」和「没人看得见它有人供」长得一模一样）。取舍写在这里：**源下架不等于声明消失** —— 成分行留着、只是没有价，形态行留着、只是不可售并说清缺口。宁可少卖，不可卖错 |
| 2026-10-28 | 初版：领域模型 + 物理模型 + 验收查询 | — |
| 2026-10-28 | 成本价从 `price_calendar` 拆出到 `supplier_price_calendar` | 多源比价从「不可比」变为「可比」 |
| 2026-10-28 | 修正 FX 换算方向（`1 CNY = rate 外币` → 折算用除法） | 影响所有跨币种成本 |
| 2026-10-28 | **补齐 C 端领域模型**：读模型、展示内容、购物车、优惠券、实名规格、库存预占、核销端（+18 表 / +4 视图） | C 端从"没有模型"变为"有可执行 schema" |
| 2026-10-28 | 展示文案从 `product.attributes` jsonb 下沉到带 `locale` 的行级表 | 多语言成为可能；前端不再猜字段名 |
| 2026-10-28 | 不变量从 20 条扩到 26 条 | 新增 6 条 C 端侧门禁 |
| 2026-11-04 | **新增变体轴与可售单元**（`product_axis` / `product_variant` / `supplier_variant` / `supplier_variant_mapping` 等 7 表 + 10 列） | 打破「商品 × 票种」两层天花板，支持人群 × 票种 × 园区范围 × 加购件的多维组合商品 |
| 2026-11-04 | 引入**覆盖语义映射**（`coverage`）：一个源变体可覆盖多个规范变体 | Zowoyoo / 自由行（参数化）与 Trip.com（固定组合 PLU）两个源能落到同一套规范变体上；覆盖不全的源被排除在路由之外 |
| 2026-11-04 | 路由粒度下沉到变体（`v_variant_routing_candidates`）；售价/成本价/订单明细/购物车/预占/实名全部下沉到变体 | 同一商品不同变体的首选源不同，这是商品级路由给不出的答案 |
| 2026-11-04 | 不变量从 26 条扩到 34 条 | 新增 8 条变体侧门禁，其中 34「有售价的变体必须可履约」当场抓出种子数据一处真实缺口 |
| 2026-11-04 | **核实携程分销侧接口**（`open.trip.com` 全球分销 OpenAPI V2.0.25，21 个接口），纠正上一版鉴权方向错误：供给源接入走 `aid/sid/key` → refresh_token，而非供应商侧的 AES/MD5 | 供给侧接入契约改用分销侧认证；错误码 → 四分类映射可落表 |
| 2026-11-04 | 不变量 35：同一订单内同一商品的多个变体必须同日（对应携程 `B0042`） | 变体级订单多行明细有了日期一致性门禁 |
| 2026-11-04 | 记录 **§4.5 待决策**：按团报价（`priceSettingType=4/5`）与价格保护（`isPrivatePrice`）我们缺约束 | 日游品类接入前必须先定口径，否则会算错钱 |
| 2026-11-04 | **§4.5 落地**：明细加 `pricing_basis`（按人/按团分支校验 + 明细级 CHECK 约束同步放宽）；售价日历加 `price_locked`、源变体加 `is_price_locked`；新增日游按团报价商品与订单 | 日游可安全接入；金额不再按人头正比计算；价格保护双向把守 |
| 2026-11-04 | 不变量从 35 条扩到 38 条（新增 36 小计自洽、37 锁价售价=源挂牌价、38 该锁没锁） | 定价侧三条门禁 |
| 2026-11-05 | **接入层用 Go 实现**（`cmd/tc-connect` + `internal/`）：传输层 / 凭证 / 四分类 / 退避重试 / 归档脱敏 / 幂等 / 各源适配器 / 注册表；分层连通性测试 + 协议级 mock 自检（14 项断言全通过）+ 7 个包单元测试 | 拿到商务授权后可直接跑测试，不需要再改结构；无凭证时明确报出缺哪个环境变量 |
| 2026-11-05 | 核实并修正 **真实 `priceCalendar` 的报价是嵌套的**（`resource.calendarDetailList[]`），样例报文同步改成嵌套形态 | 源成本价表的行数口径明确为「源变体 × 规范变体 × 日期」；拿到真报文不再解析不出价格 |
| 2026-11-05 | **门禁落地**：38 条不变量从「跑一下看报告」变成非零退出即失败（`make dbcheck`）；新增序列对齐检查（59 张表的 identity 序列必须能发出不冲突的 id）；单元测试改用一次性库，不再依赖开发机上的 `ticket_center`；CI（GitHub Actions）跑 `make check` | 种子数据用了显式 id，19 张表的序列停在 `max(id)` 之前，应用第一次 INSERT 就撞主键 —— 这个缺口 38 条不变量一条都发现不了，现在有专门的门禁和回归测试 |
| 2026-11-06 | **定价收敛为单一实现**：`fn_price_variant`（唯一实现）+ `fn_reprice_rows()`（重算入口）；种子数据不再手写金额，只写骨架（卖哪一行）；演练器不再用 Python 算钱；接入层新增 `tc-connect price`；新增 §4.6 定价口径（采纳源 / 成本 / 售价 / 生效 min_margin 取严 / 划线价 / 锁价与按团豁免）；不变量从 38 条扩到 42 条（39 币种必须可折算、40 成本=源成本×留痕汇率、41 售价行=定价函数输出、42 毛利率达标） | 此前定价有四份实现（两个视图、一个 Python 块、种子里的手写数字），各自自洽但结论不同，锁价行的售价甚至算成了加价后的 552.27 而非源方挂牌价 498.00。现在金额只有一条来路，且有门禁证明库里每一行都等于它 |
| 2026-11-06 | **选源与定价同源**：新增 `fn_route_candidates`（选源的唯一实现），路由视图 `v_variant_routing_candidates` 与定价函数 `fn_price_variant` 共用同一候选集与排序键（折算到基准币种的成本 → priority → fallback_order → 源商品 id）；不变量从 42 条扩到 45 条（43 定价采用的源=路由选中的源、44 售价行币种=该行结算币种、45 汇率留痕可复算）；汇率留痕口径改为「同币种不折算就不留快照」、留痕日期取两腿较晚的那一天以便独立复算；锁价不变量 37 改为先折算再比；重算改为 LEFT JOIN，定价算不出的行把价格清空而不是留着旧价继续卖 | 此前路由与定价各排一次序，两把尺子不完全一样，数据一变就分叉 —— 分叉的后果是「按 A 源的价格卖、按 B 源出票」，客诉说不清、对账对不上、佣金算不出。现在排序键只有一份，分叉在结构上不可能发生 |
| 2026-11-06 | **物理模型只增不改落成机制**：`db/schema.sql` 变成 `db/migrations/001_baseline.sql`（冻结的建库基线），后续结构变更一律新增 `NNN_*.sql`；新增迁移引擎 `internal/migrate` 与 `tc-connect migrate`（账本 `ops.schema_migration` 记每个文件的 sha256、每迁移一个事务、会话级互斥锁挡并发、基线接管存量库） | 「DDL 只增不改」原来只是一句约定：改基线脚本不会立刻出事，新库与存量库却从此分叉，且没人发现。现在改动已发布的迁移会被引擎当场拒绝，改结构只能新增迁移文件 |
| 2026-11-06 | **C 端读模型刷新口径收敛为一个实现**：新增 `db/migrations/002_read_model_refresh.sql`（`fn_refresh_read_models()`），种子数据、接入层 CLI、将来的定时作业都调它；新增 `internal/readmodel` 与 `tc-connect refresh [--check]`；刷新口径与 `v_c_readmodel_drift` 对齐 | 此前刷新逻辑写在种子脚本里的一段 SQL，换个调用方就得抄一遍，两份口径必然分叉 —— 分叉的后果是刷新完还被判成漂移。现在口径只在库里一份，Go 侧只负责调用与报告，漏跑时 `refresh --check` 非零退出 |
| 2026-11-06 | **交易侧状态机落成机制**：新增 `db/migrations/003_transaction_state_machine.sql`（`state_transition` 表 = 合法流转的唯一来源；触发器 `fn_guard_state_transition` 挡住非法流转、`fn_emit_state_event` 保证状态一变就落领域事件到 `event_outbox`）；不变量从 45 条扩到 53 条（46-49 状态可达、50 已确认订单必有预订、51 已出票凭证必挂预订、52 订单与履约状态一致、53 小计=明细合计），拆成 `v_invariant_checks_core` + `v_invariant_checks_tx` 两半；新增 `internal/transaction` 读流转与事件 | 状态机以前只活在 SPEC 的图里：谁 UPDATE 一下订单状态都行，订单从 paid 直接跳 fulfilled 在库里是合法的，客诉时才发现中间该出的票没出；事件也靠调用方记得写，状态改了事件丢了没人知道。现在非法流转当场报错，事件由触发器产生，Go / psql / 脚本都一样留痕 |
| 2026-11-07 | **下单写路径落地**：新增 `db/migrations/004_place_order.sql`（`fn_place_order` = 下单的唯一实现：幂等键必填、抢键用 `ON CONFLICT DO NOTHING`、金额与采纳源只取 `fn_price_variant`、一单一个币种、明细走快照、实名按 `checkout_requirement` 收齐、下单即留领域事件）；不变量从 53 条扩到 54 条（54 明细单价必须等于定价函数输出），新增 `v_invariant_checks_order`；接入层新增 `internal/order` 与 `tc-connect order place/show` | 到这一步为止系统只有「读」：订单怎么落库没人写，SPEC §3.3 的交易流只有一张图。现在下单有唯一实现，金额没有第二份计算，幂等由抢键保证而不靠调用方自觉；预订仍留在支付后创建 —— 源侧故障不阻塞订单聚合 |
| 2026-11-07 | **履约写路径落地**：新增 `db/migrations/005_fulfillment.sql`（`fn_record_payment` / `fn_create_bookings` / `fn_request_booking` / `fn_record_booking_attempt` / `fn_complete_booking` / `fn_issue_voucher` / `fn_retry_booking` / `fn_apply_order_fulfillment` = 支付 → 预订 → 出券的唯一实现：支付金额必须等于订单应付、幂等按渠道流水、预订的源场次取自 `product_session_source` 绑定、票码与持票人一一对应、订单履约状态只由 `fn_apply_order_fulfillment` 从明细出票情况推导）；不变量从 54 条扩到 60 条（55-60 履约侧），新增 `v_invariant_checks_fulfill`；新增 `db/migrations/006_duplicate_payment_guard.sql`（重复收款守卫：另一笔流水打进已付订单当场报错，不静默吞掉）；接入层新增 `internal/fulfillment` 与 `tc-connect fulfill pay\|book\|request\|attempt\|complete\|issue\|retry\|show` | 履约侧此前只有表和状态机，没有写路径：支付怎么入账、预订怎么建、票码怎么挂到人身上，全靠调用方自己 UPDATE，重复收款会静默吞掉第二笔钱，出票张数与持票人不对应也无人发现。现在每一步都有唯一实现，事实与状态不许分叉 |
| 2026-11-07 | **退款写路径落地**：新增 `db/migrations/007_refund.sql`（`fn_request_refund` / `fn_approve_refund` / `fn_complete_refund` = 退款环节的唯一实现：退款作用域是整单、退款金额必须等于订单实付、幂等键必填且同键异内容报错、「有没有收到钱」看 `sales_payment` 里成功的支付记录而不是订单状态、发起时订单推进到 `refunding` 并记 `previous_order_status`、失败时照原状态退回去、补齐 `refunding → paid/confirmed/partially_fulfilled/fulfilled/booking_pending` 的回退边）；不变量从 60 条扩到 64 条（61-64 退款侧），新增 `v_invariant_checks_refund`；接入层新增 `internal/refund` 与 `tc-connect refund request|approve|complete|show` | 退款此前只有表和状态机，钱退回来这一段没人写：退多少没有口径、重放一次就多退一次钱、退了钱订单和支付记录还挂在「已支付」上，对账时两笔对不上。现在整单退款的资格、金额、幂等、事实同步都由库里一个实现说了算；行级退款需要「优惠券/税费/折扣怎么摊到每一行」的分摊口径与源侧支持部分取消，是业务决策不是工程决策，系统对行级退款明确报错而不自己编规则 |
| 2026-11-07 | **核销写路径落地**：新增 `db/migrations/008_redemption.sql`（`fn_redeem_voucher` = 核销环节的唯一实现：核销记录永远追加、重复扫码记 `duplicate` 不覆盖事实、一张券最多成功核销一次由唯一索引 `ux_redemption_single_success` 兜底、额度一次用尽、按团报价整团一券消耗整团人数、过期/作废/未出票/订单在退款的券不认但留记录写清 reason、票码撞车按闸机所属源收窄收窄不出来就报错、过期只落记录不改券状态、`voucher.used_channel` 记订单销售渠道）；不变量从 64 条扩到 68 条（65-68 核销侧），新增 `v_invariant_checks_redemption`；接入层新增 `internal/redemption` 与 `tc-connect redeem scan\|show` | 核销此前只有状态和表，没有写路径 —— 票发出去就没人能用了，退款里「有已核销的票不许整单退」那条分支也永远走不到（没有东西能把票变成 used）。现在扫票这条路上只有一个实现：能不能进场、用多少额度、券状态怎么改全在库里；重复扫码留下事实而不是压掉，重复入场由唯一索引挡住 |
| 2026-11-07 | **库存预占写路径落地**：新增 `db/migrations/009_inventory_hold.sql`（`fn_available_qty` / `fn_reserve_qty` / `fn_hold_inventory` / `fn_release_hold` / `fn_expire_holds` = 可售数的唯一实现：源侧快照与我们的承诺对账 `unreflected = GREATEST(our_sold − source_sold, 0)`、取不到库存数据返回「不知道」而不是 0、按源场次升序加行锁防并发超卖、明知不够当场报错、预占用 `hold_no` 幂等键同键异内容报错、订单关掉由触发器把预占置 `voided`）；`fn_place_order` 整体替换一次，落明细时消费购物车预占或新建 `consumed` 预占，并把当时的可售数写进明细快照；不变量从 68 条扩到 72 条（69-72 库存预占侧），新增 `v_invariant_checks_inventory`；接入层新增 `internal/inventory` 与 `tc-connect stock show` / `tc-connect hold create\|release\|expire\|show` | 此前系统不知道「还剩多少」：源侧快照显示 20 张、我们卖出 18 张，系统仍按 20 张继续卖，超卖没有任何机制拦。直接拿源侧 `sold` 减我们的 `consumed` 会双扣 —— 每同步一次就少卖一半，所以口径改成「源侧未反映的销量 + 我们占着的量」才减。并发靠行锁而不是先查后改，最后一张票只能被一个订单卖掉 |
| 2026-11-07 | **有效期口径落地（异构差异）**：新增 `db/migrations/010_validity_window.sql`（`product_axis_option.valid_days` 列 + `fn_variant_validity_days` 唯一读法 + `fn_issue_voucher` 整体替换一次 + `v_variant_validity` / `v_variant_comparison` 两个视图）；不变量从 72 条扩到 75 条（73 口径不歧义、74 券不短于承诺、75 卖出去的源覆盖得住），新增 `v_invariant_checks_validity` | 有效期是异构产品之间最容易被抹平的一条差异：源侧有两日票，我们的规范场次是「(商品, 日期, 时段)」一行，两日票和单日票共用场次，而出券写死「场次当天 + 1 天」—— 卖了两日票发出来的券只管一天，客户第二天到门口闸机判 expired（钱收了、票买了、门不认）。现在有效期长度是轴上的数据（`1d → 1`、`2d → 2`），口径只有一处，券不得短于承诺由不变量 74 守着 |
| 2026-11-07 | **差异走到 C 端（读模型带上差异事实）**：新增 `db/migrations/011_c_end_variant_facts.sql`（`c_variant_facts` 变体级差异事实读模型 + `c_variant_calendar.valid_to` 有效期终点 + `v_c_variant_feed` C 端变体读视图 + `fn_refresh_read_models` 整体替换一次（返回值多一个计数，行类型变了只能 DROP + CREATE））；不变量从 75 条扩到 77 条（76 读模型不与主数据分叉、77 日历有效期终点不被算错），新增 `v_invariant_checks_readmodel`；接入层新增 `internal/variant` 与 `tc-connect variant compare\|coverage\|feed` | 到 010 为止，差异在主数据里说清楚了但 C 端看不到：读模型只带价格与可售天数，前端要显示「几日的票、覆盖哪些园区、能不能退」就得在请求链路里 join 主数据（违反读模型纪律），而两日票和单日票在日历上长得一模一样 —— 用户按「当天有效」理解两日票，第二天到门口才发现进不去。现在差异事实进读模型（口径只从 `v_variant_comparison` 取，不重算），日历格子带上有效期终点（前端不自己加一天），刷新作业漏跑由不变量 76 当场报出来 |
| 2026-11-07 | **异构融合方向 B（组合套餐）落地**：新增 `db/migrations/012_composite_mapping.sql`（`supplier_variant_composition` 源侧配方表 + `product_variant_relation.quantity` 规范侧组件数量 + `fn_variant_requirements` 把「变体要求集合」抽成一个函数供判定 / 缺口 / 精确匹配三处共用 + `fn_variant_covered` / `fn_variant_coverage_gaps` 整体替换一次（组合的要求取组件要求的并集）+ `fn_variant_coverage_is_exact` 精确匹配判定 + 守卫触发器 `fn_guard_included_relation`（`included` 只许挂在 combo 上）、`fn_guard_composition_parent`（配方只许挂在 combo 上）、`fn_guard_combo_mapping`（组合不许直接挂源映射）+ `v_variant_composition` 两侧并排对照 + 不变量 29 口径修订（组合豁免，但组合必须声明组件））；不变量从 77 条扩到 81 条（78 成分同源、79 成分顶得住声明的组件、80 两侧逐项对得上、81 组合不走直接映射）；接入层新增 `internal/compose` 与 `tc-connect compose plan\|apply`；演练器去掉最后两份 Python 覆盖判定镜像（`covers` / `coverage_gaps`），映射、报价、上架、定价全部由库判定 | 到 011 为止只处理了融合的一个方向（一个源 SKU 覆盖多个可售单元），GlobalTix 官方示例的「家庭套餐」（2 大 1 小 + 快速通行证，源侧一条组合表达式一次预订下完）在我们模型里没有对应物 —— 演练报告只能写「当前模型表达不了的源侧结构」，系统没法卖。现在组合套餐两侧都有声明（规范侧组件与数量、源侧配方），配对关系记下来不靠猜，覆盖判定仍然只有库里的那一份；组合暂不参与选源与定价（守卫挡住），免得定价函数用一个源 SKU 的成本给整张套餐定价 —— 收三个人的钱出一张票 |
| 2026-11-07 | **组合套餐可售（异构融合方向 B 走到成交）**：新增 `db/migrations/013_combo_sellable.sql`（`fn_combo_components` 从源侧配方取成分及其成本，`fn_price_variant` 组合分支：成本 = Σ 成分单价 × 数量、成分必须同源且都在同一场次，成分缺价 / 场次不同 / 源不同 / 价格锁定 / 按团报价一律判不可售并由 `v_combo_price_gap` 列出原因；`sales_order_item_source` 新表 = 履约单位（一份订单明细 = 一份套餐，每个成分一行），`booking.order_item_source_id` 与 `order_holder.component_variant_id` 补上成分归属；`fn_place_order` 组合分支（成分源 SKU 取自配方不重新选源、实名按 `item_index` 归属到具体成分、同一源场次多个成分的总需求一起判超卖）；`fn_create_bookings` 一个成分一次预订；`fn_issue_voucher` 按成分张数出券；`fn_available_qty` 修正池子归属（场次级共享池不许每个票种各花一遍）；`fn_bound_supplier_session` 抽出「规范场次 → 源场次」绑定的唯一读法；`v_order_item_source` / `v_combo_price_gap` 两个视图）；不变量从 81 条扩到 86 条（82 成分属于本明细的商品、83 明细成本 = Σ 成分单价 × 数量、84 出票张数 = 配方数量 × 套餐份数、85 成分同源且与明细一致、86 成分的票额够用），新增 `v_invariant_checks_combo`；不变量 69 口径修订（预占状态不参与判定，退款后的 voided 预占仍算「这一单占过多少库存」） | 组合套餐此前只到「两侧有声明、还卖不了」：定价函数只会给一个源 SKU 的成本，订一个成分的货 —— 收三个人的钱出一张票。现在组合能一路走到成交：成本按配方算、成分各订各的、各出各的票、持票人靠 `item_index` 明确归属到成人还是儿童，超卖按场次总需求判（两个成分抢同一个池子不许各花一遍），退款时成分的事实一起改。仍然差一步：C 端读模型还画不出组合（没有 `price_calendar` 行、组合的有效期终点与人群标签口径未定），这一条写进了 §5.13 的已知缺口 |
| 2026-11-08 | **预订的单位 = 源 SKU（不是成分）**：新增 `db/migrations/014_booking_unit_source_sku.sql`（`fn_booking_components()` 抽出一条预订覆盖哪些成分的唯一读法；`fn_create_bookings` 按（明细, 源 SKU, 源场次）分组建预订，幂等键改成「订单号 + 明细 + 源 SKU」，成分的拆分留在 `request_payload.components`；`fn_issue_voucher` 逐成分出券（各发各的张数、各按各的持票人与有效期，票码数仍必须等于还要发的张数）；`booking.order_item_source_id` 拆掉（一条预订可以覆盖好几个成分，这一列装不下）；新增唯一索引 `ux_booking_one_per_source_sku` 兜底（同一张明细里同一个源 SKU 只许一条预订）；`v_order_item_source` 改成按源 SKU 对账；不变量从 86 条扩到 88 条（87 同一源 SKU 只订一次、88 预订与成分双向对齐），不变量 58 与 75 按新口径重写） | 013 的口径是「一个成分一次预订」，而参数化源（自由行那种「一张通票、人群是购买时选的一档」）里**成人票与儿童票是同一个源 SKU** —— 于是同一个源 SKU 在同一个源场次上被订了两次：源侧看到两张订单单，我们这边一条客户订单对两个源单号，对账对不上；退款要退两次，其中一次退不掉就是「钱退回来了但票还在」；源侧只确认了其中一个成分时，整张套餐是半成品 —— 收了三个人的钱出了两张票。源卖的是 SKU，我们就按 SKU 订。代价说清楚：一张套餐有几条预订 = 有几个源 SKU；整张套餐的原子性取决于源侧的能力，我们只保证「所有成分都出票了才算履约完成」 |
| 2026-11-08 | **组合走到 C 端（异构融合方向 B 的最后一里）**：新增 `db/migrations/015_combo_c_end.sql`（`fn_variant_composition()` 组合成分的唯一读法（成分 / 份数 / 人群编码 / 各自的天数）；`fn_variant_validity_days` 整体替换一次（组合分支 = 成分窗口的**并集**，即最长的那个）；`v_variant_comparison` 末尾加四列（`is_combo` / `combo_audience` / `component_count` / `composition`）；新表 `c_variant_composition`（C 端的组合成分）+ `c_variant_facts` 加三列（`is_combo` / `combo_audience` / `component_count`）；`fn_refresh_read_models` 整体替换一次（写组合事实、清理过期事实）；`v_c_variant_feed` 整体替换一次（带出组合构成）+ 新视图 `v_c_variant_composition`；`fn_sync_combo_calendar()` 按成分的售价行推出组合的售价行与日历格子（金额走定价函数的组合分支）；不变量 16 / 34 按组合口径重写（组合的成本来自配方、没有直接源映射）；不变量从 88 条扩到 92 条（89 组合的有效期恰好等于成分窗口的并集、90 C 端构成不许与主数据分叉、91 组合的日历格子必须带价格、92 组合的成分折算留痕必须自洽）；接入层新增 `internal/readmodel.SyncCombos`、`internal/variant.CompositionRows`、`tc-connect variant composition`，`tc-connect refresh` 先同步组合再刷新 | §5.13 的已知缺口：组合在自己的配方里画得出来，但 C 端画不出 —— 源侧没有它的商品条目，目录同步作业看不见它，它没有 `price_calendar` 行，所以它上不了日历。这条路径补上之后，两件悬着的事定了：**有效期终点 = 成分窗口的并集**（2 份两日成人 + 1 份一日儿童 = 2 天，不是最短的 1 天、也不是相加的 3 天）；**人群不选标签**，带的是每个成分的人群编码 + 份数 + 各自的天数，「2 成人 + 1 儿童」这句话由前端按 locale 拼（硬约束 9：展示文案不进模型）。构成进读模型（C 端不许 join 主数据去算份数），与主数据分叉由不变量 90 当场抓住。同一批里补上了**跨币种套餐**（源侧日元、我们卖人民币）：组合的顶层 `fx_rate` / `fx_as_of` 是空的（这里没有单一的值），逐成分的折算留痕在 `rule->'combo'` 里 —— 这条路径以前没人复查（不变量 45 按 `cost_source_product_id` join 源价行，直接跳过组合），不变量 92 专门查它 |
| 2026-11-08 | **收紧口径：退款放行与票码可猜两处门禁**（新增 `db/migrations/016_security_hardening.sql`）：`sales_refund` 加 `approved_by` 列并记放行人；`fn_complete_refund` 整体替换一次（只接受 `approved` 的退款单，其余状态当场报错）；`fn_issue_voucher` 整体替换一次（源侧没给票码时生成 128 位随机码，不再拿连号的券号当票码）；不变量从 92 条扩到 94 条（93 走到终态的退款单必须经过放行、94 票码不许是券号派生的），新增 `v_invariant_checks_hardening`；`scripts/poc_page.py` 在把数据嵌进 HTML 前先转义（`</` → `<\/`，控制字符转成实体） | 退款是三步（发起 → 放行 → 落结果），以前 `fn_complete_refund` 只拦终态，一笔还在 `requested` 的退款能被直接结掉 —— 放行这一步形同虚设，审批形同不存在，钱却真的退了。票码那边，源侧没给票码时我们拿券号（`VC` + 日期 + 连号）顶上 —— 券号是连号的，猜得到；票码是闸机认的东西，猜得到就等于没有闸机。现在放行是必经之路（放行人留痕），票码不可猜（券号留作内部标识，对外展示与对账都用券号）。C 端 POC 页把数据直接嵌进 HTML，源报文里的 `</script>` 能提前关掉脚本块 —— 现在嵌入前统一转义 |
| 2026-11-09 | **套装：源侧把整套当一个 SKU 卖（异构融合的第三种形态）**：新增 `db/migrations/017_supplier_bundle.sql`（新表 `supplier_variant_bundle`（规范变体 ← 整套源 SKU + 源侧整套有效期）与 `supplier_variant_bundle_part`（成分 + 份数）；触发器 `fn_guard_bundle_exclusive` / `fn_guard_bundle_parent` / `fn_guard_bundle_part` 挡住「既是配方又是套装」与「成分与规范声明对不上」；`fn_bundle_components()` 套装成分的唯一读法；`fn_price_variant` 加套装分支（成本来自源侧那个整套报价，不重新选源，分摊到成分只为了对账）；`fn_place_order` 加套装分支（一条明细 → 一条按套的预占 + 逐成分的成分行）；`fn_create_bookings` 加套装分支（预订的单位是套，份数与入场份数分别记）；`fn_available_qty` / `fn_reserve_qty` 加带 `source_ticket_type_id` 的重载（套装的库存池按源侧整套票种算）；`fn_sync_combo_calendar` 加套装分支；新视图 `v_bundle_gap`（套装卖不掉的原因，按天列）、`v_variant_bundle` / `v_variant_bundle_part`（读侧）；不变量从 94 条扩到 99 条（95 形态唯一、96 成分与规范声明对得上、97 有效期盖住成分窗口、98 成本分摊守恒、99 入场份数守恒），不变量 34 / 43 / 69 / 72 / 75 / 84 按套装口径重写；新增 `db/migrations/018_booking_request_payload_merge.sql`（`fn_request_booking` 的请求报文改成合并而不是覆盖）与 `db/migrations/019_bundle_gap_days.sql`（缺口天数只数真卖不掉的那几天）；接入层新增 `internal/variant.BundleRows` / `BundlePartRows` 与 `tc-connect variant bundle`；`db/verify.sql` 加 K1-K5 验收段 | §5.13 里明说「代价说清楚：源侧把整套套餐当一个 SKU 卖的情况接不了 —— 从 `coverage` 看不出一个源 SKU 是「一整套」还是「一张谁都能用的票」，看不出来就不能猜」。现在它能接了，而且靠的是**单独声明**而不是猜：套装的成本是源侧那个整套报价（不是成分单价相加，也不是重新路由）；预订的单位是**套**（1 套 = 3 份入场，2 成人 + 1 儿童）；库存扣的是源侧整套票种的池子；有效期由源侧声明且必须盖住成分窗口。顺带修掉一个会吃掉事实的坑：`fn_request_booking` 原来用覆盖写请求报文，而参数默认值是 `'{}'` 不是 NULL，所以「不传报文」也会把整列洗掉 —— 套数与入场份数就此消失，对账时只能靠猜。现在改成合并 |
| 2026-11-09 | **套装库存池的口径收紧（补上 017 的两个超卖口子）**：新增 `db/migrations/020_bundle_inventory_scope.sql`：`fn_available_qty` 的三参重载改成「指定源票种时，余量只能来自这个源票种自己的快照」，源侧没报这个票种的库存就说**不知道**（`known = false`、可用数为空），不再拿同一场次里别的票种的余量顶上；`fn_place_order` 的套装预占改成**按池子汇总**同一订单里所有套装的套数（原来逐明细各算各的，`DISTINCT` 把重复的池子折叠掉，两条明细各要 1 套、池子只剩 1 套时两笔都放行 → 超卖）；新视图 `v_bundle_pool_demand`（订单 × 池子：需求套数 / 落单时还剩多少 / 当时知不知道）；不变量从 99 条扩到 101 条（100 池子不跨源票种、101 需求按池子加总不许超卖）；接入层新增 `internal/inventory.AvailableBySourceTicketType` 与 `tc-connect stock show --source-ticket-type`；`db/verify.sql` 加 K6 验收段 | 017 把套装走到了成交，但库存池上有两个洞：查套装余量时会掉到别的票种的数上（用儿童票的库存卖整套票），以及落单时逐明细各算各的（两条明细各要 1 套，池子只剩 1 套，两笔都过 → 超卖）。两个洞都是**跨票种/跨明细加总的错**，修在 020 里。有一个取舍写在这里：**源侧没报这个票种的库存时不拦单**（记「不知道」，落单时把当时的可售数写进明细快照），因为把「不知道」当成 0 会让整个商品下架，比超卖更贵 |
| 2026-11-09 | **三种供给形态的对照视图（异构融合读侧的最后一里）**：新增 `db/migrations/021_variant_supply_forms.sql`：新视图 `v_variant_declared_forms`（声明过的形态逐天在场次上有没有声明）与 `v_variant_supply_forms`（一行一个「可售单元 × 一天 × 一个渠道 × 一种形态」，把单张 / 配方 / 套装的源、成本、缺口、入场份数并排）；不变量从 101 条扩到 104 条（102 声明过的形态不许在对照视图里消失、103 对照视图的成本必须等于定价函数算的成本、104 入场份数必须等于 C 端构成读模型的份数），新增 `v_invariant_checks_supply_forms_021`；接入层新增 `internal/variant.SupplyFormRows` 与 `tc-connect variant supply`；`db/verify.sql` 加 K7-K8 验收段 | 017/020 把套装走到了成交，但读侧还差一环：`v_variant_routing_candidates` 与 `v_variant_source_coverage` 走 `fn_route_candidates`，而它只建模方向 A —— **配方与套装的可售单元在那些视图里一行都没有**。不是它们不卖，是读侧看不见它们在卖。看不见的后果不是少一行，是看不懂：同一个商品下两个几乎一样的家庭套餐（配方 ¥1656.48 / 套装 ¥1740.00）交付的却是同样的 2×成人 1 日 + 1×儿童 1 日，哪个在卖、卖不卖得掉、差在哪，运营侧一个都答不上来。取舍写在这里：**形态整体的缺口只在这个形态真的卖不掉时才报**，逐源的缺口放在候选明细里 —— 混在一起就是「✓ 能供，却说当天没报价」，自相矛盾的话比没有话更坏 |
