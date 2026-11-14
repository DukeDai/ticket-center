# 供应源接入契约（Connector Contract）

> 本文定义**端口（Port）**与**适配器（Adapter）**之间的边界。
> §1–§8 是契约；**§9 是已落地的接入层实现**（Go，2026-11-05）。
> 各家 GDS 的字段、错误码、结算规则必须以其正式接入文档 / 商务合同为准；
> 文末差异矩阵中标注「待核对」的项即属此类。

---

## 1. 端口定义

适配器实现以下端口。端口是领域层与外部系统之间**唯一**的接触面。

```ts
// 端口：领域层定义，基础设施层实现（依赖倒置）
interface SupplierConnector {
  readonly supplierCode: string;

  // --- 目录 ---
  listProducts(cursor?: string): Promise<SupplierProductDTO[]>;
  getProduct(externalId: string): Promise<SupplierProductDTO>;
  getTicketTypes(externalProductId: string): Promise<SupplierTicketTypeDTO[]>;

  // --- 变体（多维商品的可售单元；无变体的源可以只返回一个「默认变体」） ---
  listVariants(externalProductId: string): Promise<SupplierVariantDTO[]>;

  // --- 场次与库存 ---
  listSessions(externalProductId: string, from: string, to: string): Promise<SupplierSessionDTO[]>;
  getAvailability(q: AvailabilityQuery): Promise<AvailabilityDTO>;

  // --- 价格 ---
  getPriceCalendar(externalProductId: string, from: string, to: string): Promise<SupplierPriceDTO[]>;

  // --- 交易 ---
  createBooking(req: BookingRequest): Promise<BookingResult>;
  cancelBooking(externalBookingId: string, req: CancelRequest): Promise<CancelResult>;
  getBooking(externalBookingId: string): Promise<BookingResult>;
  refund(externalBookingId: string, req: RefundRequest): Promise<RefundResult>;

  // --- 核销（可选，部分源不支持） ---
  validate?(code: string): Promise<ValidationResult>;
}

// 源侧可售变体：固定组合型源返回 SKU 列表，参数化源返回售卖方案（方案内部含可选参数）
interface SupplierVariantDTO {
  externalVariantId: string;
  title: string;
  // 源侧原始轴取值（不归一）：{"audience":"adult","passType":"1d","parks":["studio_tour"]}
  // 参数化源可给数组：{"audience":["adult","child"],"parks":["studio_tour","snw"]}
  variantAttrs: Record<string, unknown>;
}

// 源侧 Webhook 入口（每个源形态不同，但都归一到同一组事件）
interface SupplierWebhookAdapter {
  verifySignature(raw: Buffer, headers: Record<string, string>): boolean;
  parse(raw: Buffer): NormalizedWebhookEvent[];
}

type NormalizedWebhookEvent =
  | { kind: 'booking.confirmed'; externalBookingId: string; raw: unknown }
  | { kind: 'booking.cancelled'; externalBookingId: string; raw: unknown }
  | { kind: 'booking.failed';    externalBookingId: string; raw: unknown }
  | { kind: 'voucher.issued';    externalBookingId: string; vouchers: VoucherDTO[]; raw: unknown }
  | { kind: 'availability.updated'; externalProductId: string; raw: unknown }
  | { kind: 'unknown'; raw: unknown };
```

---

## 2. 错误分类（决定重试与否）

所有源错误必须归一到四类，**领域层只看分类，不看源细节**。

| 分类 | 语义 | 处理 | 举例 |
|---|---|---|---|
| `retriable` | 临时故障，重试有意义 | 指数退避重试，超过上限进死信 | 网络超时、5xx、限流 |
| `fatal` | 业务拒绝，重试无意义 | 立即失败 → 改派备源 | 库存不足、票种售罄、场次关闭 |
| `auth` | 鉴权问题 | 告警 + 暂停该源 + 不重试 | token 过期、签名错误 |
| `rate_limit` | 被限流 | 尊重 `Retry-After`，降速全局 | 429 |

**最关键的一条**：`fatal` 不能重试。把「库存被占位」当超时重试，是线上最容易犯的错
（重试也拿不到票，还把源侧库存搅乱）。种子数据里 `BK202610280003` 就是这个场景：
前两次 `timeout`（可重试），第三次 `STOCK_LOCKED`（`fatal`）→ 直接失败并触发改派。

---

## 3. 幂等与重试

### 3.1 双向幂等

| 方向 | 机制 | 落库位置 |
|---|---|---|
| 我方 → 源 | 每次逻辑预订生成稳定 `idempotency_key`，重试时复用同一 key | `booking.idempotency_key`（唯一索引 `ux_booking_idem (supplier_id, idempotency_key)`） |
| 源 → 我方 | Webhook 按 `external_booking_id` + 事件类型去重 | `idempotency_record`（scope, key） |

**规则**：一次逻辑预订的所有重试必须用**同一个** `idempotency_key`，
这样源侧才能识别为重复请求而不重复出票。改派到备源时，**必须换新 key**（因为是另一家供应商）。

### 3.2 重试策略

```sql
-- 待重试的预订（部分索引，只扫需要的行）
CREATE INDEX ix_booking_retry ON booking (status, next_retry_at)
    WHERE status IN ('pending','requested');
```

- 退避：`next_retry_at = now() + 2^attempt * base`，base 建议 30s，上限 30min
- 最大尝试次数：按源配置（`supplier.capability`）
- 每次尝试落 `booking_attempt`（请求、响应、HTTP 状态、耗时、错误分类）
- 超过上限 → `booking.failed` → 改派备源 → 全源失败 → 订单失败 + 自动退款 + 多通道通知

### 3.3 自动重报（DD 关注的点）

「付了钱没出票」是这个系统的头号客诉。除了重试，还要有**主动补报**：

```
定时作业：扫描 v_order_fulfillment_gap.suspected_lost = true
  → 若 booking 可重试 → 触发一次重试
  → 若 booking 已 failed → 触发改派
  → 若无 booking    → 补建 booking
  → 同时发多通道通知（短信 + Lark + 邮件，见 notification_outbox.channels）
```

---

## 4. 库存获取策略

由 `supplier_product.availability_mode` 决定，每个源商品一个值：

| mode | 含义 | 落地 |
|---|---|---|
| `live` | 实时查源 API | 调 `getAvailability`，结果写 `availability_cache`（短 TTL，如 60~300s） |
| `pull_sync` | 定时拉取落库 | 同步作业写 `inventory_snapshot`，查询读最新一条 |
| `push` | 源主动推送 | Webhook 落库，查询读最新一条 |
| `static` | 固定/不限量 | 视为不限量，直接跳过库存检查 |

**降级**：源不可用时（熔断打开），`live` 回落到 `inventory_snapshot` 最新值，
并标记数据陈旧度 —— 前端要能显示「库存数据更新于 X 分钟前」。

---

## 5. 归一化契约

适配器负责把源 DTO 翻译成平台 DTO。**翻译规则不许散落在业务代码里**。

### 5.1 属性归一（配置驱动）

```sql
INSERT INTO attribute_mapping_rule (attribute_code, supplier_id, source_path, target_path, transform, priority, enabled)
VALUES ('duration_minutes', 'ingresso', '$.duration', 'duration_minutes', '{"type":"direct"}', 10, true);
```

`transform` 支持的类型（首批）：
`direct` · `wrap_min_age` · `minutes` · `currency_convert` · `split_list` · `boolean_coerce`

新增源 = 加 `attribute_mapping_rule` 配置，**不改领域代码**。

### 5.2 票种映射

源票种 → 规范票种是多对多（一个源票种可能对应多个规范票种，反之亦然）。
`ticket_type_mapping.quantity_multiplier` 表达「1 张源票 = N 张规范票」
（例：源卖「家庭票」含 4 人，对应 4 张成人票）。

