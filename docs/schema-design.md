# Schema 设计说明 — 多源票券中心

> 物理模型：`db/migrations/`（PostgreSQL 15+；基线 `001_baseline.sql` + 后续迁移文件）
> 建库：`tc-connect migrate --db <库>`（迁移引擎：账本 + 内容校验和 + 幂等 + 并发互斥）
> 验收：`db/verify.sql`（94 条不变量断言 + 17 组业务视图）
> 结论先行：**选 PostgreSQL + jsonb 混合模型**。75 张业务表（+1 张迁移账本）/ 40 张视图 / 218 个索引 / 38 个触发器 / 96 个 CHECK 约束 / 65 个序列。

---

## 1. 形态选型：SQL / 半 SQL / NoSQL

题面给了三条路，先把各自的真实代价摆清楚，再说明为什么选第三条的变体。

| 方案 | 做法 | 致命问题 |
|---|---|---|
| **纯关系（宽表 union）** | 每个源一套列：`ingresso_title`、`globaltix_title`… | 加第 6 个源要改全表；B/C 端查询写满 `COALESCE`；列爆炸 |
| **纯关系（万能 EAV）** | 属性全放 `entity_attr(entity_id, attr_id, value)` | 聚合查询全靠 pivot；类型丢失；性能随数据量塌陷；无法写 `WHERE duration > 120 AND age_min < 12` 这种自然约束 |
| **纯文档（MongoDB）** | 每个源一份文档 | **跨源去重做不了** —— 「香港故宫」在三源是三条文档，跨文档 join 和唯一约束在 Mongo 里都很别扭；金额与库存的一致性约束无处安放；结算对账查询性能不可控 |
| **半 SQL（本文采用）** | 关系骨架 + jsonb 长尾 + 原样层隔离 | 需要治理纪律：什么进 jsonb、什么进强类型列，必须有明确规则 |

### 1.1 为什么不是纯 NoSQL

这个系统的核心难点是**跨源同一实体**和**金额/库存一致性**。

- 「香港故宫」在 GlobalTix、JTB、票付通是三个不同结构的对象，要归一成一个 `product`。
  文档模型里这叫「实体解析（entity resolution）」，MongoDB 要么靠应用层做，要么靠 `$lookup` 拼，代价都高。
  关系模型里就是一张 `product_mapping` 表，一个唯一约束就够。
- 结算要对账：源侧账单金额 vs 我方成本金额 vs 订单金额，三方比对。这本质是关系查询。

所以**主数据与交易域必须是关系型**。真正需要灵活的只有「商品属性」这一块 —— 而这一块用 jsonb 就能解决，不需要为此付出整库文档化的代价。

### 1.2 jsonb 的使用纪律

jsonb 不是「不想设计表就塞进去」。

| 类别 | 位置 | 理由 |
|---|---|---|
| 源报文原样 | `supplier_product.raw_payload`、`supplier_raw_payload.response` | 结构由源决定，我们不控制，且要能回放 |
| 规范化长尾属性 | `product.attributes` | 跨源语义已统一，但维度不可预知（年龄限制/包含项/免票数…） |
| 策略类配置 | `*.policy` / `*.rule` / `*.config` | 运营要频繁改，不该走 DDL |
| 快照 | `*.snapshot` | 历史不可变，禁止强类型化（会随业务演进而无法回放旧数据） |

而这些**必须**是强类型列：

- 金额（`NUMERIC(12,2)`）、币种
- 时间（`timestamptz` + `timezone` + `session_date`）
- 状态（`CHECK` 约束枚举）
- 所有外键与唯一约束
- 跨实体引用（`supplier_id`、`product_id`…）

**判定规则一句话**：会被 join / 排序 / 过滤 / 建约束的 → 强类型列；只是「携带」和「存档」的 → jsonb。

---

## 2. 四层结构

```
┌─────────────────────────────────────────────────────────────┐
│ 交易层  sales_order / booking / voucher / settlement        │
│         与源数量完全无关                                     │
├─────────────────────────────────────────────────────────────┤
│ 渠道层  channel / channel_listing / channel_listing_source   │
│         B端与C端在此隔离                                     │
├─────────────────────────────────────────────────────────────┤
│ 规范层  product / ticket_type / product_session / price      │
│         我们自己的主数据                                     │
├─────────────────────────────────────────────────────────────┤
│ 源层    supplier_product / supplier_session / supplier_price │
│         + 防腐层 supplier_raw_payload                        │
└─────────────────────────────────────────────────────────────┘
```

**依赖方向严格单向向下**：交易层 → 渠道层 → 规范层 → 源层。
源层**不认识**规范层（源层表里没有 `product_id`），归一化关系全部放在独立的 `product_mapping`。
这样加第 6、第 7 个源时，规范层与交易层一行不改。

例外：`supplier_price_calendar.product_id` 是一个**受控的冗余**（由映射派生）。
目的是让跨源比价能一条 SQL 出结果，避免每次比价都去 join 三层。
冗余由同步作业维护，不允许业务代码写入 —— 这一条写进了字段注释。

---

## 3. 多源承载的三套机制

### 3.1 机制一：商品级映射（去重）

```sql
product_mapping(supplier_product_id, supplier_id, product_id,
                 match_type, confidence, match_evidence, is_primary, status)
```

- 多对多：源商品可拆多规范商品，规范商品可由多源供给
- `confidence` + `match_evidence`：自动匹配结果必须可解释、可人工复核
- `is_primary` + 部分唯一索引 `ux_map_single_primary (product_id, supplier_id) WHERE is_primary`：
  同一商品同一供应商只能有一个主源，其余自动是备源

实测：`v_product_source_coverage` 输出

| product_code | supplier_count | has_redundancy | suppliers |
|---|---|---|---|
| SKU-HK-PALACE | 3 | t | globaltix, goodfellows_jtb, piaofutong |
| SKU-JP-SKYTREE | 2 | t | globaltix, goodfellows_jtb |
| SKU-BR-GASTRONOMY | 1 | f | ingresso |
| SKU-IT-DOGES | 1 | f | fonticket |
| SKU-CN-THEMEPARK | 1 | f | piaofutong |

### 3.2 机制二：场次级冗余（可售性）

只在商品级做冗余不够 —— 源 A 有明天场次，源 B 可能没有。
`product_session`（规范场次）+ `product_session_source`（可供给源）把冗余下沉到场次：

```
香港故宫 2026-11-05 → globaltix(primary,10) / jtb(fallback,20) / 票付通(fallback,30)
香港故宫 2026-11-06 → globaltix(primary,10) / jtb(fallback,20) / 票付通(fallback,30)
```

### 3.3 机制三：成本归一（可比）

三个步骤缺一不可：

1. **拆表**：`supplier_price_calendar`（源成本）与 `price_calendar`（对客售价）分开。
   早期版本把 `supplier_price` 塞在 `price_calendar` 里，结果一个商品三行源价 vs 一行售价，
   无法表达「多个源的成本」，比价无从谈起。**这是本设计最重要的一次返工。**
2. **汇率快照**：`fx_rate(base_currency, quote_currency, rate, as_of_date)`，
   语义是 `1 base = rate quote`。折算到基准币种用**除法**。
   （实测中这个方向一开始写反了，被验收查询当场抓出来：2600 JPY 被算成 54990 CNY。）
3. **归一视图**：`v_source_routing_candidates` 用 `ROW_NUMBER()` 按 `cost_base` 排序出 `route_rank`。

实测路由结果（C2C / 香港故宫 / 成人票 / 2026-11-05）：

| rank | 源 | 原币 | 折算 CNY | mode |
|---|---|---|---|---|
| 1 | 票付通 | CNY 108.00 | **108.00** | push |
| 2 | globaltix | HKD 118.00 | 108.93 | live |
| 3 | goodfellows_jtb | HKD 125.00 | 115.39 | pull_sync |

### 3.4 机制四：定价收敛（唯一实现）

成本归一之后还有一步：**从成本算出对客售价**。这一步曾经有四份实现
（两个 SQL 视图、一个 Python 块、种子数据里手写的数字），四者各自自洽，给出的价不一样。
现在收敛成一条路径：

```
fn_route_candidates(variant_id, date, channel_id, target_currency)
        ↑ 选源的唯一实现（候选集 + 排序键只有一份）
        ├── v_variant_routing_candidates   路由视图（route_rank=1 即首选源）
        └── fn_price_variant(variant_id, date, context_channel_id, price_channel_id)
                 ↑ 定价的唯一实现（SQL 函数，STABLE）
                 ├── fn_reprice_rows()            重算入口：源成本 / 汇率 / 上架关系变了就整体重算
                 ├── price_calendar               落库（金额列是派生值，不是真相）
                 ├── tc-connect price             接入层与运维排查（Go，不算钱，只读结果）
                 └── scripts/mapping_dryrun.py    演练器（Python，不算钱，只读结果）
```

**为什么定价必须住在数据库里。** 钱是 `NUMERIC`（AGENTS.md 硬约束 5），
Go 标准库没有十进制类型，Python 的 `float()` 算钱迟早差一分钱。
唯一能同时被 SQL / Go / Python 三方够到、又保住精度的落点就是数据库本身。
更实际的理由是「同一个价格」：视图、演练器、接入层各算一遍，等于没有价格。

**为什么选源也必须只有一份。** 路由决定「这一单走哪个源出票」，定价决定「这个源卖多少钱」。
两边各排一次序，一旦分叉就会「按 A 源的价格卖、按 B 源出票」—— 客诉说不清、对账对不上、佣金算不出。
不变量 43（定价采用的源 = 路由选中的源）负责证明这两条路径没被改回两份。

**售价行是派生物。** `price_calendar` 写的是「卖哪一行」（变体 × 日期 × 渠道），
成本 / 售价 / 划线价 / 折扣 / 锁价 / 留痕汇率全部由函数填。
不变量 41 拿函数重算一遍并逐字段比对，任何从别的路径写进去的金额都会被抓出来；
不变量 42 把毛利率守住（生效 `min_margin` = 渠道要求与源侧底线取严）；
不变量 44 把币种守住（售价行的币种必须等于该行的结算币种）；
不变量 45 把汇率留痕守住（留痕日期能独立复算出同一个折算因子）。

**口径细节**（完整规则见 `SPEC.md` §4.6）：

| 环节 | 口径 |
|---|---|
| 采纳源 | 就是路由选中的源（`route_rank = 1`）：上架关系绑定的启用源里，折算到基准币种后成本最低者（并列按 priority → fallback_order → 源商品 id 定序，可复现） |
| 成本 | `round(net_price × 留痕汇率, 2)`；汇率用快照（`as_of_date ≤ price_date` 的最新一条），缺快照的候选源不参与比价 |
| 售价 | `max(成本 × (1 + percent/100), 成本 / (1 - 生效 min_margin), floor)` |
| 划线价 | `售价 × (1 + list_markup_percent/100)` |
| 锁价 / 按团 | 售价 = 源方价，平台不加价、不受 min_margin 约束、不造划线价 |
| 结算币种 | 渠道专属行 = 该渠道 `default_currency`；默认行 = 基准币种（`fn_price_row_currency`） |
| 汇率留痕 | `fx_rate` = 1 源币种 = ? 本行币种（8 位小数）；`fx_as_of` = 折算实际依赖的快照日期（两腿取较晚）；**同币种不折算 → 因子 1、日期 NULL** |

---

## 4. 表清单（74 张）

### 4.1 集成域（3）
`supplier` · `supplier_raw_payload` · `sync_job_log`

### 4.2 目录域（8）
`category` · `city` · `product` · `attribute_definition` · `attribute_mapping_rule` · `product_translation` · `product_media` · `product_mapping`

### 4.3 供应域（6）
`supplier_product` · `supplier_ticket_type` · `supplier_session` · `supplier_price_calendar` · `ticket_type` · `ticket_type_mapping`

