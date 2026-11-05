# DDD 领域模型 — 多源票券中心

> 配套文档：`SPEC.md`（业务合同）· `docs/schema-design.md`（物理模型）· `docs/connector-contract.md`（接入端口）
> 本文所有表名、字段名均与 `db/schema.sql` 一一对应，可直接对照阅读。

---

## 1. 为什么这样切上下文

多源票券系统最容易犯的错，是把「源系统结构」直接泄漏进核心领域：
结果每个 GDS 都长出一套自己的商品表、自己的订单表，源一变全库跟着改。

本系统的切法是：**源是"上游系统"，不是"领域概念"**。

- 源系统的商品叫 `supplier_product`（源商品），我们的商品叫 `product`（规范商品）
- 源系统的订单不叫订单，叫 `booking`（向源预订）——它是**履约动作**，不是商业交易
- 源的原样报文永远关在 `supplier_raw_payload` 与 `supplier_product.raw_payload` 里，不外泄

商业上真正的「商品 / 价格 / 库存 / 订单 / 凭证」是我们自己的领域，与源数量无关。

---

## 2. 限界上下文（Bounded Contexts）

| 上下文 | 职责 | 聚合根 | 关键表 |
|---|---|---|---|
| **Integration** 集成 | 源注册、报文归档、同步作业 | `supplier` | `supplier`, `supplier_raw_payload`, `sync_job_log` |
| **Catalog** 目录 | 规范商品主数据、属性字典、归一化映射 | `product` | `product`, `product_translation`, `product_media`, `attribute_definition`, `attribute_mapping_rule`, `category`, `city` |
| **Supply** 供应 | 源商品/票种/场次/成本价 | `supplier_product` | `supplier_product`, `supplier_ticket_type`, `supplier_session`, `supplier_price_calendar` |
| **Pricing & Inventory** 价库 | 对客售价日历、库存快照、实时可用性缓存 | `price_calendar` | `price_calendar`, `inventory_snapshot`, `availability_cache`, `fx_rate` |
| **Channel** 渠道 | B端/C端渠道、上架、货源路由 | `channel_listing` | `channel`, `channel_listing`, `channel_listing_source` |
| **Transaction** 交易 | 订单、支付、退款 | `sales_order` | `sales_order`, `sales_order_item`, `sales_payment`, `sales_refund`, `customer` |
| **Booking** 预订 | 与源的预订交互（异步、重试、改派） | `booking` | `booking`, `booking_attempt`, `booking_event` |
| **Fulfillment** 履约 | 票券凭证、出票、核销 | `voucher` | `voucher`, `voucher_entitlement`, `voucher_redemption`, `gate`, `gate_operator` |
| **Settlement** 结算 | 结算单、结算行、对账 | `settlement_statement` | `settlement_statement`, `settlement_line`, `reconciliation_run` |
| **Notification** 通知 | 多通道发券/告警 | `notification_outbox` | `notification_outbox` |
| **Merchandising** 商品内容 | 详情页渲染内容、标签、评价 | `product_highlight` | `product_highlight`, `product_inclusion`, `product_note`, `product_location`, `product_review`, `tag`, `product_tag_link` |
| **Conversion** 转化 | 购物车、优惠券、实名表单、库存预占 | `cart` | `cart`, `cart_item`, `coupon`, `coupon_redemption`, `checkout_requirement`, `order_holder`, `inventory_hold` |
| **Read Model** 读模型 | C 端列表/日历的高频读取（CQRS 读侧） | `c_product_card` | `c_product_card`, `c_product_calendar` |

### 2.1 上下文映射（Context Map）

```
        ┌──────────────┐   ACL(防腐层)   ┌──────────────┐
        │ Integration  │ ──────────────> │   Supply    │
        │  源报文归档   │                 │ 源商品原样层 │
        └──────────────┘                 └──────┬───────┘
                                                │ 归一化(映射表)
                                                v
        ┌──────────────┐                 ┌──────────────┐
        │  Catalog     │ <────────────── │  Mapping     │
        │  规范商品     │                 │ 跨源去重     │
        └──────┬───────┘                 └──────────────┘
               │ 读
               v
        ┌──────────────┐        ┌──────────────┐
        │ Transaction  │───────>|   Booking    │──> 源 API
        │   订单聚合    │  Saga  │  独立聚合     │
        └──────┬───────┘        └──────────────┘
               │ 生成
               v
        ┌──────────────┐                 ┌──────────────┐
        │ Fulfillment  │ <────────────── │  Settlement  │
        │  凭证/核销    │                 │  对账/差异   │
        └──────────────┘                 └──────────────┘
```

