# ticket-center — 多源票券中心

面向 OTA 的票券中台：把来自多个 GDS / 票务平台（Ingresso、FonTicket、Goodfellows·JTB、GlobalTix、票付通、Zowoyoo 自由行、Trip.com…）
的票券归一化成**一套规范商品模型**，对外以同一套商品/价格/库存/订单模型同时支撑 **B 端分销**与 **C 端自营**。

> **当前阶段：领域模型 + 物理模型 + 验收查询 + 接入层（Go）+ 下单 / 履约 / 退款 / 核销写路径。**
> 接入层已用 Go 实现（`cmd/tc-connect` + `internal/`）：Trip.com 分销侧协议完整核对，
> GlobalTix 端点待商务确认，其余五源待文档。拿到凭证即可直接跑分层连通性测试。
> 交易侧四段写路径各有唯一实现：下单 `fn_place_order`、履约 `005`、退款 `007`、核销 `008`；
> 各源适配器的真实联调、业务编排作业与 API / Web 尚未实施。

---

## 30 秒看懂设计

多源票券的难点不是接几个 API，而是**怎么让 5 个结构完全不同的源，长在同一套模型上**。

```
源层（各自为政）        映射层               规范层（我们的主数据）        交易层
─────────────        ─────────────        ──────────────────────      ─────────
supplier_product  →  product_mapping  →   product                    →  sales_order
supplier_variant     + 覆盖语义             product_variant              booking
supplier_session     (谁能履约哪个组合)     product_session              voucher
supplier_price_  →  supplier_variant_      ticket_type                  settlement
  calendar            mapping                price_calendar          ↘ C端读模型
                                                          ↘          c_product_card
                                                             ↘         c_variant_calendar
```

四条设计主线：

1. **源是上游系统，不是领域概念。** 源商品叫 `supplier_product`，源订单叫 `booking`（履约动作）。
   加第 6、第 7 个源，规范层与交易层一行不改。
2. **归一化是多对多的。** 一个源商品可拆多个我们的商品；一个我们的商品可由多个源供给。
3. **多源冗余下沉到场次级。** 不只是「这个商品谁在供」，而是「这一天、这个时段，谁能供」。
4. **成本必须可比才谈得上路由。** 源成本价独立成表 + 汇率快照归一 + 一个视图给出首选/备选源。

还有两条：

- **给 C 端的纪律**：展示文案必须带 locale，列表页只读读模型。
  详见 [`docs/c-end-model.md`](docs/c-end-model.md)。
- **给多维商品的纪律**：`product × ticket_type` 两层表达不了「成人 / 小孩 / 园区票」。
  可售单元下沉为 **变体**（`product_variant`），维度配置化为轴，
  源与变体之间用**覆盖语义**（`coverage`）对齐 ——
  详见 [`docs/schema-design.md` §5](docs/schema-design.md)。

---

## 跑起来

```bash
export PATH=/opt/homebrew/opt/postgresql@15/bin:$PATH

make db        # 重建主库：迁移 → 种子 → 验收
```

`make db` 等价于：

```bash
psql -h 127.0.0.1 -d postgres -c "DROP DATABASE IF EXISTS ticket_center;" \
                       -c "CREATE DATABASE ticket_center;" && \
./bin/tc-connect migrate --db ticket_center && \
psql -h 127.0.0.1 -d ticket_center -v ON_ERROR_STOP=1 -f db/seed.sql && \
psql -h 127.0.0.1 -d ticket_center -v ON_ERROR_STOP=1 -f db/verify.sql
```

存量库升级不重建，跑迁移就行：`make migrate`（应用待应用的迁移）。

需要 PostgreSQL 15+。本机 brew 装法：`brew install postgresql@15`。

**无凭证集成演练**（拿不到源的 key 也能先验证映射逻辑，建独立演练库，不动主库）：

```bash
python3 scripts/mapping_dryrun.py                                  # 演练 + 终端报告
python3 scripts/mapping_dryrun.py --poc scripts/poc/index.html    # 生成前端 POC 页面
```

产出：源报文 → 源变体 → 覆盖语义匹配 → 变体级路由 → 模型表达不了的源侧结构 → 不变量自检。
前端 POC：`scripts/poc/index.html`（单文件 HTML，数据内嵌，双击即可打开）。

```bash
open scripts/poc/index.html        # macOS
```

**C 端只读 API** —— 只读读模型，不 join 主数据：