### 5.3 场次映射

`supplier_session`（源场次）→ `product_session`（规范场次）通过 `product_session_source` 建立，
允许一个源场次支撑多个规范时段（如源只有「上午/下午」，我们要拆成「09:30/11:00/14:00」）。

### 5.4 变体映射（多维商品专用）

`product_mapping` 是**商品级**的，回答不了「这个源能供哪些组合」。
多维商品（环球影城这种人群 × 票种 × 园区范围的组合）必须再走一层：

```
supplier_variant（源可售单元）──supplier_variant_mapping(coverage)──> product_variant（规范可售单元）
```

适配器要负责两件事：

1. **把源侧结构落成源变体**：
   - 固定组合型源（Trip.com）→ 一个 SKU 一个 `supplier_variant`；
   - 参数化源（Zowoyoo / 自由行）→ 一个售卖方案一个 `supplier_variant`，参数（人群/园区）落在 `variant_attrs` 里。
2. **声明覆盖范围**：`coverage.axes` 写明这个源变体能满足哪些轴取值，
   `coverage.excludes` 写明明确不含的。

**平台侧不替源做判断**：覆盖声明错了，`fn_variant_covered` 会把它挡在路由之外
（表现为「该组合没有可履约源」，由不变量 34 报警），而不是卖出履约不了的票。

### 5.5 认证方式（2026-11-04 核实）

> ⚠ **Trip.com 有两套完全不同的开放平台，方向相反，鉴权也完全不同，别混。**
>
> | 方向 | 平台 | 文档 | 鉴权 | 我们扮演 |
> |---|---|---|---|---|
> | **分销侧** | 门票活动**全球分销**接口文档 V2.0.25 | `open.trip.com/apiplatform/openapi.jsp?category=ttd_dist` | `aid`/`sid`/`key` → **refresh_token**（10 分钟有效） | **分销商**：从携程拿货、卖给自己客户 |
> | 供应商侧 | 门票活动开放平台 2.0 | `ttdopen.ctrip.com/apiplatform/ticket.jsp` | `accountId` + **AES-128-CBC** + MD5 签名 + `sequenceId` | **供应商**：把商品推给携程卖 |

> **本系统里 Trip.com 是供给源（我们从它买库存）→ 走分销侧那一套。**
> 供应商侧那套只在「我们反向把商品推给携程」时才用到。

#### 5.5.1 分销侧认证（Trip.com 作为供给源，用这一套）

> 已核对来源：`门票活动全球分销接口文档` V2.0.25（2026-10-28）OpenAPI 规格，server =
> `https://sopenservice.ctrip.com/openservice/serviceproxy.ashx`

接入前需向携程分销商务索取三个参数：**aid（联盟ID）· sid（站点ID）· key（安全码）**。

访问形态是 **URL query 传参**（不是 header、不是 body）：

```
GET/POST https://sopenservice.ctrip.com/openservice/serviceproxy.ashx
    ?aid=123&sid=456&icode=EBF3BCA6433340A090E22736DC667B31
    &uuid=683b-b072-944d-a39c-c85d-cdb6-636d31a33619
    &token=d13a8b751a96470b9df2fbf801780272
```

| 参数 | 含义 | 我们的对应 |
|---|---|---|
| `aid` | 联盟 ID | `supplier.auth_config.aid` |
| `sid` | 站点 ID（**Ctrip 站 / Trip 站不同**） | `supplier.auth_config.sid` |
| `key` | 安全码 | `supplier.auth_config.key` |
| `icode` | 接口编码，**每个接口一个且固定** | `supplier.capability` 里的端口方法 ↔ icode 映射 |
| `token` | 身份令牌，**先调 2.1 获取、2.2 刷新，有效期 10 分钟**，10 分钟内可用于所有接口；**同时用于接口访问频次限制** | `supplier.auth_config`（token 缓存 + 过期刷新） |
| `uuid` | 合作方自生成的 GUID，**每次请求不能重复**，用于携程记录请求日志 | 请求追踪位（≠ 业务幂等键，见下） |

**幂等位要分清两个概念**：

- `uuid` 是**请求级**唯一（每次调用都要新的），用途是日志追踪 —— **不是**幂等键。
- 业务幂等在携程侧靠 **`distributorOrderID`（分销商订单号）**：
  重复创建订单会返回 `B0010 重复的创建订单请求`。
  → 正好对应我们的 `booking.idempotency_key`：**同一逻辑预订的所有重试复用同一个键**，
  改派到另一个源必须换新键。

#### 5.5.2 Zowoyoo

| 源 | 协议 | 鉴权 | 幂等位 | 状态 |
|---|---|---|---|---|
| zowoyoo（Zowoyoo / 自由行） | REST | 需申请生产 API Key（流程见 §6.0） | 待核对 | ☐ |

### 5.6 携程商品结构 ↔ 我们的变体模型

> 已核对来源：分销侧 `productDetail` / `priceCalendar` 的 schema（产品→套餐→资源三级）
> 与供应商侧「票种/产品/套餐/资源 PLU」四层结构。

**分销侧的三级**：

| 携程分销侧 | 含义 | 我们对应 |
|---|---|---|
| Product | 产品（景点/日游/活动） | `product` |
| Package | 套餐 = **可选项组合**（座席+场次、票档+场次），门票品类下不含人群 | 我们的**轴取值组合**（不含人群） |
| Resource | 资源 = 套餐下的人群维度（`bandCode`），**唯一对应价格与库存** | **`supplier_variant`（源侧可售单元）** |

**供应商侧的四层**（上一轮核对的开放平台）：票种 → 产品 → 套餐 → **资源 PLU**。

两个直接可用的结论：

1. **携程的「销售属性」就是我们说的「轴」** —— 口径一致，说明我们的建模方向对得上。
2. **携程 resource ↔ 我们的 `supplier_variant` 是 1:1**（它已保证「唯一价格和库存」）；
   再由 `supplier_variant_mapping` **1:1 覆盖映射**到我们的 `product_variant`。
   换句话说：**携程的 (package × resource) 组合 = 我们的 `product_variant`**。
   固定组合型源的 `coverage` 天然完整，宽覆盖（`is_exact=false`）只出现在
   **参数化/聚合型源**（Zowoyoo / 自由行售卖方案）。

**逐字段对照**（接携程时的翻译表）：

| 携程字段 | 含义 | 我们落库 |
|---|---|---|
| `resource.bandCode` | 人群码：ADULT/CHILD/INFANT/SENIOR/OTHER/**STANDARD**/STUDENT/PREFERENTIAL/TEENAGE/FAMILY | `ticket_type.code`（按码对齐，我们每商品自定义） |
| `resource.unitQuantity` | 每份资源适用的人数 | `ticket_type_mapping.quantity_multiplier`（1 张源票 = N 张规范票） |
| `resource.saleAloneType` | 1 不限制 / 2 **不可单独购买** / 3 仅可单独购买 | `product_variant_relation.relation_type`（included / optional_addon） |
| `resource.isPrivatePrice` | **价格保护：对客卖价必须以携程卖价为准** | ⚠ 我们目前没有这条约束，见 §5.8 |
| `package.priceSettingType` | 报价类型：1 大小同价 / 2 按人群 / 3 **按人数阶梯** / 4 **按团** / 5 按团可加人 | ⚠ **按团报价时「总价 = 单价 × 份数」不成立**，见 §5.8 |
| `package.routeInfoList` | 线路条款（**仅日游产品**） | `product_variant` 的轴取值 / `product_note` |
| `getAllProduct` / `getAllPoi` | 全量增量：`lastMaxId` 游标 + `limit`(50~100) | 我们的同步作业 + 增量游标（⚠ 目前作业没存游标，见 §5.8） |

