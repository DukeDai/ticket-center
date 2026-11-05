# SPEC — 多源票券中心（Ticket Center）

> 本文件是**合同**。任何改动业务行为的代码，必须同步改动本文件的对应章节。
> 实现现状见 `docs/ddd.md`（领域模型）与 `docs/schema-design.md`（物理模型）。

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

- 具体 API / Web 实现（下一阶段）
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

## 4. 业务不变量（Invariants）

以下 38 条已固化为 `v_invariant_checks` 视图，`db/verify.sql` 会逐条断言，任一条违反即数据违规。

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
| 12 | 已履约订单必须有 issued/used 状态凭证 |
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

## 4.3 C 端展示与购买（2026-10-28 补充）

第一版设计只覆盖了供给侧（怎么把源接进来），C 端「展示」与「购买」的领域模型是空缺的。
本次补齐，详见 `docs/c-end-model.md`。

### 展示侧

| 能力 | 落地 |
|---|---|
| 列表页卡片 | `c_product_card`（读模型，按 channel × product × locale 物化，带 `synced_at` 标注新鲜度） |
| 日历格子 | `c_product_calendar`（售罄/闭馆日**也要有格子**，前端才能画灰、禁用点击） |
| 详情页内容 | `product_highlight` / `product_inclusion` / `product_note` / `product_location` / `product_review` / `tag` |
| 多语言 | 内容表一律带 `locale` 列；`product.attributes` 只保留**语言无关的结构化事实** |

### 购买侧

| 能力 | 落地 |
|---|---|
| 购物车 | `cart` / `cart_item`（含加购时的 `price_snapshot`） |
| 库存预占 | `inventory_hold`（TTL + 状态机 + 过期自动释放） |
| 优惠券 | `coupon` / `coupon_redemption`，订单侧记 `coupon_id` + `discount_breakdown` |
| 实名表单 | `checkout_requirement`（按商品/票种/渠道定义字段与校验）+ `order_holder`（采集的输入） |
| 核销端 | `gate` / `gate_operator`，`voucher_redemption` 关联 |

### 读模型纪律

1. **读模型可随时重建**，主数据永远是唯一真相。
2. `v_c_readmodel_drift` 检测卡片起价与价格日历是否已不一致，`drifted=true` 即刷新作业漏跑。
3. 列表页的价格与库存必须来自**同一次刷新**，不允许卡片上拼两个新鲜度不同的数据源。

---

## 4.4 变体与可售单元（2026-11-04 补充）

### 为什么必须加这一层

环球影城这类商品的维度不是「商品 × 人群」两层，而是：

```
人群(成人/儿童/老年) × 票种(一日/双日) × 园区范围(单园区/园区通票) × 加购件(快速通行证)
```

旧模型把「人群」硬编码进 `ticket_type`、把「日期」硬编码进 `product_session`，
维度一多就无处安放。更麻烦的是**两个源对同一商品的分解方式根本不同**：

| 源 | 分解方式 | 后果 |
|---|---|---|
| Trip.com | 固定组合 SKU（一个 SKU = 一个完整组合） | 一个源变体对一个规范变体 |
| Zowoyoo（自由行） | 参数化售卖方案（人群/园区是下单参数），且是聚合层 | 一个源变体覆盖多个规范变体 |

`product_mapping` 回答不了「这个源到底能供哪些组合」，
商品级路由 `v_source_routing_candidates` 也回答不了「这一单该走哪个源」。
**实测：商品级路由视图对北京环球影城输出 0 行**（见 `db/verify.sql` H4）。

### 模型要点

| 概念 | 落地 | 说明 |
|---|---|---|
| 可售单元 | `product_variant` | **product 的下一级不是 `ticket_type`，而是变体** |
| 维度 | `product_axis` / `product_axis_option` | 人群沿用 `ticket_type`（历史订单语义不变），其余维度全部配置化 |
| 变体取值 | `product_variant_option` | 一个轴一个取值；多选语义由取值自身的集合承载（`option_attrs.park_ids`） |
| 可叠加件 | `product_variant_relation` | 基础票 ← 快速通行证 / 园区升级（`variant_role='addon'`） |
| 源侧变体 | `supplier_variant` | 固定组合型源的 SKU、参数化源的售卖方案 |
| 覆盖映射 | `supplier_variant_mapping.coverage` | **不是一对一，而是「覆盖」**：声明该源变体能满足哪些轴取值 |

**核心规则：`coverage` 决定「这个源能不能履约这个组合」。**
变体要求的每一项能力（人群 + 各轴取值）都必须落在 `coverage.axes[axis]` 内、
且不在 `coverage.excludes` 内，否则该源不得参与该变体的自动路由。

### 旧结构是本模型的特例

「两层 SKU」= 只有人群一个轴的变体模型。迁移规则：

1. 每个 `(product, ticket_type)` 生成一个 `base` 变体；
2. 每个 `supplier_ticket_type` 生成一个源变体，与规范票种做 1:1 精确覆盖映射；
3. 售价/成本价回填变体 id。

**不推翻任何已有表结构**，所有新增列都是 `ALTER TABLE ... ADD COLUMN`。

### 变体侧不变量（27-34）

