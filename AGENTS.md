# AGENTS.md — ticket-center

多源票券中心（OTA 票券中台）。PostgreSQL 15+。

## 这是什么

一个把多个 GDS / 票务平台（Ingresso、FonTicket、Goodfellows·JTB、GlobalTix、票付通…）的票券
归一化成统一模型，同时支撑 **B 端分销**与 **C 端自营**售卖的中台。

**当前阶段聚焦领域模型与物理模型**，API / Web 尚未实施；
**接入层已用 Go 实现**（`cmd/tc-connect` + `internal/`）：Trip.com 分销侧协议已完整核对，
GlobalTix 端点待商务确认，其余五源待文档。**Go 1.23+ 是本仓库的必备工具链。**

交易侧四段写路径各有唯一实现，全部在库里：下单 `fn_place_order`（`004`）、
履约八个函数（`005`/`006`）、退款三个函数（`007`）、核销 `fn_redeem_voucher`（`008`）。
Go 侧只拼参数、只读结果 —— 不重算金额、不重排源、不自己算状态、不自己判退款资格、不自己判能不能进场。

## 硬约束

1. **SPEC.md 是合同。** 改任何业务行为，必须同步改 `SPEC.md` 对应章节；改领域模型必须同步改
   `docs/ddd.md`；改表结构必须同步改 `docs/schema-design.md`。规格里列的 101 条不变量不得在改动中丢失。
2. **不变量是门禁。** `v_invariant_checks` 里任何一条 `actual > 0` 即为数据违规，
   `db/verify.sql` 必须全绿才能提交。
3. **DDL 只增不改，而且由机制保证。** 物理模型的唯一来源是 `db/migrations/NNN_*.sql`。
   基线 `001_baseline.sql` 一经应用就不再改；要加列 / 加表 / 改函数就**新增**一个迁移文件，
   写 `ALTER TABLE ... ADD`。迁移引擎（`internal/migrate`）把每个文件应用时的 sha256 记进账本
   `ops.schema_migration`：**已应用的迁移文件被改动，引擎直接拒绝继续跑**。
   存量库用 `tc-connect migrate` 增量升级，用 `tc-connect migrate --baseline 001` 接管。
4. **源的结构不许泄漏进核心域。** 源报文只进 `supplier_raw_payload` / `supplier_product.raw_payload`；
   归一化只走 `product_mapping` / `attribute_mapping_rule` 两条路径。
   业务代码里出现 `if (supplierCode === 'xxx')` 视为设计事故。
5. **金额一律 `NUMERIC`，禁止浮点。** 币种是行级字段，跨币种比较必须先折算到基准币种（`fx_rate`）。
6. **汇率用快照，不用实时。** 成本必须可复现、可对账。
7. **历史不可变。** 订单与明细的展示内容走快照字段（`detail_snapshot` / `pricing_snapshot`），
   不依赖当前商品表的 join 结果。
8. **源不可信。** 外部请求必须幂等（`idempotency_key`）、错误必须归一到四分类
   （`retriable` / `fatal` / `auth` / `rate_limit`）、原始报文必须归档。
9. **要渲染给用户看的文案必须有 locale。** 展示文案一律行级表 + `locale` 列
   （`product_highlight` / `product_inclusion` / `product_note`）；
   `product.attributes` 只放语言无关的结构化事实。
10. **C 端列表/日历只读读模型。** 查询打 `c_product_card` / `c_product_calendar`，
    不在请求链路里 join 主数据。读模型可重建，主数据是唯一真相。
    刷新作业漏跑时 `v_c_readmodel_drift.drifted = true` 会暴露出来。
11. **接入层零第三方依赖。** HTTP 只用标准库 `net/http`，DB 只用 `psql` 子进程；
    不引入 requests / httpx / psycopg / pgx 等。源差异一律进 `configs/api_config.json`，
    代码里不得出现 `if supplier_code == "xxx"`（注册表 `internal/registry` 除外）。
12. **凭证只从环境变量读**（其次 `supplier.auth_config` jsonb）；**不入库、不进仓库、不进日志**，
    报文归档前必须脱敏（token / key / refresh_token / Authorization / password 等）。
    没有凭证就明确报「缺哪个环境变量」，**不猜、不硬编码、不用假值糊过去**。
13. **没有公开文档的接口不许编造。** 端点、请求体、字段名进配置模板并标注「待商务确认」；
    遇到未确认接口抛 `EndpointUnconfirmed`，明确说出卡在哪、需要什么。
14. **归一化只有一个实现。** 在 `internal/normalize`（Go）；Python 侧的演练器通过
    `tc-connect normalize` 消费它，不允许再写一份 Python 版归一化。
15. **选源与定价必须同源。** 候选集与排序键只有一份，在 `fn_route_candidates`；
    路由视图 `v_variant_routing_candidates` 与定价函数 `fn_price_variant` 都从它取。
    两边各排一次序的后果是「按 A 源的价格卖、按 B 源出票」—— 客诉说不清、对账对不上。
    不变量 43 负责证明它没被改回两份。