### 5.7 Trip.com 分销侧接口全貌（21 个接口，已核对）

> 全部 **POST**；请求体 JSON；URL 统一走 `serviceproxy.ashx` + query 传参。

| 章节 | 接口 | 我们的落点 |
|---|---|---|
| 3.1 | `searchProduct` 获取产品列表 | 目录同步 |
| 3.2 | `productDetail` 获取产品详情 | `supplier_product` + `supplier_variant`（package→轴、resource→变体） |
| 3.3 | `priceCalendar` 获取产品价格日历 | **`supplier_price_calendar`**（源变体 × 规范变体 × 日期） |
| 3.4 | `poiDetail` 获取 POI 信息 | `product_location` / 景点主数据 |
| 3.5 | `getAllProduct` 产品全量（增量游标） | 同步作业 |
| 3.6 | `getAllPoi` POI 全量（增量游标） | 同步作业 |
| 3.7 | `getIdByQueryId` id 查询 | 映射辅助 |
| 4.1 | `bookingVerify` 可订检查 | 下单前的价格/库存校验 |
| 4.2 | `bookingRequiredInfo` 获取下单填写信息 | **`checkout_requirement`**（实名/出行人动态表单的数据来源） |
| 4.3 | `book` 创建订单 | `booking`（带 `distributorOrderID` 幂等键） |
| 4.4 | `bookingStatus` 获取订单状态 | `booking` 状态同步 |
| 4.5 | `bookingDetail` 获取订单详情 | `booking` / `sales_order_item` 快照 |
| 4.6 | `cancel` 订单退订 | 退订流程 |
| 4.7 | `getVoucher` 凭证信息 | **`voucher` / `voucher_entitlement`** |
| 4.8 | `getCurrentLogistics` 物流查询 | 实物配送类商品履约 |
| 4.9 | `refundDetail` 退订明细查询 | 退款金额对账（`totalLossyAmount` 有损退） |
| 4.10 | `cancelVerify` 可退检查 | 退订前置校验 |
| 5.1 | `categories` 获取品类 | **品类字典**（门票/活动/向导…） |
| 5.2 | `locations` 获取位置 | `city` / 位置树（COUNTRY/PROVINCE/CITY） |
| 5.3 | `getCurrencies` 获取货币 | 币种清单（**一个分销账户仅支持一种币种**） |
| 5.4 | `getLocales` 获取语言 | locale 清单 |

**信息推送（Part J）—— 携程 POST 回调我们**：

| method | 事件 | 我们归一到 |
|---|---|---|
| `trip.distributor.order.change` | 订单行为变更（成交/退订成功/退订失败/改单成功/改单失败）、凭证变更 | `booking_event` + `booking.status` |
| `trip.distributor.order.verification.change` | 订单核销信息变更（`actualquantity`） | `voucher_redemption` |
| `trip.tour.tnt.distributor.poi.changed` | POI 上线/下线/信息变更 | 目录缓存失效 |
| 产品信息变更推送 | 商品变更（含证件/填写信息变更） | `supplier_product` 更新 |

推送报文格式：`{method, signature, timestamp, data(JSON字符串)}` → 我们返回 `{code, message, result}`。
**注意 `data` 是嵌套的 JSON 字符串**，解析时别当对象。`signature` 需要验签（对应我们的 `SupplierWebhookAdapter.verifySignature`）。
回调域名要**提前 5 个工作日**报备并加白。

**官方 SDK（可直接参考实现）**：<https://github.com/yizhanglyy-blip/open-distribution-sdk>

#### 5.7.1 错误码 → 我们的四分类（可直接落成映射表）

> 已核对来源：文档 6.1 错误码清单

| 我们的分类 | 携程错误码 |
|---|---|
| `retriable` | S0001 系统错误、S0002 系统超时 |
| `auth` | V0003 权限不足（另含 token 过期 / icode 错 → 需刷新 token 重取） |
| `fatal`（业务拒绝，重试无用） | B0001 下单失败、B0002 退订失败、B0003 订单资料填写错误、B0004 无效资源价格、**B0005 库存不足**、B0006 产品限购、B0007 超最大购买数量、**B0008 资源不可单独预订**、B0009 无效订单号、B0013 ResourceID 无效、B0014 Question 不匹配、B0015 重复的退订请求、B0016 产品不可预订、B0032 可选项只可单独售卖、B0039 超单订单最大份数、B0040 超最大购买订单数、**B0042 多资源使用日期不一致**、B0048 支付失败 |
| 幂等命中（不是失败） | **B0010 重复的创建订单请求** → 应按「查询已有订单」处理，不是报错 |
| `rate_limit` | 文档未给独立码（频次限制体现在 token 机制与 S0002）—— **待核对** |

**B0042「多资源使用日期不一致」值得单独说**：一个订单里多个资源必须同一使用日期。
这直接约束我们「一单多行明细（同一商品不同变体）」的模型 —— 变体级价格日历必须能保证同一订单内的变体同日可用。
已固化为不变量 35（见 §5.8）。

### 5.8 这次核实发现的模型缺口

> 下面 4 条都是**真实缺口**（有携程字段/错误码佐证），不是推测。
> 第 1、2 条已于 2026-11-04 定口径并落地（见 [`spec/09-pricing.md` §4.5](../spec/09-pricing.md)），第 3、4 条仍待处理。

#### 5.8.1 已解决

**✅ 1. 按团报价 vs「总价 = 单价 × 份数」**
`package.priceSettingType = 4/5`（按团报价、按团报价可加人）时，日游产品的价格**不是**每份单价 × 份数。

**落地口径**：`sales_order_item.pricing_basis`

| 取值 | `unit_price` | `total_price` | `quantity` |
|---|---|---|---|
| `per_person`（默认） | 每份单价 | `unit_price × quantity` | 份数 |
| `per_group` | **人均分摊价** | **团总价**（直接落库） | 团内人数 |

- 团总价真值记在明细快照 `detail_snapshot.group_total`（快照不可变，是历史真相）
- 允许每人 1 分以内的分摊取整误差：`abs(total_price - unit_price × quantity) ≤ quantity × 0.01`
- `quantity` 始终是**人数**（实名采集、库存预占都依赖它），不因按团而变成「团数」
- 连带把明细的 CHECK 约束 `order_item_total_ck` 改成按 `pricing_basis` 分支
- 不变量 5 改为分支校验，另加不变量 36（订单小计 = 明细金额之和）

种子数据构造了真实的按团报价链路：携程日游商品（`priceSettingType=4`，最少 6 人成团）
→ 团总价 1200.00 / 7 人成团 → 人均 171.43 → 订单 `TC20261103000006`。

**✅ 2. 价格保护（`isPrivatePrice`）**
携程明确：价格保护的资源，**分销商的对客卖价必须以接口提供的携程卖价为准**，不得自主加价。

**落地口径**：

| 层次 | 落地 | 含义 |
|---|---|---|
| 源侧事实 | `supplier_variant.is_price_locked` | 这个源变体受价格保护 |
| 平台侧派生 | `price_calendar.price_locked` | 这一行锁价，**由采纳源决定** |

- 不变量 37：锁价行的售价必须等于采纳源的挂牌价
- 不变量 38：采纳了价格保护源的售价行**必须**锁价（防漏锁擅自加价）

**关键语义**：锁价随**采纳源**变化，不是变体的固定属性。
种子数据里「北京环球影城 · 老年·一日·单园区」的最优源是 Trip.com（486 < Zowoyoo 505，受保护）
→ 该行锁价、售价原样 498.00；同一商品其余变体采纳 Zowoyoo（非保护源）→ 未锁、可自主定价。