| # | 不变量 |
|---|---|
| 27 | 变体的轴取值必须属于该商品的轴定义 |
| 28 | 同一商品内变体指纹 `variant_key` 不得重复 |
| 29 | 在售变体必须有人群或轴取值定义，不允许空变体占位 |
| 30 | 覆盖映射必须真的覆盖目标变体的全部能力（覆盖不全不得挂 `active`） |
| 31 | 在售售价日历必须绑定变体（售价粒度不得停留在商品/票种层） |
| 32 | 订单明细的变体商品必须与明细商品一致 |
| 33 | 加购件变体必须挂在至少一个基础变体上（不得成为孤儿） |
| 34 | 有售价的变体在其上架渠道必须至少有一个可履约源 |
| 35 | 同一订单内同一商品的多个变体必须使用同一日期 |
| 36 | 订单小计必须等于明细金额之和（按人计价与按团计价都适用） |
| 37 | 锁价售价必须等于采纳源的挂牌价（价格保护，携程 `isPrivatePrice`） |
| 38 | 采纳价格保护源的售价行必须锁价（防止漏锁导致擅自加价） |

### 4.5 按团报价与价格保护（2026-11-04 已决策并落地）

接入日游品类会撞上两个携程字段，这两条已定口径并有数据验证：

#### 按团报价（`package.priceSettingType = 4/5`）

按团报价时**「总价 = 单价 × 份数」不成立**，明细必须显式声明计价基准：

| `sales_order_item.pricing_basis` | 语义 | `unit_price` | `total_price` | `quantity` |
|---|---|---|---|---|
| `per_person`（默认） | 按人计价 | 每份单价 | `unit_price × quantity` | 份数 |
| `per_group` | 按团报价 | **人均分摊价** | **团总价**（直接落库） | 团内人数 |

- 团总价的真值记在明细快照 `detail_snapshot.group_total`（快照不可变，是历史真相）。
- 人均分摊价允许每人 1 分以内的取整误差：`abs(total_price - unit_price × quantity) ≤ quantity × 0.01`。
- `quantity` 始终是**人数**，不因按团计价而变成「团数」——实名采集、库存预占都依赖这个语义。
- **准入条件**：按团报价的商品接入前，本条口径必须先落地，否则不变量 5 会误报、金额会算错。

#### 价格保护（`resource.isPrivatePrice`）

源侧标记该变体**不得自主加价**，对客售价必须原样等于源方挂牌价。

关键点：**锁价是「采纳源」的属性，不是变体的固定属性**。
同一个变体若改由非保护源供货，售价即解锁。

| 层次 | 落地 | 含义 |
|---|---|---|
| 源侧 | `supplier_variant.is_price_locked` | 这个源变体受价格保护（携程 `isPrivatePrice`） |
| 平台侧 | `price_calendar.price_locked` | 这一行售价已锁定，**由采纳源派生**，不允许自主加价 |

不变量 37 / 38 双向把守：锁价行售价必须等于采纳源挂牌价；采纳了保护源的行**必须**锁价（防漏锁擅自加价）。

实测（北京环球影城）：同一商品下，老年票的最优源是 Trip.com（486 < Zowoyoo 505）→ 该行锁价，售价原样 498.00；
其余变体采纳 Zowoyoo（非保护源）→ 未锁，可自主定价。**同一商品里锁与不锁并存**，这正是「锁价随采纳源变化」的体现。

---

## 5. 状态机

### 5.1 订单 `sales_order.status`

```
created → awaiting_payment → paid → booking_pending → confirmed → fulfilled
                ↓                 ↓            ↓             ↓
             expired          failed        failed       cancelled
                                                  ↓
                                            refunding → refunded
```

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

---

## 6. 领域事件（Domain Events）

| 事件 | 触发点 | 典型订阅方 |
|---|---|---|
| `ProductMapped` | 映射新建/变更 | 定价、索引重建 |
| `PriceChanged` | 源成本或对客价变更 | 缓存失效、推送 |
| `SessionSoldOut` | 场次售罄 | 下架、通知候补 |
| `OrderPlaced` | 下单 | 风控、库存预占 |
| `OrderConfirmed` | 预订成功 | 发券、通知 |
| `BookingRequested` | 发起预订 | 追踪 |
| `BookingConfirmed` | 源确认 | 出券 |
| `BookingFailed` | 源失败 | 改派、退款、告警 |
| `VoucherIssued` | 出票 | 短信/邮件/Lark 通知 |
| `VoucherRedeemed` | 核销 | 对账、评价邀请 |
| `RefundRequested` | 退款申请 | 财务 |
| `StatementReconciled` | 对账完成 | 财务 |

事件统一经 `event_outbox` 落库后发布，保证「状态已改但事件丢失」不发生。

---

## 7. 验收标准（Acceptance Criteria）

- [x] 一份可重复执行的 `db/schema.sql`，在空库上零错误建表
- [x] 一份 `db/seed.sql`，构造 5 个异构源 / 5 个规范商品 / 8 条跨源映射 / 3 源冗余场次
- [x] 一份 `db/verify.sql`，跑通全部视图并对 38 条不变量逐条断言
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
- [x] **无凭证集成演练**：用 Trip.com / GlobalTix 真实报文结构跑通 mapping → 路由（`scripts/mapping_dryrun.py`），演练库 38 条不变量全 PASS
- [x] **前端 POC**：`scripts/poc/index.html` 展示变体矩阵 / 覆盖语义匹配 / 变体级路由 / 模型缺口 / 不变量自检
- [ ] 各源真实适配器（下一阶段，按 `docs/connector-contract.md` 实施）
- [ ] API / Web 端（B 端管理台 + C 端购买链路，下一阶段）

---

## 8. 变更记录

| 日期 | 变更 | 影响 |
|---|---|---|
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