**ACL（防腐层）的位置**：源报文 → 规范模型的转换只能发生在
`supplier_product` → `product_mapping` → `product` 这条路径上，
转换规则由 `attribute_mapping_rule` 配置驱动，**不允许在业务代码里散落 if-else 判断源**。

---

## 3. 聚合与不变量边界

### 3.1 聚合清单

| 聚合根 | 成员实体 | 一致性边界 | 为什么这么切 |
|---|---|---|---|
| `product` | ticket_type, media, translation, 属性值 | 单商品内 | 商品属性是同一份真相，不该跨商品写 |
| `product_variant` | product_variant_option, product_variant_relation | 单变体内 | 一个可售组合的轴取值必须自洽；变体与源变体的覆盖关系独立于变体本身 |
| `supplier_product` | supplier_ticket_type, supplier_variant, supplier_session | 单源商品内 | 源侧对象树，保证源结构完整不被拆散 |
| `product_session` | product_session_source | 单场次内 | 一个场次的可供给源集合是原子的，改派要一致 |
| `channel_listing` | channel_listing_source | 单上架内 | 上架与货源绑定必须同时生效 |
| `sales_order` | sales_order_item, payment, refund | 单订单内 | 金额自洽必须在一个事务里保证 |
| `booking` | booking_attempt, booking_event | 单预订内 | 重试与状态流转独立于订单提交 |
| `voucher` | voucher_entitlement, redemption | 单券内 | 权益扣减必须原子，防超用 |
| `settlement_statement` | settlement_line | 单结算单内 | 汇总金额需自洽 |

### 3.2 跨聚合引用一律用 ID + 快照

```sql
sales_order_item.detail_snapshot = {
  "title": "香港故宫文化馆 特展门票",
  "date": "2026-11-05",
  "slot": "10:00-12:00",
  "meeting_point": "特展入口 B2",
  "ticket_type": "成人票"
}
```

商品改名、改价、下架、源侧文案变更之后，历史订单详情必须原样可复现 —— 这靠快照，不靠 join 当前表。

### 3.3 为什么 Order 与 Booking 要拆成两个聚合

这是整个模型里最重要的一处决策。

| 维度 | Order | Booking |
|---|---|---|
| 一致性要求 | 强（金额、幂等） | 弱（可重试、可改派） |
| 失败语义 | 失败=业务失败，退款 | 失败=技术失败，换源重试 |
| 生命周期 | 秒级 | 分钟到小时级 |
| 跨系统边界 | 内部 | 外部（源 API） |

放一起的后果：源侧一次 3 秒超时，会把整个订单事务挂住，还会让「订单状态」和「源的状态」语义混淆。
拆开后：

- 订单提交只做本地事务 + 写 `event_outbox`，**不等待源**
- 预订失败 → `booking.failed` → 触发改派/退款/通知，**订单不受损**
- 源恢复后可通过 `booking.next_retry_at` 自动重报（DD 关心的「自动重报」）

---

## 4. 核心领域模型

### 4.1 归一化：三层结构

```
┌─ 规范层 (Catalog) ────────────────────────────────────┐
│ product          我们的商品：标题/描述/分类/地点/属性   │
│ ticket_type      我们的票种：成人/儿童/家庭            │
│ product_session  我们的场次：日期 + 时段               │
└────────────────────────────────────────────────────────┘
                         ▲  product_mapping
                         │  （多对多 + 置信度 + 证据）
┌─ 源层 (Supply) ───────────────────────────────────────┐
│ supplier_product      源商品（Ingresso 的 product、    │
│                       GlobalTix 的 package、票付通的   │
│                       goods —— 各叫各的）                │
│ supplier_ticket_type  源票种（item / spec / category）  │
│ supplier_session      源场次（departure / slot / 批次） │
│ supplier_price_calendar 源成本价                        │
└────────────────────────────────────────────────────────┘
```

**映射是多对多的**，原因：

- 一个源商品可能打包了多个我们的商品（源卖「双馆通票」，我们拆成两个 SKU）→ 允许 1 源 → N 规范商品
- 一个我们的商品可能由多个源供给 → N 源 → 1 规范商品

每个映射带 `match_type`（auto/rule/manual）、`confidence`（0~1）、`match_evidence`（判定依据 JSON），
支持「自动匹配先落 `pending_review`，人工确认后转 `active`」的审核流。