### 4.4 价库域（6）
`price_calendar` · `inventory_snapshot` · `availability_cache` · `fx_rate` · `product_session` · `product_session_source`

### 4.5 渠道域（3）
`channel` · `channel_listing` · `channel_listing_source`

### 4.6 交易域（8）
`customer` · `sales_order` · `sales_order_item` · `sales_order_item_source` · `sales_payment` · `sales_refund` · `idempotency_record` · `state_transition`

### 4.7 预订域（3）
`booking` · `booking_attempt` · `booking_event`

### 4.8 履约域（3）
`voucher` · `voucher_entitlement` · `voucher_redemption`

### 4.9 结算域（3）
`settlement_statement` · `settlement_line` · `reconciliation_run`

### 4.10 运维（3）
`event_outbox` · `notification_outbox` · `app_setting`

### 4.11 视图（39）

| 视图 | 回答什么问题 |
|---|---|
| `v_product_source_coverage` | 哪些商品有多源冗余？覆盖度够不够？ |
| `v_product_source_compare` | 各源成本差多少？（已折算基准币种） |
| `v_source_routing_candidates` | 这一刻该选哪个源？首选和备选是谁？（商品 × 票种粒度） |
| `v_product_variant_matrix` | 这个商品到底有哪些可售组合？每个组合的轴取值是什么？ |
| `v_variant_source_coverage` | 每个组合有哪些源能供？缺什么？（`can_fulfil` / `gaps`） |
| `v_variant_routing_candidates` | 这个组合该选哪个源？（变体粒度，强制覆盖校验） |
| `v_variant_validity` | 这个组合的有效期窗口到哪天？（场次当天起算，连续 `valid_days` 天） |
| `v_variant_comparison` | 两个组合差在哪？（人群 / 轴取值 / 有效期 / 退款口径 / 可用源，一行看清） |
| `v_order_fulfillment_gap` | 哪些订单「付了钱没出票」？ |
| `v_settlement_gap` | 哪些已确认预订没进结算单？ |
| `v_supplier_sync_health` | 哪个源在掉链子？ |
| `v_invariant_checks` | 94 条业务不变量有没有被破坏？（= core 45 条 + tx 8 条 + order 1 条 + fulfill 6 条 + refund 4 条 + redemption 4 条 + inventory 4 条 + validity 3 条 + readmodel 6 条 + composition 4 条 + combo 7 条 + hardening 2 条） |
| `v_invariant_checks_core` | 供给/定价/展示侧 45 条有没有被破坏？ |
| `v_invariant_checks_tx` | 交易侧 8 条有没有被破坏？（状态可达性与订单/预订/凭证一致性） |
| `v_invariant_checks_order` | 下单侧 1 条有没有被破坏？（明细单价必须等于定价函数输出） |
| `v_invariant_checks_fulfill` | 履约侧 6 条有没有被破坏？（支付、预订、出券与订单履约状态一致性） |
| `v_invariant_checks_refund` | 退款侧 4 条有没有被破坏？（退款金额、已退款订单的事实与状态一致性） |
| `v_invariant_checks_redemption` | 核销侧 4 条有没有被破坏？（已核销必有成功记录、一张券最多成功一次、额度用尽且账对得上、核销在有效期内） |
| `v_invariant_checks_inventory` | 库存预占侧 4 条有没有被破坏？（每条明细有预占、量对得上、可售数没被扣两遍） |
| `v_invariant_checks_validity` | 有效期侧 3 条有没有被破坏？（口径不歧义、券不短于承诺、卖出去的源覆盖得住） |
| `v_invariant_checks_readmodel` | 读模型侧 6 条有没有被破坏？（读模型不与主数据分叉、日历有效期终点不被算错、组合的有效期 = 成分窗口的并集、组合构成不与主数据分叉、组合的格子带价格） |
| `v_invariant_checks_composition` | 组合映射侧 4 条有没有被破坏？（成分同源、成分覆盖得住、两侧数量一致、组合不许直接挂源映射） |
| `v_invariant_checks_combo` | 组合售卖侧 7 条有没有被破坏？（成分属于本明细的商品、明细成本 = Σ 成分单价 × 数量、出票张数 = 配方数量 × 份数、成分同源且与明细一致、成分票额够用、同一源 SKU 只订一次、预订与成分双向对齐） |
| `v_invariant_checks_supply` | 供给/定价/展示侧不变量视图的**供给侧**子集（45 条里去掉 29，剩 44 条） |
| `v_c_listing_feed` | C 端列表页直出（一行一卡片，无额外 join） |
| `v_c_product_detail` | C 端详情页内容一次聚合 |
| `v_c_checkout_requirements` | 结算页动态表单规格 |
| `v_c_readmodel_drift` | 读模型卡片与价格日历是否已不一致？ |
| `v_c_variant_feed` | C 端变体行直出（差异事实 + 本渠道价格区间与可售天数，一行一变体）；组合另带构成（`is_combo` / `combo_audience` / `component_count` / `composition`） |
| `v_c_variant_composition` | C 端组合成分明细（一行一个成分：份数 / 人群编码 / 各管几天），详情页直接读 |
| `v_variant_composition` | 组合映射一行看清（组合 / 组件 / 源 SKU / 源侧数量 vs 声明数量） |
| `v_order_item_source` | 订单明细的履约单位一行看清（成分变体 / 源 SKU / 数量 / 出票张数 / 单价 / 预订 / 券） |
| `v_combo_price_gap` | 这个组合为什么卖不了？（成分缺价 / 场次不同 / 源不同 / 价格锁定 / 按团报价，逐条列原因） |

### 4.12 C 端域（20，见 `docs/c-end-model.md`）

**读模型（4）**：`c_product_card` · `c_product_calendar` · `c_variant_facts` · `c_variant_composition`

**展示内容（6）**：`tag` · `product_tag_link` · `product_highlight` · `product_inclusion` · `product_note` · `product_location` · `product_review`

**购买漏斗（6）**：`cart` · `cart_item` · `coupon` · `coupon_redemption` · `checkout_requirement` · `order_holder` · `inventory_hold`

**核销端（2）**：`gate` · `gate_operator`

> 加上 `ALTER TABLE` 补的 4 列（`sales_order.cart_id/coupon_id/discount_breakdown`、`voucher_redemption.gate_id/gate_operator_id`）。

### 4.13 变体域（9，详见 §5 与 §20）

`product_axis` · `product_axis_option` · `product_variant` · `product_variant_option` · `product_variant_relation` · `supplier_variant` · `supplier_variant_mapping` · `supplier_variant_composition` · `c_variant_calendar`

---

## 5. 变体模型：把「可售组合」从表结构里解出来

> 这一节回答一个具体问题：**环球影城这种「大人 / 小孩 / 园区票」的商品，怎么进这套模型？**

### 5.1 原模型的天花板在哪

现有可售单元是 `(product, ticket_type)` 两层：

```
product（香港故宫）── ticket_type（成人/儿童）── product_session（日期+时段）
                    └─ price_calendar（售价）
```

维度被**硬编码进了表结构**：人群塞在 `ticket_type`，日期塞在 `product_session`。
当一个商品需要「人群 × 票种(1日/2日) × 园区范围(单园区/园区通票) × 加购件(快速通行证)」时，
这张表就没有位置放「园区」了 —— 塞进 `ticket_type` 会污染票种语义，
拆成多个 `product` 会让组合数量爆炸，而且**跨源无法对齐**。

第二重问题在源侧：同一张「成人·一日·园区通票」，

| 源 | 源侧形态 | 源侧可售单元 |
|---|---|---|
| Trip.com | 固定组合 SKU | 一个 SKU = 一个完整组合 |
| Zowoyoo（自由行） | 参数化售卖方案（人群/园区是下单参数） | 一个方案覆盖多个组合 |

`product_mapping` 是商品级的，它回答不了「这个源到底能供哪些组合」。

### 5.2 三步解法

```
① 维度配置化    product_axis / product_axis_option
                 维度不再进表结构；人群沿用 ticket_type（历史订单语义不动）

② 可售单元下沉  product_variant (+ product_variant_option / product_variant_relation)
                 product 的下一级从 ticket_type 变成「变体」

③ 覆盖语义映射  supplier_variant / supplier_variant_mapping
                 源变体 → 规范变体不是一对一，而是「覆盖声明」
```

**「两层 SKU」= 只有人群一个轴的变体模型**，是本模型的特例而不是被推翻的对象。

### 5.3 覆盖语义（`coverage`）

```json
{
  "axes":     {"audience":["adult","child","senior"],
               "pass_type":["1d"],
               "park_scope":["studio_only"]},
  "excludes": []
}
```

判定函数 `fn_variant_covered(coverage, variant_id)`：
变体要求的每一项能力（人群 + 各轴取值）都必须落在 `coverage.axes[axis]` 内，
且不在 `coverage.excludes` 内 → 该源可履约该变体。

这条规则是**「不能卖出履约不了的票」的技术保证**：
覆盖不全的源不会进入路由候选，而不是先卖出去、再在履约环节失败。

配套的 `fn_variant_coverage_gaps` 直接给出缺口（如 `{park_scope:studio_snw}`），
运营不用猜「为什么这个源接不了这单」。

### 5.4 新增表（8 张，另见 §20）

| 表 | 域 | 作用 |
|---|---|---|
| `product_axis` | 目录 | 商品的可变维度定义 |
| `product_axis_option` | 目录 | 维度上的可选值（语言无关的结构化事实） |
| `product_variant` | 目录 | 规范可售单元（product 的下一级） |
| `product_variant_option` | 目录 | 变体在各轴上的取值 |
| `product_variant_relation` | 目录 | 变体可叠加关系（基础票 ← 快速通行证） |
| `supplier_variant` | 供应 | 源侧可售单元（固定组合 SKU / 参数化售卖方案） |
| `supplier_variant_mapping` | 供应 | 覆盖语义映射（1 源变体 → N 规范变体） |
| `c_variant_calendar` | C 端 | 变体级日历读模型 |
| `c_variant_composition` | C 端 | 组合成分读模型：渠道 × 套餐 × 成分，一行带份数 / 人群编码 / 各自的天数 |

### 5.5 新增列（13 列，全部 `ALTER TABLE ... ADD COLUMN`）

| 表.列 | 用途 |
|---|---|
| `price_calendar.product_variant_id` | 售价粒度下沉到变体 |
| `price_calendar.price_locked` | 锁价行：对客售价必须等于采纳源挂牌价（由采纳源派生） |
| `supplier_price_calendar.product_variant_id` / `.supplier_variant_id` | 源成本价粒度下沉到变体 |
| `sales_order_item.product_variant_id` | 订单明细记明卖的是哪个组合 |
| `sales_order_item.pricing_basis` | 计价基准：`per_person` / `per_group`（按团报价） |
| `cart_item.product_variant_id` | 购物车按变体区分 |
| `inventory_hold.product_variant_id` | 库存配额按变体隔离（园区票与基础票配额不同） |
| `checkout_requirement.product_variant_id` | 实名要求可按变体配置 |
| `booking.supplier_variant_id` / `voucher.product_variant_id` / `voucher.supplier_variant_id` | 履约链路可追溯到具体组合；预订的源 SKU 是预订的单位（见 §22） |
| `supplier_variant.is_price_locked` | 源侧价格保护标记（携程 `isPrivatePrice`） |

**两处约束变更**（不是加列，是把旧约束改对）：

```sql
-- 明细金额 CHECK：旧口径只认「total = unit × qty」，对按团报价是错的
ALTER TABLE sales_order_item DROP CONSTRAINT order_item_total_ck;
ALTER TABLE sales_order_item ADD CONSTRAINT order_item_total_ck CHECK (
    CASE pricing_basis
      WHEN 'per_person' THEN total_price = unit_price * quantity
      ELSE total_price > 0 AND unit_price > 0
    END);
```