16. **没折算过就不留汇率快照。** `price_calendar.fx_rate` 的口径是
    「1 单位源币种 = fx_rate 单位本行币种」，`fx_as_of` 是这次折算实际依赖的快照日期
    （两腿取较晚的那一天，留痕日期能独立复算出同一个因子）。
    同币种不折算 → 因子 1、快照日期 NULL。留一个假日期等于声称用过这份汇率，对账会查无此账。
17. **状态机由机制保证，不靠自觉。** 合法流转写在 `state_transition` 表里（唯一来源），
    触发器 `fn_guard_state_transition` 挡住非法流转，触发器 `fn_emit_state_event`
    保证状态一变就落一条领域事件到 `event_outbox`。
    改状态机 = 改那张表 + 同步 `SPEC.md` §5，不是去改某个 Go 分支。
    不变量 46-49 守住「状态必须能从初始状态走到」。
18. **下单有唯一实现。** 订单落库只走库里的 `fn_place_order()`（`db/migrations/004_place_order.sql`）：
    金额与采纳源只从 `fn_price_variant()` 取，Go 侧不另算一遍；幂等键必填，抢键用
    `INSERT ... ON CONFLICT DO NOTHING`（不走「先查后插」）；明细走快照；实名按
    `checkout_requirement` 收齐。预订不在下单里建 —— 源侧故障不阻塞订单聚合。
19. **履约有唯一实现。** 支付 / 预订 / 出券只走库里的 `fn_record_payment()` /
    `fn_create_bookings()` / `fn_request_booking()` / `fn_record_booking_attempt()` /
    `fn_complete_booking()` / `fn_issue_voucher()` / `fn_retry_booking()` /
    `fn_apply_order_fulfillment()`（`db/migrations/005_fulfillment.sql`），
    Go 侧是 `internal/fulfillment`（只拼参数、只读结果，不另算状态、不另拼票码）。
    三条口径写死：
    - **订单的履约状态不归调用方写。** 只由 `fn_apply_order_fulfillment()` 从明细的
      实际出票情况推导（不变量 60）。谁 UPDATE 一下 `fulfillment_status` 就是设计事故。
    - **票码与持票人一一对应。** 票码数必须等于要发的张数，对不上当场报错；
      按人计价一人一券、按团报价整团一券。
    - **预订的源场次来自绑定。** 取 `product_session_source` 的场次级绑定，
      不按日期猜（不变量 59）。猜错了就是「按 A 源的价格卖、按 B 源出票」。
    另外：**重复收款当场报错**（`db/migrations/006_duplicate_payment_guard.sql`）。
    同一笔流水重放 = 幂等命中；另一笔流水打进已付订单 = 重复收款，要走退款流程 ——
    钱收了两次库里只记一笔，对账时这笔钱会凭空消失，不能静默吞掉。
20. **退款有唯一实现。** 发起 / 放行 / 完成只走库里的 `fn_request_refund()` /
    `fn_approve_refund()` / `fn_complete_refund()`（`db/migrations/007_refund.sql`），
    Go 侧是 `internal/refund`（只拼参数、只读结果，不自己判资格、不自己算退多少）。
    四条口径写死：
    - **退款作用域是整单。** 行级退款需要「优惠券 / 税费 / 折扣怎么摊到每一行」的
      分摊口径 + 源侧支持部分取消 —— 那是业务决策不是工程决策。
      在这两样落地之前，系统对行级退款明确报错，不自己编一条分摊规则。
    - **退款金额必须等于订单实付。** 少退客户投诉，多退公司承担。
    - **「有没有真的收到钱」看支付记录，不看订单状态。** 订单状态是人写的，
      `sales_payment` 里 `status='succeeded'` 的记录才是事实。
    - **幂等键必填，同键异内容报错。** 重放一次退款就是多退一次钱；
      静默返回上一笔等于吞掉一次退款。
    另外：**退款成功后事实一起改**（明细 / 凭证 / 预订 / 支付 / 订单，不变量 61-64）；
    **退款失败时订单照 `previous_order_status` 退回去**，退不回去就留在 `refunding`
    等人处理，不硬改；**有已核销的票不许整单退**，要人工处理。
21. **核销有唯一实现。** 扫票只走库里的 `fn_redeem_voucher()`（`db/migrations/008_redemption.sql`），
    Go 侧是 `internal/redemption`（只拼参数、只读结果，不自己判能不能进场、不自己算扣多少额度）。
    四条口径写死：
    - **核销记录永远追加。** 一次核销 = 一次扫票，成功失败都落一条，不覆盖、不去重 ——
      重复扫票本身就是事实（票务欺诈的入口），压掉就看不见了。
    - **一张券最多成功核销一次。** 由 `voucher_redemption` 上的唯一索引
      `ux_redemption_single_success`（`WHERE result='success'`）兜底，不靠约定。
      第二次扫同一张券 → `result='duplicate'`，并带回第一次核销的记录 id 与时间，
      调用方据此对账。网络重试丢响应和恶意重复扫码在这里是同一件事。
    - **过期 / 作废 / 已退款的券不认核销，但要留记录说清原因。**
      `not_yet_valid` / `past_valid_to` / `voucher_void` / `voucher_refunded` /
      `voucher_not_issued` / `no_entitlement` / `entitlement_exhausted` /
      `order_refunding` / `gate_inactive` / `already_redeemed`。
    - **正在退款的订单不认核销。** 钱在退的时候把人放进去，退款就退不干净。
      这里刻意不锁订单行（退款路径的加锁顺序是「订单 → 凭证」，反向加锁会死锁）。
    另外：**核销后整单退款会被挡下**（退款路径撞上「有已核销的票」时明确报错要人工处理）。
    额度一次用尽（一人一券消耗 1，按团报价整团一券消耗整团人数）——
    多次入场的通票还没进模型，真要支持这一条要重新设计。