#### 5.8.2 仍待处理

**⚠ 3. Ctrip 站 / Trip 站是两套数据集**
官方明说：Ctrip 经营简体中文产品、**仅支持人民币结算**；Trip 经营非简中多语言产品、支持多币种。
**一个分销账户仅支持一种币种**；`voucherUrl`（携程包装的凭证页）**仅 Trip 分销商可用，Ctrip 分销商请勿使用**；
文档另有独立的 10.1「CTrip 测试数据」。
→ 同一个 supplier 需要**站点维度**（`sid`）。**零 schema 改动的解法**：
在 `supplier` 表注册两个源 —— `trip_com_c`（Ctrip 站）与 `trip_com_t`（Trip 站），
`auth_config` 里各自放 sid/key。这样源能力、币种、语言、凭证能力天然隔离。

**⚠ 4. 组合履约：一个规范变体可能由多个源变体拼出来**
GlobalTix 的 SKU 映射表达式给出了现成的做法：
`80041201-8004120101|2+80041201-8004120102|1+80041902-8004190201|1+80041902-8004190202|1`
—— 官方示例正是「**环球影城日本入园票 + 快速通行证家庭套餐（2 成人 + 1 儿童）**」，
即**一个可售单元由 4 个源 SKU 组合而成**。
→ 组合表已落地：`supplier_variant_composition`（规范变体 ← 源变体 + 数量）+
`product_variant_relation.quantity`（规范侧组件声明），
路由与定价按组合评估成本与履约可行性（不变量 78-86）。
（注意：携程侧同一组合是**一个 SKU**，所以携程没有这个问题 —— 这是**源之间能力不对等**，不是我们模型的错。）

**⚠ 5. 同步作业没有增量游标**
携程全量接口是 `lastMaxId` + `limit` 的增量形态（`getAllProduct` / `getAllPoi`），
我们 `sync_job_log` 只存 `stats`，没有存「上次同步到哪」的游标 → 每次只能全量重拉。
→ 需要在同步作业上加游标字段（可先放 `sync_job_log.stats`，正式做法是加列）。

> **尚未核对**：限流与配额、token 刷新失败的重试策略、推送 `signature` 的具体算法、
> 分销佣金口径与结算单格式、5.4 语言清单与 6.3 币种清单的具体条目。

### 5.9 无凭证集成演练（mapping dry-run）

**为什么需要它**：拿不到 `aid/sid/key`、`Reseller ID/API Key` 之前，
「源报文 → 归一化 → 变体映射 → 路由」这条链路是**可以先验证**的 ——
凭证只影响最后一步的 HTTP 调用，不影响映射逻辑本身。

```bash
python3 scripts/mapping_dryrun.py                                  # 建演练库 → 建表 → 灌报文 → 出报告
python3 scripts/mapping_dryrun.py --json scripts/poc/data.json    # 额外导出结构化结果
python3 scripts/mapping_dryrun.py --poc scripts/poc/index.html    # 直接生成单文件前端 POC
```

演练库：`ticket_center_dryrun`（与主库隔离，**主库数据不受影响**）。

**组成**：

| 文件 | 作用 |
|---|---|
| `scripts/mapping_rules.json` | **映射规则配置**：每个源的报文路径、轴取值映射表、人群码映射、标志位 |
| `scripts/fixtures/canonical_catalog.json` | 我们自己的规范商品目录（商品 / 轴 / 取值 / 票种 / 变体） |
| `scripts/fixtures/trip_com_catalog.json` | Trip.com 分销侧报文集合：3 个源商品（门票多组合 / 按团报价日游 / 快速通行证）+ 3 份价格日历 |
| `scripts/fixtures/globaltix_catalog.json` | GlobalTix Supply API 报文集合：4 个源商品 + 组合 mappingId 表达式 |
| `scripts/mapping_dryrun.py` | 演练器：解析 → 覆盖语义匹配 → 落库 → 出报告 → 导出 JSON |
| `scripts/poc_page.py` | 前端 POC 渲染器（单文件 HTML，数据内嵌，离线可看） |
| `scripts/poc/index.html` | 生成物：变体映射 POC 页面 |
| `scripts/poc/data.json` | 生成物：演练结果的结构化输出 |

**纪律**：归一化规则全部来自 `mapping_rules.json`，**脚本里不出现任何按源分支的代码**
（对应 AGENTS.md 硬约束 4：源的结构不许泄漏进核心域）。新接一个源 = 加一段配置。

**归一化与组合映射都在 Go 侧**（`internal/normalize` / `internal/compose`，唯一实现）。
演练器只调 `tc-connect normalize` 与 `tc-connect compose`，然后读结果 ——
脚本里不再自带一份 Python 版覆盖判定或组合解析（两份实现必然分叉）。

**报告五段**：① 源报文 → 源变体与覆盖声明 ② 覆盖语义匹配 ③ 变体级路由 ④ 当前模型表达不了的源侧结构 ⑤ 不变量自检。

**前端 POC**：`scripts/poc/index.html`（单文件，数据内嵌，直接双击打开）展示五块内容：

1. **规范变体矩阵** —— 商品 → 变体 → 轴取值 chips，并标出每个变体「N 源可履约」
2. **覆盖语义匹配** —— 每个源变体 → 规范变体的映射 + `coverage.axes` 原文 + 判定
3. **变体级路由** —— `route_rank` / 源净价 / 折算成本 / 对客售价 / 锁价标记
4. **组合映射** —— 组合表达式解出来的配方（规范组件 ← 源 SKU / 两侧数量）与解不出的缺口
5. **不变量自检** —— 108 条逐条绿/红

顶部可按源（Trip.com / GlobalTix）筛选，统计卡片实时反映条目数。

**演练跑出来的实测结果**（2026-11-04，扩充后的完整集合）：

| 结论 | 证据 |
|---|---|
| 两个源的报文都能正确落成 `supplier_variant` + 覆盖声明 | Trip.com 10 个 resource、GlobalTix 7 个 SKU，共 17 个源变体 / 7 个源商品 |
| 覆盖语义匹配成立 | 17 条变体级映射，`fn_variant_covered` 全 true |
| 一个源商品可映射到多个规范商品 | GlobalTix 的 `80041201` 同时供给门票与快速通行证两个规范商品 |
| 同一变体多源时，**售价只由采纳成本最低的源决定** | `adult:1d:studio_only` → globaltix 520 胜出、trip_com 545 备选 |
| **锁价随采纳源变化** | `adult:1d:studio_snw` 只由 trip_com 供、该 resource 带 `isPrivatePrice` → 该行锁价；同一商品的其它变体采纳 globaltix → 未锁 |
| **组合履约确实表达不了** | GlobalTix 的 `...|2+...|2+...|1+...|1`（门票+快速券家庭套餐 2大1小）= 4 个源 SKU 组成一个可售单元，单个 `supplier_variant` 无处安放 |
| **组合现在能表达了**（2026-11-07 补上） | 同一份报文用 `tc-connect compose apply` 解析成 4 行配方（规范侧组件声明 + 源侧成分逐项对得上）；不变量 78-81 全 PASS |
| **组合现在能卖了**（2026-11-07 补上） | 成本 = Σ 成分单价 × 数量（成分取自源侧配方，不重新选源）；预订按配方带整组源 SKU；出券按成分张数发。卖不了的时候 `v_combo_price_gap` 逐条列原因（成分缺价 / 场次不同 / 源不同 / 价格锁定 / 按团报价） |
| **预订的单位是源 SKU**（2026-11-08 补上） | 参数化源里成人票与儿童票是**同一个**源 SKU（`ZWO-1D-BASE`，人群是购买时选的一档）。按成分建预订就是同一个源 SKU 订两次：源侧看到两张订单单，一条客户订单对两个源单号。改成一个源 SKU 一条预订，成分的拆分留在请求明细里 |
| 演练库 **不变量全 PASS** | 模型在真实报文结构下自洽 |
| 同一商品同一供应商只能一个 primary 映射 | 演练撞出 `ux_map_single_primary` 约束 → 映射生成逻辑按 (商品, 源) 去重 |

