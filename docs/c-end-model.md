# C 端领域模型 — 展示与购买

> 配套：`SPEC.md`（合同）· `docs/ddd.md`（整体领域模型）· `docs/schema-design.md`（物理模型）
> 本文补的是 v1 建模里最大的一块缺口：**怎么把商品"展示"出去，怎么把它"卖出去"**。

---

## 1. 为什么这块不能算"API 层的事"

第一版设计把 C 端理解成「API + Web」，于是只做了供给侧（怎么把源接进来）。
但拆开看，C 端真正要做的事里，有一大半是**领域模型**，跟有没有 API 无关：

| C 端要做的事 | 是领域模型还是表现层 | 本次补的表 |
|---|---|---|
| 列表页展示「¥95 起 / 最近有票 / 免退」 | **领域模型**（读模型） | `c_product_card` |
| 日历条上每天的价格与余票 | **领域模型**（读模型） | `c_product_calendar` |
| 详情页亮点 / 包含项 / 使用须知 / FAQ | **领域模型**（内容） | `product_highlight` / `product_inclusion` / `product_note` |
| 商品在地图上在哪、怎么去 | **领域模型**（内容） | `product_location` |
| 用户评价 | **领域模型**（内容） | `product_review` |
| 筛选标签 | **领域模型**（内容） | `tag` / `product_tag_link` |
| 购物车 | **领域模型**（交易） | `cart` / `cart_item` |
| 优惠券 | **领域模型**（交易） | `coupon` / `coupon_redemption` |
| 实名信息要收哪些字段、怎么校验 | **领域模型**（交易） | `checkout_requirement` / `order_holder` |
| 购物车期间占住库存 | **领域模型**（交易） | `inventory_hold` |
| 景区闸机 / 核销员是谁 | **领域模型**（履约） | `gate` / `gate_operator` |

所以这块属于 schema 范围，不属于下一阶段的 API 范围。

---

## 2. 三块内容

### 2.1 读模型（Read Model）—— C 端能扛住流量的前提

**问题**：列表页一页 20-50 个卡片，每张卡要图、标题、评分、起价、可售天数、标签。
这些字段散在 `product` / `product_media` / `price_calendar` / `product_session` /
`inventory_snapshot` / `tag` 六张表里，实时 join 的成本随页大小线性上升。

更糟的是**数据新鲜度不一致**：
- 价格来自 `price_calendar`（可能是 5 分钟前的同步结果）
- 库存来自 `inventory_snapshot` 或 `availability_cache`（可能是 30 秒前）
- 商品标题来自 `product`（可能是 1 天前）

三者拼在一张卡上，用户看到「¥95 起」但点进去发现明天售罄 —— 这是最典型的差评来源。

**做法**：后台刷新作业把卡片需要的字段**物化**成读模型：

```
c_product_card (channel_id, product_id, locale)  ← 列表页一行一卡片
  title / subtitle / thumb / rating / from_price / list_price
  next_available_date / available_days / tag_labels / selling_points
  synced_at                                        ← 整卡的数据新鲜度，一目了然
```

关键点：
- **反范式是刻意的**。卡片表冗余标题、图、标签，换来「查询不打主表」。
- **按 (channel, product, locale) 建维度**。C 端中文站、B 端港代站、英文站各一份。
- **`synced_at` 是运营的救命字段**。卡片显示"价格更新于 X"还是"实时"，取决于这个。

配套的日历格子表：

```
c_product_calendar (channel_id, product_id, date)
  price_min / price_max / ticket_types / status
```

**为什么售罄日和闭馆日也要有格子**：前端要画灰、画删除线、禁用点击。
如果"没有这行"就等于"这天不存在"，用户根本不知道这产品未来一周只开了两天。
所以 `status` 枚举包含 `sold_out` / `closed` / `pending`，且 `price_min` 可为 NULL。

**读模型必须可重建**：主数据永远是唯一真相，读模型随时可以从主数据 + 价格 + 库存重算。
这条对应 `v_c_readmodel_drift` 视图 —— 检测卡片起价与价格日历是否已经不一致，
`drifted=true` 说明刷新作业漏跑了，可以直接接告警。

实测（种子数据，9 张卡片）：