22. **可售数有唯一实现。** 剩多少只走 `fn_available_qty()` / `fn_reserve_qty()`
    （`db/migrations/009_inventory_hold.sql`），Go 侧是 `internal/inventory`（只拼参数、只读结果）。
    五条口径写死：
    - **不知道就是不知道。** 取不到源侧库存快照与可用性缓存时返回 `known = false`，
      **不许返回 0** —— 返回 0 意味着「卖完了」，会让整个商品下架，比超卖更贵。
    - **源侧快照与我们自己的承诺要对账，不许各减一遍。**
      `unreflected = GREATEST(our_sold − source_sold, 0)`（源侧还没反映的销量）、
      `committed = unreflected + active_held`、`remaining = GREATEST(available − committed, 0)`。
      直接拿源侧 `sold` 减我们的 `consumed` 会双扣 —— 每同步一次就少卖一半。
    - **并发靠锁，不靠先查后改。** `fn_reserve_qty` 按 `supplier_session.id` **升序**加行锁
      （升序是为了不让两个订单互相死锁），锁拿到后再算再判。
    - **明知不够当场报错**，源侧状态一并带出；「不知道」时不拦，
      但要把当时的可售数写进明细快照（`detail_snapshot.availability`）—— 那是事后对账的依据。
    - **预占是事实，幂等键必填。** `fn_hold_inventory` 的 `hold_no` 是幂等键，
      同键异内容当场报错（重放一次预占等于凭空多占一份）。
      `released` = 从未卖出，`voided` = 卖出后收回（退款/取消/超时）——
      **卖出的事实不许被改写**，所以 `voided` 的 `consumed_quantity` 仍是原数。
23. **有效期是数据，不是常量。** 有效期长度住在轴选项上（`product_axis_option.valid_days`），
    唯一读法是 `fn_variant_validity_days()`，出券只调它（`db/migrations/010_validity_window.sql`）。
    - **不许写死 `+1`。** 两日票发成只管一天的券，客户第二天到门口闸机判 expired ——
      钱收了、票买了、门不认，这是本项目最贵的一种 bug。
    - **口径不许有歧义。** 一个变体不能同时挂两个取值不同的 `valid_days`（不变量 73），
      有歧义就当场报出来，不猜。
    - **券不得短于产品承诺**（不变量 74）：这是「哪天又有人把 `+1` 写回去」的门禁。
    - **源侧能不能兑现是选源时定的**（`fn_variant_covered`），卖了之后不许变（不变量 75）：
      真变了走退款，不是把历史订单改成「当时就不该卖」。
    - **一个事实只写一处**：`valid_days` 不许再塞回 `option_attrs`。
24. **异构差异必须走到 C 端。** 差异事实进读模型，不进请求链路
    （`db/migrations/011_c_end_variant_facts.sql`），Go 侧是 `internal/variant`（只读三张视图）。
    - **差异不许在请求链路里 join 出来。** C 端要显示「几日的票、覆盖哪些园区、能不能退」，
      只有两条路：join 主数据（违反硬约束 10），或者把差异事实也放进读模型。走后者。
    - **事实只写一份。** 读模型里的每个字段都从 `v_variant_comparison` 取，
      不重算 `valid_days`、不重算 `axes` —— 重算就是第二份实现。
    - **读模型不许与主数据分叉**（不变量 76）：刷新作业漏跑当场报出来。
    - **有效期终点由库算好**（不变量 77）：`c_variant_calendar.valid_to = 格子日期 + 有效天数`，
      前端不许自己加一天 —— 前端加一天和应用侧加一天，早晚有一天对不上。
    - **两日票和单日票在日历上必须长得不一样。** 否则用户按「当天有效」理解两日票，
      第二天到门口才发现进不去 —— 这是 010 想根治、011 才治到最后一里的那个 bug。