**锁价的关键语义**：锁价不是变体的固定属性，而是**采纳源**的属性。
`supplier_variant.is_price_locked` 是源侧事实，`price_calendar.price_locked` 是平台侧派生结果。
同一变体若改由非保护源供货，售价即解锁 —— 种子数据里「北京环球影城」就演示了这一点：
老年票的最优源是 Trip.com（受保护）→ 锁价、售价原样 498.00；
其余变体采纳 Zowoyoo → 未锁、可自主定价。

### 5.6 唯一键必须换

价格表的唯一键原本是 `(product_id, date, ticket_type_id, channel_id, session_id)`。
变体引入后，同一票种下可能并存多个变体（成人·一日·单园区 / 成人·一日·园区通票），
旧键挡不住，因此：

```sql
CREATE UNIQUE INDEX ux_price_variant_scope
    ON price_calendar (product_variant_id, date, COALESCE(channel_id,0), COALESCE(session_id,0))
    WHERE product_variant_id IS NOT NULL;
CREATE UNIQUE INDEX ux_spc_variant_scope
    ON supplier_price_calendar (supplier_variant_id, product_variant_id, date)
    WHERE supplier_variant_id IS NOT NULL;
```

旧键保留为 `_legacy` 部分索引，覆盖迁移窗口内尚未回填的行。

### 5.7 存量库迁移顺序

```sql
-- ① 生成 base 变体：每个 (product, ticket_type) 一个
INSERT INTO product_variant (product_id, variant_code, variant_key, title, variant_role, ticket_type_id, status, sort_order)
SELECT tt.product_id, p.product_code||'-'||tt.code, p.product_code||':'||tt.code,
       p.title||' · '||tt.name, 'base', tt.id, 'active', tt.sort_order
  FROM ticket_type tt JOIN product p ON p.id = tt.product_id;

-- ② 生成源变体 + 1:1 精确覆盖映射（每个 supplier_ticket_type 一个）
-- ③ 回填 price_calendar.product_variant_id / supplier_price_calendar.{product,supplier}_variant_id
-- ④ 回填完成后可收紧：ALTER TABLE price_calendar ALTER COLUMN product_variant_id SET NOT NULL;
```

完整可执行版本见 `db/seed.sql` 第 16.2 节。

## 6. 索引策略

### 6.1 jsonb 的索引

```sql
CREATE INDEX ix_product_attr_gin ON product USING GIN (attributes jsonb_path_ops);
```

`jsonb_path_ops` 比默认 GIN 体积小约 1/3，且支持 `@>` 包含查询：

```sql
SELECT * FROM product WHERE attributes @> '{"age_limit":{"min":3}}';
```

同时给 `title` 建了 trigram 索引支持模糊搜索：

```sql
CREATE EXTENSION pg_trgm;
CREATE INDEX ix_product_title_trgm ON product USING GIN (title gin_trgm_ops);
```

### 6.2 可空维度的唯一索引（踩坑点）

Postgres 的 `UNIQUE` 约束**不把 NULL 视为相等**，所以
`UNIQUE (product_id, ticket_type_id, channel_id, date)` 里 `channel_id` 为 NULL 时，
同一个商品同一天会被插入多条「无渠道覆盖价」而互不冲突。

解决办法是**表达式唯一索引**：

```sql
CREATE UNIQUE INDEX ux_price_scope
    ON price_calendar (product_id, date,
                       COALESCE(ticket_type_id, 0), COALESCE(channel_id, 0), COALESCE(session_id, 0));
```

同类处理：`ux_spc_scope`（源成本价日历）、`ux_map_single_primary`（部分唯一索引 + WHERE）。

### 6.3 关键查询路径

| 场景 | 走哪条索引 |
|---|---|
| C 端按日期查可售场次 | `ix_ps_product_date (product_id, session_date, status)` |
| 路由选源 | `ix_spc_src_date (supplier_product_id, date, status)` + `ux_map_single_primary` |
| 履约漏斗扫描 | `ix_booking_retry (status, next_retry_at) WHERE status IN (...)` |
| 重报扫描 | `ix_booking_retry` 部分索引，只索引待重试的行 |
| 订单幂等 | `ux_order_idem (channel_id, idempotency_key) WHERE idempotency_key IS NOT NULL` |
| 出票去重 | `ux_voucher_code (supplier_id, code) WHERE code IS NOT NULL` |

---

## 7. 约束设计

### 7.1 状态一律用 CHECK 枚举，不用 PG ENUM

```sql
status TEXT NOT NULL DEFAULT 'active'
  CHECK (status IN ('active','inactive','suspended','onboarding'))
```

理由：`ALTER TYPE ... ADD VALUE` 在旧版本 PG 里不能用在有默认值的列上，
且加值要等事务结束；`CHECK` 改起来是普通 DDL。
代价是状态多了要改约束 —— 用 `COMMENT ON COLUMN` 列出全部取值做补偿。

### 7.2 业务不变量就地约束

```sql
CONSTRAINT order_item_total_ck CHECK (total_price = unit_price * quantity)
CONSTRAINT sales_order_money_ck  CHECK (total >= 0 AND subtotal >= 0)
CONSTRAINT entitlement_qty_ck    CHECK (consumed_quantity >= 0 AND consumed_quantity <= quantity)
CONSTRAINT booking_retry_time_ck CHECK (next_retry_at IS NULL OR next_retry_at >= created_at - interval '1 minute')
CONSTRAINT coupon_usage_ck       CHECK (used_count >= 0 AND (usage_limit IS NULL OR used_count <= usage_limit))
```

跨行、跨表的不变量无法用 CHECK 表达，统一落到 `v_invariant_checks` 视图 + CI 断言。

### 7.3 IDENTITY vs 显式 ID

主键统一 `BIGINT GENERATED ALWAYS AS IDENTITY`。
种子数据用 `OVERRIDING SYSTEM VALUE` 显式指定 id，保证可重复、可阅读、可断言。

---

## 8. 索引与触发器清单（实测）

- 表 74 / 视图 37 / 索引 217 / 触发器 35 / CHECK 约束 94 / 序列 65
- `updated_at` 由统一触发器 `fn_set_updated_at()` 维护，避免应用层漏更新
- 交易侧状态机由 12 个触发器守着（4 张表 × 守卫 + 事件）：非法流转当场报错，状态一变就落一条领域事件
- 订单关上（`cancelled` / `expired` / `refunded`）时由 `trg_release_holds_on_order_close` 把它的库存预占置为 `voided`：承诺要放掉，但「卖出过」这个事实不许被改写

---

## 9. 演进路线（尚未实施，方案已定）

### 9.1 订单分区

单表 `sales_order` 目前不分区。超过 2000 万行时按 `placed_at` 做 RANGE 分区。

**注意**：分区表的唯一约束必须包含分区键，`UNIQUE(order_no)` 会直接失败。
解法是引入独立的 `order_no_registry(order_no PK)` 表做全局唯一，
分区表上只保留 `(order_no, placed_at)` 组合唯一。

### 9.2 读写分离

`supplier_raw_payload` 是典型的「只写 + 冷查询」，独立库或列存更合适。
`v_product_source_compare` 这类跨源比价查询也应走只读副本。

### 9.3 源报文冷热分离

`supplier_raw_payload` 超过 90 天归档到对象存储，库里只留索引与摘要。

### 9.4 换库成本评估

若最终必须迁到 MySQL 8：

- `jsonb` → `JSON`（去掉 GIN jsonb_path_ops，改为生成列 + 普通索引）
- `LATERAL` → 改写为派生表或窗口函数
- 表达式唯一索引 → 生成列 + 唯一索引
- `GENERATED ALWAYS AS IDENTITY` → `AUTO_INCREMENT`
- 部分索引（`WHERE`）→ MySQL 不支持，需改为普通索引或冗余列

工作量集中在 6 个视图和 3 张价格/库存表，核心聚合表基本平移。

---

## 10. 结构演进：迁移引擎（只增不改的机制）

物理模型的唯一来源是 `db/migrations/`：

```
db/migrations/001_baseline.sql   建库基线（冻结：应用之后不许再改）
db/migrations/002_xxx.sql        后续演进（ALTER TABLE ... ADD）
```

`db/schema.sql` 已经不存在了 —— 它就是今天的 `001_baseline.sql` 改了名。
留着一份「可以随手改的建表脚本」和一个「不许改的基线」，等于给分叉留了一个入口。

### 10.1 为什么必须有账本

只增不改靠人记着迟早破：有人改了建表脚本里的一个列名，本机重建的库没问题，
存量库从此和新库结构不同，等到某天报「column does not exist」才发现，
而且往往是在生产上。所以要把纪律变成机制：

| 机制 | 做法 | 挡住什么 |
|---|---|---|
| 账本 | `ops.schema_migration(version, name, checksum, applied_at, duration_ms)` | 同一个迁移被执行两次 |
| 内容校验和 | 每个文件应用时记 sha256，再跑时对不上就报错 | 改了已发布的迁移 |
| 每迁移一事务 | 建表与记账在同一事务里 | 崩了留半截结构 |
| 会话级互斥锁 | 整轮迁移在一个 psql 会话里，`pg_advisory_lock` | 两个进程同时改结构 |
| 基线接管 | `--baseline 001` 记账不执行 | 存量库无法升级 |

账本放在独立的 `ops` schema：公共 schema 里只应该有业务表。
`ops` 不是领域的一部分（见 `docs/ddd.md` 的限界上下文），不该混进业务表清单。

### 10.2 怎么用

```bash
tc-connect migrate --db ticket_center            # 应用待应用的迁移
tc-connect migrate --db ticket_center --status   # 哪些已应用、哪些待应用
tc-connect migrate --db ticket_center --dry-run   # 只算计划
tc-connect migrate --db ticket_center --baseline 001   # 接管存量库
```

存量库（用旧脚本建出来的、账本为空的库）先接管再升级：基线记下 001 的校验和
而不重跑它（结构本来就是它建出来的），之后新增的迁移照常应用。

### 10.3 迁移里放了什么

目前有十四个文件：