| channel | product | locale | card_from_price | list_price | truth_min_price | drifted |
|---|---|---|---|---|---|---|
| C2C | 1 | zh-CN | 89.46 | 108.87 | 89.46 | f |
| C2C | 1 | en-HK | 89.46 | 108.87 | 89.46 | f |
| C2C | 3 | zh-CN | 188.96 | 218.63 | 188.96 | f |
| C2C | 7 | zh-CN | 1200.00 | 1200.00 | 1200.00 | f |
| B2B_HK | 1 | zh-HK | 92.04 | 107.87 | 92.04 | f |

注意 B2B_HK 的起价 92.04 ≠ C2C 的 89.46 —— **同一商品在不同渠道的起价不同**，
这正是 `channel` 存在的意义，也是 `price_calendar.channel_id` 唯一索引要带渠道维度的原因。

卡片上的价格不是各写各的：它们是 `fn_price_variant` 算出来后落到 `price_calendar` 的，
刷新作业（`fn_refresh_read_models()`）只是把最近 30 天的最小售价搬进卡片。
漂移检测把「卡片价 ≠ 价格日历最小价」标出来。

### 2.2 展示内容（Marketing Content）—— 详情页渲染什么

**纪律**（这一条直接决定了多语言能不能做）：

> 凡是"要按语言渲染给用户看"的文案 → 行级表 + `locale` 列。
> `product.attributes` 只保留**语言无关的结构化事实**。

| 内容 | 表 | 说明 |
|---|---|---|
| 亮点 | `product_highlight` | 卡片下方的三行卖点，详情页顶部 |
| 包含 / 不包含 | `product_inclusion` | `kind` 区分，前端分两栏渲染 |
| 使用须知 / 取消政策 / 换票方式 / FAQ | `product_note` | `kind` 区分，前端按 tab 渲染 |
| 地点坐标 / 集合点 / 交通 / 周边 | `product_location` | 一商品一行 |
| 评价 | `product_review` | 含图文、脱敏用户标识 |
| 筛选标签 | `tag` + `product_tag_link` | 运营侧维度 |

**第一版踩的坑**：我把「包含项目」塞在 `product.attributes.includes` 里。
结果三个问题：① 无法多语言；② 前端得猜字段名才知道里面是什么；
③ 没法区分「包含」和「不包含」。

现在 `attributes` 里只留结构化事实（时长、年龄门槛、可否手机出票、免票儿童数），
文案全部下沉到带 locale 的行级表。

**多语言怎么做**：每张内容表都有 `locale` 列，`(product_id, locale, kind, sort_order)` 建索引。
中文站查 `locale='zh-CN'`，英文站查 `locale='en-HK'`。
列表卡片则直接按 locale 物化成多行（`c_product_card` 的 PK 含 locale）。

实测 `v_c_product_detail` 一次聚合出全部内容：

| product_code | highlights | notes | inclusions | tags | reviews |
|---|---|---|---|---|---|
| SKU-HK-PALACE | 3 | 5 | 5 | 5 | 3 |
| SKU-CN-THEMEPARK | 1 | 2 | 3 | 2 | 2 |
| SKU-IT-DOGES | 0 | 0 | 0 | 1 | 0 |

### 2.3 购买漏斗（Conversion Funnel）

#### 购物车 + 库存预占

```
cart (cart_no, channel_id, customer_id, status, expires_at)
  └── cart_item (product_id, session_id, ticket_type_id, quantity, unit_price, price_snapshot, hold_id)
        └── inventory_hold (product_session_id, ticket_type_id, quantity, status, cart_id, order_id, expires_at)
```

`inventory_hold` 是这组的核心：**购物车 ≠ 占了库存，但结算页必须占**。
- `status`: `active` → `consumed`（下单成功）/ `released`（主动释放）/ `expired`（超时）/ `voided`（卖出后收回：退款 / 取消 / 订单超时）
- `expires_at` + 部分索引 `ix_hold_expiry ... WHERE status='active'`：定时作业扫过期释放
- 断言 21 保证预占数量与购物数量一致；断言 22 保证活跃预占必须挂在某个购物车或订单上（不能凭空占库存）