25. **异构融合有两条方向，都要能表达。**
    - **方向 A（一个源 SKU 覆盖多个可售单元）**：`supplier_variant_mapping.coverage`
      + `fn_variant_covered`（010 建的），读法在 `internal/coverage`。
    - **方向 B（一个可售单元由多个源 SKU 按数量组成）**：`supplier_variant_composition`
      + `product_variant_relation.quantity`（012 建的），写侧在 `internal/compose`。
    - **两侧都要有声明，缺一不可。** 规范侧声明组件与数量，源侧给配方；
      少一个成分 = 源侧少给一份，多一个 = 我们多卖一份，数量不一致 = 卖错规格
      （不变量 79、80）。
    - **配对关系记下来，不靠猜。** 两个组件数量一样、又被同一个源 SKU 覆盖得住的时候，
      猜就是瞎猜 —— 所以 `supplier_variant_composition.component_variant_id` 显式记
      「这个源 SKU 顶的是哪个组件」，对账逐行比。
    - **组合的要求 = 组件要求的并集**（`fn_variant_requirements`）。
      所以单个源 SKU 覆盖不住整张配方，而整张配方（各成分覆盖的并集）覆盖得住 ——
      方向 A 与方向 B 不打架。
    - **组件暂时只有一层，不许嵌套。** 组件要是组合，两侧的对账就得递归算，
      错了没人说得清。触发器 `fn_guard_included_relation` 当场挡住。
    - **组合不许直接挂源映射**（守卫触发器 `fn_guard_combo_mapping` + 不变量 81）。
      组合的成本 = Σ 组件成本 × 数量，一次预订要带整组源 SKU ——
      定价与预订还没接组合之前，挂上源映射会让定价函数用**一个**源 SKU 的成本
      给整张套餐定价：收三个人的钱，出一张票。宁可少卖，不可卖错。
    - **代价说清楚**：源侧把整套套餐当一个 SKU 卖的情况，从 `coverage` 看不出来 ——
      看得出的是「一个源 SKU 覆盖多个可售单元」，不是「一个源 SKU 就是一整套」，
      看不出来就不能猜。所以这种形态单独声明（硬约束 29），不推断。
26. **组合套餐有唯一实现，能一路走到成交。**
    - **成本 = Σ 成分单价 × 数量。** 组合的成本从**源侧配方**算起
      （`fn_combo_components` → `fn_price_variant` 的组合分支），不重新选源 ——
      重新选源会让配方变成摆设，出现「按 A 源的价格卖、按 B 源出票」。
    - **不可售就明确不可售，不猜。** 成分缺价 / 成分不在同一场次 / 成分不同源 /
      价格锁定 / 按团报价 —— 五种情况一律判不可售，理由由 `v_combo_price_gap` 列出。
    - **一份订单明细 = 一份套餐；成分是履约单位。**
      `sales_order_item_source` 一个成分一行（普通明细也写一行，履约代码只有一条路），
      `order_holder.component_variant_id` 记成分归属。
    - **预订的单位是源 SKU，不是一个成分。** 源卖的是 SKU，我们就按 SKU 订：
      一张明细里同一个源 SKU 在同一个源场次上只订一次（唯一索引
      `ux_booking_one_per_source_sku` 兜底，不变量 87 / 88 复查）。
      参数化源里成人票与儿童票是**同一个**源 SKU —— 按成分建预订就是同一个源 SKU
      订了两次：源侧看到两张订单单，一条客户订单对两个源单号，对账对不上。
      成分的拆分留在预订的请求明细里（`request_payload.components`），
      它覆盖哪些成分由 `fn_booking_components` 推出来（不另存一份，免得两份事实分叉）。
    - **出券逐成分发。** 一条预订覆盖几个成分就发几张（各发各的张数、
      各按各的持票人与有效期），票码数仍必须等于还要发的张数。
    - **持票人归属靠 `item_index`，不靠猜。** 同一个成分变体出现在多行明细时，
      实名的 `item_index` 指明是哪一行（1 起）；歧义当场报错，不静默挂错人。
    - **超卖按源场次总需求判。** 多个成分抢同一个源场次时按合起来的总需求判 ——
      各判各的会卖超（场次级共享池不许每个票种各花一遍，`fn_available_qty` 口径）。
    - **退款改的是全部成分的事实。** 整单退款把成分的预订 / 券 / 票额一起改，
      成分层面的事实不许留在「已出票」上。
27. **组合在 C 端有唯一实现（015）。** 组合是**我们自己的配方** —— 源侧没有它的商品条目，
    目录同步作业看不见它，所以它的售价行与日历格子由它自己推：
    `fn_sync_combo_calendar()`（按成分的售价行推组合的售价行，金额走定价函数的组合分支）
    + `fn_refresh_read_models()`（把构成写进读模型）。Go 侧是 `internal/readmodel.SyncCombos`
    与 `internal/variant.CompositionRows`。
    - **组合的售价行不许在同步作业里另算一遍钱。** 成本来自定价函数的组合分支
      （Σ 成分单价 × 份数）。同步作业只负责「凑齐成分 → 该组合当天可售」。
    - **有效期终点 = 成分窗口的并集**（最长的那个，不是最短、不是相加）。
      2 份两日成人 + 1 份一日儿童 = 2 天。不变量 89 两边独立读：组合那边走
      `fn_variant_validity_days`，成分那边直接读轴选项 —— 拿自己证明自己永远绿灯。
    - **人群不选标签，带编码。** 组合不带「家庭」标签，带的是每个成分的
      人群编码 + 份数 + 各自的天数；「2 成人 + 1 儿童」这句话由前端按 locale 拼
      （硬约束 9：展示文案不进模型）。
    - **构成进读模型，不在请求链路里 join 主数据算份数**
      （`c_variant_composition` / `v_c_variant_composition`）。
      与主数据分叉由不变量 90 当场抓住；挂着的组合必须卖得掉（不变量 91：格子要有价格）。
    - **组合没有单一源币种，折算留痕在成分上。** 组合售价行的顶层
      `fx_rate` / `fx_as_of` 是空的（那是「这里没有单一的值」，不是「同币种、汇率 1」）；
      逐成分的留痕在 `price_calendar.rule->'combo'` 里：同币种 → 因子 1、快照日期为空；
      跨币种 → 必须有快照日期且因子能复算。
      **这条路径要自己的门禁**：组合的 `cost_source_product_id` 是空的，
      不变量 45 按那个字段 join 源价行，直接跳过组合 —— 不变量 92 专门查它。