| 文件 | 内容 | 为什么它是迁移而不是种子 |
|---|---|---|
| `001_baseline.sql` | 全部表 / 视图 / 索引 / 触发器 / 函数 | 建库基线，一经应用即冻结 |
| `002_read_model_refresh.sql` | `fn_refresh_read_models()`（刷新 `c_product_card` 与 `c_variant_calendar`） | 它是**长期存在的能力**，不是一次性数据。刷新口径写进库，才有一份口径；种子、CLI、定时作业都调它 |
| `003_transaction_state_machine.sql` | `state_transition` 表 + 守卫触发器 + 事件触发器 + 交易侧不变量视图 | 状态机是长期存在的规则，不是数据。规则住在库里才能「谁都绕不过去」（见下） |
| `004_place_order.sql` | `fn_place_order()` + `seq_order_no` + 下单侧不变量视图 | 下单是长期存在的写路径，不是数据。写路径住在库里，金额才有唯一来路（见 §13） |
| `005_fulfillment.sql` | 支付 / 预订 / 出券的八个函数 + `seq_booking_no` / `seq_voucher_no` + 履约侧不变量视图 | 履约是长期存在的写路径，不是数据。事实（支付、预订、票码）与状态不许分叉，规则得住库（见 §14） |
| `006_duplicate_payment_guard.sql` | `fn_record_payment()` 的重复收款守卫（`CREATE OR REPLACE`） | 005 已经在库里应用过，改它等于内容漂移 —— 「DDL 只增不改」这条规矩自己也得守（见 §14.4） |
| `007_refund.sql` | `fn_request_refund()` / `fn_approve_refund()` / `fn_complete_refund()` + `seq_refund_no` + 退款侧不变量视图 + 回退用的状态边 | 退款是长期存在的写路径，不是数据。退了钱，事实必须一起改，规则得住库（见 §15） |
| `008_redemption.sql` | `fn_redeem_voucher()` + `voucher_redemption` 的 `reason` / `consumed_quantity` 两列 + 唯一索引 `ux_redemption_single_success` + 核销侧不变量视图 | 核销是长期存在的写路径，不是数据。重复入场是票务欺诈的入口，一致性得由唯一索引兜底而不是靠约定（见 §16） |
| `009_inventory_hold.sql` | `fn_available_qty()` / `fn_reserve_qty()` / `fn_hold_inventory()` / `fn_release_hold()` / `fn_expire_holds()` + `inventory_hold` 的四列 + 订单关上的放占触发器 + 库存侧不变量视图 | 可售数是长期存在的口径，不是数据。源侧快照与我们的承诺必须对账（不然每同步一次就少卖一半），并发扣减必须靠锁（见 §17） |
| `010_validity_window.sql` | `product_axis_option.valid_days` 列 + `fn_variant_validity_days()` + `fn_issue_voucher()` 的整体替换（`CREATE OR REPLACE`）+ `v_variant_validity` / `v_variant_comparison` + 有效期侧不变量视图 | 有效期是产品的差异维度，得住轴上（它要被计算、要被门禁断言）。写死 `+1` 等于卖两日票发一天有效期的券，客户第二天进不了场（见 §18） |
| `011_c_end_variant_facts.sql` | `c_variant_facts` 表 + `c_variant_calendar.valid_to` 列 + `v_c_variant_feed` + `v_invariant_checks_readmodel` + `fn_refresh_read_models()` 的整体替换（DROP + CREATE：返回值多一个 OUT 参数，行类型变了，PostgreSQL 不许改函数的返回类型） | 差异在主数据里说清楚了但 C 端看不到，唯一的出路是把差异事实也放进读模型（请求链路不许 join 主数据）。两日票和单日票在日历上长得一模一样，用户按「当天有效」理解两日票，第二天到门口才发现进不去（见 §19） |
| `012_composite_mapping.sql` | `supplier_variant_composition` 表 + `product_variant_relation.quantity` 列 + `fn_variant_requirements()` / `fn_variant_coverage_is_exact()` + `fn_guard_composition_parent` / `fn_guard_combo_mapping` 两个守卫触发器 + `v_variant_composition` + `v_invariant_checks_composition` | 异构融合有两条方向，方向 B（一个可售单元由多个源 SKU 组成）也得有模型。配方与声明必须两侧对得上（不变量 78-81），否则就是「收三个人的钱，出一张票」（见 §20） |
| `013_combo_sellable.sql` | `sales_order_item_source` 表 + `booking.order_item_source_id` / `order_holder.component_variant_id` 两列 + `fn_combo_components()` / `fn_bound_supplier_session()` + `fn_price_variant()` / `fn_place_order()` / `fn_create_bookings()` / `fn_issue_voucher()` / `fn_apply_order_fulfillment()` 的整体替换（`CREATE OR REPLACE`）+ `fn_available_qty()` 的池子归属修正 + `v_order_item_source` / `v_combo_price_gap` + `v_invariant_checks_combo` | 组合套餐此前只到「两侧有声明、还卖不了」：定价只会给一个源 SKU 的成本、只订一个成分的货 —— 收三个人的钱出一张票。组合能成交的条件是成本按配方算、成分各订各券、成分的源 SKU 取自配方（重选源就出现「按 A 源的价格卖、按 B 源出票」），这些都得住在库里（见 §21）。**其中 `booking.order_item_source_id` 被 014 拆掉**（一条预订可以覆盖好几个成分，这一列装不下） |
| `014_booking_unit_source_sku.sql` | `fn_booking_components()`（一条预订覆盖哪些成分的唯一读法）+ `fn_create_bookings()` / `fn_issue_voucher()` 的整体替换（`CREATE OR REPLACE`）+ 拆掉 `booking.order_item_source_id` + 唯一索引 `ux_booking_one_per_source_sku` + `v_order_item_source` 重建 + 履约侧 / 有效期侧 / 组合侧不变量视图重建（不变量 87 / 88 新增，58 与 75 按新口径重写） | 预订的单位定错了：013 按成分建预订，而参数化源里成人票与儿童票是**同一个源 SKU** —— 于是同一个源 SKU 在同一个源场次上订了两次，源侧看到两张订单单，我们这边一条客户订单对两个源单号。源卖的是 SKU，我们就按 SKU 订（见 §22） |
| `015_combo_c_end.sql` | `fn_variant_composition()`（组合成分的唯一读法）+ `fn_variant_validity_days()` 整体替换（组合分支 = 成分窗口的并集）+ `v_variant_comparison` 加四列（`is_combo` / `combo_audience` / `component_count` / `composition`）+ `c_variant_composition` 表 + `c_variant_facts` 加三列 + `fn_refresh_read_models()` 整体替换 + `v_c_variant_feed` 整体替换 + `v_c_variant_composition` + `fn_sync_combo_calendar()` + 核心不变量视图按组合口径重写（16 / 34）+ 不变量 89-92 新增 | 组合在自己的配方里画得出来，但 C 端画不出：源侧没有它的商品条目，目录同步作业看不见它，它没有 `price_calendar` 行，所以上不了日历。015 补上这条路径 —— 组合的售价行与日历格子由配方推出来，构成进读模型（见 §23） |
| `016_security_hardening.sql` | `sales_refund.approved_by` 列 + `fn_complete_refund()` 整体替换（只接受 `approved` 的退款单）+ `fn_issue_voucher()` 整体替换（源侧没给票码时生成 128 位随机码）+ `v_invariant_checks_hardening` + `v_invariant_checks` 重建（不变量 93-94 新增） | 放行与出券这两步以前可以在实现里被绕过：绕过之后系统照样跑，只是没人知道钱是谁放行的、闸机认的是哪张票。两处门禁把「必经之路」变成机制（见 §24） |

读模型刷新写成一个 SQL 函数而不是散在调用方里，是有代价换来的：
`fn_refresh_read_models()` 的口径必须与 `v_c_readmodel_drift` 一致，
否则刷新完自己被判成漂移 —— 这条约束由 `internal/readmodel` 的测试守着
（改完刷新函数，测试会告诉你漂移检测和刷新口径是不是还对得上）。

### 10.4 边界

- 迁移文件必须是纯 SQL：行首不能有反斜杠（psql 会当元命令），引擎会拦。
- 迁移文件里不能有 `CREATE INDEX CONCURRENTLY`（不能在事务里跑）。
- 迁移不负责回滚。回滚是另一个动作（写反向迁移文件），本项目暂时不做 ——
  宁可停下来问人，也不要自动倒着跑一遍 DDL。

## 11. 交易侧状态机：规则住在库里

状态机以前只活在 `SPEC.md` 的图里。库里没有任何东西拦着「订单从 paid 直接跳 fulfilled」，
所以这件事必须由机制保证。

### 11.1 一张表装下合法流转

```sql
state_transition (aggregate_type, from_status, to_status, event_type)
```

`from_status = ''` 表示「刚创建」这一条边（INSERT 时落在这个状态）。
`event_type` 为 NULL 的流转不发事件。

表名到聚合名的映射走 `fn_aggregate_type`：`sales_order` → `order`、
`sales_order_item` → `order_item`、`booking` → `booking`、`voucher` → `voucher`。
用的是聚合名而不是表名，因为 `event_outbox.aggregate_type` 记的是领域聚合。

### 11.2 两个触发器

| 触发器 | 时机 | 做什么 | 挡住什么 |
|---|---|---|---|
| `fn_guard_state_transition` | BEFORE UPDATE | 目标状态不在合法边上就 `RAISE EXCEPTION` | 跳过中间态、无声地改状态 |
| `fn_emit_state_event` | AFTER INSERT / UPDATE | 往 `event_outbox` 写一条领域事件 | 「状态改了但事件丢了」 |

报错长这样：

```
ERROR:  非法状态流转：order expired → confirmed（表 sales_order，id=4）
HINT:  合法流转见 state_transition 表与 SPEC.md §5；不允许跳过中间态
```

### 11.3 为什么放库里而不是放应用层

- **谁都绕不过去。** Go、psql、脚本、手工改库走同一条路；放应用层只挡得住走应用层的写入。
- **状态与事件不分家。** 事件是状态变化的副产品，不是调用方的额外责任。
- **改状态机不用发版。** 加一条合法流转 = 往 `state_transition` 插一行 + 同步 `SPEC.md` §5。

代价是这张表得有人维护。所以它同时是不变量 46-49 的对象：
「状态必须能从初始状态走到」保证表里的边自洽（不会有一条孤立的边让人永远走不到）。

### 11.4 不变量视图拆成两半

`v_invariant_checks` 原来一条一条列着 45 条不变量。要加交易侧的 8 条，
只有两种做法：把 45 条抄一遍（抄一遍就会分叉，分叉的门禁等于没有门禁），
或者拆开：

```sql
ALTER VIEW v_invariant_checks RENAME TO v_invariant_checks_core;   -- 原 45 条原样保留
CREATE VIEW v_invariant_checks_tx AS ...;                         -- 交易侧 8 条
CREATE VIEW v_invariant_checks AS
    SELECT * FROM v_invariant_checks_core
    UNION ALL
    SELECT * FROM v_invariant_checks_tx;
```

改名而不抄一遍，是为了让「新增一条不变量」的成本等于「新增一个视图里的一个 UNION 项」。

## 12. 下单写路径：写规则住在库里

订单怎么落库以前没人写。现在只有一个入口：`fn_place_order()`
（`db/migrations/004_place_order.sql`）。

### 12.1 它是唯一实现，不是「一个便利函数」

`fn_place_order` 内部对每一行明细调 `fn_price_variant(variant, date, channel, channel)`，
拿到的售价与采纳源一起落库。所以：

- 金额没有第二份计算（Go 侧不重算，视图也不重算）；
- 采纳源就是路由选中的源（不变量 43 的延伸：下单不会选另一个源出票）。

不变量 54 把这件事钉住：订单明细的 `unit_price` 必须等于定价函数在同一天的输出，
逐行比对。

### 12.2 幂等怎么保证

幂等记录落在 `idempotency_record`（`scope = 'order:<channel_id>'`，
`request_hash = md5(渠道|明细|联系信息|备注|持票人)`）。

抢键用 `INSERT ... ON CONFLICT (scope, idempotency_key) DO NOTHING`：

- 抢到了 → 继续下单；
- 没抢到 → 比 `request_hash`：一样就返回原来那张单（`created = false`），
  不一样就报错「幂等键已用于另一笔请求」。

**不用「先查后插」**：两个并发请求会双双通过「查不到」的检查，然后双双落单。
`ON CONFLICT DO NOTHING` 把这个竞态交给唯一索引裁决。

订单表上还有一条 `ux_order_idem` 唯一索引（`channel_id, idempotency_key`）兜底 ——
即使幂等记录被清过，同键也落不下第二张单。

### 12.3 订单号

`seq_order_no` 序列 + `TC + YYYYMMDD + 6 位流水`。
流水由数据库发号，所以并发下不会撞号（`order_no` 上有唯一约束兜底）。

### 12.4 实名与快照

实名信息按 `checkout_requirement` 收：份数、必填字段、最大长度、正则格式逐项校验，
校验口径与不变量 25 同一份 —— 两处口径不一样就会出现「函数放行、门禁拦下」。
持票人按字段一行落 `order_holder`（值另存 `value_hash`）。

明细快照写进 `detail_snapshot`（商品标题、访客日、计价口径、成本源商品、汇率留痕），
订单级定价快照写进 `pricing_snapshot`。订单历史因此不依赖当前商品表（硬约束 7）。

---

## 13. 已验证 / 未验证清单

**已在本机 PostgreSQL 18.6 实测通过：**

- `db/migrations/` 在空库零错误执行（`tc-connect migrate`），且生成的公共 schema
  与直接 `psql -f 001_baseline.sql` **逐行一致**（pg_dump 对比，差异只有 `ops` 账本）