```bash
make api                                     # 起服务（默认 :8080）
curl -s "http://127.0.0.1:8080/api/v1/products?channel_id=1&locale=zh-CN"
```

浏览卡片 / 变体差异 / 套餐构成 / 日历四个读侧端点。
写侧（购物车 / 结算 / 下单 / 支付）还没开 —— 系统里还没有调用方身份。

**接入层（Go）** —— 拿不到凭证也能跑 L0 连通性与离线自检：

```bash
make build                          # 构建 bin/tc-connect（需要 Go 1.23+）
make test                           # 单元测试
make mock                           # 协议级自检（本地 mock，14 项断言）
make layers                         # 分层连通性测试（连通→认证→目录→详情→价格→映射→路由）
make check                          # 提交前完整自检（vet + test + mock + 演练器）
```

**拿到商务授权后**（凭证只从环境变量读，不入库、不进仓库）：

```bash
export TRIPCOM_AID=… TRIPCOM_SID=… TRIPCOM_KEY=…
./bin/tc-connect layers --supplier trip_com --env sandbox   # 先沙箱
./bin/tc-connect layers --supplier trip_com --env prod      # 再生产
```

缺凭证时报告会明确写出缺哪个环境变量；原始报文归档到独立库 `ticket_center_integration`，不污染主库。
接入层设计详见 [`docs/integrations.md`](docs/integrations.md)。

---

## 实测结果

| 项 | 结果 |
|---|---|
| 表 / 视图 / 索引 / 触发器 / CHECK | 77 + 1 迁移账本 / 54 / 227 / 39 / 99 |
| 种子数据 | 7 源 · 12 源商品 · 7 规范商品 · 12 跨源映射 · 14 场次源绑定 · 10 订单 · 11 明细 · 10 预订 · 19 凭证 · 2 结算单 · 9 读模型卡片 · 14 日历格子 · 4 优惠券 · 4 购物车 · 16 库存预占 · 11 结算规格 · 34 持票人 · 6 评价 · 21 变体（含 2 张套餐 + 1 张套装） · 26 源变体 · 29 覆盖映射 · 6 组合成分行 · 2 套装成分行 |
| 不变量断言 | **107 / 107 PASS**（供给/定价/展示侧 45 条 + 交易侧 8 条 + 下单侧 1 条 + 履约侧 6 条 + 退款侧 4 条 + 核销侧 4 条 + 库存预占侧 4 条 + 有效期侧 3 条 + 读模型侧 6 条 + 组合映射侧 4 条 + 组合售卖侧 7 条 + 收紧侧 2 条 + 套装侧 5 条 + 套装库存侧 2 条 + 供给形态对照侧 3 条 + 供给形态不许缩小侧 3 条） |

**多源覆盖度**（同一商品几个源在供）：

| 商品 | 源数 | 多源冗余 | 源 |
|---|---|---|---|
| SKU-HK-PALACE | 3 | ✅ | globaltix, goodfellows_jtb, piaofutong |
| SKU-JP-SKYTREE | 2 | ✅ | globaltix, goodfellows_jtb |
| 其余 3 个 | 1 | — | 单源 |

**自动选源**（C 端 / 香港故宫 / 成人票 / 2026-11-05，成本已折算 CNY）：

| rank | 源 | 原币成本 | 折算 CNY | 库存模式 |
|---|---|---|---|---|
| 1 | 票付通 | CNY 108.00 | **108.00** | push |
| 2 | globaltix | HKD 118.00 | 108.93 | live |
| 3 | goodfellows_jtb | HKD 125.00 | 115.39 | pull_sync |

票付通 `priority` 排最后但成本最低，所以排第一 —— **路由按归一后成本排序，priority 只作同价 tiebreaker**。

**履约漏斗**识别出「已付款 30 分钟仍未出票」的订单（种子里的订单 3，`suspected_lost=t`）。

**多维商品的变体级路由**（C 端 / 北京环球影城 / 2026-11-16，成本已折算 CNY）：

| 变体 | 首选源 | 备选 | 说明 |
|---|---|---|---|
| 成人 · 一日 · 单园区 | Zowoyoo ¥505 | Trip.com ¥545 | |
| 老年 · 一日 · 单园区 | **Trip.com ¥486** | Zowoyoo ¥505 | 同一商品，最优源与上一行不同 |
| 儿童 · 一日 · 园区通票 | Zowoyoo ¥482 | — | Trip.com 没有儿童园区票，只剩 1 个候选 |