28. **放行与出券是必经之路，不靠调用方自觉（016）。**
    - **退款必须先放行才能落结果。** `fn_complete_refund()` 只接受 `approved` 的
      退款单，其余状态当场报错（不变量 93）。以前只拦终态，一笔还在 `requested`
      的退款能被直接结掉 —— 放行这一步形同虚设，钱却真的退了。
      放行人记在 `sales_refund.approved_by`，放行时间在 `approved_at`：
      走到终态的退款单这两个字段都必须在。
    - **票码不许是券号派生的。** 源侧给了票码就用源侧的；没给就生成 128 位随机码
      （`VC-` + 32 位十六进制），不拿连号的券号顶上（不变量 94）。
      券号是连号的、猜得到；票码是闸机认的东西，猜得到就等于没有闸机。
      券号留作内部标识（对外展示、对账、核销查的都是券号）。
29. **套装是第三种异构融合形态，必须单独声明（017）。**
    - **形态不许靠猜。** 源侧把整套当一个 SKU 卖（`supplier_variant_bundle` +
      `supplier_variant_bundle_part`），从 `coverage` 看不出来是「一整套」还是
      「一张谁都能用的票」—— 看不出来就不能猜。触发器
      `fn_guard_bundle_exclusive` 挡住「既是配方又是套装」。
    - **三个单位不许混**：售卖单位是**套**（订单明细的 quantity）、
      成分单位是**预订的单位**（一个源 SKU 一条预订，份数是套数）、
      入场份数是**发的券的张数**。一套「2 成人 + 1 儿童」= 1 套 / 3 份入场。
      不变量 99 守住这条：入场份数必须等于套装声明的份数 × 套餐份数。
    - **成本来自源侧那个整套报价，不重新选源。** 重新选源 = 配方变摆设 =
      「按 A 源的价格卖、按 B 源出票」。分摊到成分只是为了对账，
      Σ 分摊 × 套数精确等于整套成本 × 套数（不变量 98）。
    - **库存池按源侧整套票种算**（`fn_available_qty` / `fn_reserve_qty` 的
      带 `source_ticket_type_id` 重载），预占一条，份数是套数。
    - **池子不许跨源票种取数（020）。** 指定源票种时，可售数只能来自**这个源票种
      自己的快照**；源侧没报这个票种的库存就说**不知道**（`known = false`、
      可售数为空），不许拿同一场次里别的票种的余量顶上（不变量 100）。
      拿儿童票的库存卖整套票，卖出去的钱收不回。
    - **需求按池子加总，不许逐明细各算各的（020）。** 两条明细各自记着「还剩 1 套」，
      各要 1 套，各自都过；加在一个池子上就是 2 套，超卖。落单时预占必须按
      **池子**汇总同一订单里所有套装的套数再比（不变量 101），
      对账看 `v_bundle_pool_demand`（订单 × 池子：需求套数 / 落单时还剩多少）。
    - **「不知道」时不拦单，但要留痕。** 源侧没报这个票种的库存时，
      不把「不知道」当成 0 —— 返回 0 意味着「卖完了」，会让整个商品下架，
      比超卖更贵（硬约束 22）。不拦，但要把当时的可售数写进明细快照，
      那是事后对账的依据。
    - **有效期是源侧声明的**（`supplier_variant_bundle.valid_days`），
      必须盖住成分窗口的并集（不变量 97）—— 盖不住就是第二天进不去。
    - **事实不许被一次调用洗掉（018）。** `fn_request_booking` 的请求报文改成
      **合并**而不是覆盖：套数与入场份数是我们写的事实，接入层这次发出去的
      报文盖在上面，不许把整列洗掉。
    - **缺口要说清（`v_bundle_gap`）。** 卖不掉要说出为什么：
      没有源侧报价 / 没有规范场次 / 没绑源场次 / 没有源侧票种 /
      有效期盖不住 / 可售数未知。看不出来就说看不出来，不猜。

## 目录

