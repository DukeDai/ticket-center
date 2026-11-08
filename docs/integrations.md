# 供应源接入层（Go）

多源票券中心的**外部系统接入层**：把各家 GDS / 票务平台的原始报文，
按统一口径归一化成我们的源商品 / 源变体 / 源成本价，并守住三条底线——
**凭证不外泄、错误不乱重试、原始报文必归档**。

> 零第三方依赖：HTTP 用标准库 `net/http`，数据库用 `psql` 子进程。
> 业务口径见 [`connector-contract.md`](connector-contract.md)。

---

## 快速开始

```bash
make build          # 构建 bin/tc-connect
make test           # 单元测试
make mock           # 协议级自检（本地 mock，14 项断言，不需要凭证）
make layers         # 分层连通性测试（真实端点）
make check          # 提交前完整自检（vet + test + mock + 演练器）
```

---

## 包结构

```
cmd/tc-connect/              CLI：sources / layers / mock / normalize / compose / price / migrate / refresh / order / fulfill / refund / redeem / stock / hold / variant
internal/
  apperr/                    错误四分类 + 缺失凭证 + 端点未确认
  credential/                凭证解析（环境变量优先 → supplier.auth_config）
  transport/                 HTTP 客户端：退避重试 / Retry-After / 脱敏
  config/                    传输层配置（端点 / ICODE / 错误码映射）
  normalize/                 归一化核心（配置驱动，无按源分支）
  pricing/                   定价入口（读 fn_price_variant 的结果，**不算钱**）
  store/                     DB 访问（psql 子进程）+ 报文归档 + 幂等
  supplier/                  端口定义与公共基类
    tripcom/                 Trip.com 分销侧适配器
    globaltix/               GlobalTix Supply API 适配器（端点待商务确认）
    pending/                 接口细节未核实的源的占位适配器
  registry/                  supplier.code → 适配器
  layertest/                 分层测试引擎 + 离线自检 + 协议自检
  migrate/                   迁移引擎：账本 + 内容校验和 + 幂等 + 并发互斥
  readmodel/                 C 端读模型：刷新（口径在库里）与漂移检查 + 组合的售价行/日历格子同步
  transaction/               交易域读侧：状态机的合法流转与领域事件
  order/                     下单：拼参数 / 收结果（不重算金额，不重排源）
  fulfillment/               履约：支付 / 预订 / 出券（只调库里的函数，不自己算状态）
  refund/                    退款：发起 / 放行 / 完成（只调库里的函数，不自己判资格）
  redemption/                核销：扫票 / 查券（只调库里的函数，不自己判能不能进场、不自己算扣多少额度）
  inventory/                 库存：查可售 / 预占 / 放掉（只调库里的函数，不自己算可售数、不自己判够不够）
  variant/                   异构差异读侧：对照表 / 源覆盖缺口 / C 端读视图 + 组合构成（只读视图，不重算有效天数与覆盖判定）
  compose/                   组合映射写侧：组合表达式 → 配方（核组件、核数量；覆盖判定走库里的 fn_variant_covered）
  mock/                      Trip.com 分销侧协议 mock（标准库 net/http）
  idgen/                     请求级 UUID（追踪位，**不是**幂等键）
configs/                     api_config.json / mapping_rules.json（仓库根）
fixtures/                    真实报文结构的样例（仓库根）
```

---

## 设计纪律

1. **源差异只在配置里。** `configs/api_config.json` 声明端点、21 个接口的
   沙箱/生产 ICODE、凭证口径、错误码映射；`configs/mapping_rules.json` 声明
   报文路径与轴取值映射。代码里**没有** `if supplier == "xxx"` 这类分支。
2. **凭证只从环境变量读**（其次 `supplier.auth_config`）；取值不打印、
   不序列化、不写库；报文归档前递归脱敏（token / key / refresh_token /
   Authorization / password…）。
3. **错误四分类决定重试与否。** `retriable` / `rate_limit` 才重试；
   `fatal`（库存不足之类）**立即失败**并改派备源；`auth` 刷新 token 后最多再试 1 次。
4. **幂等命中不是失败。** 携程 `B0010`（重复下单）被识别并标记为幂等命中。
5. **没有公开文档的接口不许编造。** 端点、请求体、字段名留在配置里，
   遇到未确认接口抛 `EndpointUnconfirmed`，明确说出卡在哪、需要什么。