- 迁移幂等：重复执行不重复记账、不重复建表
- 内容漂移会被拦：改动已应用的迁移文件 → 引擎拒绝继续跑
- 存量库接管：`--baseline 001` 记账不执行，后续迁移照常应用
- 并发：两个迁移进程同时跑，会话级互斥锁把它们串行化
- `db/seed.sql` 完整装载（7 源 / 11 源商品 / 7 规范商品 / 11 映射 / 13 场次源绑定 / 6 订单 / 7 明细 / 6 预订 / 7 凭证 / 2 结算单 / 9 读模型卡片 / 11 日历格子 / 4 优惠券 / 4 购物车 / 4 库存预占 / 11 结算规格 / 10 持票人 / 6 评价 / 19 变体（含 2 张套餐）/ 25 源变体 / 29 覆盖映射 / 4 组合成分行）
- `db/verify.sql` 全部视图正常输出
- `v_invariant_checks` 94 条断言 **94/94 PASS**
- 状态机机制实测：非法流转（`expired → confirmed`）当场报错且数据未变；
  合法流转（`failed → pending`）写进去了，并在 `event_outbox` 留下 `BookingRetryScheduled`
- C 端读模型漂移检测：9 张卡片全部 `drifted=f`（`drifted=true` 计数 0）
- 变体级路由：环球影城 8 个变体 14 条候选，**同一商品不同变体首选源不同**
- 覆盖语义：儿童园区通票只有 Zowoyoo 一个候选；商品级路由视图对该商品输出 **0 行**
- 定价：23 行在售售价行全部由 `fn_price_variant` 生成，锁价行售价 = 源方挂牌价（498.00），
  按团报价行售价 = 团总价（1200.00），毛利率全部达标
- 选源与定价同源：23 行售价行的采纳源与 `fn_route_candidates` 的 `route_rank = 1` 完全一致（不变量 43）；
  汇率留痕可用留痕日期独立复算（不变量 45），同币种行不留快照
- 下单写路径实测（`tc-connect order place`）：变体 9 × 2 张 → 订单 7（CNY 1171.60 = 585.80 × 2，
  明细单价与 `fn_price_variant` 输出一致）；同一幂等键重复提交返回同一张单（`created=false`），
  库里仍是一张；同一键配不同内容报错；缺实名报错（报出缺哪个字段、要几份）；
  当天无可售价格报错；按团变体 17 × 7 人合计仍是团总价 1200.00（人均 171.43 只是分摊）
- 履约写路径实测（`tc-connect fulfill`）：订单 7 走完 支付 → 建预订 → 预订尝试 → 确认 → 出券，
  订单状态落到 `fulfilled`；金额不符报错、币种不符报错、票码张数与要发的张数不符报错；
  同一笔渠道流水重放幂等命中（不新记一笔），**另一笔流水打进已付订单当场报错**（重复收款）
- 增量升级实测：已有数据的库上 `tc-connect migrate` 报「应用 1 个，跳过 5 个」，
  新迁移与已应用的迁移互不干扰
- 退款写路径实测（`tc-connect refund`）：订单 3（已支付、预订失败）走完 发起 → 放行 → 完成，
  订单落到 `refunded` / 支付 `refunded` / 履约 `cancelled`，明细同步 `cancelled`，支付记录同步 `refunded`；
  同一幂等键重放幂等命中（不新退一次），同键异内容报错，金额与实付不符报错，
  没支付的订单报错，票已核销报错，退完再退一次报错；退款失败时订单照 `previous_order_status` 退回去
- 核销写路径实测（`tc-connect redeem`）：券扫一次成功、额度用尽、券落 `used`；
  同一张券再扫返回 `duplicate` 并带回第一次的记录 id 与时间；过期券不认但留记录写清 `past_valid_to`；
  订单在退款时不认核销；票码撞车收窄候选集
- 库存预占实测（`tc-connect stock` / `tc-connect hold`）：源侧快照 20 张、我们卖出 2 张时
  剩余 18 张（不是 16 —— 源侧 `sold` 已经反映了那 2 张，双扣会越卖越少）；
  源侧没有库存数据时返回「不知道」而不是 0；明知只剩 3 张要 5 张当场报错；
  同一 `hold_no` 重放幂等命中、同键异内容报错；并发抢最后一张时**只有一个订单成功**；
  订单取消后它的预占变成 `voided` 且 `consumed_quantity` 仍是原数（卖出过的事实没被改写）
- 有效期实测：两日票（轴选项 `valid_days = 2`）出券后券的窗口是场次当天起算两天，
  不是一天；不变量 74（券不得短于承诺）在把券窗口改短时报红
- 组合映射实测（`tc-connect compose`）：规范侧声明「2 成人票 + 2 成人快速通行证 + 1 儿童票 + 1 儿童快速通行证」，
  源侧配方逐项对得上，4 行成分落库（不变量 78-80 全 PASS）；
  组合变体挂直接源映射当场报错（不变量 81）；
  组合的需求集合 = 各组件需求的并集，所以单个源 SKU 覆盖不住整张配方，
  整张配方（各成分覆盖的并集）覆盖得住 —— 方向 A 与方向 B 不打架
- 组合套餐售卖实测：家庭套餐（2 成人 × 1 儿童）走完 下单 → 支付 → 建预订 → 出券，
  明细成本 = Σ 成分单价 × 数量（成人成分单价 505 × 2 + 儿童成分单价 418 × 1），
  每个成分一行 `sales_order_item_source`，成人成分发 2 张券、儿童成分发 1 张券，
  券上写的是**成分**的可售单元与票种；持票人按 `component_variant_id` 归到具体成分；
  同一源场次上多个成分的总需求一起判超卖（把池子压到 8 张时当场报「库存不足」）；
  整单退款后 3 张券转 `refunded`、2 张预占转 `voided`
  （`consumed_quantity` 仍是原数 —— 卖出过的事实不许被改写）
- **预订单位实测（014）**：家庭套餐的两个成分共用同一个参数化源 SKU，
  建预订只产生 **1 条**预订（013 的口径会产生 2 条 —— 同一个源 SKU 订两次）；
  这条预订覆盖 2 个成分、3 份入场，出券 3 张（成人 2 张挂成人成分、儿童 1 张挂儿童成分，
  持票人按成分归位）；建预订幂等（重放还是那一条）；
  同一张明细里同一个源 SKU 插第二条预订被唯一索引 `ux_booking_one_per_source_sku` 当场挡下；
  整单退款后 1 条预订转 `cancelled`

**尚未验证（需真实环境）：**

- 各 GDS 的真实 API 字段与错误码 → 见 `docs/connector-contract.md` 的差异矩阵（标注为「待核对」）
- 真实汇率来源与刷新频率
- 大并发下的库存预占与超卖防护（锁策略已实现并单测覆盖，压测仍需要真实环境）
- 分区改造与只读副本的实际性能收益

---

## 14. 履约写路径：事实与状态不许分叉

支付 → 预订 → 出券以前只有表和状态机，没有写路径 ——
支付怎么入账、预订怎么建、票码怎么挂到人身上，全靠调用方自己 UPDATE。
现在每一步都只有一个实现，全在 `db/migrations/005_fulfillment.sql`：

| 函数 | 职责 | 关键口径 |
|---|---|---|
| `fn_record_payment()` | 支付入账 | 金额必须等于订单应付；幂等按渠道流水 |
| `fn_create_bookings()` | 按明细建预订 | 预订的源场次取自 `product_session_source` 绑定，不按日期猜 |
| `fn_request_booking()` | 向源发起预订 | 幂等键必填 |
| `fn_record_booking_attempt()` | 归档一次外呼 | 请求 / 响应 / HTTP 状态 / 时延 / 错误分类都留痕 |
| `fn_complete_booking()` | 落源侧的预订结果 | 确认的预订必须带源侧预订号 |
| `fn_issue_voucher()` | 出券 | 票码数必须等于要发的张数，票码与持票人一一对应 |
| `fn_retry_booking()` | 安排重试 | 重试走 `booking` 的状态机，不绕过 |
| `fn_apply_order_fulfillment()` | 推导订单的履约状态 | 状态是结论，结论只有一个算法 |

### 14.1 顺序不是「谁先谁后」，是「谁允许谁」

状态推进走 `state_transition` 表，触发器守着：支付在 `awaiting_payment → paid`，
预订在 `paid → booking_pending`，出券在 `confirmed → fulfilled`。
中间跳过一步，触发器当场报错 —— 与 §11 说的是同一件事。

### 14.2 订单的履约状态不归调用方写

`fulfillment_status` 是**结论**，不是输入。结论由 `fn_apply_order_fulfillment()`
从明细的实际出票情况推导：几条明细出齐了、几条还没出，函数自己数。
调用方只报事实（这张预订确认了、这几张票出了），不报状态。

不变量 60 守的就是这条：`fulfillment_status` 与明细的出票情况必须一致。
谁 UPDATE 一下 `sales_order.fulfillment_status`，这条当场报警。

### 14.3 票码与持票人一一对应

出券时票码数必须等于这张预订要发的张数，对不上当场报错。
按人计价一人一券，按团报价整团一券 —— 分档不同，但**「发几张」这件事只有一个来源**。

### 14.4 重复收款不静默吞掉

`fn_record_payment` 的幂等分两层：

- **同一笔渠道流水重放** → 幂等命中，返回原记录，不新记一笔；
- **另一笔流水打进已付订单** → 报错「重复收款，需要走退款流程」。

第二层是 `006_duplicate_payment_guard.sql` 加的，因为 005 已经在库里应用过，
改它等于内容漂移 —— 「DDL 只增不改」这条规矩自己也得守。

不报错的后果很具体：钱收了两次，库里只记一笔，对账时这笔钱会凭空消失，
而系统一声不吭。宁可当场报错让人走退款。

---

## 15. 退款写路径：退了钱，事实必须一起改

履约走通了以后，钱收了、票出了，但钱退回来这一段没人写。
`sales_refund` 有表、状态机里有 `refunding` / `refunded` 这条边，写路径是空的。
现在每一段都只有一个实现，全在 `db/migrations/007_refund.sql`：

| 函数 | 职责 | 关键口径 |
|---|---|---|
| `fn_request_refund()` | 发起退款 | 整单退款；金额必须等于订单实付；幂等键必填；订单推进到 `refunding` |
| `fn_approve_refund()` | 人工放行 | 订单状态不动（钱还没回来） |
| `fn_complete_refund()` | 落退款结果 | 成功时一次改完事实与订单；失败时订单照原状态退回去 |

### 15.1 退款金额必须等于订单实付

`fn_request_refund` 拿 `p_amount` 与 `sales_order.total` 比，不等就报错。
少退客户会投诉，多退公司自己承担 —— 这条要在写路径上挡，
不能等对账时才发现少退了多少。

**行级退款（只退某几行）系统明确拒绝。** 它需要一张
「优惠券 / 税费 / 折扣怎么摊到每一行」的分摊口径，还需要源侧支持部分取消 ——
那是业务决策，不是工程决策。在这两样落地之前自己编一条分摊规则，
就是把一个没人拍板的口径写进代码里。

### 15.2 「有没有真的收到钱」看支付记录，不看订单状态

判退资格时查的是 `sales_payment` 里 `status='succeeded'` 的金额合计。
订单状态是人写进去的（可能写错），支付记录是事实。
订单状态只做第一道粗筛（`paid` / `booking_pending` / `confirmed` /
`partially_fulfilled` / `fulfilled` / `failed` 才能进退款流程），
真正的判据是「有没有成功的支付记录」。

### 15.3 幂等键必填，同键异内容报错

抢键用 `INSERT ... ON CONFLICT DO NOTHING`（不走「先查后插」）。
同一个键配不同内容（金额、原因、发起人任一不同）直接报错 ——
静默返回上一笔等于吞掉一次退款。

### 15.4 发起就进 `refunding`，失败能退回去

