# ticket-center — 多源票券中心

面向 OTA 的票券中台：把来自多个 GDS / 票务平台（Ingresso、FonTicket、Goodfellows·JTB、GlobalTix、票付通、Zowoyoo 自由行、Trip.com…）
的票券归一化成**一套规范商品模型**，对外以同一套商品/价格/库存/订单模型同时支撑 **B 端分销**与 **C 端自营**。

> **当前阶段：领域模型 + 物理模型 + 验收查询 + 接入层（Go）+ 下单 / 履约 / 退款 / 核销写路径 + C 端只读 API。**
> 接入层已用 Go 实现（`cmd/tc-connect` + `internal/`）：Trip.com 分销侧协议完整核对，
> GlobalTix 端点待商务确认，其余五源待文档。拿到凭证即可直接跑分层连通性测试。
> 交易侧四段写路径各有唯一实现：下单 `fn_place_order`、履约 `005`、退款 `007`、核销 `008`。
> **C 端只读 API 已落地**（`cmd/tc-api` + `internal/capi`：浏览 / 变体差异 / 套餐构成 / 日历四个端点，
> 只读读模型、不 join 主数据）；但**购物车 → 下单 → 支付**这一段还没开口子（没有调用方身份），
> Web 也没有。各源适配器的真实联调与业务编排作业尚未实施。

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
只服务在营的自营 C 端渠道（`channel_type='b2c_own'`），其余渠道回 403。
写侧（购物车 / 结算 / 下单 / 支付）还没开 —— 系统里还没有调用方身份。

**接入层（Go）** —— 拿不到凭证也能跑 L0 连通性与离线自检：