6. **原始报文必归档**（`supplier_raw_payload`），落库前脱敏。
7. **钱不在 Go 里算。** 定价的唯一实现是库里的 `fn_price_variant`，
   `internal/pricing` 只读结果。Go 标准库没有十进制类型，`float64` 接住 `NUMERIC`
   迟早差一分钱；更麻烦的是同一批源数据会被算出多个价格。
8. **状态不在 Go 里推导。** 下单走 `fn_place_order`，履约走 `005` 里的八个函数，
   退款走 `007` 里的三个函数，核销走 `008` 里的 `fn_redeem_voucher`，
   可售数与预占走 `009` 里的 `fn_available_qty` / `fn_reserve_qty` / `fn_hold_inventory`；
   Go 侧只拼参数、只读结果。履约状态是结论，
   结论只有一个算法 —— Go 里再实现一遍，等于两个人各自数一遍出票张数。
   退款的资格与金额同理：Go 里再判一遍「能不能退」，就有两份规则。
   核销的能不能进场同理：Go 里再判一遍，就有两份「这张票进不进得去」的口径。
   可售数同理：Go 里再减一遍，就有两份「还剩多少」——
   而源侧快照与我们的承诺必须对账才能算对（`unreflected = our_sold − source_sold`），
   这一步写错一次就会越卖越少。
9. **有效期不在 Go 里算。** 有效期长度住在轴选项上（`product_axis_option.valid_days`），
   唯一读法是库里的 `fn_variant_validity_days()`。Go 侧再写一遍「两天就是 +1 天」，
   就多了一个能悄悄写错的地方 —— 写错的后果是卖了两日票发一天有效期的券。

---

## CLI

### `tc-connect sources` — 看有哪些源、各自什么状态

```
✅ trip_com           rest-json      tripcom.Adapter      POST + URL query 传参…
⏳ globaltix          rest-json…     globaltix.Adapter    端点与请求体无公开文档…
⏳ ingresso           xml (OCTO)     pending.Adapter       文档不公开…
```

### `tc-connect layers` — 分层连通性测试

分层顺序：**连通 → 认证 → 目录 → 详情 → 价格 → 映射 → 路由**。

```bash
./bin/tc-connect layers                              # 全部源
./bin/tc-connect layers --supplier trip_com --env prod
./bin/tc-connect layers --offline                    # 完全不外呼
```

没有凭证时 L0 连通性照跑（不需要凭证），L1 起明确报出缺哪个环境变量：

```
【trip_com】
  ✓ L0 连通    业务：TCP openservice.open.uat.ctripqa.com:443 可连接（66ms）；认证：…:80 可连接（14ms）
  – L1 认证    缺少凭证：aid（环境变量 TRIPCOM_AID）；sid（环境变量 TRIPCOM_SID）；key（环境变量 TRIPCOM_KEY）
  – L2 目录    凭证缺失（见 L1）
```

原始报文归档到独立库 `ticket_center_integration`，**不污染主库**。

### `tc-connect mock` — 协议级自检

用本地 mock 按官方规格跑通完整链路，**不需要任何凭证**：

| 断言 | 验证内容 |
|---|---|
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

另有 4 项离线自检（配置完整性 / 归一化自检 / 组合表达式解析 / 凭证脱敏）。

### `tc-connect normalize` — 归一化（脚本可消费的稳定接口）

```bash
./bin/tc-connect normalize --source trip_com --fixture fixtures/trip_com_catalog.json
```

输出源商品 / 源变体 / 覆盖声明 / 报价行的 JSON。
`scripts/mapping_dryrun.py` 通过它落库，保证**归一化只有一个实现**。

### `tc-connect compose` — 组合映射（异构融合的方向 B）

```bash
./bin/tc-connect compose plan  --source globaltix --fixture fixtures/globaltix_catalog.json --db ticket_center
./bin/tc-connect compose apply --source globaltix --fixture fixtures/globaltix_catalog.json --db ticket_center
```

源侧的组合表达式长这样（GlobalTix 官方示例）：

```
mappingId: 80041201-8004120101|2 + 80041201-8004120102|2 + 80041902-8004190201|1 + 80041902-8004190202|1
           成人门票×2            + 成人快速通行证×2     + 儿童门票×1            + 儿童快速通行证×1
```

`plan` 只解算不写库，`apply` 落库。输出：

```
组合 family:2adult:1child（规范变体 12）
  adult:1d:studio_only       × 2    ← 源 SKU 80041201-8004120101
  adult:express              × 2    ← 源 SKU 80041201-8004120102
  child:1d:studio_only       × 1    ← 源 SKU 80041902-8004190201
  child:express              × 1    ← 源 SKU 80041902-8004190202
  整张配方合起来覆盖得住这个组合
```

