# Schema 设计说明 — 多源票券中心

> 物理模型：`db/schema.sql`（PostgreSQL 15+，可直接执行）
> 验收：`db/verify.sql`（38 条不变量断言 + 15 组业务视图）
> 结论先行：**选 PostgreSQL + jsonb 混合模型**。69 张表 / 14 张视图 / 198 个索引 / 18 个触发器 / 86 个 CHECK 约束。

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

---

## 4. 表清单（69 张）

### 4.1 集成域（3）
`supplier` · `supplier_raw_payload` · `sync_job_log`

### 4.2 目录域（8）
`category` · `city` · `product` · `attribute_definition` · `attribute_mapping_rule` · `product_translation` · `product_media` · `product_mapping`

### 4.3 供应域（5）
`supplier_product` · `supplier_ticket_type` · `supplier_session` · `supplier_price_calendar` · `ticket_type` · `ticket_type_mapping`

### 4.4 价库域（6）
`price_calendar` · `inventory_snapshot` · `availability_cache` · `fx_rate` · `product_session` · `product_session_source`

### 4.5 渠道域（3）
`channel` · `channel_listing` · `channel_listing_source`

### 4.6 交易域（6）
`customer` · `sales_order` · `sales_order_item` · `sales_payment` · `sales_refund` · `idempotency_record`

### 4.7 预订域（3）
`booking` · `booking_attempt` · `booking_event`

### 4.8 履约域（3）
`voucher` · `voucher_entitlement` · `voucher_redemption`

### 4.9 结算域（3）
`settlement_statement` · `settlement_line` · `reconciliation_run`

### 4.10 运维（2）
`event_outbox` · `notification_outbox`

### 4.11 视图（14）

| 视图 | 回答什么问题 |
|---|---|
| `v_product_source_coverage` | 哪些商品有多源冗余？覆盖度够不够？ |
| `v_product_source_compare` | 各源成本差多少？（已折算基准币种） |
| `v_source_routing_candidates` | 这一刻该选哪个源？首选和备选是谁？（商品 × 票种粒度） |
| `v_product_variant_matrix` | 这个商品到底有哪些可售组合？每个组合的轴取值是什么？ |
| `v_variant_source_coverage` | 每个组合有哪些源能供？缺什么？（`can_fulfil` / `gaps`） |
| `v_variant_routing_candidates` | 这个组合该选哪个源？（变体粒度，强制覆盖校验） |
| `v_order_fulfillment_gap` | 哪些订单「付了钱没出票」？ |
| `v_settlement_gap` | 哪些已确认预订没进结算单？ |
| `v_supplier_sync_health` | 哪个源在掉链子？ |
| `v_invariant_checks` | 38 条业务不变量有没有被破坏？ |
| `v_c_listing_feed` | C 端列表页直出（一行一卡片，无额外 join） |
| `v_c_product_detail` | C 端详情页内容一次聚合 |
| `v_c_checkout_requirements` | 结算页动态表单规格 |
| `v_c_readmodel_drift` | 读模型卡片与价格日历是否已不一致？ |

### 4.12 C 端域（18，见 `docs/c-end-model.md`）

**读模型（2）**：`c_product_card` · `c_product_calendar`

**展示内容（6）**：`tag` · `product_tag_link` · `product_highlight` · `product_inclusion` · `product_note` · `product_location` · `product_review`

**购买漏斗（6）**：`cart` · `cart_item` · `coupon` · `coupon_redemption` · `checkout_requirement` · `order_holder` · `inventory_hold`

**核销端（2）**：`gate` · `gate_operator`

> 加上 `ALTER TABLE` 补的 4 列（`sales_order.cart_id/coupon_id/discount_breakdown`、`voucher_redemption.gate_id/gate_operator_id`）。

### 4.13 变体域（8，详见 §5）

`product_axis` · `product_axis_option` · `product_variant` · `product_variant_option` · `product_variant_relation` · `supplier_variant` · `supplier_variant_mapping` · `c_variant_calendar`

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

### 5.4 新增表（8 张）

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
| `booking.supplier_variant_id` / `voucher.product_variant_id` / `voucher.supplier_variant_id` | 履约链路可追溯到具体组合 |
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

### 5.1 jsonb 的索引

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

### 5.2 可空维度的唯一索引（踩坑点）

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

### 5.3 关键查询路径

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

### 6.1 状态一律用 CHECK 枚举，不用 PG ENUM

```sql
status TEXT NOT NULL DEFAULT 'active'
  CHECK (status IN ('active','inactive','suspended','onboarding'))
```

理由：`ALTER TYPE ... ADD VALUE` 在旧版本 PG 里不能用在有默认值的列上，
且加值要等事务结束；`CHECK` 改起来是普通 DDL。
代价是状态多了要改约束 —— 用 `COMMENT ON COLUMN` 列出全部取值做补偿。

### 6.2 业务不变量就地约束

```sql
CONSTRAINT order_item_total_ck CHECK (total_price = unit_price * quantity)
CONSTRAINT sales_order_money_ck  CHECK (total >= 0 AND subtotal >= 0)
CONSTRAINT entitlement_qty_ck    CHECK (consumed_quantity >= 0 AND consumed_quantity <= quantity)
CONSTRAINT booking_retry_time_ck CHECK (next_retry_at IS NULL OR next_retry_at >= created_at - interval '1 minute')
CONSTRAINT coupon_usage_ck       CHECK (used_count >= 0 AND (usage_limit IS NULL OR used_count <= usage_limit))
```

跨行、跨表的不变量无法用 CHECK 表达，统一落到 `v_invariant_checks` 视图 + CI 断言。

### 6.3 IDENTITY vs 显式 ID

主键统一 `BIGINT GENERATED ALWAYS AS IDENTITY`。
种子数据用 `OVERRIDING SYSTEM VALUE` 显式指定 id，保证可重复、可阅读、可断言。

---

## 8. 索引与触发器清单（实测）

- 表 69 / 视图 14 / 索引 198 / 触发器 18 / CHECK 约束 87
- `updated_at` 由统一触发器 `fn_set_updated_at()` 维护，避免应用层漏更新

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

## 10. 已验证 / 未验证清单

**已在本机 PostgreSQL 18.6 实测通过：**

- `db/schema.sql` 在空库零错误执行
- `db/seed.sql` 完整装载（7 源 / 11 源商品 / 7 规范商品 / 11 映射 / 13 场次源绑定 / 6 订单 / 7 明细 / 6 预订 / 7 凭证 / 2 结算单 / 9 读模型卡片 / 9 日历格子 / 4 优惠券 / 4 购物车 / 4 库存预占 / 11 结算规格 / 10 持票人 / 6 评价 / 17 变体 / 25 源变体 / 29 覆盖映射）
- `db/verify.sql` 全部视图正常输出
- `v_invariant_checks` 38 条断言 **38/38 PASS**
- C 端读模型漂移检测：8 张卡片全部 `drifted=f`
- 变体级路由：环球影城 8 个变体 14 条候选，**同一商品不同变体首选源不同**
- 覆盖语义：儿童园区通票只有 Zowoyoo 一个候选；商品级路由视图对该商品输出 **0 行**

**尚未验证（需真实环境）：**

- 各 GDS 的真实 API 字段与错误码 → 见 `docs/connector-contract.md` 的差异矩阵（标注为「待核对」）
- 真实汇率来源与刷新频率
- 并发下的库存预占与超卖防护（需要压测与锁策略设计）
- 分区改造与只读副本的实际性能收益