```
SPEC.md                      业务合同（范围/流程/不变量/状态机/验收标准）
docs/ddd.md                   领域模型：限界上下文、聚合、事件、状态机
docs/c-end-model.md           C 端：读模型、展示内容、购买漏斗
docs/schema-design.md         物理模型：选型论证、表清单、索引策略、演进路线
docs/connector-contract.md    供应源接入端口契约 + 七源差异矩阵 + §9 接入层实现现状
docs/integrations.md          接入层（Go）：包结构、设计纪律、CLI 用法
db/migrations/                全部 DDL（77 业务表 + 1 迁移账本 / 50 视图 / 227 索引 / 39 触发器 / 124 函数）
db/migrations/001_baseline.sql 建库基线（冻结，不许改）；后续结构变更走新增的 NNN_*.sql
db/migrations/002_*.sql        读模型刷新作业（fn_refresh_read_models）—— 迁移机制的第一个真实用例
db/migrations/003_*.sql        交易侧状态机（state_transition + 守卫/事件触发器）
db/migrations/004_*.sql        下单写路径（fn_place_order）—— 幂等 + 定价唯一来源 + 明细快照
db/migrations/005_*.sql        履约写路径（支付 → 预订 → 出券）—— 事实与状态不许分叉
db/migrations/006_*.sql        重复收款守卫（另一笔流水打进已付订单 → 报错，不静默吞掉）
db/migrations/007_*.sql        退款写路径（发起 → 放行 → 完成）—— 整单退款 + 事实同步改
db/migrations/008_*.sql        核销写路径（fn_redeem_voucher）—— 扫票记录永远追加 + 状态效果幂等
db/migrations/009_*.sql        库存预占写路径（fn_available_qty / fn_reserve_qty / fn_hold_inventory）—— 可售数唯一实现 + 锁防超卖
db/migrations/010_*.sql        有效期口径（valid_days 落在轴选项上）—— 券的窗口按可售单元算
db/migrations/011_*.sql        C 端读模型带上差异事实（c_variant_facts + 日历有效期终点）—— 差异走到最后一里
db/migrations/012_*.sql        组合映射（supplier_variant_composition）—— 异构融合方向 B：一个可售单元由多个源 SKU 组成
db/migrations/013_*.sql        组合套餐可售（sales_order_item_source + 组合定价/预订/出券）—— 方向 B 走到成交
db/migrations/014_*.sql        预订单位 = 源 SKU（fn_booking_components）—— 同一个源 SKU 不许订两次
db/migrations/015_*.sql        组合在 C 端（组合售价行/日历格子 + 构成读模型）—— 方向 B 的最后一里
db/migrations/016_*.sql        收紧口径（退款必须先放行 / 票码不可猜）—— 两处门禁
db/migrations/017_*.sql        套装（supplier_variant_bundle）—— 异构融合方向 B 的第三种形态：源侧把整套当一个 SKU 卖
db/migrations/018_*.sql        预订请求报文改成合并（fn_request_booking）—— 事实不许被一次调用洗掉
db/migrations/019_*.sql        套装缺口天数只数真卖不掉的那几天
db/migrations/020_*.sql        套装库存池口径收紧（池子不跨源票种 + 需求按池子加总）—— 补上 017 的两个超卖口子
db/seed.sql                   种子数据（7 源 / 7 规范商品 / 29 映射 / 14 场次源绑定 / 10 订单 / 9 读模型卡片 / 21 变体（含 2 张套餐 + 1 张套装）/ 26 源变体 / 4 组合成分行；售价金额由定价函数生成）
db/verify.sql                 验收查询（17 组视图 + 101 条不变量断言）
cmd/tc-connect/               CLI：sources / layers / mock / normalize / compose / price / migrate / refresh / order / fulfill / refund / redeem / stock / hold / variant
internal/
  apperr/                     错误四分类 + 缺失凭证 + 端点未确认
  credential/                 凭证解析（环境变量优先 → supplier.auth_config）
  transport/                  HTTP 客户端：退避重试 / Retry-After / 脱敏
  config/                     传输层配置加载与校验
  normalize/                  归一化核心（配置驱动）—— 唯一实现
  pricing/                    定价入口（读 fn_price_variant 的结果，不算钱）
  store/                      DB 访问（psql 子进程）+ 报文归档 + 幂等
  supplier/tripcom/           Trip.com 分销侧适配器（21 接口全配置驱动）
  supplier/globaltix/         GlobalTix Supply API 适配器（端点待商务确认）
  supplier/pending/           其余五源的占位适配器（接口细节未核对）
  registry/                   supplier.code → 适配器
  layertest/                  分层测试引擎 + 离线自检 + 协议自检
  migrate/                    迁移引擎：账本 + 内容校验和 + 幂等 + 并发互斥
  readmodel/                  C 端读模型：刷新（口径在库里的 fn_refresh_read_models）与漂移检查
  transaction/                交易域读侧：状态机的合法流转与领域事件
  order/                      下单：拼参数 / 收结果 / 报错原样带出（不重算金额）
  fulfillment/                履约：支付 / 预订 / 出券（只调库里的函数，不自己算状态）
  refund/                     退款：发起 / 放行 / 完成（只调库里的函数，不自己判资格）
  redemption/                 核销：扫票 / 查券（只调库里的函数，不自己判能不能进场、不自己算扣多少额度）
  inventory/                  库存：查可售 / 预占 / 放掉（只调库里的函数，不自己算可售数、不自己判够不够）
  variant/                    异构差异读侧：对照表 / 源覆盖缺口 / C 端读视图 / 套装构成（只读视图，不重算有效天数与覆盖判定）
  coverage/                   覆盖语义读侧：源变体覆盖住哪些可售单元（判定走库里的 fn_variant_covered）
  compose/                    组合映射写侧：组合表达式 → 配方（核组件、核数量；覆盖判定走库里的 fn_variant_covered）
  mock/                       Trip.com 分销侧协议 mock（标准库 net/http）
configs/api_config.json       传输层配置：端点 / 21 接口 ICODE / 凭证口径 / 错误码映射
configs/mapping_rules.json    映射规则配置（演练器与接入层共用）
fixtures/                     真实报文结构的样例（canonical / trip_com / globaltix）
scripts/mapping_dryrun.py     无凭证集成演练（源报文 → 归一化 → 路由 → 报告）
scripts/order_demo.py         下单链路端到端演示（自己找有售价的日期，不写死日期）
scripts/poc_page.py           前端 POC 渲染器
Makefile                      build / test / mock / layers / dryrun / db / check / order-demo
```