**演练暴露的两个额外规则**（都是落库时才撞到的，已写进脚本注释）：

1. **`price_calendar` 一个变体只能有一行**（唯一键 `ux_price_variant_scope`）——
   多源报价时必须先选采纳源再落售价，不能一个源一行。
2. **演练数据也必须守生产约束**：演练一开始给 `price_calendar.source` 写了 `'dryrun'`，
   直接被 `CHECK (source IN ('manual','sync','calc'))` 拒了 —— 说明约束在真实地拦人。

---

## 6. 七源差异矩阵

> ⚠️ **本表为设计假设，不是已核对的接入文档。**
> 每一行在实施前必须以该源的正式文档确认；已确认的请在「已核对」列打勾并附文档链接。

### 6.0 商品分解方式（决定要不要走变体层）

这是最关键的一列：**同一个商品，不同源的分解方式不同**。

| 源 | 分解方式 | 源侧可售单元 | 落到平台 |
|---|---|---|---|
| ingresso / fonticket | 单层票种 | 一个票种 = 一个可售单元 | 票种映射即可 |
| goodfellows_jtb | 单层票种 | 同上 | 票种映射即可 |
| globaltix | 固定组合 item | 一个 item = 一个组合 | 变体 1:1 精确映射 |
| piaofutong | 固定组合 spec | 一个 spec = 一个组合 | 变体 1:1 精确映射 |
| **trip_com** | **固定组合 PLU**（四层：票种/产品/套餐/资源） | 一个 PLU = 一个组合，**PLU 唯一对应价格与库存** | 变体 1:1 精确映射 ✅ 已核对 |
| **zowoyoo (Zowoyoo / 自由行)** | **参数化售卖方案 / 聚合层** | 一个方案覆盖多个组合；上游还连着 30+ OTA | 变体宽覆盖映射 ☐ |

参数化源的关键差异：**同一个源变体在成人/儿童/老年上的价格不同**，
所以源成本价必须落到「源变体 × 规范变体 × 日期」，
不能只按「源变体 × 日期」记一行。

### 6.1 商品模型