**预占的写路径与口径在 `db/migrations/009_inventory_hold.sql`**：
`fn_hold_inventory`（幂等键 `hold_no`，同键异内容报错）建预占，
`fn_available_qty` 是「还剩多少」的唯一实现，`fn_reserve_qty` 在锁内判断够不够。
下单时 `fn_place_order` 消费匹配的购物车预占（`active → consumed`），
没有就新建一条 `consumed` 的 —— **卖出多少是事实，必须查得到**。

`released` 与 `voided` 分开是有意的：`released` = 占过但**从未卖出**，
`voided` = **卖出后又被收回**。合成一个状态的话，退款与超卖的账永远算不清。

购物车项存 `price_snapshot`：加购时的价格快照，结算时价格变了要提示用户重新确认，
而不是静默按新价扣款。

#### 优惠券

```
coupon (code, channel_id, discount_type, discount_value, min_amount, max_discount,
        applicable_scope jsonb, validity jsonb, usage_limit, used_count, per_customer_limit, status)
coupon_redemption (coupon_id, order_id, customer_id, discount_amount, status)
```

`applicable_scope` 用 jsonb 存适用范围（品类/商品/票种 id 列表），因为这类规则变化频繁，
不该每次改规则都走 DDL。`usage_limit` / `per_customer_limit` / `used_count` 三者配合做限领。

订单侧：`sales_order.coupon_id` + `sales_order.discount_breakdown`（JSONB，区分券折扣与促销折扣）。
断言 24 保证「订单引用了券就必须有核销记录」，防止券被核销了但订单没记上。

#### 实名信息（结算表单）

这是 C 端最容易漏的一块。票券常按票种要求实名（成人要身份证、儿童要出生日期）。
**表单要渲染成什么样，得由数据定义，不能写死在前端。**

```
checkout_requirement (product_id, ticket_type_id, channel_id,
                      field_code, label, data_type, required,
                      max_length, pattern, min_age, max_age,
                      privacy_level, sort_order)
```

前端按这个渲染动态表单，后端按同一个定义校验 —— 一份定义，两处使用，不会漂移。
`privacy_level` 区分 `public` / `internal` / `sensitive`；`sensitive` 字段（如证件号）
在 `order_holder` 里只存哈希（`value_hash`），明文按合规要求加密或独立存储。

`order_holder` 与 `voucher.holder_snapshot` 的分工：
- `order_holder` = 下单时**采集的输入**（按 sequence 区分第几张票）
- `voucher.holder_snapshot` = 出票时**固化的快照**（凭证上显示什么）

快照不是出票时随手抄的：`fn_issue_voucher()`（`db/migrations/005_fulfillment.sql`）
按 `order_holder` 的 sequence 把人一一对上票码，票码数与要发的张数对不上当场报错。
「票发给谁」这件事只有一处实现，改它得同时改写路径和门禁。

断言 25 保证「要求实名的票种，持票人数必须等于票数」—— 少填一个人的票是最常见的出票事故。

C 端展示给用户的是**券号**（内部标识，对账与客服都用它），
闸机前刷的是**票码**。源侧没给票码时我们生成一个 128 位随机码，
不拿连号的券号顶上（`016` 收紧，不变量 94）—— 券号猜得到，票码必须猜不到。

`checkout_requirement.channel_id` 可为 NULL（所有渠道通用）或指定渠道。
种子数据里 P1 的实名要求只对 C2C 生效，B2B 分销商代客下单不需要 —— 这就是渠道维度的价值。

#### 核销端

```
gate (code, name, location_name, latitude, longitude, supplier_id)      ← 景区闸机 / 门店柜台
gate_operator (gate_id, code, name)                                      ← 核销员
voucher_redemption.gate_id / .gate_operator_id                            ← 核销记录关联
```

`voucher_redemption.operator_id`（TEXT）是**源侧**的操作员标识，与本地 `gate_operator` 并存不冲突：
一个核销动作可能同时有本地核销员和源侧流水号。

核销的**写路径**已经落地（2026-11-07）：扫一次票只走库里的 `fn_redeem_voucher()`
（`db/migrations/008_redemption.sql`），Go 侧是 `internal/redemption`。
口径：一次扫票一条记录（重复扫票记 `duplicate`，不覆盖事实）；
一张券最多成功核销一次（唯一索引 `ux_redemption_single_success` 兜底）；
过期 / 作废 / 未出票的券不认，但都要留记录写清原因。
详见 [`SPEC.md` §5.8](SPEC.md)。