订单在**发起**时就推进到 `refunding`，不是在成功时。
发起的那一刻就该拦住履约推进 —— 免得一边退一边出票。
触发器因此落一条 `RefundRequested` 领域事件。

发起时把订单原状态记进 `sales_refund.previous_order_status`。
退款失败时照它恢复。为此在 `state_transition` 里补了几条「往回走」的边：

```
('order','refunding','paid')
('order','refunding','confirmed')
('order','refunding','partially_fulfilled')
('order','refunding','fulfilled')
('order','refunding','booking_pending')
```

原来的状态机只往前走，没有退路 —— 退款失败时订单会卡在 `refunding`，
而 `refunding` 的出边只有一条通往 `refunded`。
补不上边的状态就留在 `refunding` 等人处理，系统不硬改。

### 15.5 退款成功时事实一起改

一次 `fn_complete_refund` 里改完：

| 对象 | 改成 |
|---|---|
| `sales_order_item` | `confirmed` / `ticketed` → `refunded`；其余 → `cancelled` |
| `voucher` | `pending` / `issued` / `expired` / `void` → `refunded` |
| `booking` | `pending` / `requested` / `confirmed` / `ticketed` → `cancelled` |
| `sales_payment` | `succeeded` → `refunded` |
| `sales_order` | `status='refunded'`、`payment_status='refunded'`、`fulfillment_status='cancelled'` |

不变量 61-64 把住这件事：退超了不行、已退款订单必须有成功的退款记录、
已退款订单的每条明细必须已取消或已退款、已退款订单不能留着成功的支付记录。

### 15.6 有已核销的票不许整单退

票已经用掉了，钱不该全退。这笔要人工处理，系统明确报错，
不自己判断该不该退 —— 判断权在业务，不在函数里。

---

## 16. 核销写路径：扫一次票，留一条事实

前面三段写路径（下单 / 履约 / 退款）都通了，票也发出去了，但**票发出去就没人能用了**：
`voucher_redemption` 有表、状态机里有 `issued → used` 这条边，写路径是空的。
连带的后果是退款里「有已核销的票不许整单退」那条分支也永远走不到 ——
没有东西能把票变成 `used`。

现在这一段只有一个实现，全在 `db/migrations/008_redemption.sql`：

| 函数 | 职责 | 关键口径 |
|---|---|---|
| `fn_redeem_voucher()` | 扫一次票：判能不能进场、用尽额度、改券状态、落核销记录 | 幂等靠状态：唯一索引挡住第二次成功核销，第二次记 `duplicate` |

### 16.1 表结构补齐

`voucher_redemption` 在基线里只有 `result`（五档：`success` / `failed` / `duplicate` /
`expired` / `revoked`）。两件事补在 `008`：

| 列 | 类型 | 为什么 |
|---|---|---|
| `reason` | `TEXT` | 核销没成功的原因（`not_yet_valid` / `past_valid_to` / `voucher_void` / `voucher_refunded` / `voucher_not_issued` / `no_entitlement` / `entitlement_exhausted` / `order_refunding` / `gate_inactive` / `already_redeemed`）。`result` 只有五档，细分原因放这里 —— 闸机要告诉人「券还没出」，客服要查「为什么进不去」 |
| `consumed_quantity` | `INTEGER NOT NULL DEFAULT 0` | 这次核销实际消耗的入场额度（按人是 1，按团是整团人数）。记在核销记录上，是为了跟券的额度账对得上（不变量 67） |

配一条 CHECK：`consumed_quantity >= 0`。

### 16.2 一张券最多成功核销一次（唯一索引兜底）

```sql
CREATE UNIQUE INDEX ux_redemption_single_success
    ON voucher_redemption (voucher_id)
 WHERE result = 'success';
```

**这是机制保证，不是约定。** 两个闸机同时扫同一张券时，索引挡住第二条 `success` ——
重复入场是票务欺诈的入口，不能靠「先查后改」防。

扫描记录照旧两条都留（一次 `success` + 一次 `duplicate`），事实不丢。
第二次扫的结果里带回第一次成功核销的 `id` 与 `scanned_at`
（`original_redemption_id` / `original_scanned_at`），调用方据此对账：
**网络重试丢了响应，和恶意重复扫码，在这里是同一件事**，不该分成两条路。

### 16.3 额度一次用尽

`voucher_entitlement` 有 `quantity` / `consumed_quantity` 两列。一次核销把这张券的
全部入场额度用尽：一人一券的券一次扫一张（额度 1），整团一券的券一次扫全团（额度 = 团人数）。
成功后券从 `issued` 变 `used`，触发器落一条 `VoucherRedeemed` 领域事件。

**前提是凭证是一次性入场凭证。** 多次入场的通票还没进模型 ——
真要支持，额度不该被一次扫票用尽，这一条要重新设计。

### 16.4 锁顺序：券 → 额度行，刻意不锁订单行

| 步骤 | 加锁 |
|---|---|
| 找券 | `SELECT ... FROM voucher WHERE ... FOR UPDATE` |
| 判有效期 / 订单状态 | 不加锁（读快照） |
| 消耗额度 | `SELECT ... FROM voucher_entitlement WHERE voucher_id = ... ORDER BY id FOR UPDATE` |
| 改券状态 | `UPDATE voucher SET status='used'`（行已锁） |

**订单行刻意不锁。** 退款路径的加锁顺序是「订单 → 凭证」，这边再锁订单就是反序，
并发时死锁。核销只读一次订单快照判断「是不是在退款中」即可：
万一退款在核销之后发起，退款路径会撞上「有已核销的票」并要求人工处理 ——
两边不可能同时放行。

### 16.5 票码撞车不猜

票码在不同源之间可能撞车（两个源各自发了一串同样的数字）。
所以票码不唯一时按**闸机所属的源**收窄候选集；还收窄不出来就报错 ——
不能猜一张，猜错就是「拿 A 源的票进了 B 源的场」。

票码不存在 / 不唯一是**调用方的问题，不是扫票的结果** ——
`voucher_redemption.voucher_id` 是 `NOT NULL`，没法为一张不存在的券记一条扫描，
所以这两类情况报错而不是留记录。

### 16.6 过期只落记录，不改券状态

券过期了，只落一条核销记录（`result='expired'` / `reason='past_valid_to'`），
**不改券状态** —— 券状态留给过期作业统一改（这个作业还没做，见 SPEC §7）。
一件事一件事分开，才说得清是谁在什么时候把哪张票判成什么。

### 16.7 `used_channel` 记的是销售渠道

`voucher.used_channel` 记的是这张券**所属订单的销售渠道**（`channel.code`），
用于按渠道对账；闸机 / 操作员 / 设备另记在 `voucher_redemption` 上。
两者不是一回事：一张券在哪里被扫，与它是从哪个渠道卖出去的，是两个问题。

### 16.8 幂等靠状态，不靠幂等键

核销记录必须每次都追加，不能靠幂等键去重 —— 一去重就把重复扫票的事实压掉了。
「一张券最多成功核销一次」这件事由状态（券的 `status`）与唯一索引共同保证，
不是由幂等键保证。

---

## 17. 库存预占：可售数只有一个实现

源侧说「还剩 20 张」，我们卖出 18 张 —— 系统应该按 2 张卖，不是 20 张。
这件事此前没有人写：**没有地方算还剩多少，没有地方扣我们已经承诺出去的量，
也没有机制拦住两个并发订单卖掉同一张票。**

### 17.1 源侧快照与我们的承诺要对账

源侧快照里的 `sold` 只包含**已经同步到源侧的那些**销量；我们账上的 `consumed`
是全部卖出量。两者差的那部分才是「源侧还不知道、但我们已经卖出去」的量：

```
unreflected = GREATEST(our_sold − source_sold, 0)
committed   = unreflected + active_held
remaining   = GREATEST(available − committed, 0)
```

**不这么算就会双扣**：每次源侧同步后 `source_sold` 涨一次，
我们再扣一次全量 `consumed`，可售数会一路掉到只剩一半。
这个坑不是理论上的 —— 第一版实现就是这么写的，被种子数据当场抓出来。

### 17.2 不知道就是不知道

源侧没给库存快照、也没有可用性缓存时，`fn_available_qty` 返回 `known = false`。
**不许返回 0**：返回 0 意味着「卖完了」，会让整个商品下架，比超卖更贵。
不知道时不拦下单，但要把当时的可售数写进明细快照（`detail_snapshot.availability`）——
那是事后对账的依据。

### 17.3 并发靠锁

`fn_reserve_qty` 按 `supplier_session.id` **升序**加行锁：

```sql
PERFORM 1 FROM supplier_session ss WHERE ss.id = ANY(v_session_ids) ORDER BY ss.id FOR UPDATE;
```

升序是为了不让两个订单互相死锁（A 锁 1 再锁 2、B 锁 2 再锁 1 会死锁）。
锁拿到之后再算可售、再判断够不够 —— **不靠「先查后改」**，
先查后改在两个并发下会各卖各的最后一张。

### 17.4 预占是事实

`fn_hold_inventory` 的 `hold_no` 是幂等键（作用域 `hold:<channel_id>`），
同键异内容当场报错 —— 重放一次预占等于凭空多占一份。

预占的五个状态里有两个必须分清：

| 状态 | 含义 | `consumed_quantity` |
|---|---|---|
| `active` | 占着，没成交 | 0 |
| `consumed` | 已卖出 | = `quantity` |
| `released` | 放过，**从未卖出** | 0 |
| `expired` | TTL 到，从未卖出 | 0 |
| `voided` | **卖出后又被收回**（退款 / 取消 / 超时） | = `quantity`（事实不改写） |

`voided` 与 `released` 是一回事的话，退款与超卖的账就永远算不清：
「卖出去过」和「从没卖过」在账上分不开。

订单走到 `cancelled` / `expired` / `refunded` 时，
触发器 `trg_release_holds_on_order_close` 把它的预占置为 `voided`。
**触发器而不是应用层**：谁改的订单状态都一样放掉预占。

### 17.5 卖出的数查得到

`fn_place_order` 落明细之后，为每条明细写一条预占记录：
有匹配的购物车预占就消费掉（`active → consumed`，承诺量不变，不会重复扣），
没有就新建一条 `consumed` 的（`hold_no = 'HOLD' || 订单号 || '-' || 序号`）。
**卖出多少是事实，必须查得到**（不变量 69）。

---

## 18. 有效期：异构差异不许被抹平

USJ 有单日票（`pass_type = 1d`）和两日票（`pass_type = 2d`）。
源侧 zowoyoo 的 `ZWO-2D-BASE` 确实是个两日票，源侧场次也只在 2026-11-19 一天。
我们的规范场次是「(商品, 日期, 时段)」一行 —— 单日票和两日票共用同一个场次。

而出券写死的是「场次当天 + 1 天」：

```sql
valid_to = (session_date + 1)::timestamptz
```

结果：卖了两日票，发出来的券只管 2026-11-19 一天。
客户第二天拿着付过钱的票到门口，闸机判 expired ——
钱收了、票买了、门不认。这是本项目里最贵的一种 bug（客诉 + 赔付 + 平台罚款）。

### 18.1 有效期长度是数据，不是代码

`valid_days` 住在轴选项上：

| 列 | 类型 | 说明 |
|---|---|---|
| `product_axis_option.valid_days` | `INTEGER`（可空，`> 0`） | 这条轴取值对应「有效几天」。`NULL` = 这条轴不描述有效期（比如园区范围） |

为什么是轴选项而不是商品或变体：轴选项本来就是「产品的差异维度」的载体，
有效期是差异维度之一。挂在别处会和轴打架 —— 同一个事实两处写，迟早分叉。

为什么从 `option_attrs` 搬出来：`option_attrs` 是自由袋子，
`valid_days` 是要被计算、要被门禁断言的事实 —— 它得有自己的类型和约束。
种子里原本把它塞在 `option_attrs` 里，**没有任何函数读它** ——
事实存在但没人用，等于没有。现在它搬到列上，`option_attrs` 里的同名键一并去掉。