对照：商品级路由视图 `v_source_routing_candidates` 对环球影城输出 **0 行** ——
「成人·一日·园区通票」与「儿童·一日·园区通票」在 `(product, ticket_type)` 这一层无法区分。
这就是加变体层的原因（`db/verify.sql` H 段）。

**C 端走查**（`db/verify.sql` G 段）：

| 环节 | 结果 |
|---|---|
| 列表页直出 `v_c_listing_feed` | 8 张卡片，无额外 join；同一商品 C2C 起价 ¥95 / B2B 起价 HK$88 |
| 详情页聚合 `v_c_product_detail` | 香港故宫：3 亮点 / 5 须知 / 5 包含项 / 5 标签 / 3 评价 一次拿到 |
| 日历 `c_product_calendar` | 含 `sold_out` / `closed` 格子（前端要画灰，不是"这天不存在"） |
| 变体日历 `c_variant_calendar` | 同一天不同变体价格不同、可履约源数不同 |
| 读模型漂移 `v_c_readmodel_drift` | 8 张卡片全部 `drifted=f` |
| 购物车→预占→实名→用券 | 全链路有数据，断言 21-26 把住 |
| 变体链路 | 订单 5 两行明细 = 同商品两个变体 → 两条预订 → 两张券 → 实名，断言 27-34 把住 |

**接入层（Go，2026-11-05）**：

| 项 | 结果 |
|---|---|
| Trip.com 分销侧接口 | 21 个 POST 接口，**沙箱 + 生产 ICODE 全部提取**（3 个接口缺生产 ICODE，已标注） |
| 协议级自检 | **14 / 14 通过**（配置完整性 / 归一化自检 / 组合表达式 / 脱敏 + 取 token / uuid 唯一 / retriable 重试 / fatal 不重试 / auth 刷新一次 / B0010 幂等命中 / 归档脱敏 / 归一化→路由 / token 自动刷新 / 业务幂等不重复外呼） |
| 分层连通性（无凭证） | trip_com **L0 连通通过**（真实 TCP 到携程 UAT 66ms），L1–L6 明确报出缺 3 个环境变量 |
| 其余六源 | 显式报「待商务确认」，**零编造端点** |
| Go 单元测试 | **26 个包全绿**（config / credential / normalize / store / transport / layertest / tripcom / pricing / migrate / readmodel / transaction / order / fulfillment / refund / redemption / inventory / variant …） |
| 依赖 | 零第三方依赖（标准库 `net/http` + `psql` 子进程） |

**交易侧状态机（2026-11-06）**：合法流转写在 `state_transition` 表里，触发器守着 ——
非法流转当场报错（`expired → confirmed` 写不进去），合法流转写进去就一定在 `event_outbox`
留下一条领域事件。改状态机不用发版，加一行表 + 同步 SPEC 即可。

**下单写路径（2026-11-07）**：订单落库只走 `fn_place_order()` ——
幂等键必填（同键同内容返回同一张单，同键异内容报错），
金额与采纳源只取定价函数的唯一实现 `fn_price_variant`，
明细走快照（订单历史不依赖当前商品表），实名按 `checkout_requirement` 收齐。
不变量 54 逐行比对明细单价与定价函数输出 ——
哪天有人在下单函数里手写一个乘数，这条当场报警。

```bash
make order-demo                                       # 端到端演示：找有售价的日期 → 下单 → 幂等重放 → 查单
./bin/tc-connect order place --db ticket_center --request req.json
./bin/tc-connect order show  --db ticket_center --id 7
```

演示脚本自己找当天有售价的日期，不写死日期 —— 写死的样例文件过几天就失效。

**履约写路径（2026-11-07）**：支付 → 预订 → 出券，每一步都只有库里的一个实现
（`db/migrations/005_fulfillment.sql`），Go 侧 `internal/fulfillment` 只负责拼参数和读结果。

| 环节 | 口径 |
|---|---|
| 支付 `fn_record_payment` | 金额必须等于订单应付；幂等按渠道流水；**另一笔流水打进已付订单 = 重复收款，当场报错**（`006` 守卫，不静默吞掉） |
| 建预订 `fn_create_bookings` | 预订的源场次取自 `product_session_source` 的场次级绑定，不按日期猜 |
| 预订尝试 `fn_request_booking` / `fn_record_booking_attempt` | 每次外呼留一条 attempt（请求/响应/HTTP 状态/时延/错误分类） |
| 完成预订 `fn_complete_booking` | 确认的预订必须带源侧预订号，否则回头找不到源对账 |
| 出券 `fn_issue_voucher` | 票码数必须等于要发的张数，票码与持票人一一对应 |
| 订单履约状态 `fn_apply_order_fulfillment` | 状态是结论，结论只有一个算法：从明细的实际出票情况推导（不变量 60） |