### 2.4 变体层：多维商品在 C 端怎么卖（2026-11-04 补充）

**问题**：环球影城不是一个商品，是一堆组合 —— 人群 × 票种 × 园区范围 × 加购件。
如果 C 端只有 `(product, ticket_type)` 两级，用户在选择器里根本没法表达
「我要一张成人一日园区通票」，库存也管不住（园区票和基础票配额不同）。

**做法**：把「可售单元」下沉为变体，C 端多一层选择器。

```
v_product_variant_matrix           ← 详情页渲染变体选择器的数据源
  一个商品下每个变体：人群 + 各轴取值 + 可叠加的加购件

c_variant_calendar (channel_id, product_variant_id, date)
  price_min / price_max / status / source_count
```

三处必须跟着变体走：

| 环节 | 字段 | 为什么 |
|---|---|---|
| 日历 | `c_variant_calendar` 按变体出格 | 同一天不同变体价格不同、可履约源数不同（儿童园区通票只有 1 个源） |
| 购物车 | `cart_item.product_variant_id` | 同一商品同一票种可以同时存在多个变体（基础票 + 园区升级），旧的购物车唯一键挡不住 |
| 库存预占 | `inventory_hold.product_variant_id` | 园区票与基础票是**两套配额**，混在一个池子里必然超卖 |
| 结算实名 | `checkout_requirement.product_variant_id` | 儿童票要出生日期、成人票要证件号，规则挂在变体上 |
| 订单明细 | `sales_order_item.product_variant_id` | 一单可以包含同一商品的多个变体（成人园区通票 + 儿童园区通票） |

**卡片起价不能把加购件算进去**：快速通行证 ¥398 不是「入场起价」。
`v_c_readmodel_drift` 已排除 `variant_role='addon'` 的变体。

实测（北京环球影城，C2C 渠道，2026-11-18）：

| 变体 | 售价 | 可履约源数 |
|---|---|---|
| 成人 · 一日 · 单园区 | ¥585.80 | 2 |
| 儿童 · 一日 · 单园区 | ¥484.88 | 2 |
| 老年 · 一日 · 单园区 | ¥498.00（锁价） | 2 |
| 成人 · 一日 · 园区通票 | ¥640.32 | 2 |
| 儿童 · 一日 · 园区通票 | ¥559.12 | **1**（只有 Zowoyoo） |
| 成人 · 双日 · 单园区 | ¥992.96 | 2 |
| 儿童 · 双日 · 单园区 | ¥888.56 | **1**（只有 Zowoyoo） |
| 快速通行证（加购件） | ¥392.08 | 2 |

「可履约源数」这一列是给前端的关键信号：**只有 1 个源的组合没有备源，
源一挂就变不可售**，前端应该在选择器上做提示。

### 2.5 按团报价商品在 C 端怎么展示（2026-11-04 补充）

日游的「按团报价」商品，**起价不是每人价，是团总价** —— 直接显示「¥1200 起」会误导用户。

| 展示位 | 正确做法 |
|---|---|
| 列表卡片 `from_price` | 记**团总价**，但必须同时展示起订人数（如「¥1200 起 · 6 人起订」） |
| 变体日历 | 同样以团总价出格，`source_count` 反映可履约源数 |
| 加购 | 购物车项的 `quantity` 是**人数**，不是团数；下单才校验是否达到起订人数 |
| 结算 | 按团的总价直接展示，不展示「单价 × 人数」的推算 |

**为什么 `quantity` 必须是人数**：实名采集（`order_holder`）与库存预占（`inventory_hold`）
都以「份数 = 人数」为口径。若按团时把 `quantity` 记成团数，断言 25（持票人数 = 票数）
与库存预占口径都会失真。所以团总价只影响**金额**，不影响**份数语义**。

**锁价对 C 端无感**：价格保护是「采纳源」的属性，锁价行的售价已原样等于源方挂牌价，
前端照常展示即可；区别只在平台不能自主加价。

### 2.6 有效期在 C 端怎么展示（2026-11-07 补充）

单日票与两日票的价格不一样、可用日期不一样，**有效期窗口也不一样**。
C 端必须把这个差异显示出来，否则用户会按「当天有效」理解两日票，
第二天拿着票到门口才发现进不去 —— 这是最贵的一种客诉。