### 18.2 口径只有一处

```sql
CREATE FUNCTION fn_variant_validity_days(p_variant_id BIGINT) RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(MAX(ao.valid_days), 1) ...
$$;
```

取最大值而不是求和：有效期是「窗口有多长」，不是「各条轴各占几天」。
一个变体可以一条都不带，这时按 1 天算（单日票的默认口径）。
出券只调这个函数，Go 侧不算，视图不加减。

### 18.3 券不得短于产品承诺

不变量 74 守着这件事：

```
已发出的券不得短于该可售单元承诺的有效期
```

这是「哪天又有人把 `+1` 写回去」的门禁 —— 两日票发成一天，这里就红。

### 18.4 源侧能不能兑现是选源时定的

源变体能不能装配出这个可售单元，由 `fn_variant_covered` 判断
（`coverage` 里必须含对应的轴取值）。卖了之后这条不许变（不变量 75）：
真变了（源侧下架了这个组合）走的是退款，
不是把历史订单改成「当时就不该卖」。

### 18.5 差异要能一眼看出来

`v_variant_comparison` 一行一个可售单元，给出：人群、轴取值、有效期天数、
单次使用与否、时区、退款口径与手续费、时长与年龄下限、
以及「有几个源能装配出它」。

`source_count` 与 `fulfilable_source_count` 之差就是「这个可售单元有些源根本卖不了」——
这是差异，也是风险。

---

## 19. 差异走到 C 端：读模型带上差异事实

### 19.1 问题

到 §18 为止，异构差异在主数据里已经表达清楚了：轴（`product_axis` / `product_axis_option`）、
覆盖（`supplier_variant_mapping.coverage`）、有效期（`valid_days`），
外加一张差异对照表 `v_variant_comparison`。

但 **C 端看不到它们**。读模型只有 `c_product_card`（卡片）与 `c_variant_calendar`（变体日历），
带的是价格与可售天数。前端要显示「这是几日的票 / 覆盖哪些园区 / 能不能退」，只有两条路：

1. 在请求链路里 join 主数据 —— 违反读模型纪律（请求链路不许 join 主数据）；
2. 把差异事实也放进读模型。

最要命的是有效期：两日票和单日票在日历上**长得一模一样**（都是「一格」），
用户按「当天有效」理解两日票，第二天拿着票到门口，闸机判 expired。
010 治好了「发出来的券只管一天」，011 治「C 端看不出来这是两日票」。

### 19.2 结构

| 表 / 视图 | 干什么 |
|---|---|
| `c_variant_facts` | 变体级差异事实读模型：渠道 × 可售单元，一行带人群 / 轴取值 / 有效天数 / 退款口径 |
| `c_variant_calendar.valid_to` | 日历格子的有效期终点 = 格子日期 + 有效天数，前端不用自己加一天 |
| `v_c_variant_feed` | C 端变体读视图：差异事实 + 本渠道价格区间与可售天数，一行一变体 |

### 19.3 口径

- **事实只写一份。** `c_variant_facts` 的每个字段都从 `v_variant_comparison` 取，
  刷新函数里不重算 `valid_days`、不重算 `axes` —— 重算就是第二份实现，
  而两份实现的后果是「展示说两日票、发出来的是一天有效期的券」。
- **读模型不许与主数据分叉**（不变量 76）。刷新作业漏跑当场报出来：
  读模型可重建，但重建前它就是错的。
- **有效期终点由库算好**（不变量 77）。前端加一天和应用侧加一天，早晚有一天对不上。
- **哪些变体上这个渠道由日历格子决定。** 刷新建事实，也清掉已经没有格子的旧事实 ——
  不然 C 端会看到「有事实、没格子」的幽灵变体。

### 19.4 为什么必须 DROP + CREATE

`fn_refresh_read_models()` 的返回值多了一个 OUT 参数（变体事实的条数），
行类型就变了 —— PostgreSQL 不许改函数的返回类型
（`ERROR: cannot change return type of existing function`）。
所以 `011` 先按参数个数判断再删：只有当它还是 `002` 那一版（2 个 OUT 参数）才删，
迁移被人手重放时也不会把新版删掉。

---

## 20. 组合映射：异构融合的方向 B

### 20.1 两条方向

| 方向 | 现实场景 | 模型 |
|---|---|---|
| A：一个源 SKU 覆盖多个可售单元 | 源侧一张「成人 / 儿童通用」的通票，我们拆成成人票、儿童票两个可售单元 | `supplier_variant_mapping.coverage` + `fn_variant_covered()`（§5、§18） |
| B：一个可售单元由多个源 SKU 按数量组成 | 源侧套餐 = 门票 × 2 + 快速通行证 × 2 + 儿童门票 × 1 + 儿童快速通行证 × 1 | `supplier_variant_composition` + `product_variant_relation.quantity`（012） |

方向 A 是「一个源顶多个可售单元」，方向 B 是「一个可售单元顶多个源」。
真实商品两种都有，所以两个方向都得能表达。

### 20.2 两侧都要有声明

| 侧 | 声明什么 | 落在哪 |
|---|---|---|
| 规范侧 | 这个组合由哪些组件组成、各几个 | `product_variant_relation`（`relation_type='included'`）+ `quantity` 列 |
| 源侧 | 这个源 SKU 顶的是哪个组件、几个 | `supplier_variant_composition`（`component_variant_id` + `quantity`） |

两侧只有一侧 = 不完整：只有规范侧，源侧少给一份（客人少拿一张票）；只有源侧，
我们多卖一份（公司多赔一张票）。

`supplier_variant_composition.component_variant_id` 显式记「这个源 SKU 顶的是哪个组件」，
不是为了查，是为了对账：两个组件数量一样、又被同一个源 SKU 覆盖得住的时候，
猜就是瞎猜，逐行比才知道哪一行对不上。

### 20.3 数量是 `NUMERIC(8,2)`

数量不是整数这件事是真的：「2 大 1 小」里有 0.5 张通票、1.5 份配菜的时候，
`INTEGER` 会当场报错或悄悄截断。金额与数量一律 `NUMERIC`，禁止浮点。

### 20.4 组合的需求集合 = 组件需求的并集

`fn_variant_requirements(p_variant_id)` 用递归 CTE 沿 `product_variant_relation`
取这个变体的要求（人群 + 轴取值）。对组合来说，返回的是**各组件要求的并集**。

这条是方向 A 与方向 B 不打架的关键：

- 单个源 SKU 的覆盖集合永远覆盖不住一张组合（组合的要求是并集，比任何单张票大）；
- 整张配方（各成分覆盖的并集）覆盖得住组合。

所以组合不需要在方向 A 的表里出现，它走方向 B。

### 20.5 组件只许一层

组件要是组合，两侧的对账就得递归算，错了没人说得清。
触发器 `fn_guard_included_relation` 当场挡住（`relation_type='included'` 只许挂在
`variant_role='combo'` 的父变体上，且组件不许再是组合）。

### 20.6 组合不许直接挂源映射

触发器 `fn_guard_combo_mapping` + 不变量 81。

理由是成本：组合的成本 = Σ 组件成本 × 数量，一次预订要带整组源 SKU。
定价与预订还没接组合之前，若允许组合直接挂一条源映射，
`fn_price_variant` 会用**一个**源 SKU 的成本给整张套餐定价 ——
收三个人的钱，出一张票。宁可少卖，不可卖错。

### 20.7 接不上的情况，说清楚

源侧把整套套餐当**一个** SKU 卖的情况接不了。
从 `coverage` 看不出一个源 SKU 是「一整套」还是「一张谁都能用的票」，
看不出来就不能猜 —— 猜错就是「按 A 源的价格卖、按 B 源出票」。

### 20.8 唯一实现

写侧是 `internal/compose`（`tc-connect compose plan|apply`）：

- 覆盖判定只走库里的 `fn_variant_covered()`，Go 侧不重算；
- 数量比选用 `math/big.Rat`，不用浮点；
- 写库是幂等 upsert，源侧撤掉的成分置 `retired` 而不是删（历史要对账）。

演练器（`scripts/mapping_dryrun.py`）不再自带一份 Python 版覆盖判定，
它只调 `tc-connect normalize` 与 `tc-connect compose`，然后读结果。

---

## 21. 组合套餐的售卖：方向 B 走到成交

§20 把「一个可售单元由多个源 SKU 组成」建模了，但那只到声明为止。
这一节是把它接到成交上的那部分。

### 21.1 履约单位不是订单明细

一条订单明细（`sales_order_item`）是**计价单位**：一份套餐卖多少钱。
组合套餐有多个成分、一个成分可能有多张票，所以另开一张表当**履约单位**：

| `sales_order_item_source` | 含义 |
|---|---|
| `order_item_id` | 属于哪条订单明细 |
| `component_variant_id` | 这是哪个成分变体（普通明细 = 明细自己的变体） |
| `supplier_variant_id` | 这个成分由哪个源 SKU 出 |
| `quantity` | 配方里的数量（成人 ×2） |
| `admission_quantity` | 这一行要占多少入场额（按团报价时 = 整团人数） |
| `unit_cost` | 成分单价快照（成分行的成本口径） |
| `product_session_id` / `supplier_session_id` / `supplier_product_id` | 成分落在哪个场次、哪个源场次 |

**普通明细也写一行**（`component_variant_id` = 明细自己的变体）。
这样预占、出券、票额、持票人只有一条代码路径 ——
不为组合单开一套平行实现。

`order_holder.component_variant_id` 记持票人属于哪个成分。
**预订不再按成分建**（013 曾经这么做，014 改掉了 —— 见 §22），
所以预订与成分的归属由 `fn_booking_components()` 推出来，不另存一列。

### 21.2 成分的源 SKU 取自配方，不重新选源

`fn_combo_components()` 从 `supplier_variant_composition`（源侧配方）取成分与数量。
定价、预订都从这一个函数拿成分。

**不许重新选源。** 重新选源意味着配方只是装饰：按 A 源的价格卖、按 B 源出票，
客诉说不清、对账对不上 —— 这是硬约束 15 的同一个道理。

### 21.3 卖不了的时候，说清为什么

组合比普通变体多几种卖不了的情况，一律判不可售并列出原因
（`v_combo_price_gap`）：

| 情况 | 为什么卖不了 |
|---|---|
| 某个成分没有价格行 | 成本算不出来，报价就是猜的 |
| 成分不在同一个源场次 | 一次预订拿不到整组货 |
| 成分来自不同的源 | 一次预订跨源，退款与对账都要跨源处理 |
| 价格被锁（`price_locked`） | 锁价的是另一个口径的价，不许拿它当成本 |
| 按团报价（`per_group`） | 份数与人数的关系不是线性的，Σ 成分单价 × 数量算不对 |

宁可少卖，不可卖错。

### 21.4 超卖按源场次总需求判

多个成分可能落在同一个源场次上（成人票与儿童票抢同一个池子）。
逐个成分判会卖超：每个成分各自看到「还剩 2 张」，合起来卖了 4 张。

所以下单时先按**源场次汇总这一单的总需求**判一次（`fn_reserve_qty`），
再逐成分判可售数。

同时修了 `fn_available_qty()` 的池子归属：
源侧只报场次合计（`supplier_ticket_type_id IS NULL`）时，票种视角的剩余数
不许比场次视角更乐观 —— 否则两个票种各能把整个池子花一遍。

### 21.5 持票人归属靠 `item_index`

同一个成分变体出现在多行明细里时，光看 `variant_id` 分不出持票人属于哪一行。
实名的 `item_index` 指明是哪一行明细（1 起）。

带了 `item_index` 的实名必须**全带**：一半带一半不带就报错 ——
部分归属的实名会让持票人集错，票发出去才发现。

### 21.6 退款改的是全部成分的事实