```bash
make build                          # 构建 bin/tc-connect（需要 Go 1.23+）
make test                           # 单元测试
make mock                           # 协议级自检（本地 mock）
make counts                         # 打印各处文档引用的那些数（不变量条数 / 测试条数 / mock 断言数）
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
| 表 / 视图 / 索引 / 触发器 / CHECK | 77 + 1 迁移账本 / 61 / 227 / 39 / 99 |
| 种子数据 | `make counts` 的「种子行数」段（表名取自 `db/seed.sql` 自己的统计段，不另抄一份） |
| 不变量断言 | **全 PASS**（`v_invariant_checks`；条数跑 `make counts`；每条不变量住在 SPEC §4 对应小节，门禁是 `db/verify.sql` 的 F 段） |

不变量分组的条数会随 SPEC §4 的小节增删而变，**别在这张表里手抄分组条数** ——
抄一次就多一份会漂移的副本。要看分组，问库：

```bash
make counts                                    # 条数 + 各主题分组的条数（一次数清）
psql -h 127.0.0.1 -d ticket_center -c "select seq, check_name, passed from v_invariant_checks order by seq;"
```

**多源覆盖度**（同一商品几个源在供）：

| 商品 | 源数 | 多源冗余 | 源 |
|---|---|---|---|
| SKU-HK-PALACE | 3 | ✅ | globaltix, goodfellows_jtb, piaofutong |
| SKU-JP-SKYTREE | 2 | ✅ | globaltix, goodfellows_jtb |
| SKU-CN-USJ-BEIJING | 2 | ✅ | trip_com, zowoyoo |
| 其余 4 个 | 1 | — | 单源 |

**自动选源**（C 端 C2C / 香港故宫 / 成人票 / <日期>；日期现查：`tc-connect variant feed --db <库> --channel 1`）：

| rank | 源 | 源侧报价 | 归一后成本 | 折算 CNY | 库存模式 |
|---|---|---|---|---|---|
| 1 | 票付通 | CNY 118.00 | 108.00 | **108.00** | push |
| 2 | globaltix | HKD 120.00 | 118.00 | 108.93 | live |
| 3 | goodfellows_jtb | HKD 125.00 | 125.00 | 115.39 | pull_sync |

票付通 `priority` 排最后但归一后成本最低，所以排第一 —— **路由按归一后成本排序，priority 只作同价 tiebreaker**。
（B2B 渠道只有两个源在供：globaltix 118.00 排第一，goodfellows_jtb 125.00 第二 —— 票付通不供 B2B。）

**履约漏斗**识别出「已付款 30 分钟仍未出票」的订单（种子里的订单 3，`suspected_lost=t`）。

**多维商品的变体级路由**（C 端 C2C / 北京环球影城 / <日期>；日期现查：`tc-connect variant feed --db <库> --channel 1`）：

| 变体 | 首选源 | 备选 | 说明 |
|---|---|---|---|
| 成人票 · 一日 · 工作室之旅 | Zowoyoo ¥505 | Trip.com ¥545 | |
| 老年票 · 一日 · 工作室之旅 | **Trip.com ¥486** | Zowoyoo ¥505 | 同一商品，最优源与上一行不同 |
| 儿童票 · 一日 · 园区通票 | Zowoyoo ¥482 | — | Trip.com 没有儿童园区票，只剩 1 个候选 |
| 成人票 · 一日 · 园区通票 | Zowoyoo ¥552 | Trip.com ¥642 | 园区通票比工作室之旅贵 |

对照：商品级路由视图 `v_source_routing_candidates` 对环球影城输出 **0 行** ——
「成人·一日·园区通票」与「儿童·一日·园区通票」在 `(product, ticket_type)` 这一层无法区分。
这就是加变体层的原因（`db/verify.sql` H 段）。

**C 端走查**（`db/verify.sql` G 段）：

| 环节 | 结果 |
|---|---|
| 列表页直出 `v_c_listing_feed` | 9 行（C2C 8 + B2B 1；C2C 那 8 行是 7 个商品 —— 香港故宫有中英两个 locale），无额外 join；香港故宫 C2C 起价 ¥89.46 / B2B 起价 HK$92.04 |
| 详情页聚合 `v_c_product_detail` | 香港故宫：3 亮点 / 5 须知 / 5 包含项 / 5 标签 / 3 评价 一次拿到 |
| 日历 `c_product_calendar` | 含 `sold_out` / `closed` 格子（前端要画灰，不是"这天不存在"） |
| 变体日历 `c_variant_calendar` | 同一天不同变体价格不同、可履约源数不同；`valid_to` 由库算好，前端不自己加一天 |
| 读模型漂移 `v_c_readmodel_drift` | 9 行全部 `drifted=f` |
| 购物车→预占→实名→用券 | 全链路有数据，断言 21-26 把住 |
| 变体链路 | 订单 5 两行明细 = 同商品两个变体 → 两条预订 → 两张券 → 实名，断言 27-34 把住 |

**接入层（Go，2026-11-05）**：

| 项 | 结果 |
|---|---|
| Trip.com 分销侧接口 | 21 个 POST 接口，**沙箱 + 生产 ICODE 全部提取**（3 个接口缺生产 ICODE，已标注） |
| 协议级自检 | **全通过**（配置完整性 / 归一化自检 / 组合表达式 / 脱敏 + 取 token / uuid 唯一 / retriable 重试 / fatal 不重试 / auth 刷新一次 / B0010 幂等命中 / 归档脱敏 / 归一化→路由 / token 自动刷新 / 业务幂等不重复外呼；断言条数跑 `make counts`） |
| 分层连通性（无凭证） | trip_com **L0 连通通过**（真实 TCP 到携程 UAT 66ms），L1–L6 明确报出缺 3 个环境变量 |
| 其余六源 | 显式报「待商务确认」，**零编造端点** |
| Go 单元测试 | **全绿**（包与用例条数跑 `make counts`；有测试的包：config / credential / normalize / store / transport / layertest / tripcom / pricing / migrate / readmodel / transaction / order / fulfillment / refund / redemption / inventory / variant …） |
| 依赖 | 零第三方依赖（标准库 `net/http` + `psql` 子进程） |

**交易侧写路径**：四段各有唯一实现，全部在库里；Go 侧只拼参数、只读结果 ——
不重算金额、不重排源、不自己算状态、不自己判退款资格、不自己判能不能进场。

| 段 | 唯一实现 | 规则与不变量 |
|---|---|---|
| 下单 | `fn_place_order`（`004`） | [SPEC §5.5](SPEC.md#55-下单写路径2026-11-07-落地) · 不变量 54 |
| 履约 | `fn_record_payment` / `fn_create_bookings` / `fn_request_booking` / `fn_record_booking_attempt` / `fn_complete_booking` / `fn_issue_voucher` / `fn_retry_booking` / `fn_apply_order_fulfillment`（`005`/`006`） | [SPEC §5.6](SPEC.md#56-履约写路径2026-11-07-落地) · 不变量 55-60 |
| 退款 | `fn_request_refund` / `fn_approve_refund` / `fn_complete_refund`（`007`） | [SPEC §5.7](SPEC.md#57-退款写路径2026-11-07-落地) · 不变量 61-64 |
| 核销 | `fn_redeem_voucher`（`008`） | [SPEC §5.8](SPEC.md#58-核销写路径2026-11-07-落地) · 不变量 65-68 |

状态机由机制保证：合法流转写在 `state_transition` 表里（唯一来源），
`fn_guard_state_transition` 挂在 `trg_*_status_guard` 上挡住非法流转，
`fn_emit_state_event` 挂在 `trg_*_status_event` 上保证状态一变就落一条领域事件到
`event_outbox`。改状态机 = 改那张表 + 同步 SPEC §5，不去改某个 Go 分支。
（[SPEC §5.4](SPEC.md#54-状态机由机制保证2026-11-06-落地)）

库存可售数、有效期长度、份数区间、单位价这四样也各有唯一实现，
口径见 [SPEC §5.9](SPEC.md#59-库存预占写路径2026-11-07-落地) ·
[§5.10](SPEC.md#510-有效期口径2026-11-07-落地) ·
[§5.21](SPEC.md#521-源侧的售卖份数区间口径2026-11-11-落地) ·
[§5.22](SPEC.md#522-按团报价的单位价口径2026-11-11-落地)。

异构融合的三种供给形态（单张 / 配方 / 套装）与改派口径见
[SPEC §5.12](SPEC.md#512-组合映射口径2026-11-07-落地) —
[§5.20](SPEC.md#520-改派的口径2026-11-11-落地)。

```bash
make order-demo                                       # 端到端演示：找有售价的日期 → 下单 → 幂等重放 → 查单
./bin/tc-connect order place --db ticket_center --request req.json
./bin/tc-connect order show  --db ticket_center --id 7
./bin/tc-connect order stale  --db ticket_center
./bin/tc-connect order reassign --db ticket_center --order 7 --item 3 --reason "源侧降价了"
./bin/tc-connect fulfill show --db ticket_center --order 7
./bin/tc-connect refund show  --db ticket_center --refund 1
./bin/tc-connect redeem scan  --db ticket_center --code TKT-001
./bin/tc-connect redeem show  --db ticket_center --voucher 3
./bin/tc-connect redeem overdue --db ticket_center              # 到期却还停在 issued 的券（过期作业漏跑）
./bin/tc-connect redeem expire  --db ticket_center              # 跑凭证过期作业（issued → expired）
./bin/tc-connect stock show  --db ticket_center --supplier-session 1
./bin/tc-connect variant feed    --db ticket_center --channel 1   # 先看哪一天有售价（下面 <日期> 从这里取）
./bin/tc-connect hold create --db ticket_center --no HOLD001 --channel 1 --variant 11 --qty 2 --date <日期>
./bin/tc-connect variant compare  --db ticket_center --product 6
./bin/tc-connect variant coverage --db ticket_center --variant 14
./bin/tc-connect variant bundle   --db ticket_center --variant 21
./bin/tc-connect variant supply  --db ticket_center --variant 18
```

`<日期>` 不是占位符的客气话 —— **种子里的日期是 `current_date + N`**（`db/seed.sql`），
所以任何写死的绝对日期都会随灌库那天烂掉，`variant feed` 打印的才是当天真的有售价的日子。
演示脚本（`make order-demo`）也是自己找有售价的日期，不写死。

`hold create` 不带 `--ttl` 时用默认 900 秒（不变量 119 守着「预占必须有确定的到期时间」）。

**写路径的实测证据**：

| 证据 | 结果 |
|---|---|
| 幂等重放 | 同键同内容返回同一张单；同键异内容当场报错 |
| 重复收款 | 另一笔流水打进已付订单 → 报错，不静默吞掉（`006` 守卫） |
| 订单履约状态 | 由明细的实际出票情况推导，调用方 UPDATE 即为设计事故（不变量 60） |
| 退款金额 | 必须等于订单实付；行级退款明确报错（分摊口径与源侧部分取消都还没落地） |
| 退款放行 | `fn_complete_refund` 只接受 `approved` 的退款单，其余状态当场报错（不变量 93） |
| 核销 | 扫票记录永远追加；第二张扫同一张券 → `duplicate` + 带回第一次的记录 id 与时间（`ux_redemption_single_success`） |
| 库存 | 源侧快照与我们自己的承诺对账（`unreflected = our_sold − source_sold`），不各减一遍；取不到快照返回「不知道」而不是 0 |
| 有效期 | 读 `product_axis_option.valid_days`，不写死 `+1`（不变量 73-75） |
| 份数区间 | 按团报价 1 个人不能按团价成交；接不住当场报错说清源 / 日期 / 区间 / 份数（不变量 113-115） |
| 单位价 | 按团总价 1200 / 团成本 1100 → 明细里记分摊到人的 171.43 / 157.14（不变量 116-118） |
| 改派 | 重复改派返回 `no_change`，留痕不追加（不变量 109-112） |

**异构融合的实测证据**：

| 证据 | 结果 |
|---|---|
| 覆盖映射 | 29 行覆盖映射；方向 A（`coverage`）与方向 B（`supplier_variant_composition`）两侧都有声明（不变量 79、80） |
| 组合成分 | 6 组合成分行 + 2 套装成分行；配对关系由 `component_variant_id` 显式记着，不靠猜 |
| 组合成本 | Σ 成分单价 × 份数，从**源侧配方**取，不重新选源（不变量 82-88） |
| 组合有效期 | 成分窗口的并集：2 份两日成人 + 1 份一日儿童 = 2 天（不变量 89） |
| 预订单位 | 一个源 SKU 一条预订（`ux_booking_one_per_source_sku`），成分的拆分留在请求明细里（不变量 87、88） |
| 套装 | 三个单位不许混：1 套 = 3 份入场；有效期必须盖住成分窗口的并集（不变量 97、99） |
| 供给形态对照 | `v_variant_supply_forms` 一行一个「可售单元 × 一天 × 渠道 × 形态」（不变量 102-104） |
| 源下架 | 成分行留着只是没价；形态不消失；缺口点名「源 SKU 已下架」（不变量 105-107） |
| 可履约源数 | 单张按路由算，配方与套装按声明的源算，不是价格行数（不变量 108） |

**C 端只读 API（2026-11-10）**：`cmd/tc-api` + `internal/capi`，四个业务端点
（浏览 / 变体差异 / 套餐构成 / 日历）+ `/healthz`。只读读模型，**不在请求链路里
join 主数据**；只服务 `channel_type = 'b2c_own'` 且 `status = 'active'` 的渠道，
四个收 `channel_id` 的端点走同一个闸门 `requireChannel`。

```bash
make api                                     # 起服务（默认 :8080，库 ticket_center）
curl -s "http://127.0.0.1:8080/api/v1/products?channel_id=1&locale=zh-CN"
curl -s "http://127.0.0.1:8080/api/v1/products/6/variants?channel_id=1"
curl -s "http://127.0.0.1:8080/api/v1/variants/19/composition?channel_id=1"
curl -s "http://127.0.0.1:8080/api/v1/variants/19/calendar?channel_id=1"
```

渠道（`channel_id`）是必答的：读模型按渠道建，不按渠道过滤会把份数数成两遍。
渠道不存在与渠道不对外服务给**同一个答复** —— 不给调用方一个能枚举渠道的探针。
（[SPEC §5.18](SPEC.md#518-c-端只读-api-的口径2026-11-10-落地)）

**C 端读模型的实测证据**：

| 环节 | 结果 |
|---|---|
| 列表页直出 `v_c_listing_feed` | 9 张卡片，无额外 join；同一商品 C2C 起价 ¥95 / B2B 起价 HK$88 |
| 详情页聚合 `v_c_product_detail` | 香港故宫：3 亮点 / 5 须知 / 5 包含项 / 5 标签 / 3 评价 一次拿到 |
| 日历 `c_product_calendar` | 含 `sold_out` / `closed` 格子（前端要画灰，不是"这天不存在"） |
| 变体日历 `c_variant_calendar` | 同一天不同变体价格不同、可履约源数不同；`valid_to` 由库算好，前端不自己加一天 |
| 变体差异 `c_variant_facts` | 人群 / 轴取值 / 有效天数 / 退款口径进读模型，不在请求链路里 join 主数据算 |
| 组合构成 `c_variant_composition` | 成分 + 份数 + 人群编码（不选标签）；与主数据分叉由不变量 90 当场抓住 |
| 读模型漂移 `v_c_readmodel_drift` | 9 张卡片全部 `drifted=f` |

---

## 目录

| 文件 | 内容 |
|---|---|
| [`SPEC.md`](SPEC.md) | 业务合同：范围、角色、流程、**不变量**、状态机、验收标准 |
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
| [`internal/`](internal/) | **接入层实现**：传输层 / 凭证 / 归一化 / 各源适配器 / 归档幂等 / 定价读侧 / 迁移引擎 / 读模型刷新 / 状态机读侧 / 下单 / 改派 / 履约 / 退款 / 核销 / 库存 / 异构差异读侧 / 覆盖语义 / 组合配方写侧 / **C 端 API** / mock / 业务 ID / 测试库 |
| [`configs/`](configs/) | 传输层配置（端点 / ICODE / 凭证口径 / 错误码）+ 映射规则（单一真相） |
| [`fixtures/`](fixtures/) | 真实报文结构的样例（canonical / trip_com / globaltix） |
| [`scripts/mapping_dryrun.py`](scripts/mapping_dryrun.py) | **无凭证集成演练**：用真实报文结构跑一遍 mapping → 路由（归一化调用 Go 实现） |
| [`scripts/order_demo.py`](scripts/order_demo.py) | **下单链路演示**：找有售价的日期 → 下单 → 幂等重放 → 查单 |
| [`scripts/poc/index.html`](scripts/poc/index.html) | 前端 POC：变体矩阵 / 覆盖语义匹配 / 变体级路由 / 模型缺口（演练生成物） |
| [`Makefile`](Makefile) | build / test / mock / layers / dryrun / db / check / order-demo / api |
| [`AGENTS.md`](AGENTS.md) | 仓库级硬约束与命令约定 |

---

## 下一个阶段

- [ ] **拿到 Trip.com 分销侧凭证**（`aid` / `sid` / `key`）→ 跑沙箱 + 生产分层测试，核对 4 个待确认点（见 `docs/integrations.md`）
- [ ] 拿到 **GlobalTix 接口文档** → 填 `configs/api_config.json` 的端点与请求体 → 启用适配器
- [ ] 其余五源（Ingresso / JTB / Zowoyoo / FonTicket / 票付通）的接口文档到位后逐个实现
- [x] **组合映射表** `supplier_variant_composition`（GlobalTix 的 `A|2+B|1` 能表达了，规范侧声明 + 源侧配方两侧对得上）
- [x] **组合套餐真的能卖**：定价（成本 = Σ 成分单价 × 数量）、预订（按源 SKU 带整组源 SKU）、出券（一张组合按成分出几张券）都接上了 —— 见下面「组合套餐可售」
- [x] **预订的单位 = 源 SKU**：参数化源里成人与儿童是同一个源 SKU，按成分建预订就是同一个源 SKU 订两次（源侧两张订单单、对账对不上、退款退不掉）—— 见上面「预订的单位是源 SKU」
- [x] **组合进 C 端读模型**：组合的售价行由 `fn_sync_combo_calendar()` 推出来，构成进 `c_variant_composition`（10 行），有效期终点 = 成分窗口的并集（不变量 89）—— 见上面「组合在 C 端」
- [ ] 接入层之上的**业务编排作业**（同步调度 / 改派 / 自动补报 / 退款重试）
- [ ] B 端管理台：商品/上架/路由/映射审核/异常单
- [ ] C 端链路：搜索 → 详情 → 选场次 → 下单 → ~~出券 → 核销~~（出券与核销的写路径都已落地；**读侧已开成 HTTP 接口** —— `cmd/tc-api` 的浏览 / 变体差异 / 套餐构成 / 日历四个端点；剩下的是搜索、详情界面与购买链路的写侧，还差调用方身份与鉴权）
- [ ] 订单表分区、只读副本、源报文冷热分离（方案见 `docs/schema-design.md` §9）