### 4.2 场次级冗余：多源不是只在商品级

只在商品级做多源不够 —— 源 A 有明天的场次，源 B 可能没有。
所以冗余下沉到**场次级**：

```
product_session (香港故宫, 2026-11-05, default)
   ├── product_session_source → globaltix  (role=primary,  priority=10)
   ├── product_session_source → jtb        (role=fallback, priority=20)
   └── product_session_source → 票付通     (role=fallback, priority=30)
```

下单前路由决策：`v_source_routing_candidates` 把
渠道 → 源 → 成本 → FX 归一 → 排序，一次查询给出首选与备选。

实测结果（C2C 渠道，香港故宫成人票 2026-11-05）：

| route_rank | 源 | 原币成本 | 折算 CNY | availability_mode |
|---|---|---|---|---|
| 1 | 票付通 | CNY 108.00 | **108.00** | push |
| 2 | globaltix | HKD 118.00 | 108.93 | live |
| 3 | goodfellows_jtb | HKD 125.00 | 115.39 | pull_sync |

注意：票付通虽然 `priority=30`（最靠后），但成本最低所以排第一。
**路由的排序键是「成本归一后的净值」，priority 只作同价时的 tiebreaker**。
如果业务上更看重稳定性而非最低价，改 `v_source_routing_candidates` 的 ORDER BY 即可，不用动数据。

### 4.3 变体：把「可售组合」从表结构里解出来

§4.1 的三层结构假设「一个商品 = 一个体验 × 若干票种」。环球影城打破了这个假设：
它卖的不是「一张成人票」，而是 **人群 × 票种 × 园区范围 × 加购件** 的组合。

#### 4.3.1 三步解法

```
product ──> product_variant ──> product_variant_option ──> product_axis_option
                │                                             (维度取值)
                ├──> product_variant_relation (可叠加：基础票 ← 快速通行证)
                │
supplier_product ──> supplier_variant ──> supplier_variant_mapping(coverage)
                                                │
                                                └──> product_variant
```

| 层次 | 表 | 职责 |
|---|---|---|
| 维度定义 | `product_axis` / `product_axis_option` | 哪些维度可变、每个维度有哪些取值（配置，不是 DDL） |
| 规范可售单元 | `product_variant` | 一个具体组合；**人群沿用 `ticket_type`，其余维度走轴** |
| 源可售单元 | `supplier_variant` | 源的 SKU（固定组合）或售卖方案（参数化） |
| 对齐 | `supplier_variant_mapping` | **覆盖**：源变体能满足哪些组合 |

#### 4.3.2 覆盖语义：源怎么跟变体对齐

两个源对同一商品的分解方式天然不同：

```
Trip.com：  TC-A1D-STD   成人 / 一日 / 单园区        ← 固定组合，精确命中
Zowoyoo：   ZWO-1D-BASE  人群∈{成人,儿童,老年} / 一日 / 单园区   ← 参数化，宽覆盖
```

所以映射不是一对一，而是**覆盖声明**：

```json
{
  "axes":     {"audience":["adult","child","senior"],
               "pass_type":["1d"],
               "park_scope":["studio_only"]},
  "excludes": []
}
```

判定规则（`fn_variant_covered`）：变体要求的每一项能力
（人群 + 各轴取值）都必须落在 `coverage.axes[axis]` 内，且不在 `excludes` 内。

这条规则是**「不能卖出履约不了的票」的技术保证**：
覆盖不全的源不会被路由选中，而不是先卖出去再在履约时失败。

#### 4.3.3 两个视图的分工

| 视图 | 粒度 | 用途 |
|---|---|---|
| `v_source_routing_candidates` | (商品, 票种) | 老商品的选源路径，保留不动 |
| `v_variant_routing_candidates` | (变体) | 新路径：强制做覆盖校验，覆盖不全的源直接不进候选 |

实测（北京环球影城，C2C 渠道）：

| 变体 | 首选源 | 备选 | 说明 |
|---|---|---|---|
| 成人·一日·单园区 | Zowoyoo ¥505 | Trip.com ¥545 | |
| 老年·一日·单园区 | **Trip.com ¥486** | Zowoyoo ¥505 | 同一商品，最优源与上面不同 |
| 儿童·一日·园区通票 | Zowoyoo ¥482 | — | Trip.com 没有儿童园区票，只有 1 个候选 |