整单退款时，成分的预订、券、票额一起改（不变量 61-64 的延伸）。
成分层面留着「已出票」的事实，就是退款退不干净。

### 21.7 已知缺口

已闭合（见 §24）。C 端读模型画不出组合的三条原因：

- 组合没有 `price_calendar` 行，所以读模型没有它的价格；
- 组合的有效期终点没定（成分的有效期不一样时，组合的有效期是交集还是并集）；
- 组合的人群标签（成人 + 儿童）没法用单个 `audience` 表达。

015 把三条都定了，详见 §23。

## 22. 预订的单位是源 SKU，不是一个成分

013 定的口径是「一个成分一次预订」。这个口径在参数化源上是错的。

### 22.1 参数化源里成人与儿童是同一个源 SKU

自由行（Zowoyoo）的 `ZWO-1D-BASE` 是一个**参数化售卖方案**：
一个源 SKU，人群是购买时选的一档（成人 / 儿童 / 老年）。
种子的家庭套餐配方就是这么写的：

| 成分 | 数量 | 源 SKU |
|---|---|---|
| `adult:1d:studio_only` | ×2 | `ZWO-1D-BASE`（id 21） |
| `child:1d:studio_only` | ×1 | `ZWO-1D-BASE`（id 21） |

两个成分 = **同一个源 SKU**。按成分建预订，就是这个源 SKU 在同一个源场次上
（源场次 12）被订了两次。后果有三样：

1. 源侧看到**两张订单单**（一次 2 张、一次 1 张），我们这边一条客户订单对两个源单号，
   对账时对不上；
2. 退款要退两次，其中一次退不掉就是「钱退回来了但票还在」；
3. 源侧只确认了其中一个成分时，整张套餐是半成品 —— **收了三个人的钱出了两张票**。

### 22.2 改成按源 SKU 建预订

**源卖的是 SKU，我们就按 SKU 订。** 一张订单明细里，
同一个源 SKU 在同一个源场次上只订一次：

```sql
GROUP BY s.supplier_variant_id, s.supplier_product_id, s.supplier_id,
         s.supplier_session_id, s.product_session_id
```

成分的拆分留在预订的请求明细里（`request_payload.components`），
出券时再按成分把票码和持票人分下去。

幂等键从「订单号 + 成分行 id」改成「订单号 + 明细 id + 源 SKU」，
唯一索引 `ux_booking_one_per_source_sku` 兜底
（同一张明细里同一个源 SKU 只许一条预订）。

### 22.3 预订覆盖哪些成分：推出来，不另存

013 用 `booking.order_item_source_id` 记「这条预订服务哪个成分」。
一条预订可以覆盖好几个成分，这一列装不下 —— 装得下就会误导
（以为一条预订只服务一个成分）。

所以这一列拆掉了，改为 `fn_booking_components()` 按
（明细, 源 SKU, 源场次）推出来。推导是唯一的：一个成分只属于一个源 SKU 分组，
不会分叉。老明细（013 之前下的单）没有成分行，这时成分就是明细本身。

### 22.4 出券逐成分发

一条预订覆盖几个成分就发几张：应发张数 = 各成分入场份数之和
（按团报价时每个成分一张）。每个成分：

- 自己的张数（按团一券 / 按人一人一份）；
- 自己的持票人（按**成分变体**归位，不是按票种 ——
  成人门票与成人快速通行证是同一个票种，按票种分会把这个人的两份实名混在一起）；
- 自己的有效期（`fn_variant_validity_days(成分变体)`）——
  门票两日、快速通行证一日，各按各的。

票码数仍然必须等于还要发的张数（少一个报错，不拿一张券顶两个人的票）。

### 22.5 代价说清楚

- 成分可以来自不同的源商品（GlobalTix 的门票 + 快速通行证是两个源商品），
  所以**一张套餐有几条预订 = 有几个源 SKU**。
- 整张套餐的原子性（要么全出票、要么全退）取决于源侧的能力。
  我们这边只保证「所有成分都出票了才算履约完成」，
  退款时全部成分的预订 / 券 / 票额一起改。
- 源侧把整套套餐当**一个** SKU 卖的情况接不了 ——
  那从 `coverage` 看不出来（看得出的是「一个源 SKU 覆盖多个可售单元」，
  不是「一个源 SKU 就是一整套」），看不出来就不能猜。

### 22.6 门禁

| 不变量 | 内容 |
|---|---|
| 87 | 同一张订单明细里同一个源 SKU 只能有一条预订 |
| 88 | 订单进入预订阶段后，预订与成分必须双向对齐（每个成分都被订到，每条预订都有成分） |

不变量 58（预订的源要等于它覆盖的那些成分的源）与
75（卖出去的源要覆盖得住它服务的那份成分）按新口径重写。

## 23. 组合在 C 端：配方自己推自己的日历

组合是**我们自己的配方**。源侧没有它的商品条目，目录同步作业看不见它，
所以 §19 那条「源侧同步 → 读模型」的路径对它不成立 ——
源侧同步跑得再勤，组合在 C 端也是一片空白。

015 把这条路补上：**组合的售价行与日历格子由它自己的配方推出来。**

### 23.1 售价行：按成分的售价行推

`fn_sync_combo_calendar()` 做两件事：

1. **价格行**：取成分在同一天、同一源场次上的 `price_calendar` 行，
   凑齐全部成分（`HAVING count(DISTINCT 成分) = 成分数`）才算这个组合当天可售；
   金额**走定价函数的组合分支**（成本 = Σ 成分单价 × 份数），同步作业不另算一遍钱。
2. **日历格子**：`price_calendar`（基准行）× `channel_listing`（上架），
   格子上的价格取自刚推出来的价格行。

推出来的价格行带 `cost_source_product_id = NULL` ——
组合的成本来自配方，不是来自某一个源商品。
所以不变量 16（售价日历的采纳成本必须可追溯到具体源）对组合改口径：
组合有**有效的源侧配方**即算可追溯；不变量 34（上了架的变体必须有可履约源）
对组合改口径：组合的成分各自覆盖得住即算有源。

### 23.2 有效期终点：成分窗口的并集

`fn_variant_validity_days` 的组合分支取成分的最大值：

| 配方 | 成分窗口 | 组合给客户的窗口 |
|---|---|---|
| 2 × 一日成人 + 1 × 一日儿童 | 1 / 1 | 1 天 |
| 2 × 两日成人 + 1 × 一日儿童 | 2 / 1 | **2 天** |

不是最短（第二天进不去），不是相加（多赔客户一天）。
不变量 89 的两边**独立读**：组合那边走 `fn_variant_validity_days`，
成分那边直接读 `product_axis_option.valid_days` ——
拿自己证明自己永远绿灯，独立读才知道错在哪一遍。

### 23.3 人群不选标签，带编码

组合不带一个「家庭」标签。它带的是每个成分的**人群编码 + 份数 + 各自的天数**：

```json
[{"audience": "adult", "quantity": 2.00, "valid_days": 2},
 {"audience": "child", "quantity": 1.00, "valid_days": 1}]
```

「2 成人 + 1 儿童」这句话由前端按 locale 拼 ——
展示文案不进模型（硬约束 9：`product.attributes` 只放语言无关的结构化事实）。

### 23.4 构成进读模型

| 表 / 视图 | 干什么 |
|---|---|
| `c_variant_composition` | C 端的组合成分（一行一个成分：渠道 / 套餐 / 成分 / 顺序 / 份数 / 人群编码 / 天数 / 标题） |
| `v_c_variant_composition` | 组合成分明细视图，详情页直接读 |
| `c_variant_facts` | 加三列：`is_combo` / `combo_audience` / `component_count` |
| `v_c_variant_feed` | 加四列，组合的构成以 jsonb 带出来 |

请求链路不许 join 主数据去算份数 —— 那与 §19 的纪律是同一条。

### 23.5 跨币种：组合没有单一源币种

组合的成本是 Σ 成分成本 × 份数，成分可以各自是不同币种
（源侧日元、我们卖人民币）。所以组合售价行的顶层 `fx_rate` / `fx_as_of` 是**空的** ——
那是「这里没有单一的值」，不是「同币种、汇率 1」。
填成 1 是声称「没折算过」，那会让对账去查一份不存在的折算。

逐成分的留痕在 `price_calendar.rule->'combo'` 里：

```json
[{"currency": "JPY", "fx_rate": 0.04728132, "fx_as_of": "2026-01-01",
  "net_price": 2600.00, "quantity": 2.00, "cost": 245.86}]
```

同币种 → 因子 1、快照日期为空（没折算过就不留假快照）；
跨币种 → 必须有快照日期，且因子能用这个日期独立复算出来。

**这条路径要自己的门禁**：组合的 `cost_source_product_id` 是空的，
不变量 45（售价行留痕的汇率与快照必须自洽）按那个字段 join 源价行，
**直接跳过组合**。没人复查 = 留个假快照日期都没人知道，对账时查无此账。

### 23.6 门禁

| 不变量 | 内容 |
|---|---|
| 89 | 组合的有效期必须恰好等于成分窗口的并集 |
| 90 | C 端的组合构成必须与主数据一致（多一行、少一行、份数或天数变了都算分叉） |
| 91 | 组合的日历格子必须带价格 |
| 92 | 组合的成分折算留痕必须自洽（同币种不折算、跨币种必须留快照日期且因子能复算） |

不变量 90 是 C 端那句「读模型可重建，主数据是唯一真相」的延伸：
读模型的份数被改坏（2 份写成 5 份），C 端就显示「5 份成人」，实际只发 2 份。

不变量 92 是「汇率用快照，不用实时」（硬约束 6）的延伸：
组合没有单一的汇率，因为成分各有币种 —— 留痕只能逐成分留。

## 24. 收紧口径：放行与出券必须是必经之路

§14-§16 把三段写路径（履约 / 退款 / 核销）落在库里，各自有一条唯一实现。
但实现里还有两个地方**可以在不报错的情况下被绕过**，绕过之后系统照样跑，
只是没人知道钱是谁放行的、闸机认的是哪张票。这两处由 016 收紧。

### 24.1 退款必须先放行

退款是三步：发起（`requested`）→ 放行（`approved`）→ 落结果（`succeeded` / `failed`）。
`fn_complete_refund()` 以前只拦终态，一笔还在 `requested` 的退款能被直接结掉 ——
**放行这一步形同虚设**，审批形同不存在，钱却真的退了。

016 的做法：

| 改哪 | 怎么改 |
|---|---|
| `sales_refund` | 加 `approved_by TEXT`，放行时记放行人；`approved_at` 已有 |
| `fn_complete_refund()` | 整体替换一次：状态不是 `approved` 就当场报错 |
| `v_invariant_checks_hardening` | 不变量 93：走到终态（`succeeded` / `failed`）的退款单，放行时间与放行人都要在 |

放行是人工动作，所以留痕是必须的：放行时间与放行人两个字段都得在，
否则事后没人说得清这笔钱是谁批的。

### 24.2 票码不许是券号派生的

源侧给了票码就用源侧的。源侧没给的时候，券号（`VC` + 日期 + 连号）以前被拿来当票码 ——
券号是连号的，**猜得到**；票码是闸机认的东西，猜得到就等于没有闸机。

016 的做法：

| 改哪 | 怎么改 |
|---|---|
| `fn_issue_voucher()` | 整体替换一次：源侧没给票码时生成 `VC-` + 32 位十六进制（`gen_random_uuid()`） |
| `v_invariant_checks_hardening` | 不变量 94：券的票码不许等于券号 |

券号留作内部标识：对外展示、对账、核销查的都是券号。
票码只在闸机前刷一次 —— 它的职责就是**不可猜**。

### 24.3 代价

出券时多一次随机数生成（可忽略），退款完成时多一道状态检查（可忽略）。
换来的是：放行是必经之路，票码不可猜。
这两条都不靠「调用方记得传对参数」，靠的是写路径自己挡住。