## 常用命令

本机 PostgreSQL 15（brew，`postgresql@15`），默认监听 5432，超级用户为当前 OS 用户。

```bash
export PATH=/opt/homebrew/opt/postgresql@15/bin:$PATH

# 重建（会清库）
psql -h 127.0.0.1 -d postgres -c "DROP DATABASE IF EXISTS ticket_center;" \
                       -c "CREATE DATABASE ticket_center;"

# 建表（走迁移引擎：账本 + 只增不改的校验）
./bin/tc-connect migrate --db ticket_center

# 灌种子
psql -h 127.0.0.1 -d ticket_center -v ON_ERROR_STOP=1 -f db/seed.sql

# 验收（必须全绿）
psql -h 127.0.0.1 -d ticket_center -v ON_ERROR_STOP=1 -f db/verify.sql
```

无凭证集成演练（拿不到源的 key/id/token 时，先用真实报文结构验证 mapping → 路由；
建独立演练库 ticket_center_dryrun，不动主库）。归一化由 Go 实现提供，
演练器通过 `tc-connect normalize` 消费它的输出：

```bash
make dryrun                                  # 演练 + 终端报告（101 条不变量自检）
python3 scripts/mapping_dryrun.py --poc scripts/poc/index.html    # 生成前端 POC
```

接入层（Go 1.23+；无凭证也能跑 L0 连通性 + 离线自检 + 协议级 mock 自检）：

```bash
make build                          # 构建 bin/tc-connect
make test                           # 单元测试（26 个包）
make mock                           # 协议级自检（本地 mock，14 项断言）
make layers                         # 分层连通性测试（连通→认证→目录→详情→价格→映射→路由）
make check                          # 提交前完整自检（vet + test + mock + 演练器）
make migrate                        # 应用待应用的迁移（存量库升级用这个，别重建）
make dbstatus                       # 看迁移状态（哪些已应用、哪些待应用）
make refresh                        # 刷新 C 端读模型并查漂移
make order-demo                     # 下单链路端到端演示（下单 → 幂等重放 → 查单）
./bin/tc-connect fulfill show --db ticket_center --order 7   # 查履约状态（支付/预订/出券）
./bin/tc-connect refund show --db ticket_center --refund 1    # 查退款单状态
./bin/tc-connect redeem scan  --db ticket_center --code TKT-001  # 扫一次票
./bin/tc-connect redeem show  --db ticket_center --voucher 3    # 查这张券和它的核销流水
./bin/tc-connect stock show  --db ticket_center --supplier-session 1   # 查这个源场次还剩多少
./bin/tc-connect hold create --db ticket_center --no HOLD001 --channel 1 --variant 11 --qty 2 --date 2026-11-18
./bin/tc-connect hold expire --db ticket_center            # 跑 TTL 过期作业
./bin/tc-connect variant compare --db ticket_center --product 6   # 看这个商品的可售单元差在哪
./bin/tc-connect variant coverage --db ticket_center --variant 14 # 看哪些源能供、缺什么
./bin/tc-connect variant feed    --db ticket_center --channel 1   # 看 C 端读模型里的变体行
./bin/tc-connect variant bundle  --db ticket_center --variant 21   # 看套装（源侧把整套当一个 SKU 卖）由谁组成
./bin/tc-connect compose plan    --db ticket_center --source globaltix --fixture fixtures/globaltix_catalog.json   # 组合配方能不能解出来
```

拿到凭证后（**凭证只从环境变量读，不入库、不进仓库、不进日志**）：

```bash
export TRIPCOM_AID=… TRIPCOM_SID=… TRIPCOM_KEY=…
./bin/tc-connect layers --supplier trip_com --env sandbox   # 先沙箱
./bin/tc-connect layers --supplier trip_com --env prod      # 再生产
```