**这个命令不重算任何口径**：能不能覆盖住由库里的 `fn_variant_covered` 判定
（Go 侧只调它，不在 Go 里再写一份），数量比选用 `math/big.Rat`（不用浮点）。
写库是幂等 upsert：同键同内容幂等命中，源侧撤掉的成分置 `retired` 而不是删 ——
历史要对账，删了就说不清当初出票是按什么配方。

`--json <path>` 导出结构化结果（演练器读它，不读终端文本）。

### `tc-connect price` — 定价（走库里的唯一实现）

```bash
./bin/tc-connect price --variant 11 --date 2026-11-18
./bin/tc-connect price --reprice
```

单变体查询的输出：

```
变体 11 · 2026-11-18
  采纳源商品 9（CNY）
  源净价 486.00 → 成本 486.00 CNY（汇率 1（同币种））
  售价 498.00  [锁价]   划线价 498.00（折扣 0%）
```

括号里是这次折算的留痕：`汇率 <因子> @ <快照日期>`。源币种与本行币种相同（没折算）时显示「汇率 1（同币种）」——
没折算过就不假装折算过（库里那一行的 `fx_as_of` 也是 NULL）。

`--price-channel <id>` 查渠道专属价：上下文渠道与结算渠道是同一个渠道，只给 `--price-channel` 时上下文跟着走。

`--reprice` 重算库里所有在售售价行，随后列出没定上价的行（缺源报价 / 缺上架关系 / 缺汇率快照），
有则非零退出。源成本变了、汇率快照换了、上架关系改了，都走这一条路，不写局部补丁。

金额一律以字符串返回（库里是 `NUMERIC`，`float64` 接住就是丢精度）。

### `tc-connect migrate` — 库结构迁移

```bash
./bin/tc-connect migrate --db ticket_center            # 应用待应用的迁移
./bin/tc-connect migrate --db ticket_center --status   # 哪些已应用、哪些待应用
./bin/tc-connect migrate --db ticket_center --dry-run   # 只算计划
./bin/tc-connect migrate --db ticket_center --baseline 001   # 接管存量库
```

物理模型只增不改，而且由机制保证：迁移引擎把每个文件的 sha256 记进账本
`ops.schema_migration`，**已应用的迁移文件被改动，引擎直接拒绝继续跑**。
整轮迁移在一个 psql 会话里跑（会话级互斥锁挡住并发改结构），每个迁移一个事务
（建表与记账同一事务，崩了不留半截）。细节见 `docs/schema-design.md` §10。

### `tc-connect refresh` — C 端读模型刷新与漂移检查

```bash
./bin/tc-connect refresh --db ticket_center          # 刷新读模型并报告漂移
./bin/tc-connect refresh --db ticket_center --check   # 只查漂移（漏跑时非零退出）
```

刷新的口径写在库里的 `fn_refresh_read_models()`，Go 侧只负责调用与报告 ——
读模型的口径不在应用层再写一遍。漂移检测用 `v_c_readmodel_drift`：
卡片起价与价格日历算出来的真值不一致，就是刷新作业漏跑了。

**刷新之前先同步组合**（`fn_sync_combo_calendar()`）。组合源侧没有商品条目，
目录同步作业看不见它 —— 它的售价行与日历格子得自己推。
不先推，刷新出来的 C 端就没有套餐（组合会静默地缺席，不是报错）。
同步是幂等的，重复跑不会多出价格行，也不会多出格子。

### `tc-connect order` — 下单与查单

```bash
make order-demo                                       # 端到端演示（自己找有售价的日期）
./bin/tc-connect order place --db ticket_center --request req.json
./bin/tc-connect order show  --db ticket_center --id 7
```

`make order-demo` 走一遍完整链路：找一天有售价的日期 → 下单 → 重复提交（幂等命中）→ 查单。
演示脚本不写死日期 —— 种子数据用 `current_date+N` 写日期，写死的样例文件过几天就失效。

请求走文件（`--request`）：下单的入参是领域对象（明细 + 实名 + 联系信息），
摊成一排命令行参数反而更容易拼错。文件格式：

```json
{
  "channel_id": 1,
  "customer_id": 3,
  "idempotency_key": "cli-demo-001",
  "items": [{"variant_id": 9, "quantity": 2, "visit_date": "2026-11-19"}],
  "holders": [
    {"variant_id": 9, "sequence": 1, "field_code": "holder_name", "value": "张三"},
    {"variant_id": 9, "sequence": 1, "field_code": "id_number", "value": "H110101199001011234"}
  ],
  "contact": {"phone": "13800000000"},
  "buyer_note": ""
}
```