```bash
./bin/tc-connect fulfill pay      --db ticket_center --order 7 --method alipay \
                                   --amount 1171.60 --currency CNY --provider alipay --txn ALI-001
./bin/tc-connect fulfill book     --db ticket_center --order 7
./bin/tc-connect fulfill request  --db ticket_center --booking 12
./bin/tc-connect fulfill complete --db ticket_center --booking 12 --status confirmed \
                                   --external-booking-id EXT-BK-001 --code C1 --code C2
./bin/tc-connect fulfill show     --db ticket_center --order 7
```

**退款写路径（2026-11-07）**：发起 → 放行 → 完成，只走库里的一个实现
（`db/migrations/007_refund.sql`），Go 侧 `internal/refund` 只负责拼参数和读结果。

| 环节 | 口径 |
|---|---|
| 发起 `fn_request_refund` | 整单退款；金额必须等于订单实付；**有没有真的收到钱看 `sales_payment` 里成功的支付记录，不看订单状态**；幂等键必填，同键异内容报错 |
| 放行 `fn_approve_refund` | 人工过一道；订单状态不动（钱还没回来） |
| 完成 `fn_complete_refund` | 成功时一次改完明细 / 凭证 / 预订 / 支付 / 订单（不变量 61-64）；失败时订单照 `previous_order_status` 退回去，退不回去就留在 `refunding` 等人处理 |

行级退款（只退某几行）需要「优惠券 / 税费 / 折扣怎么摊到每一行」的分摊口径，
还需要源侧支持部分取消 —— 那是业务决策，不是工程决策。
在这两样落地之前，系统对行级退款**明确报错**，不自己编一条分摊规则。

```bash
./bin/tc-connect refund request  --db ticket_center --order 3 --amount 368.00 \
                                 --key RF-001 --reason "源侧预订失败" --by ops@test
./bin/tc-connect refund approve  --db ticket_center --refund 1 --by boss@test
./bin/tc-connect refund complete --db ticket_center --refund 1 --success \
                                 --supplier-refund-id EXT-RF-001
./bin/tc-connect refund show     --db ticket_center --refund 1
```

**核销写路径（2026-11-07）**：扫票入场，只走库里的一个实现
（`db/migrations/008_redemption.sql`），Go 侧 `internal/redemption` 只负责拼参数和读结果。

| 环节 | 口径 |
|---|---|
| 一次核销 = 一次扫票 | 核销记录**永远追加**，成功失败都落，不覆盖、不去重 —— 重复扫票本身就是事实 |
| 状态效果幂等 | 一张券最多成功核销一次，由唯一索引 `ux_redemption_single_success` 兜底；第二次扫返回 `duplicate` 并带回第一次核销的记录 id 与时间 |
| 额度一次用尽 | 一人一券消耗 1，按团报价整团一券消耗整团人数；成功后券从 `issued` 变 `used`，触发器落 `VoucherRedeemed` |
| 不认核销但留记录 | 过期 / 作废 / 已退款 / 未出票 / 订单在退款 / 闸机停用 —— 都落一条记录并写清 `reason` |
| 票码撞车不猜 | 有闸机就按闸机所属的源收窄候选集，收窄不出来就报错（票码不存在 / 不唯一是调用方的问题，不是扫票的结果） |

扫票**结果不是异常**：券过期、券作废、券还没出票、订单在退款，
都是扫票的正常结果 —— 返回给闸机看，同时在库里留一条记录。
只有票码不存在 / 不唯一才报错。

```bash
./bin/tc-connect redeem scan --db ticket_center --code TKT-001 [--gate 1 --device POS-01]
./bin/tc-connect redeem show --db ticket_center --voucher 3
```

**库存预占（2026-11-07）**：还剩多少只有库里的一个实现
（`db/migrations/009_inventory_hold.sql`），Go 侧 `internal/inventory` 只负责拼参数和读结果。