| 展示位 | 数据来源 | 说明 |
|---|---|---|
| 变体选择器 | `v_product_variant_matrix.axes`（含 `valid_days`） | 选项标签带上「1 日 / 2 日」 |
| 变体日历 | `v_variant_validity` | 给出 `valid_from` / `valid_to` / `valid_days` |
| 差异对照 | `v_variant_comparison` | 两个可售单元差在哪（人群 / 轴 / 有效期 / 退款口径 / 可用源） |
| 下单后 | `voucher.valid_from` / `valid_to` | 用户看到的最终窗口，以券为准 |

**有效期长度是轴选项上的数据**（`product_axis_option.valid_days`），
唯一读法是库里的 `fn_variant_validity_days()`。
前端不许自己「日期 + 1」—— 应用侧加一天和库里加一天，早晚有一天对不上。

### 2.7 差异走到读模型（2026-11-07 补充，缺口已补上）

上一节留的缺口已经补上：**C 端读模型现在带差异事实了**。

| 展示位 | 数据来源 | 说明 |
|---|---|---|
| 变体行 | `v_c_variant_feed` | 人群 / 轴取值 / 有效天数 / 退款口径 + 本渠道价格区间与可售天数，一行一变体 |
| 日历格子 | `c_variant_calendar.valid_to` | 有效期终点由库算好（格子日期 + 有效天数），前端不自己加一天 |
| 事实表 | `c_variant_facts` | 读模型的底稿：渠道 × 可售单元 |

三条口径：

- **差异不许在请求链路里 join 出来。** 请求链路只读 `c_variant_facts` /
  `c_variant_calendar`，不碰主数据（硬约束 10）。
- **事实只写一份。** 每个字段都从 `v_variant_comparison` 取，不重算有效天数、不重算轴取值 ——
  重算就是第二份实现。
- **读模型不许与主数据分叉。** 不变量 76 逐字段比对，刷新作业漏跑当场报出来；
  不变量 77 保证日历格子的有效期终点没被算错。

### 2.8 组合套餐在 C 端怎么展示（2026-11-07 补充，2026-11-08 展示口径已定）

异构融合的第二个方向（一个可售单元由多个源 SKU 按数量组成）现在有模型了：
规范侧 `product_variant_relation` 声明组件与数量，源侧 `supplier_variant_composition` 给配方
（不变量 78-81 守着两侧逐项对得上）。

C 端要展示套餐，「里面有什么、各几个」这条事实住在组合变体上：

| 展示位 | 数据来源 | 说明 |
|---|---|---|
| 组合行 | `v_c_variant_feed` | 组合变体与普通变体一样出现在变体行里，另带 `is_combo` / `combo_audience` / `component_count` / `composition` |
| 组件清单 | `v_c_variant_composition` | C 端的成分明细：一行一个成分（份数 / 人群编码 / 各管几天） |
| 配方对照 | `v_variant_composition` | 组合 / 组件 / 源 SKU / 源侧数量 vs 声明数量（B 端对账用） |
| 差异对照 | `v_variant_comparison` | 组合与普通变体的差异（人群取并集、轴取值取并集） |

**写路径已经接上组合了**（`SPEC.md` §5.13）：定价（成本 = Σ 成分单价 × 数量）、
预订（按配方带整组源 SKU）、出券（一个成分发该成分应发的张数）、
实名（`item_index` 指明属于哪一行）都做完了。

**展示口径也定了**（`SPEC.md` §5.14，2026-11-08）：

1. **组合的售价行与日历格子由配方推出来。** 组合源侧没有商品条目，
   目录同步作业看不见它 —— 所以 `fn_sync_combo_calendar()` 按成分的售价行推出组合的售价行
   （金额走定价函数的组合分支），再推出日历格子。
   `tc-connect refresh` 先同步组合再刷新。
2. **有效期终点 = 成分窗口的并集**（最长的那个）。
   2 份两日成人 + 1 份一日儿童 = **2 天**；2 份一日成人 + 1 份一日儿童 = 1 天。
   取最短就是第二天进不去，取相等多赔客户一天（不变量 89）。