而商品级视图对同一商品输出 **0 行** —— 两层结构表达不了这种商品。

#### 4.3.4 旧结构不是被推翻，而是被包含

「商品 × 票种」两层 = 只有人群一个轴的变体模型。迁移三步：

1. `(product, ticket_type)` → 生成一个 `base` 变体；
2. `supplier_ticket_type` → 生成一个源变体 + 1:1 精确覆盖映射；
3. 售价/成本价回填变体 id。

迁移后旧商品的变体路由结果与迁移前的商品级路由结果一致，
两套视图可以并存运行，直到调用方切换。

### 4.4 属性归一化：配置驱动而非代码分支

`attribute_definition` 是属性字典（管筛选 UI），`attribute_mapping_rule` 是映射规则：

| 属性码 | 源 | 源字段路径 | 变换 |
|---|---|---|---|
| duration_minutes | ingresso | `$.duration` | direct |
| duration_minutes | goodfellows_jtb | `$.durationMin` | direct |
| duration_minutes | piaofutong | `$.durationMinutes` | direct |
| age_limit | ingresso | `$.minAge` | wrap_min_age |

新增一个源，只加配置，不改领域代码。

### 4.5 快照与留痕的四层

| 层 | 表 | 作用 |
|---|---|---|
| 源报文 | `supplier_raw_payload` | 排障、对账、重放、字段漂移检测 |
| 源对象 | `supplier_product.raw_payload` | 源侧当前状态原样 |
| 映射证据 | `product_mapping.match_evidence` | 为什么这么归一 |
| 交易快照 | `sales_order.pricing_snapshot` / `sales_order_item.detail_snapshot` | 历史订单原样可复现 |

---

## 5. 状态机（详版）

### 5.1 Order

```
                    ┌──────────┐
                    │ created  │
                    └────┬─────┘
                         ▼
               ┌──────────────────┐
               │ awaiting_payment │
               └────┬────────┬────┘
          timeout  │        │ paid
                    ▼        ▼
              ┌──────────┐  ┌──────┐
              │ expired  │  │ paid │
              └──────────┘  └──┬───┘
                               │ 启动 saga
                               ▼
                     ┌──────────────────┐
                     │ booking_pending  │
                     └──┬───────────┬───┘
              booking  │           │  booking
              confirmed│           │  failed(全源不可用)
                        ▼           ▼
                 ┌───────────┐  ┌────────┐
                 │ confirmed │  │ failed │──> refunding ──> refunded
                 └─────┬─────┘  └────────┘
                       │ 部分出票       ▲
                       ▼               │
              ┌──────────────────┐     │
              │partially_fulfilled│────┘
              └────────┬─────────┘
                       │ 全部出票
                       ▼
                 ┌───────────┐
                 │ fulfilled │
                 └───────────┘
```

### 5.2 Booking

```
 pending ──发起──> requested ──源确认──> confirmed ──出票──> ticketed
    ▲                  │
    │ 可重试错误        │ 不可重试错误 / 业务拒绝
    │ (timeout,5xx)    ▼
    └────── next_retry_at   failed
                            │
                            ├──> cancelled（用户取消 / 超时未付）
                            └──> expired（源侧超时未支付）
```

`booking_attempt` 逐次记录请求/响应/耗时/错误分类，`booking_event` 逐次记录状态流转。
两者共同支撑「这个单为什么失败」的客服自助排查。

### 5.3 Voucher

```
 pending ──出票──> issued ──核销──> used
    │                │
    │                └──> expired（过有效期）
    └──> void（源侧作废）
 issued/used ──退款──> refunded
```

---

## 6. 领域事件与 Outbox

```
聚合内状态变更 ──> 同事务写 event_outbox ──> 发布器轮询 ──> MQ / 订阅方
```

`event_outbox` 与业务写在**同一事务**里，因此不会出现「订单确认了但事件丢了，通知没发」。

通知侧另有 `notification_outbox`，其 `channels` 字段是一个 JSON 数组，记录
每个通道（短信/Lark/邮件）各自的状态，支持**单通道失败不影响其他通道**并独立重试。

---

## 7. 值对象与领域服务