| 源 | 假定模型 | 商品主键 | 票种容器 | 已核对 |
|---|---|---|---|---|
| ingresso | `product` + `items[]` | 数字 id | `items[].id` | ☐ |
| fonticket | `event` + `categories[]` | 数字 id | `categories[]` | ☐ |
| goodfellows_jtb | `product` + `departures[]` | `productCode` | 独立规格接口 | ☐ |
| globaltix | `package` + `items[]` | 数字 id | `items[].itemId` | ☐ |
| piaofutong | `goods` + `specList[]` | `goodsId` | `specList[].specId` | ☐ |
| trip_com | 四层：票种/产品/套餐/**资源 PLU** | productCode + PLU | PLU（唯一价格库存） | ✅ 官方开放平台已核对 |
| zowoyoo (Zowoyoo / 自由行) | `goods` + `specList[]` + 可选参数（聚合层） | `goodsId` | `specList[].specId`（参数化方案） | ☐ |

### 6.2 价格模型

| 源 | 计价单位 | 币种 | 价格有效期 | 含税 | 已核对 |
|---|---|---|---|---|---|
| ingresso | 按日期 | BRL | 随商品窗口 | 待确认 | ☐ |
| fonticket | 按日期区间 | EUR | 整段窗口统一定价 | 待确认 | ☐ |
| goodfellows_jtb | 按出发日 + 票种 | HKD / JPY | 阶梯价 | 待确认 | ☐ |
| globaltix | 按日期 + item | HKD | `validityDays` 决定 | 待确认 | ☐ |
| piaofutong | 按 spec | CNY | 指定使用日 | 含税（演示数据按含税建模） | ☐ |
| trip_com | 按 SKU + 日期 | CNY | 随商品窗口 | 待确认 | ☐ |
| zowoyoo | 按 spec + 人群参数 | CNY | 指定使用日 | 待确认 | ☐ |

### 6.3 场次模型

| 源 | 场次粒度 | 是否绑票种 | 有容量概念 | 已核对 |
|---|---|---|---|---|
| ingresso | 出发日期 + 出发时间 | 否（票种在 items） | 有（maxPax） | ☐ |
| fonticket | 日期区间 + slot | 否 | 无 | ☐ |
| goodfellows_jtb | 出发日期 + 时间 | 否 | 待确认 | ☐ |
| globaltix | 使用日期 + 时段 | 是（item 维度） | 待确认 | ☐ |
| piaofutong | 使用日期 + 开始时间 | 是（spec 维度） | 无 | ☐ |
| trip_com | 使用日期（无固定时段） | 是（SKU 维度） | 待确认 | ☐ |
| zowoyoo | 使用日期（无固定时段） | 是（spec 维度） | 待确认 | ☐ |

**设计上的通用解法**：不管源怎么绑，`product_session`（规范场次）与 `product_session_source`（源绑定）
都是「场次 ↔ 源」的连接表，源侧绑不绑票种都不影响平台模型。

### 6.4 预订与取消

| 源 | 预订响应 | 是否异步确认 | 取消截止 | 部分取消 | 已核对 |
|---|---|---|---|---|---|
| ingresso | 同步返回预订号 | 待确认 | 待确认 | 否（假定） | ☐ |
| fonticket | 同步 | 待确认 | 待确认 | 否（假定） | ☐ |
| goodfellows_jtb | 同步 | 待确认 | 待确认 | 否（假定） | ☐ |
| globaltix | 同步 | 待确认 | 待确认 | **是**（能力已声明） | ☐ |
| piaofutong | 同步 | 待确认 | 待确认 | 是（能力已声明） | ☐ |
| trip_com | 同步 | 待确认 | 待确认 | 待确认 | ☐ |
| zowoyoo | 同步 | 待确认 | 待确认 | 待确认 | ☐ |

### 6.5 结算

| 源 | 账单形式 | 周期 | 佣金口径 | 已核对 |
|---|---|---|---|---|
| ingresso | 待确认 | postpaid（能力已声明） | 待确认 | ☐ |
| fonticket | 待确认 | postpaid | 待确认 | ☐ |
| goodfellows_jtb | 待确认 | monthly | 待确认 | ☐ |
| globaltix | 待确认 | monthly | 待确认 | ☐ |
| piaofutong | 待确认 | monthly | 待确认 | ☐ |
| trip_com | 待确认 | monthly | 待确认 | ☐ |
| zowoyoo | 待确认 | monthly | 待确认 | ☐ |

**平台侧统一口径**：`settlement_line` 一行挂一个 `booking`，
比对基准是 `booking` 当时的 `unit_cost`（快照，不可变）。
任何金额差异都落 `discrepancy_type` / `discrepancy_amount`，不做自动抹平。

---

## 7. 适配器实现清单

每实现一个源，需要交付：

- [ ] `SupplierConnector` 全部方法实现
- [ ] 错误 → 四分类的映射函数
- [ ] `attribute_mapping_rule` 配置（该源的全部属性）
- [ ] `ticket_type_mapping` 配置
- [ ] `supplier_variant` 落库 + `supplier_variant_mapping` 的覆盖声明（多维商品必做）
- [ ] `product_mapping` 的自动匹配规则（或人工匹配 SOP）
- [ ] Webhook 验签 + 事件归一
- [ ] 同步作业（目录/价格/库存）配置 + `sync_policy`
- [ ] `supplier.capability` 声明（哪些端口可用）
- [ ] 契约测试：固定报文 → 期望 DTO
- [ ] 熔断与限流配置

---

## 8. 尚未验证事项（诚实清单）

### 8.1 已核对

| 项 | 结论 | 来源 |
|---|---|---|
| trip_com 鉴权与幂等 | `accountId` + AES-128-CBC(body) + MD5 签名；`sequenceId` = 日期+GUID 做幂等 | 携程门票活动开放平台 2.0 官方文档 |
| trip_com 商品结构 | 四层：票种 / 产品 / 套餐 / 资源(PLU)；PLU 唯一对应价格与库存 | 同上 |
| trip_com 接入前提 | **需已签合同 + 供应商信息进携程供应商管理系统 + contractId + 携程分配接口参数 + 供应商接口地址备案/IP白名单** | 同上 |
| zowoyoo (Zowoyoo / 自由行) 接入流程 | Get In Touch → 注册 → 拿文档 → 测试 key → 申请生产 key → 上线；注册约 3-5 工作日、开发测试约 4-8 周 | zowoyooglobal.com/pages/api、/pages/technical |
| zowoyoo (Zowoyoo / 自由行) 定位 | 全球旅游资源整合平台，上游连 30+ OTA、200k+ 酒店 PMS、景点、支付 | zowoyooglobal.com/pages/technical |
| **ingresso** 鉴权与文档开放度 | 有 API 且 **OCTO compliant**（OCTO 标准全覆盖 + 更多）；**文档不公开** —— 需联系 commercial@ingresso.co.uk 索取文档 URL 与密码；接入前提是 mutual NDA + ticketing agreements 签署 | ingresso.co.uk/frequently-asked-questions、/api-documentation |
| **ingresso** 商务模式 | 两种：**Direct**（分销商直接与供应商签约付款）/ **Ingresso Managed**（ingresso 代签约代付，影响结算与对账口径） | 同上 |
| **goodfellows_jtb** 接入方式 | 走 JTB GMT 的 **hostConnect**（XML/API，集成进自有系统）；另一条 webConnect 是给旅行社用的 B2B 预订网站。**基于 OTA XML 标准模式（OTA 2010A）**；收到权限凭据 + 技术规格 + 支持文档后即可开发 | jtbgmt.com 服务页 |
| **globaltix** 接入方式 | 有 **Supply API**（采购侧）；凭证 = User ID (Reseller ID / x-agent ID) + Reseller Name + Username + Secret Key + **IP 白名单**；支持 **Price & Stock Sync Subscription**（价格库存订阅） | BookingMeta 帮助中心《Integrate with Global Tix via Supply API》（第三方公开接入实录） |
| **globaltix** 价格与库存口径 | **Settlement Cost Price**（我与 GlobalTix 的结算价）≠ **Recommended Selling Price**（建议零售价）；「有价格限制的商品」需遵守销售政策 —— 与携程 `isPrivatePrice` 同类机制 | 同上 |
| **globaltix** SKU 映射格式 | 组合表达式：`80041202-8004120203`（一对一）/ `...|2`（一份 SKU 映射多份）/ `A|2+B|1`（组合多个源 SKU） | 同上 |

**各家「公开度」一句话总结**：Trip.com 是唯一能把 OpenAPI JSON **直接下载**的；
其余都是「文档存在但要商务开口子」—— GlobalTix 有第三方公开的接入实录可抄，Ingresso 要密码，JTB 要凭据。

**GDS 侧的协议规律**：Ingresso 走 **OCTO**、JTB 走 **OTA XML 2010A** —— 这类源多半是 XML 而非 JSON。
我们的 `SupplierConnector` 端口不绑定序列化格式，一个源一个适配器即可。

### 8.2 仍未核对

1. **携程的采购侧接口**：分销侧 OpenAPI 已完整核对（§5.7）；
   但**供应商侧**（我们把票推给携程卖）那套 AES/MD5 的接口细节本次未展开，只核对了鉴权形态。
2. **fonticket（FonTicket / 丰趣科技）未找到公开的 API 文档**。公开信息只到产品线层面：
   FonTour（目的地资源管理与 B2B 分销，含 City Pass / 自由行组合包）、FonTicket（票务 SaaS）、
   FonPay（支付）、FonBoard（闸机/TVM）；战略上明确「open API + 分润模式」，
   且其库存已分销到 klook / KKday / Trip.com / GetYourGuide / WAUG 等。
   → **对接前必须找他们要 API 文档与接口清单**。
3. **票付通（福建票付通信息科技）未找到公开的 API 文档**。公开信息为业务事实：
   2014 年成立、覆盖全国 1 万+ 景区的云票务平台、宣称每秒百万级并发、
   有「优待人群智能核验系统」（残疾人证 / 退役军人证 / 学生证与国家级数据库实时对接）。
   → 其**人群维度 + 证件核验**能力与我们的 `ticket_type` + `checkout_requirement` 高度相关，值得优先对接。
2. **限流与配额未核对**（携程与 Zowoyoo 均未公开）。
3. **Webhook 事件语义未核对**（各源的"预订成功"事件名与字段）。
4. **结算单格式未核对**（CSV / XLSX / API 分页）。
5. **核销能力仅 ingresso 与票付通在演示配置中声明支持**，其余待确认。
6. **Zowoyoo 的接口清单、鉴权方式、结算条款未核对**；且「参数化方案」的参数是否真的能覆盖多个人群，
   需商务确认 —— 这直接决定 `coverage` 能不能按当前写法声明。
7. **聚合层的归一化边界（设计预警）**：Zowoyoo 上游连着 30+ OTA，我们看不到原始供应商结构，
   只能看到它归一化后的结果。对我们的影响：
   - `supplier_raw_payload` 归档的是 **Zowoyoo 的报文**，不是原始供应商报文；
   - `coverage` 声明必须基于 **Zowoyoo 自己的轴口径**，不能假设它与我们的轴一一对应；
   - 归一化链路变成 我们 → Zowoyoo → 上游，我们只对 Zowoyoo 这一层负责（它已替我们做了一层归一化）。
   好处是少接很多源，代价是**轴语义由它定义**，必要时要在它之上做二次映射。
8. **别去爬 C 端页面**。这两家都是 B2B 商务合作，走商务拿 key 是唯一可持续的路径；
   抓取既有合规风险，也无法保证字段与库存口径正确。

在拿到各家接入文档前，任何"这个源怎么接"的实现细节都是猜测。
本阶段交付的是**能容纳这些差异的骨架**，不是适配器本身。

---

## 9. 接入层实现现状（2026-11-05，Go）

> §1–§8 是**契约**；本节是**已落地的代码**。
> 实现语言：**Go 1.23+**（`cmd/tc-connect` + `internal/`），零第三方依赖。
> 目标：**拿到商务授权后直接跑测试，不需要再改结构。**
> 包结构与 CLI 细节见 [`integrations.md`](integrations.md)。

### 9.1 目录

```
cmd/tc-connect/              CLI：sources / layers / mock / normalize / compose / price
internal/
  apperr/                    错误四分类 + 缺失凭证 + 端点未确认
  credential/                凭证解析（环境变量优先 → supplier.auth_config）
  transport/                 HTTP 客户端：退避重试 / Retry-After / 脱敏
  config/                    传输层配置加载与校验
  normalize/                 归一化核心（配置驱动，无按源分支）—— **唯一实现**
  pricing/                   定价入口（读 fn_price_variant 的结果，**不算钱**）
  store/                     DB 访问（psql 子进程）+ 报文归档 + 幂等
  supplier/tripcom/          Trip.com 分销侧适配器
  supplier/globaltix/        GlobalTix Supply API 适配器（端点待商务确认）
  supplier/pending/          接口细节未核实的源的占位适配器
  registry/                  supplier.code → 适配器
  layertest/                 分层测试引擎 + 离线自检 + 协议自检
  inventory/                 库存：查可售 / 预占 / 放掉（只调库里的函数，不自己算可售数）
  compose/                   组合映射：解析组合表达式 → 配方（核组件、核数量；覆盖判定走库里的 fn_variant_covered）
  readmodel/                 C 端读模型：刷新 + 漂移检查 + 组合的售价行/日历格子同步（口径在库里的函数）
  variant/                   异构差异读侧：对照表 / 源覆盖缺口 / C 端读视图（含组合的构成）
  mock/                      Trip.com 分销侧协议 mock（标准库 net/http）
configs/api_config.json      传输层配置：端点 / 21 个 ICODE / 凭证口径 / 错误码映射
configs/mapping_rules.json   映射规则配置（接入层与演练器共用）
fixtures/                    真实报文结构的样例
```

**零第三方依赖**：HTTP 用标准库 `net/http`，DB 用 `psql` 子进程。

**归一化只有一个实现**（`internal/normalize`）：Python 侧的演练器通过
`tc-connect normalize` 消费它的输出，不再各写一份。

**定价也只有一个实现**（`fn_price_variant`，SQL 函数）：`internal/pricing` 只负责读结果，
Go 侧不做任何价格计算（标准库没有十进制类型，用 `float64` 接金额迟早差一分钱）。
演练器也不再用 Python 算钱 —— 全部落到库里算。详见 [`spec/09-pricing.md` §4.6](../spec/09-pricing.md)。

**选源也只有一个实现**（`fn_route_candidates`，SQL 函数）：路由视图与定价函数共用同一候选集与排序键，
所以「定价采用的源」与「路由选中的源」永远一致（不变量 43）。

**组合的售卖也只有一个实现**（[`spec/17-composition.md` §5.13](../spec/17-composition.md)，2026-11-07 落地）：
成本 = Σ 成分单价 × 数量，成分从**源侧配方**取（不重新选源）；
预订按配方带整组源 SKU；出券按成分应发的张数。
接入层拿到组合订单时，**按配方里的成分去拼请求**，不自己决定订哪个源 SKU ——
重新选源就出现「按 A 源的价格卖、按 B 源出票」。

**预订的单位是源 SKU**（[`spec/11-fulfillment.md` §5.6](../spec/11-fulfillment.md) 第四条 / [`spec/17-composition.md` §5.13](../spec/17-composition.md) 第五条，2026-11-08 修订）：
接入层向源侧下单时，**一个源 SKU 发一次请求**，不是每个成分发一次。
理由是源卖的是 SKU —— 参数化源里成人票与儿童票是同一个源 SKU，
按成分各发一次 = 同一个 SKU 订两次（源侧两张订单单，对账对不上）。
成分的拆分放在请求体的 `components` 里（那是给源侧看的说明），不决定发几次请求。
一条预订覆盖哪些成分由库里的 `fn_booking_components` 推出来，接入层不自己算。

**组合映射也只有一个实现**（`internal/compose`，2026-11-07 落地）：
源侧的组合表达式（`mappingId` 里用 `+` 与 `|` 表达「多个源 SKU 按数量组成一个可售单元」）
解析成配方，核上规范侧的组件声明与数量。覆盖判定走库里的 `fn_variant_covered`，
数量比选用 `math/big.Rat`（不用浮点），写库是幂等 upsert。
演练器不再自带一份 Python 版组合解析 —— 两份实现必然分叉。

**组合在 C 端也只有一个实现**（[`spec/17-composition.md` §5.14](../spec/17-composition.md)，2026-11-08 落地）：
组合源侧没有商品条目，目录同步作业看不见它 —— 它的售价行与日历格子由配方推出来
（`fn_sync_combo_calendar()`），构成进读模型（`c_variant_composition`）。
`internal/readmodel.SyncCombos` 只调库里的函数，`internal/variant.CompositionRows` 只读视图。
有效期终点 = 成分窗口的**并集**（不变量 89），人群只带**编码 + 份数 + 天数** ——
「2 成人 + 1 儿童」那句话由前端按 locale 拼，接入层不拼展示文案。

**可售数也只有一个实现**（`fn_available_qty` / `fn_reserve_qty`，SQL 函数，2026-11-07 落地）：
`internal/inventory` 只读结果，Go 侧不减库存、不判断够不够。
这一条对接入层尤其要紧 —— **源侧的库存口径各不相同**（`pull_sync` / `push` / 场次级 / 票种级），
我们自己的账只有一份：对账口径写死在库里的 `fn_available_qty`，
源差异由它统一吸收（取票种级快照 → 场次级快照 → 可用性缓存 → 不知道）。
接入层拿到源库存后只负责落库，不负责解释它。

### 9.2 端口实现现状

| 源 | 适配器 | 已实现的端口 | 状态 |
|---|---|---|---|
| **trip_com** | `tripcom.Adapter` | 取/刷 token、目录、详情、价格日历、字典（品类/位置/币种/语言）、全量增量、创建订单、订单状态/详情、退订、凭证 | ✅ 协议已核对，等凭证 |
| **globaltix** | `globaltix.Adapter` | 凭证齐备性校验、组合表达式解析、组合覆盖并集 | ⏳ 端点与请求体无公开文档 → 显式报「待商务确认」 |
| ingresso / goodfellows_jtb / zowoyoo / fonticket / piaofutong | `pending.Adapter` | 凭证齐备性校验、端点已配置时的 TCP 探测 | ⏳ 卡在商务/文档 |

**没有编造任何端点。** GlobalTix 的接口端点、请求体、字段名在 `api_config.json` 里留空并标注原因；
其余五源同理。适配器遇到未确认的接口一律抛 `EndpointUnconfirmed`，**明确说出卡在哪、需要什么**。

### 9.3 凭证获取方式（只从环境变量读）

凭证解析顺序：**环境变量优先 → 其次 `supplier.auth_config`（jsonb）**。
两者都没有 → 抛 `MissingCredentials`，**明确列出缺哪个环境变量**。
凭证**不入库、不进仓库、不进日志**；归档前对 `token / key / refresh_token / Authorization / password` 等字段脱敏。

| 源 | 环境变量 | 备注 |
|---|---|---|
| trip_com | `TRIPCOM_AID` `TRIPCOM_SID` `TRIPCOM_KEY` | 联盟ID / 站点ID（Ctrip 站与 Trip 站不同）/ 安全码 |
| globaltix | `GLOBALTIX_RESELLER_ID` `GLOBALTIX_RESELLER_NAME` `GLOBALTIX_USERNAME` `GLOBALTIX_API_KEY` | 另需把**出站 IP 加白名单** |
| ingresso | `INGRESSO_URL` `INGRESSO_USERNAME` `INGRESSO_PASSWORD` | 商务提供 |
| goodfellows_jtb | `JTB_USERNAME` `JTB_PASSWORD` | 商务提供 |
| zowoyoo | `ZOWOYOO_API_KEY` | 申请流程：注册 3-5 工作日 → 开发 4-8 周 |
| fonticket | `FONTICKET_API_KEY` | 需主动索取文档 |
| piaofutong | `PIAOFUTONG_API_KEY` | 需主动索取文档 |

### 9.4 Trip.com 端点（已核对）

| 用途 | 生产 | 沙箱 |
|---|---|---|
| 取 token | `https://openserviceauth.ctrip.com/openserviceauth/authorize.ashx?aid&sid&key` | `http://openservice.open.uat.ctripqa.com/openserviceauth/authorize.ashx` |
| 刷 token | `https://openserviceauth.ctrip.com/openserviceauth/refresh.ashx?aid&sid&refresh_token` | `https://openservice.open.uat.ctripqa.com/openserviceauth/refresh.ashx` |
| 业务 | `https://sopenservice.ctrip.com/openservice/serviceproxy.ashx?aid&sid&icode&uuid&token` | `https://openservice.open.uat.ctripqa.com/openservice/serviceproxy.ashx` |

21 个接口的 **沙箱 ICODE 与生产 ICODE 都已提取**到 `api_config.json`（从 OpenAPI 规格每个接口
description 里的「沙箱测试ICODE / 生产ICODE」表格）。

⚠️ **三个接口缺生产 ICODE**（规格只给了沙箱值 / 干脆没给），代码遇到时抛 `EndpointUnconfirmed`：
`getAllProduct`（3.5）、`getAllPoi`（3.6）、`getIdByQueryId`（3.7）。

### 9.5 错误四分类 → 实际处理

| 分类 | 携程错误码 | 适配器行为 | 对应契约 |
|---|---|---|---|
| `retriable` | S0001 系统错误、S0002 系统超时 | 指数退避重试（base 1s，翻倍，上限 30s，带抖动），最多 3 次 | §3.2 |
| `fatal` | B0001~B0048 绝大多数（**B0005 库存不足**、B0008 不可单独预订、**B0042 多资源同日**…）、V0001/V0002/V0004/V0005 | **不重试**，立即失败 → 触发改派备源 | §2 |
| `auth` | V0003 权限不足、1001/1002/1003/1004/1005 | 刷 token 后**最多再试 1 次**，仍失败即告警；绝不当作可重试错误 | §2 |
| `rate_limit` | 文档未给独立码（频次限制体现在 token 机制与 S0002） | 尊重 `Retry-After`，退避上限受 `backoff_cap` 约束 | §2 |

**幂等命中不是失败**：`B0010`（重复的创建订单请求）由分类器放行，适配器标记 `_idempotent_hit=true` 返回，
调用方应改查已有订单。`B0015`（重复退订）同理，但目前仍按 `fatal` 归档 —— **口径待商务确认**。

### 9.6 两处幂等，别搞混

| 层级 | 机制 | 落点 |
|---|---|---|
| 请求级 | `uuid` **每次请求都新的** | 只做携程侧日志追踪，**不是幂等键** |
| 业务级（我方→源） | `distributorOrderID` | 携程侧识别重复下单（返回 B0010） |
| 业务级（本地） | `idempotency_record(scope, key, request_hash)` | 适配器在 `create_booking` 前登记；同 key 同内容直接回放缓存响应，**不重复外呼**；同 key 不同内容报 `IdempotencyConflict` |

### 9.7 报文归档

所有真实调用落 `supplier_raw_payload`（`supplier_id / entity_type / entity_ref / direction /
request / response / http_status / latency_ms / trace_id`），**落库前递归脱敏**。
`entity_type` 取值：`product / price / booking / cancel / refund / auth`。

集成测试默认归档到独立库 `ticket_center_integration`，**不污染主库**。

### 9.8 跑法

```bash
make build                          # 构建 bin/tc-connect
make test                           # Go 单元测试
make mock                           # 协议级自检（本地 mock）
make counts                         # 打印各处文档引用的那些数（不变量条数 / 测试条数 / mock 断言数）
make layers                         # 分层连通性测试
make check                          # 提交前完整自检（vet + test + mock + 演练器）
```

也可直接用 CLI：

```bash
./bin/tc-connect sources                    # 已注册源与状态
./bin/tc-connect layers --supplier trip_com --env prod
./bin/tc-connect layers --offline            # 完全不外呼
./bin/tc-connect normalize --source trip_com --fixture fixtures/trip_com_catalog.json
./bin/tc-connect compose plan  --source globaltix --fixture fixtures/globaltix_catalog.json  # 组合配方解算（不写库）
./bin/tc-connect compose apply --source globaltix --fixture fixtures/globaltix_catalog.json  # 落库
./bin/tc-connect price --variant 11 --date <日期>      # 某变体某天的对客价（走库里唯一实现；日期现查：variant feed）
./bin/tc-connect price --reprice                          # 源成本/汇率变了 → 统一重算
```

`price` 子命令的价值是「所有入口给出同一个价格」：演练器、接入层、运维排查走的都是这一条路。
`--reprice` 重算后会列出没定上价的行（缺源报价 / 缺上架关系 / 缺汇率快照），有则非零退出。

**分层结果示例（无凭证，2026-11-05 实测）**：

```
【trip_com】
  ✓ L0 连通    业务：TCP openservice.open.uat.ctripqa.com:443 可连接（66ms）；认证：…:80 可连接（14ms）
  – L1 认证    缺少凭证：aid（环境变量 TRIPCOM_AID）；sid（环境变量 TRIPCOM_SID）；key（环境变量 TRIPCOM_KEY）
  – L2 目录    凭证缺失（见 L1）   … L3 / L4 / L5 / L6 同
```

**协议自检（4 项离线 + 10 项协议；断言条数跑 `make counts`）**：

| 断言 | 验证内容 |
|---|---|
| O1–O4 | 配置完整性 / 归一化自检 / 组合表达式解析 / 凭证脱敏 |
| M1 | 取 token（authorize 只调一次，token 缓存 600s） |
| M2 | query 参数齐全（aid/sid/icode/uuid/token）+ **uuid 每请求唯一** |
| M3 | `retriable`：前 2 次 S0001 → 第 3 次成功（退避重试生效） |
| M4 | `fatal`：B0005 只调 1 次（**不重试**） |
| M5 | `auth`：V0003 刷 token 后最多再试 1 次，**不当可重试错误** |
| M6 | `B0010` 识别为**幂等命中**，不是失败 |
| M7 | 报文归档落库 + **凭证零泄露** |
| M8 | 归一化 → 覆盖映射 → 路由全链路 |
| M9 | 业务返回 1004 → **自动刷 token** → 重试成功 |
| M10 | 同一 `distributorOrderID` 调 2 次 → 源侧只收到 1 次（本地幂等生效） |

### 9.9 这一轮核对新发现的两件事

1. **真实 `priceCalendar` 的报价是嵌套的**：`resource.calendarDetailList[]`，一天一条
   （`priceCalendar.CalendarDetail`：`date / netPrice / salePrice / currency / stock`）。
   之前的 fixture 把 `date/salePrice/netPrice` **平铺在 resource 上**，形状与真实 API 不一致 ——
   拿到真报文会解析不出价格。fixture 已改成嵌套形态，归一化同时兼容两种形态。
   → **一个源变体在多天上有多个报价行**，源成本价表的行数是「源变体 × 规范变体 × 日期」。
2. **`uuid` 不是幂等键**已在 §9.6 固化；另有 **业务层 B0010 幂等命中**的识别逻辑（分类器放行 + 单独标记）。

### 9.10 拿到授权后的验证清单

```bash
export TRIPCOM_AID=… TRIPCOM_SID=… TRIPCOM_KEY=…
./bin/tc-connect layers --supplier trip_com --env sandbox   # 先沙箱
./bin/tc-connect layers --supplier trip_com --env prod      # 再生产
```

要盯的四个点：

1. **2.1 取 token 的返回字段名**（`Access_Token` / `Expires_In` / `Refresh_Token`）与真实报文的差异；
2. **业务层 token 过期的错误码**（规格里是 `1004`，但业务错误码表只有 S/V/B —— 需实测确认是 `1004` 还是 `V0003`）；
3. **`searchProduct` 的必填参数**（`categoryIDList` / `destination` / `site` 的真实可用值）；
4. **价格日历是否真的返回 `calendarDetailList`**（若与规格不同，归一化要再改一处）。