下单的实现只有一个：库里的 `fn_place_order()`。Go 侧不重算金额，也不重排源 ——
理由与 `tc-connect price` 一样：钱在 Go 里算不出可复现的结果，
选源在 Go 里再排一次就会出现「按 A 源的价格卖、按 B 源出票」。

幂等由库保证：同一渠道 + 同一幂等键，重复提交返回同一张单（输出「幂等命中」）；
同一个键配不同内容直接报错。名的字段、份数、长度、格式按 `checkout_requirement` 收，
收不齐就报错 —— 报的是「订单行（变体 9）要求实名信息：持票人姓名 需要 2 份，实收 0 份」。

**组合套餐的实名多一个 `item_index`**：同一个成分变体出现在多行明细里时，
光看 `variant_id` 分不出持票人属于哪一行，`item_index` 指明是哪一行明细（1 起）。
带 `item_index` 的实名必须全带 —— 一半带一半不带直接报错（部分归属的实名会把票发错人）：

```json
  "holders": [
    {"variant_id": 18, "item_index": 1, "sequence": 1, "field_code": "holder_name", "value": "王大明"},
    {"variant_id": 18, "item_index": 2, "sequence": 1, "field_code": "holder_name", "value": "王小明"}
  ],
```

### `tc-connect fulfill` — 支付 → 预订 → 出券

```bash
./bin/tc-connect fulfill pay      --db ticket_center --order 7 --method alipay \
                                   --amount 1171.60 --currency CNY --provider alipay --txn ALI-001
./bin/tc-connect fulfill book     --db ticket_center --order 7
./bin/tc-connect fulfill request  --db ticket_center --booking 12 [--request req.json]
./bin/tc-connect fulfill attempt  --db ticket_center --booking 12 --response resp.json \
                                   [--http-status 200] [--latency-ms 120] [--error-type retriable]
./bin/tc-connect fulfill complete --db ticket_center --booking 12 --status confirmed \
                                   --external-booking-id EXT-BK-001 [--code C1 --code C2]
./bin/tc-connect fulfill issue    --db ticket_center --booking 12 [--code C1 --code C2]
./bin/tc-connect fulfill retry    --db ticket_center --booking 12 [--next-retry-at RFC3339]
./bin/tc-connect fulfill show     --db ticket_center --order 7
```

`fulfill show` 是只读的：把一张订单的支付、预订、票码和当前状态一次打出来，
排查时不用连查四张表。

实现同样只有一个：`db/migrations/005_fulfillment.sql` 里的八个函数。
Go 侧**不**判断状态该往哪走、不算履约状态、不拼票码与持票人的对应关系。
理由和 `tc-connect price` / `tc-connect order` 一样：规则住在库里，
Go、psql、脚本走的是同一条路。

几条会当场报错的：

- 金额与订单应付不符 → 「支付金额与订单应付不符：订单 TC2026… 应付 1171.60，实付 1200.00」；
- 币种不符 → 报错；
- 同一笔渠道流水重放 → 幂等命中，不新记一笔；
- **另一笔流水打进已付订单 → 重复收款，当场报错**，要人走退款流程；
- 票码数与要发的张数不符 → 报错；
- 确认预订没给源侧预订号 → 报错（没有它就无法回头找源对账）。

源侧没给票码时我们生成一个 128 位随机码（`VC-` + 32 位十六进制），
不拿连号的券号顶上 —— 券号是内部标识，票码是闸机认的东西（`016` 收紧，不变量 94）。

**预订的单位是源 SKU**（2026-11-08 修订）：`fulfill book` 给一张订单建预订时，
**一个源 SKU 建一条**，不是每个成分建一条。参数化源里成人票与儿童票是同一个源 SKU
（`ZWO-1D-BASE`，人群是购买时选的一档），按成分建就是同一个 SKU 订两次 ——
源侧看到两张订单单，我们这边一条客户订单对两个源单号。
组合套餐因此只有一条预订，出券时按成分分下去（成人 2 张、儿童 1 张）。
一条预订覆盖哪些成分由库里的 `fn_booking_components` 推出来，Go 侧不自己算；
`fulfill show` 里看到的就是这个口径。