3. **人群不选标签，带编码。** 组合不带「家庭」标签，
   带的是每个成分的人群编码 + 份数 + 各自的天数：
   `[{adult, 2.00, 2}, {child, 1.00, 1}]`。
   「2 成人 + 1 儿童」这句话由**前端按 locale 拼** ——
   展示文案不进模型（硬约束 9：展示文案一律行级表 + `locale` 列）。

所以组合现在与普通变体一样出现在日历上，只是组件清单多一段。
`tc-connect variant composition --variant 18 --channel 1` 看它由谁组成。

**成分明细是按渠道读的。** C 端读模型是按渠道建的：一个套餐上了两个渠道
就有两份成分明细。不按渠道过滤，「2 份成人 + 1 份儿童」会被数成两遍 ——
详情页显示 4 份成人，实际只发 2 份。

### 2.9 套装在 C 端怎么展示（2026-11-09 补充）

异构融合的第三种形态：**源侧把整套当一个 SKU 卖**。
从 `coverage` 看不出一个源 SKU 是「一整套」还是「一张谁都能用的票」，
所以套装单独声明（`supplier_variant_bundle` + `supplier_variant_bundle_part`）。

对 C 端来说，套装与配方型组合的展示几乎一样 —— 都是「一套里有啥、各几个」：
成分清单走 `v_c_variant_composition`（读模型里的 `c_variant_composition`），
有效期终点走 `c_variant_calendar.valid_to`（仍由 `fn_variant_validity_days` 算，
前端不自己加一天）。

套装多出来的是**可售性的口径**：

| 展示位 | 数据来源 | 说明 |
|---|---|---|
| 套装行 | `v_c_variant_feed` | 与普通变体一样出现在变体行里，带 `is_combo` / `component_count` / `composition` |
| 成分清单 | `v_c_variant_composition` | 一行一个成分（份数 / 人群编码 / 各管几天） |
| 套装供给形态 | `v_variant_bundle` | 源侧整套 SKU、整套有效期 vs 成分窗口、缺口诊断 |
| 缺口诊断 | `v_bundle_gap` | 哪几天卖不掉、为什么（没有报价 / 没有场次 / 有效期盖不住 / 可售数未知） |

**套装的售卖单位是套，展示的是份。** 一套「2 成人 + 1 儿童」= 1 套 / 3 份入场。
C 端下单页写「1 套」，下单后发三张入场券 —— 不变量 99 守着这条
（入场份数 = 套装声明的份数 × 套餐份数）。

**有效期终点仍由库算。** 套装的整套有效期是源侧声明的
（`supplier_variant_bundle.valid_days`），必须盖住成分窗口的并集；
C 端的 `valid_to` 不另算一遍。

**「这一套卖不掉」要说清原因，不许只显示一个空的日历格子。**
`v_bundle_gap` 按天列原因，前端按 locale 拼文案（硬约束 9）。

---

## 3. C 端的完整链路（对应种子的数据）

```
① 浏览           v_c_listing_feed → 9 张卡片（C2C 7 商品 + 英文版 + B2B_HK）
② 详情           v_c_product_detail → 亮点/须知/包含/标签/评价/地点 一次聚合
③ 选变体         v_product_variant_matrix → 人群/票种/园区范围/加购件 的组合选择器
④ 看日历         c_product_calendar + c_variant_calendar → 含 sold_out / closed 格子
⑤ 加购          cart + cart_item + inventory_hold（变体级占库存，带 TTL）
⑥ 结算          v_c_checkout_requirements → 动态表单；coupon 校验
⑦ 下单          sales_order(coupon_id, discount_breakdown) + order_holder（实名）
⑧ 支付          sales_payment
⑨ 出票          booking → voucher（记源变体，可追溯到具体组合）
⑩ 核销          voucher_redemption + gate + gate_operator
```

每一步都有对应的断言把住（21-26 与 27-34），不靠人工盯。

### 卡片上的价格从哪来

```
源成本（supplier_price_calendar）
   └─ 快照汇率折算 → 成本
        └─ 定价函数 fn_price_variant（唯一实现）→ 售价 / 划线价 / 折扣
             └─ price_calendar（落库）
                  └─ 刷新作业 → c_product_card.from_price / list_price
```

四层各司其职，任何一层都不许自己算一遍：