| 环节 | 口径 |
|---|---|
| 算可售 `fn_available_qty` | 源侧快照与我们的承诺**对账**：`unreflected = our_sold − source_sold`，`committed = unreflected + active_held`。直接拿源侧 `sold` 减我们的 `consumed` 会双扣 —— 每同步一次就少卖一半 |
| 不知道就是不知道 | 取不到库存快照与可用性缓存时返回「不知道」，**不返回 0**（返回 0 意味着卖完了，会让整个商品下架） |
| 扣减 `fn_reserve_qty` | 按源场次**升序**加行锁后再算再判（升序是为了不让两个订单互相死锁）；明知不够当场报错；不知道时不拦，但把当时的可售数写进明细快照 |
| 预占 `fn_hold_inventory` | `hold_no` 是幂等键，同键异内容报错；TTL 到由 `fn_expire_holds` 统一放掉 |
| 订单关上 | 触发器把预占置 `voided`：**卖出过的事实不许改写**（`released` = 从未卖出，`voided` = 卖出后收回） |

```bash
./bin/tc-connect stock show  --db ticket_center --supplier-session 1
./bin/tc-connect hold create --db ticket_center --no HOLD001 --channel 1 --variant 11 --qty 2 --date 2026-11-18
./bin/tc-connect hold release --db ticket_center --no HOLD001 --reason cart_abandoned
./bin/tc-connect hold expire --db ticket_center
./bin/tc-connect hold show   --db ticket_center --no HOLD001
```

**有效期（2026-11-07）**：异构产品之间最容易被抹平的一条差异 ——
源侧有两日票，我们的规范场次是「(商品, 日期, 时段)」一行，两日票和单日票共用场次，
而出券写死「场次当天 + 1 天」的话，卖了两日票发出来的券只管一天，
客户第二天到门口闸机判 expired（钱收了、票买了、门不认）。

| 环节 | 口径 |
|---|---|
| 有效期长度是数据 | `product_axis_option.valid_days`（`1d → 1`、`2d → 2`），不写在代码里 |
| 口径只有一处 | `fn_variant_validity_days()` 是唯一读法，出券只调它 |
| 不许有歧义 | 一个变体不能同时挂两个取值不同的 `valid_days`（不变量 73），有歧义当场报出来 |
| 券不得短于承诺 | 不变量 74：这是「哪天又有人把 `+1` 写回去」的门禁 |
| 源侧能不能兑现是选源时定的 | `fn_variant_covered` 说了算；卖了之后不许变（不变量 75），真变了走退款 |

差异要能一眼看出来：`v_variant_comparison` 一行看清两个可售单元差在哪
（人群 / 轴取值 / 有效期 / 退款口径 / 有几个源能装配出它）。

**差异走到 C 端（2026-11-07）**：到上一步为止，差异在主数据里说清楚了，
但 C 端看不到 —— 读模型只带价格与可售天数，前端要显示「几日的票、覆盖哪些园区、
能不能退」就得在请求链路里 join 主数据，而请求链路不许 join 主数据。
两日票和单日票在日历上长得一模一样，用户按「当天有效」理解两日票，第二天到门口才发现进不去。

| 环节 | 口径 |
|---|---|
| 差异事实进读模型 | `c_variant_facts`（渠道 × 可售单元）：人群 / 轴取值 / 有效天数 / 退款口径 |
| 事实只写一份 | 每个字段都从 `v_variant_comparison` 取，不重算有效天数、不重算轴取值 |
| 读模型不与主数据分叉 | 不变量 76：刷新作业漏跑当场报出来 |
| 有效期终点由库算好 | `c_variant_calendar.valid_to = 格子日期 + 有效天数`，前端不自己加一天（不变量 77） |
| 没有格子的变体不留事实 | 渠道撤下一个变体，事实跟着撤（读模型可重建，主数据是唯一真相） |

```bash
./bin/tc-connect variant compare  --db ticket_center --product 6   # 这个商品的可售单元差在哪
./bin/tc-connect variant coverage --db ticket_center --variant 14  # 哪些源能供、缺什么
./bin/tc-connect variant feed     --db ticket_center --channel 1  # C 端读模型里的变体行
./bin/tc-connect variant composition --db ticket_center --variant 18 --channel 1  # 这张套餐由谁组成
./bin/tc-connect variant bundle   --db ticket_center --variant 21  # 这张套装（源侧整套卖）由谁组成
```