金额参数是十进制文本，不是浮点：Go 里 `1171.60` 传成 `float64` 会变成
`1171.5999999999999`，落库就成了另一笔钱。包里用正则校验，不走 `ParseFloat`。

### `tc-connect refund` — 发起 → 放行 → 完成

```bash
./bin/tc-connect refund request  --db ticket_center --order 3 --amount 368.00 \
                                 --key RF-001 --reason "源侧预订失败" --by ops@test
./bin/tc-connect refund approve  --db ticket_center --refund 1 --by boss@test
./bin/tc-connect refund complete --db ticket_center --refund 1 --success \
                                 --supplier-refund-id EXT-RF-001 [--payload resp.json]
./bin/tc-connect refund complete --db ticket_center --refund 1 --fail \
                                 --error-code SOURCE_TIMEOUT --error-message "源侧超时"
./bin/tc-connect refund show     --db ticket_center --refund 1
```

实现同样只有一个：`db/migrations/007_refund.sql` 里的三个函数。
Go 侧**不**判断能不能退、不算该退多少、不改订单状态。
理由和 `tc-connect price` / `tc-connect order` 一样：规则住在库里，
Go、psql、脚本走的是同一条路。

`--success` 与 `--fail` 必须明确给一个 —— 落「成功」意味着钱退回来了，
不能靠默认值猜。

几条会当场报错的：

- 退款金额与订单实付不符 → 「退款金额与订单实付不符：订单 TC2026… 实付 368.00，申请退 0.01」；
- 订单没有成功的支付记录 → 「订单 TC2026… 没有成功的支付记录，无款可退」；
- 票已核销 → 「订单 TC2026… 有已核销的票，不能整单退款 —— 请人工处理」；
- 同一个幂等键配不同内容 → 「幂等键 RF-001 已用于另一笔退款请求（订单 TC2026…）」；
- 缺幂等键 → 「缺少幂等键（退钱的操作重放一次就多退一次）」；
- 已经退过款 → 「订单 TC2026… 已经退过款」。
- **没放行就想落结果 → 「退款单 RF2026… 当前状态 requested 不能完成（只允许已放行的退款单）」**
  （`016` 收紧，不变量 93）。放行是必经之路，放行人与放行时间记在退款单上。

退款失败时（`--fail`），订单照发起退款前的状态退回去
（记在 `sales_refund.previous_order_status`），退不回去就留在 `refunding` 等人处理。

### `tc-connect redeem` — 扫票 → 结果

```bash
./bin/tc-connect redeem scan --db ticket_center --code TKT-001 \
                              [--gate 1 --gate-operator 2 --device POS-01 --operator alice] \
                              [--payload scan.json] [--json out.json]
./bin/tc-connect redeem show --db ticket_center --voucher 3 [--json out.json]
```

`scan` 扫一次票，`show` 看这张券和它的核销流水（从新到旧）。
`--code` 与 `--voucher` 至少给一个：闸机扫的是票码，后台补录给的是券 id。

实现同样只有一个：`db/migrations/008_redemption.sql` 里的 `fn_redeem_voucher`。
Go 侧**不**判断券能不能进场、**不**算该扣多少额度、**不**改券状态 ——
理由和 `tc-connect price` / `tc-connect order` 一样：规则住在库里，
Go、psql、脚本走的是同一条路。

**扫票结果不是异常，只有票码不存在 / 不唯一才报错。**
券过期、券作废、券还没出票、订单在退款、闸机停用 —— 这些都是扫票的正常结果：
返回 `result` 与 `reason` 给闸机看，同时在库里留一条记录。

| `result` | 含义 |
|---|---|
| `success` | 核销成功，券从 `issued` 变 `used`，入场额度一次用尽 |
| `duplicate` | 这张券之前已经成功核销过；`original_redemption_id` / `original_scanned_at` 带回第一次核销的记录与时间，调用方据此对账 |
| `expired` | 过期了（`reason='past_valid_to'`；券状态本身已经是 `expired` 的记 `voucher_expired`） |
| `revoked` | 作废 / 已退款（`reason='voucher_void'` / `voucher_refunded'`） |
| `failed` | 没过。`reason` 说清为什么：`not_yet_valid` / `voucher_not_issued` / `no_entitlement` / `entitlement_exhausted` / `order_refunding` / `gate_inactive` |

会当场报错的：

- 票码不存在 → 「票码 TKT-001 不存在」；
- 票码命中多张凭证 → 「票码 TKT-001 不唯一（命中 N 张凭证），无法确定是哪一张」；
- 给了闸机但闸机不存在 → 「闸机 N 不存在」。