| 概念 | 落地方式 |
|---|---|
| 金额 | `NUMERIC(12,2)`，不用浮点；多币种由行级 `currency` 决定 |
| 时间 | 源侧本地时间存 `supplier_session.local_start_label` + `timezone`；统一时刻用 `timestamptz` |
| 币种换算 | `fx_rate` 快照（按 `as_of_date` 取最新），**不允许实时汇率**，保证成本可比与可复现 |
| 归一化指纹 | `product.canonical_key`（标题+地点+品类+时长的稳定哈希），自动聚类的锚 |
| 变体指纹 | `product_variant.variant_key`（人群 + 各轴取值的稳定拼接），去重与外部引用的锚 |
| 变体覆盖判定 | 领域服务 `fn_variant_covered(coverage, variant_id)`：源变体的覆盖声明是否完整覆盖规范变体的全部能力；`fn_variant_coverage_gaps` 给出缺口 |
| 计价基准 | `sales_order_item.pricing_basis`：`per_person`（总价 = 单价 × 份数）/ `per_group`（总价 = 团总价，与人数不成正比，团总价真值在明细快照 `group_total`）。`quantity` 始终是人数，实名与预占都依赖它 |
| 价格保护 | `supplier_variant.is_price_locked`（源侧是否受保护）+ `price_calendar.price_locked`（平台侧派生）。**锁价随采纳源变化**：同一变体改由非保护源供货即解锁 |
| 路由决策 | 领域服务，输入 (channel, product, date, ticket_type)，输出有序候选源列表 |

---

## 8. 已知取舍

| 取舍 | 选择 | 代价 | 何时该改 |
|---|---|---|---|
| 源商品拆成多个规范商品 | 允许（映射多对多） | 运营复杂度高 | 实际遇到打包拆分再开启审核流 |
| 库存 | 实时查 + 快照 + 缓存三层 | 三处数据可能打架，靠 `captured_at`/`expires_at` 判新旧 | 若源普遍不支持实时查，可砍掉 `availability_cache` |
| 售价 | 与源成本**分表** | 两表 join 才能看全貌 | 若只需要展示价，可合并 |
| 事件 | Outbox 模式（polling） | 有延迟 | 若吞吐要求高，可换 CDC |
| 商品 ID | `BIGINT IDENTITY` | 单库自增，跨库合并麻烦 | 若要多机房写入，改 UUID |
| 订单表 | 未分区 | 数据量大后清理困难 | 单表超 2000 万行时按 `placed_at` RANGE 分区（注意分区表的唯一约束须含分区键） |
| 维度建模 | 通用轴（`product_axis`）+ 按需实例化变体 | 变体行数随维度组合增长；运营要理解"轴/取值/变体"三层 | 若某些品类维度极多（如酒店房型），可把该维度的取值直接挂到 `product_variant.variant_key` 上跳过轴表 |
| 人群维度 | 沿用 `ticket_type` 而非新建轴 | 人群与"票种"两个概念容易混淆 | 若将来"学生票/军人票"等人群细分超过三层，再独立成轴 |
| 源对齐 | 覆盖语义（非一对一） | 一个源变体可对应多个规范变体，映射表比一对一大 | 若某源永远 1:1，`is_exact=true` 即可，不影响判定 |
| 变体级路由与商品级路由并存 | 两套视图并存，老商品走老路径 | 两套逻辑要同步维护 | 调用方全部切到变体级后，下线 `v_source_routing_candidates` |

---

## 9. C 端：为什么单独有一层读模型

供给侧模型解决的是「怎么把源接进来」，C 端模型解决的是「怎么把它展示出去、卖出去」。
两者的建模逻辑不同，不能用同一套表硬扛：

| | 供给侧模型 | C 端读模型 |
|---|---|---|
| 优化目标 | **准**（忠于源结构） | **快**（列表页扇出） |
| 数据形态 | 规范化、一份真相 | 反范式、可重建 |
| 新鲜度 | 各源各异 | 整卡同一次刷新 |
| 失败后果 | 算错成本 | 卡片与详情页对不上 |

读模型（`c_product_card` / `c_product_calendar`）由后台作业从主数据 + 价格 + 库存物化而来，
**主数据永远是唯一真相，读模型随时可重建**。
漂移检测见 `v_c_readmodel_drift`。

C 端展示内容（亮点/包含/须知/评价）与购买漏斗（购物车/优惠券/实名/预占）的完整说明，
见 `docs/c-end-model.md`。

---

## 10. 下一阶段的接口契约

见 `docs/connector-contract.md`：定义各 GDS 适配器必须实现的端口、错误分类、幂等与重试策略、
以及五家源在「商品模型 / 价格模型 / 场次模型 / 预订响应 / 取消规则 / 结算」六个维度的差异矩阵。