| 层 | 职责 | 谁负责刷新 |
|---|---|---|
| `supplier_price_calendar` | 源方原始报价（原币） | 接入层同步作业 |
| `price_calendar` | 折算后的成本与对客售价（默认行基准币种，渠道专属行按该渠道结算币种） | `fn_reprice_rows()` |
| `c_product_card` | 卡片起价与划线价（近 30 天最小价）+ 最近可售日 + 可售天数 | `fn_refresh_read_models()` |
| `c_variant_calendar` | 变体当日的价格区间与可履约源数 | `fn_refresh_read_models()` |

读模型刷新的口径写在库里的 `fn_refresh_read_models()`（`db/migrations/002_read_model_refresh.sql`），
种子、演练器、接入层、定时作业都调它 —— **口径只有一份**。
若刷新用的口径与漂移检测用的口径各写一份，刷新完还会被判成漂移，等于自己告自己。

```bash
tc-connect refresh              # 刷新读模型，并报告漂移
tc-connect refresh --check      # 只查漂移（刷新作业漏跑时非零退出）
```

刻意不做：新建日历格子（格子该不该出现由上架与库存同步决定，不由定价决定）、
以及刷新 `c_product_calendar`（商品级格子带票种价格与库存状态 `sold_out` / `closed`，
由库存同步作业写，半更新比不更新更糟）。

**划线价与折扣是定价函数给的，不是展示层编的**：
`list_price = 售价 × (1 + list_markup_percent/100)`，`discount_pct` 由这两个数算出来。
锁价行与按团报价行的划线价 = 售价（折扣 0）—— 平台不能为一个源方已定死的价伪造折扣。

前端的义务只有一条：**折扣为 0 时不显示划线价**。

---

## 4. 刻意没做的部分

| 没做 | 原因 | 何时补 |
|---|---|---|
| 推荐算法 / 猜你喜欢 | 需要行为数据，当前无 | 有埋点后 |
| 首页楼层 / 专题位 / Banner | 运营 CMS，另立上下文 | 做运营后台时 |
| 组合套餐（bundle）进 C 端 | 写路径都接上了（§2.8：定价 / 预订 / 出券 / 实名按成分），但组合**没有 `price_calendar` 行**、有效期终点口径没定、人群标签没法用单个 `audience` 表达，所以还不在可售列表里 | 组合的售价日历 + 有效期终点 + 人群标签三条口径定下来之后 |
| 拼团 / 秒杀 / 分销裂变 | 独立玩法，独立上下文 | 做活动时 |
| 优惠券自动匹配引擎 | 现在是"用户选券"，不是"系统最优券" | 做转化优化时 |
| 多币种展示 | 卡片带 `currency` 字段，但展示层换算策略未定 | C 端出海时 |

---

## 5. 新增不变量（21-26）

| # | 不变量 | 为什么必须有 |
|---|---|---|
| 21 | 购物车项的库存预占数量必须一致 | 少占=超卖，多占=浪费 |
| 22 | 活跃库存预占必须关联购物车或订单 | 否则是"幽灵占库存"，真实库存被吃掉却查不到 |
| 23 | 优惠券使用次数不得超过发放上限 | 超发=直接财务损失 |
| 24 | 订单引用的优惠券必须有核销记录 | 券核销了订单没记 = 对不上账 |
| 25 | 要求实名的票种持票人数必须与票数一致 | 少填一个名字 = 到现场进不去 |
| 26 | C 端读模型卡片的起价必须能追溯到价格日历 | 卡片价格无出处 = 展示层自说自话 |

变体层新增的 27-34 见 `SPEC.md` §4.4，其中直接影响 C 端的是：

| # | 不变量 | 为什么必须有 |
|---|---|---|
| 30 | 源变体覆盖映射必须完整覆盖目标变体 | 覆盖不全却路由过去 = 卖出履约不了的票 |
| 31 | 在售售价日历必须绑定变体 | 售价还停在票种层 = 同一票种不同组合价格串了 |
| 33 | 加购件变体必须挂在基础变体上 | 孤儿加购件 = 前端选得到、结算页算不出价 |
| 34 | 有售价的变体在其上架渠道必须至少有一个可履约源 | 只有一个源的组合 = 源挂了商品直接不可售，得提前知道 |
