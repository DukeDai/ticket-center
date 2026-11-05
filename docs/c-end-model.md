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

实测（种子数据，7 张卡片）：

| channel | product | card_from_price | truth_min_price | drifted |
|---|---|---|---|---|
| C2C | 1 | 95.00 | 95.00 | f |
| B2B_HK | 1 | 88.00 | 88.00 | f |
| C2C | 3 | 188.50 | 188.50 | f |

注意 B2B_HK 的起价 88.00 ≠ C2C 的 95.00 —— **同一商品在不同渠道的起价不同**，
这正是 `channel` 存在的意义，也是 `price_calendar.channel_id` 唯一索引要带渠道维度的原因。

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
- `status`: `active` → `consumed`（下单成功）/ `released`（主动释放）/ `expired`（超时）
- `expires_at` + 部分索引 `ix_hold_expiry ... WHERE status='active'`：定时作业扫过期释放
- 断言 21 保证预占数量与购物数量一致；断言 22 保证活跃预占必须挂在某个购物车或订单上（不能凭空占库存）

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

断言 25 保证「要求实名的票种，持票人数必须等于票数」—— 少填一个人的票是最常见的出票事故。

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

实测（北京环球影城，C2C 渠道，2026-11-16）：

| 变体 | 售价 | 可履约源数 |
|---|---|---|
| 成人 · 一日 · 单园区 | ¥585 | 2 |
| 儿童 · 一日 · 单园区 | ¥495 | 2 |
| 成人 · 一日 · 园区通票 | ¥645 | 2 |
| 儿童 · 一日 · 园区通票 | ¥565 | **1**（只有 Zowoyoo） |
| 成人 · 双日 · 单园区 | ¥985 | 2 |
| 快速通行证（加购件） | ¥398 | 2 |

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

---

## 3. C 端的完整链路（对应种子的数据）

```
① 浏览           v_c_listing_feed → 8 张卡片（C2C 6 商品 + 英文版 + B2B_HK）
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

---

## 4. 刻意没做的部分

| 没做 | 原因 | 何时补 |
|---|---|---|
| 推荐算法 / 猜你喜欢 | 需要行为数据，当前无 | 有埋点后 |
| 首页楼层 / 专题位 / Banner | 运营 CMS，另立上下文 | 做运营后台时 |
| 组合套餐（bundle，含子项列表） | 用变体关系表 `product_variant_relation` 表达「基础票 ← 园区升级/快速通行证」，但**打包成一个不可拆的组合**还需要 bundle 子模型 | 出现必须整体售卖、不可拆售的组合票时 |
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