一键重建并验收：

```bash
export PATH=/opt/homebrew/opt/postgresql@15/bin:$PATH
make db                             # 重建主库（迁移 → 种子 → 验收）
```

## 沙箱注意（本机实测）

- `bash` 里**不能写 heredoc**（`cat <<EOF` 会报 `cannot create temp file for here document: Operation not permitted`）。
  写多行内容用 `write` 工具，脚本用文件 + `python3 file.py`。
- 临时脚本放 `/tmp` 可以，但 `/tmp` 下的文件删除会被沙箱拒绝，别为清理它阻塞交付。

## 改完 schema 后的自检清单

- [ ] `db/migrations/` 里的迁移在空库零错误执行（`tc-connect migrate`）
- [ ] 新增/改动的迁移文件是**新增**的，不是改了已发布的那个
- [ ] `tc-connect migrate --status` 里没有「内容漂移」
- [ ] `db/seed.sql` 完整装载
- [ ] `db/verify.sql` 全部视图正常输出
- [ ] `v_invariant_checks` 101 条全 PASS（`db/verify.sql` 的 F 段会 `RAISE EXCEPTION`）
- [ ] 改动状态机 → `state_transition` 表 + `SPEC.md` §5 同步更新，且非法流转仍被触发器挡住
- [ ] 改动下单口径 → `fn_place_order` + `SPEC.md` §5.5 同步更新，且幂等与实名校验仍生效
- [ ] 改动履约口径 → `005/006` 迁移 + `SPEC.md` §5.6 同步更新，且幂等、重复收款、票码张数、源场次绑定仍生效
- [ ] 改动退款口径 → `007` 迁移 + `SPEC.md` §5.7 同步更新，且幂等、金额等于实付、事实同步改、失败可退回仍生效
- [ ] 改动核销口径 → `008` 迁移 + `SPEC.md` §5.8 同步更新，且重复扫码、额度用尽、订单在退款不认核销仍生效
- [ ] 改动可售数口径 → `009` 迁移 + `SPEC.md` §5.9 同步更新，且「不知道不拦、明知不够报错、源侧快照与承诺对账不双扣、订单关掉放掉预占」仍生效
- [ ] 改动有效期口径 → `010` 迁移 + `SPEC.md` §5.10 同步更新，且「有效期读轴选项、券不短于承诺、源覆盖得住」仍生效
- [ ] 改动读模型口径 → `011` 迁移 + `SPEC.md` §5.11 同步更新，且「读模型不与主数据分叉、日历有效期终点不被算错」仍生效
- [ ] 改动组合售卖口径 → `013` 迁移 + `SPEC.md` §5.13 同步更新，且「成本 = Σ 成分单价 × 数量、成分源取自配方不重选、成分各订各券、超卖按场次总需求、整单退款改全部成分事实」仍生效
- [ ] 改动预订单位口径 → `014` 迁移 + `SPEC.md` §5.6 / §5.13 同步更新，且「一个源 SKU 一条预订、成分由 fn_booking_components 推出来、票码数仍等于应发张数」仍生效
- [ ] 改动组合在 C 端的口径 → `015` 迁移 + `SPEC.md` §5.14 同步更新，且「有效期 = 成分窗口的并集、人群只带编码、构成不许与主数据分叉、格子必须带价格」仍生效
- [ ] 改动放行或出券的口径 → `016` 迁移 + `SPEC.md` §4.18 / §5.6 / §5.7 同步更新，且「退款必须先放行、终态退款单放行痕迹齐全、票码不许是券号派生的」仍生效
- [ ] 改动套装口径 → `017` 迁移 + `SPEC.md` §4.19 / §5.15 同步更新，且「形态唯一、成分与声明对得上、有效期盖住成分窗口、成本分摊守恒、入场份数守恒」仍生效
- [ ] 改动预订请求报文的口径 → `018` 迁移 + `SPEC.md` §5.6 同步更新，且「我们写的事实不许被接入层发的报文覆盖」仍生效
- [ ] 改动套装缺口天数的口径 → `019` 迁移 + `SPEC.md` §5.15 同步更新，且「缺口天数只数真卖不掉的那几天」仍生效
- [ ] 改动套装库存池的口径 → `020` 迁移 + `SPEC.md` §4.19 / §5.15 同步更新，且「池子不跨源票种相加、需求按池子加总、不知道不拦但留痕」仍生效
- [ ] `make test` 全绿（Go 单元测试）
- [ ] `make mock` 协议自检 14/14 全 PASS
- [ ] `python3 scripts/mapping_dryrun.py` 演练库 101/101 全 PASS
- [ ] `SPEC.md` 变更记录追加一行
- [ ] `docs/schema-design.md` 的表清单/索引统计数字同步更新
- [ ] `docs/ddd.md` 若涉及聚合边界或状态机，同步更新
- [ ] 改动 C 端展示或购买链路 → `docs/c-end-model.md` 同步更新
- [ ] 改动接入层 / 错误分类 / 幂等口径 → `docs/connector-contract.md` §9 与 `docs/integrations.md` 同步更新