**组合映射（2026-11-07）**：异构融合有两条方向，方向 A 是「一个源 SKU 覆盖多个可售单元」
（`coverage` + `fn_variant_covered`），方向 B 是「一个可售单元由多个源 SKU 按数量组成」。
真实商品两种都有：源侧一张通用通票我们要拆成成人票儿童票（方向 A），
源侧一个套餐我们要拆成门票加快速通行证加儿童票（方向 B）。

| 环节 | 口径 |
|---|---|
| 两侧都要有声明 | 规范侧声明组件与数量（`product_variant_relation.quantity`），源侧给配方（`supplier_variant_composition`）；少一个成分 = 源侧少给一份，多一个 = 我们多卖一份（不变量 79、80） |
| 配对关系记下来 | `component_variant_id` 显式记「这个源 SKU 顶的是哪个组件」，对账逐行比，不靠猜 |
| 组合的要求 = 组件要求的并集 | `fn_variant_requirements`，所以单个源 SKU 覆盖不住整张配方，整张配方覆盖得住 —— 方向 A 与 B 不打架 |
| 组件只许一层 | 触发器 `fn_guard_included_relation` 当场挡住嵌套 |
| 组合不许直接挂源映射 | 触发器 `fn_guard_combo_mapping` + 不变量 81：定价与预订还没接组合，挂上源映射会用一个源 SKU 的成本给整张套餐定价（收三个人的钱，出一张票） |
| 接不上的就说清 | 源侧把整套套餐当一个 SKU 卖的情况（套装）从 `coverage` 看不出「一整套」还是「一张谁都能用的票」，猜不得 —— 所以它**单独声明**（见下面的套装一节） |

**组合在 C 端（2026-11-08）**：组合是**我们自己的配方** —— 源侧没有它的商品条目，
目录同步作业看不见它，所以它的售价行与日历格子由配方推出来，构成也进读模型。

| 环节 | 口径 |
|---|---|
| 组合的售价行由配方推 | `fn_sync_combo_calendar()` 按成分的售价行推组合的售价行，金额走定价函数的组合分支（Σ 成分单价 × 份数）—— 同步作业不另算一遍钱 |
| 有效期终点 = 成分窗口的并集 | 2 份两日成人 + 1 份一日儿童 = **2 天**（不是最短的 1 天，也不是相加的 3 天）；不变量 89 两边独立读 |
| 人群不选标签，带编码 | 组合带的是每个成分的人群编码 + 份数 + 各自的天数；「2 成人 + 1 儿童」由前端按 locale 拼（展示文案不进模型） |
| 构成进读模型 | `c_variant_composition` / `v_c_variant_composition`；与主数据分叉由不变量 90 当场抓住 |
| 挂着的组合必须卖得掉 | 日历格子必须有价格（不变量 91） |
| 跨币种的组合逐成分留折算痕迹 | 组合没有单一源币种：顶层 `fx_rate` / `fx_as_of` 留空，逐成分留痕在 `price_calendar.rule->'combo'`；不变量 45 按 `cost_source_product_id` join 源价行，直接跳过组合，不变量 92 专门查它 |

```bash
./bin/tc-connect compose plan  --db ticket_center --source globaltix --fixture fixtures/globaltix_catalog.json
./bin/tc-connect compose apply --db ticket_center --source globaltix --fixture fixtures/globaltix_catalog.json
```

**组合套餐可售（2026-11-07）**：组合从「两侧对得上」走到「能成交」。

| 环节 | 口径 |
|---|---|
| 成本 = Σ 成分单价 × 数量 | `fn_combo_components` 从**源侧配方**取成分与成本；成分的源 SKU 不重新选源 —— 重选源就出现「按 A 源的价格卖、按 B 源出票」 |
| 卖不了就说清为什么 | 成分缺价 / 场次不同 / 源不同 / 价格锁定 / 按团报价，五种情况一律判不可售，理由由 `v_combo_price_gap` 列出 |
| 履约单位是成分 | `sales_order_item_source` 一个成分一行（普通明细也写一行）；`order_holder.component_variant_id` 记持票人属于哪个成分 |
| 预订的单位是**源 SKU** | 一个源 SKU 一条预订（不是按成分建 —— 参数化源里成人与儿童是同一个源 SKU，按成分建就是同一个源 SKU 订两次）；成分的拆分留在预订的请求明细里，覆盖关系由 `fn_booking_components` 推出来 |
| 逐成分出券 | 成人成分发 2 张券、儿童成分发 1 张券，券上写的是**成分**的可售单元与票种，持票人按成分归位 |
| 持票人归属靠 `item_index` | 同一个成分出现在多行明细时，实名的 `item_index` 指明是哪一行（1 起）；一半带一半不带就报错 |
| 超卖按源场次总需求判 | 多个成分抢同一个源场次时按合起来的总需求判（场次级共享池不许每个票种各花一遍） |
| 退款改全部成分 | 整单退款把成分的预订 / 券 / 票额一起改，成分层面不留「已出票」的事实 |