**核销记录永远追加**：重复扫票记 `duplicate`，不覆盖前一次。
一张券最多成功核销一次由唯一索引 `ux_redemption_single_success` 兜底，不靠约定。

### `tc-connect stock` / `tc-connect hold` — 可售数与预占

```bash
./bin/tc-connect stock show  --db ticket_center --supplier-session 1 [--ticket-type 1] [--json out.json]
./bin/tc-connect hold create --db ticket_center --no HOLD001 --channel 1 --variant 11 \
                              --qty 2 --date 2026-11-18 [--cart 3] [--ttl 900] [--json out.json]
./bin/tc-connect hold release --db ticket_center --no HOLD001 [--reason cart_abandoned] [--json out.json]
./bin/tc-connect hold expire --db ticket_center [--limit 500] [--json out.json]
./bin/tc-connect hold show   --db ticket_center --no HOLD001 [--json out.json]
```

`stock show` 回答「这个源场次还剩多少」，`hold` 管住「谁占着」。
实现同样只有一个：`db/migrations/009_inventory_hold.sql` 里的
`fn_available_qty` / `fn_reserve_qty` / `fn_hold_inventory` / `fn_release_hold` / `fn_expire_holds`。
Go 侧**不**算可售数、**不**判断够不够、**不**改预占状态。

`stock show` 的输出里 `known` 是关键：

| `known` | 含义 |
|---|---|
| `true` | 源侧给了库存数据，`remaining_qty` 是真的还能卖多少 |
| `false` | **不知道**（没有库存快照也没有可用性缓存）。`remaining_qty` 为 NULL —— 不是 0 |

「不知道」不许当成 0：0 意味着卖完了，会让整个商品下架。
不知道的时候下单不拦，但当时看到的数会写进明细的 `availability` 快照，事后对账用。

`hold create` 的 `--no` 是幂等键：同键同内容重放返回同一张预占，
同键异内容报错（重放一次预占等于凭空多占一份）。

`hold release` 重复调用返回「已经放过了」，不报错 —— 放占是幂等的。
`hold expire` 是 TTL 作业，只动已过期且仍 `active` 的预占。

### `tc-connect variant` — 异构差异的三个视角

```bash
./bin/tc-connect variant compare  --db ticket_center [--product 6] [--json out.json]
./bin/tc-connect variant coverage --db ticket_center [--variant 14] [--json out.json]
./bin/tc-connect variant feed     --db ticket_center [--channel 1] [--product 6] [--json out.json]
./bin/tc-connect variant composition --db ticket_center [--variant 18] [--channel 1] [--json out.json]
```

| 子命令 | 回答什么问题 | 读什么 |
|---|---|---|
| `compare` | 这个商品的可售单元差在哪？ | `v_variant_comparison` |
| `coverage` | 哪些源能供这个单元、缺什么？ | `v_variant_source_coverage` |
| `feed` | C 端读模型里的变体行长什么样？ | `v_c_variant_feed` |
| `composition` | 这张套餐由谁组成？（几份成人、几份儿童、各管几天） | `v_c_variant_composition` |

三个子命令都只读视图，**不重算任何口径**：有效天数走 `fn_variant_validity_days`，
覆盖判定走 `fn_variant_covered`。在 Go 里再写一遍就是第二份实现 ——
两份实现迟早分叉，而分叉的后果是「展示说两日票、发出来的是一天有效期的券」。

`feed` 是 C 端请求链路真正读的那一层：差异事实（人群 / 轴取值 / 有效天数 / 退款口径）
加上本渠道的价格区间与可售天数，一行一变体，前端不用再 join 主数据。
组合另带四列：`is_combo` / `combo_audience` / `component_count` / `composition` ——
**人群是编码不是文案**，「2 成人 + 1 儿童」这句话由前端按 locale 拼。

---

## 拿到授权后

```bash
export TRIPCOM_AID=… TRIPCOM_SID=… TRIPCOM_KEY=…
./bin/tc-connect layers --supplier trip_com --env sandbox   # 先沙箱
./bin/tc-connect layers --supplier trip_com --env prod      # 再生产
```

要盯的四个点（详见 `docs/connector-contract.md` §9.10）：

1. 2.1 取 token 的返回字段名与真实报文的差异；
2. 业务层 token 过期的真实错误码（`1004` 还是 `V0003`）；
3. `searchProduct` 必填参数的真实可用值；
4. 价格日历是否真的返回 `calendarDetailList`（若与规格不同，归一化要再改一处）。