**预订的单位是源 SKU（2026-11-08 修订）**：上一版按成分建预订，在参数化源上是错的。

| 问题 | 后果 |
|---|---|
| 自由行的 `ZWO-1D-BASE` 是**一个**源 SKU，人群是购买时选的一档 | 成人成分与儿童成分共用它 |
| 按成分建预订 = 同一个源 SKU 在同一个源场次上订两次 | 源侧看到两张订单单，我们这边一条客户订单对两个源单号，对账对不上 |
| 退款要退两次 | 一次退不掉就是「钱退回来了但票还在」 |
| 源侧只确认了其中一个成分 | 整张套餐是半成品 —— 收了三个人的钱出了两张票 |

改成按源 SKU 建预订：一条预订 = 一个源 SKU 在一个源场次上的预留，
成分的拆分留在请求明细里，出券时再按成分分下去。
唯一索引 `ux_booking_one_per_source_sku` 兜底，不变量 87 / 88 复查。
代价说清楚：一张套餐有几条预订 = 有几个源 SKU；整张套餐的原子性取决于源侧能力，
我们只保证「所有成分都出票了才算履约完成」。

**套装：源侧把整套当一个 SKU 卖（2026-11-09）**：异构融合的第三种形态。
方向 A 是「一个源 SKU 覆盖多个可售单元」，方向 B 的配方是「一个可售单元由多个源 SKU
按数量组成」，套装是**一个源 SKU 把整套当一个 SKU 卖**。
从 `coverage` 看不出是哪种 —— 所以套装单独声明，不许靠猜。

| 环节 | 口径 |
|---|---|
| 单独声明 | `supplier_variant_bundle`（规范变体 ← 整套源 SKU + 源侧整套有效期）+ `supplier_variant_bundle_part`（成分 + 份数）；触发器挡住「既是配方又是套装」 |
| 三个单位不许混 | 售卖单位是**套**、成分单位是**预订的单位**、入场份数是**发的券的张数**。一套「2 成人 + 1 儿童」= 1 套 / 3 份入场（不变量 99） |
| 成本来自源侧那个整套报价 | 不重新选源（重选源 = 按 A 源的价格卖、按 B 源出票）；分摊到成分只为对账，Σ 分摊 × 套数精确等于整套成本 × 套数（不变量 98） |
| 库存扣源侧整套票种的池子 | `fn_available_qty` / `fn_reserve_qty` 加带 `source_ticket_type_id` 的重载；预占一条，份数是套数 |
| 有效期是源侧声明的 | 整套有效期必须盖住成分窗口的并集 —— 盖不住就是第二天进不去（不变量 97） |
| 缺口要说清 | `v_bundle_gap` 按天列：没有源侧报价 / 没有规范场次 / 没绑源场次 / 没有源侧票种 / 有效期盖不住 / 可售数未知 |
| 事实不许被一次调用洗掉 | `fn_request_booking` 的请求报文改成**合并**而不是覆盖 —— 套数与入场份数是我们写的事实，接入层发一次请求不许把它们冲掉 |

```bash
./bin/tc-connect variant bundle --db ticket_center --variant 21
```

---

## 目录

| 文件 | 内容 |
|---|---|
| [`SPEC.md`](SPEC.md) | 业务合同：范围、角色、流程、**107 条不变量**、状态机、验收标准 |
| [`docs/ddd.md`](docs/ddd.md) | 限界上下文、聚合边界、领域事件、归一化与路由机制、**变体与覆盖语义** |
| [`docs/c-end-model.md`](docs/c-end-model.md) | **C 端：读模型、展示内容、购买漏斗、变体选择器** |
| [`docs/schema-design.md`](docs/schema-design.md) | SQL / 半 SQL / NoSQL 选型论证、表清单、**变体模型（§5）**、**库存预占（§17）**、**有效期（§18）**、**组合映射（§20）**、演进路线 |
| [`docs/connector-contract.md`](docs/connector-contract.md) | 供应源接入端口、错误四分类、幂等重试、七源差异矩阵、**§9 接入层实现现状** |
| [`docs/integrations.md`](docs/integrations.md) | **接入层（Go）**：包结构、设计纪律、CLI 用法、拿到授权后的验证清单 |
| [`db/migrations/`](db/migrations/) | 全部 DDL：冻结的建库基线 + 后续迁移文件（`tc-connect migrate` 应用） |
| [`db/seed.sql`](db/seed.sql) | 种子数据 |
| [`db/verify.sql`](db/verify.sql) | 验收查询 + 不变量断言 |
| [`cmd/tc-api/`](cmd/tc-api/) | **C 端只读 API 服务**：浏览 / 变体差异 / 套餐构成 / 日历 |
| [`cmd/tc-connect/`](cmd/tc-connect/) | **接入层 CLI**：`sources` / `layers` / `mock` / `normalize` / `compose` / `price` / `migrate` / `refresh` / `order` / `fulfill` / `refund` / `redeem` / `stock` / `hold` / `variant` |
| [`internal/`](internal/) | **接入层实现**：传输层 / 凭证 / 归一化 / 各源适配器 / 归档幂等 / 定价读侧 / 迁移引擎 / 读模型刷新 / 状态机读侧 / 下单 / 履约 / 退款 / 核销 / 库存 / 组合映射 / mock |
| [`configs/`](configs/) | 传输层配置（端点 / ICODE / 凭证口径 / 错误码）+ 映射规则（单一真相） |
| [`fixtures/`](fixtures/) | 真实报文结构的样例（canonical / trip_com / globaltix） |
| [`scripts/mapping_dryrun.py`](scripts/mapping_dryrun.py) | **无凭证集成演练**：用真实报文结构跑一遍 mapping → 路由（归一化调用 Go 实现） |
| [`scripts/order_demo.py`](scripts/order_demo.py) | **下单链路演示**：找有售价的日期 → 下单 → 幂等重放 → 查单 |
| [`scripts/poc/index.html`](scripts/poc/index.html) | 前端 POC：变体矩阵 / 覆盖语义匹配 / 变体级路由 / 模型缺口（演练生成物） |
| [`Makefile`](Makefile) | build / test / mock / layers / dryrun / db / check / order-demo |
| [`AGENTS.md`](AGENTS.md) | 仓库级硬约束与命令约定 |

---

## 下一个阶段

- [ ] **拿到 Trip.com 分销侧凭证**（`aid` / `sid` / `key`）→ 跑沙箱 + 生产分层测试，核对 4 个待确认点（见 `docs/integrations.md`）
- [ ] 拿到 **GlobalTix 接口文档** → 填 `configs/api_config.json` 的端点与请求体 → 启用适配器
- [ ] 其余五源（Ingresso / JTB / Zowoyoo / FonTicket / 票付通）的接口文档到位后逐个实现
- [x] **组合映射表** `supplier_variant_composition`（GlobalTix 的 `A|2+B|1` 能表达了，规范侧声明 + 源侧配方两侧对得上）
- [x] **组合套餐真的能卖**：定价（成本 = Σ 成分单价 × 数量）、预订（按源 SKU 带整组源 SKU）、出券（一张组合按成分出几张券）都接上了 —— 见下面「组合套餐可售」
- [x] **预订的单位 = 源 SKU**：参数化源里成人与儿童是同一个源 SKU，按成分建预订就是同一个源 SKU 订两次（源侧两张订单单、对账对不上、退款退不掉）—— 见上面「预订的单位是源 SKU」
- [ ] **组合进 C 端读模型**：组合没有 `price_calendar` 行，读模型画不出它；组合的有效期终点与人群标签口径还没定（`SPEC.md` §5.13 的已知缺口）
- [ ] 接入层之上的**业务编排作业**（同步调度 / 改派 / 自动补报 / 退款重试）
- [ ] B 端管理台：商品/上架/路由/映射审核/异常单
- [ ] C 端链路：搜索 → 详情 → 选场次 → 下单 → ~~出券 → 核销~~（出券与核销的写路径都已落地；**读侧已开成 HTTP 接口** —— `cmd/tc-api` 的浏览 / 变体差异 / 套餐构成 / 日历四个端点；剩下的是搜索、详情界面与购买链路的写侧，还差调用方身份与鉴权）
- [ ] 订单表分区、只读副本、源报文冷热分离（方案见 `docs/schema-design.md` §9）
