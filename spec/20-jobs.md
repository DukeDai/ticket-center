# 预占到期时间侧不变量、凭证过期作业侧不变量、凭证过期作业、作业调度、值进 SQL、同步落库

> 合同的一部分。章节：§4.26-4.28 · §5.24-5.27。索引见 [`SPEC.md`](../SPEC.md)。
> 本文件是**合同**：改动这里的业务行为，必须同步改这里，并同步 `docs/ddd.md`（领域模型）与 `docs/schema-design.md`（物理模型）。

---

### 4.26 预占到期时间侧不变量（119，2026-11-13 补充）

预占是**会过期的承诺**：购物车里的票占了坑，TTL 到就得放掉，
坑才能被别人买走。门禁住在 `v_invariant_checks_hold_ttl` 里。

| # | 不变量 |
|---|---|
| 119 | 落库的预占必须有确定的到期时间（`expires_at` 不许是 NULL） |

- 到期时间是 NULL（不变量 119）—— 这张预占**永远不过期**：
  `fn_expire_holds` 只动已过期且仍 `active` 的，NULL 的行它认不出来，
  于是这个坑一直被占着，可售数一直少一张 —— 一个不会释放的库存占用。
  表结构上 `expires_at` 是 `NOT NULL`，这一条守的是**别让这个约束在某次迁移里被放松**，
  以及别让一条 NULL 的预占绕过约束落进库。

口径在 §5.23。

### 4.27 凭证过期作业侧不变量（120-121，2026-11-13 补充）

券的有效期过了，券的状态还停在 `issued` —— 这是一个**看得见的状态洞**：
券还能被扫成「过期」，但券本身说「我还是有效的、还没用过」。
两个地方说的不是同一件事。门禁住在 `v_invariant_checks_voucher_expiry` 里。

| # | 不变量 |
|---|---|
| 120 | 过期的凭证必须有有效期终点（`expired` 的券没有 `valid_to` = 判它过期的依据没了） |
| 121 | 过期的凭证必须已出票（`expired` 的券没有 `issued_at` = 一张从没交付过的券被说成「过期了」） |

- 没有有效期终点（不变量 120）—— `expired` 说的是「有效期过了」，
  没有 `valid_to` 就没法说它是哪一天过的。券卡在 `expired` 上，
  客户问「我这张票哪天过期」，答不上来。
- 没出票就过期（不变量 121）—— `expired` 蕴含「这张券给过客户」。
  没出票的券是 `pending` 或 `void`，把它推成 `expired` 就是
  **凭空造出一次交付**：订单的履约状态、库存的已售数、对账的交付口径全都会跟着偏。

口径在 §5.24。

---

### 5.24 凭证过期作业的口径（2026-11-13 落地）

**这件事是什么**：券的有效期过了，券的状态还停在 `issued`。
券已经不能进场了，状态却还写着「已出票、还没用过」——
任何读券状态的地方都会读到错的值，客户问「我这张票还能用吗」也答不上来。

**为什么核销路径不直接改**：核销路径（008）刻意**只落核销记录、不改券状态**：

```
WHEN 'expired' THEN v_result := 'expired'; v_reason := 'voucher_expired';
```

——「过期只落核销记录，不改券状态 —— 券状态由过期作业统一改。
一件事一件事分开，才说得清是谁在什么时候把哪张票判成什么。」

那句话不是注释，是承诺。现在补上兑现它的那一半。

**唯一实现**：`fn_expire_vouchers(p_limit INTEGER DEFAULT 500)`
（`db/migrations/028_voucher_expiry.sql`），Go 侧是 `internal/redemption`
的 `ExpireOverdue`（只拼参数、只读结果，不自己判哪张券过期、不自己改状态、不自己发事件）。

五条口径写死：

- **只动 `status='issued'` 的券。**
  `pending` 是还没出票的券，`used` 是已核销的券（它「被用过」这个事实与过期无关），
  `void` / `refunded` 是另外两条事实。作业只推进这一种。
- **判据是券自己的 `valid_to`（`valid_to <= now()`）。**
  不重算、不看别的表 —— 有效期口径在 010 已经统一到「格子日期 + 有效天数」，这里只是读它。
- **幂等。** 同一张券只会被改一次（第二次跑没有「到期且仍是 `issued`」的券了）。
  跑第二遍返回 0，不报错、不重复改。
- **限批。** 一次最多 `p_limit` 条（默认 500），按 `valid_to, id` 排序取 ——
  避免一次锁太多行。
- **事件由机制保证，不由自觉。** `state_transition` 里 `('issued' → 'expired')`
  早就在（003），守卫触发器 `trg_voucher_status_guard` 挡住非法流转，
  事件触发器 `trg_voucher_status_event` 自动落一条 `VoucherExpired` 到 `event_outbox`。
  所以作业只 `UPDATE` 状态，**不自己插事件**。

**「交付过」的口径必须一起改（这一条最容易漏）**：

全库有一批地方用 `v.status IN ('issued', 'used')` 表达一个意思：
**「票确实交付到客户手上了」**。这个集合漏掉了 `expired`。
漏掉的后果不是「过期券算不出来」，是**交付过的事实被改写**：

1. `fn_apply_order_fulfillment` 的 `delivered` 口径 ——
   券一过期，`delivered` 归零，订单的 `fulfillment_status` 从 `fulfilled` 翻成
   `partially_fulfilled` / `failed`。客户交了钱、拿到了票，票只是过期了，
   系统却说这张单没履约。
2. `fn_reassign_order_item` 的「已经出票不许改派」守卫 ——
   券一过期，这条明细又变成「可改派」。已经卖出去的票被换源重卖一次，
   一次交付两次出票 —— 这是最贵的一种：**按 A 源的价格卖、按 B 源出票**。
3. `fn_issue_voucher` 的 `ticketed` 判定、`v_order_item_source`、
   `v_reassign_candidates` —— 同一个毛病。

所以口径改成：**交付过 = `issued` / `used` / `expired`**，
`void` / `refunded` 不算（作废与退款是另外两条事实）。

为什么 `expired` 算交付过：状态机说得清（`issued → expired → refunded`
是一条合法的边链，`expired` 坐在交付之后）；退款路径认它
（`fn_complete_refund` 的券状态白名单里有 `expired` —— 过期券该退能退，
说明它是真实交付出去的东西）；核销路径把它与 `void` / `refunded` 分开。

**一个事实只写一处**：这个判定散在 5 个函数与 3 个视图里，
每处自己写一遍 `IN` 列表就是同一个意思写五遍，改一处忘了另一处就复发。
所以它有一个共享读法：`fn_delivered_voucher_statuses()` 返回
`ARRAY['issued','used','expired']`，调用方一律读它。

**诊断视图 `v_order_fulfillment_gap`** 是例外：它的 `issued_vouchers` /
`used_vouchers` 是**状态分布统计**，不是「交付过」的判定。
过期券单独开一列 `expired_vouchers`，另加一列 `delivered_vouchers`；
`suspected_lost`（已付款但没交付 → 疑似丢单）改用 `delivered` 口径，
否则过期之后每张正常交付的单都会被误报成疑似丢单。

**作业漏跑看得见，但不挡门禁**：
`v_voucher_expiry_overdue` 给出「到期却还停在 `issued`」的券数、
有效期终点的范围、分布在多少张订单上。
**不加**「不许有过了期还停在 `issued` 的券」这种门禁 ——
那是**作业有没有跑**的问题，不是数据对不对的问题；
拿它当门禁，库会因为「作业没被调度」而红，那是把运维状态混进数据质量。

**作业也不碰订单状态**：`fulfillment_status` 是**推导值**，
由 `fn_apply_order_fulfillment` 从明细的实际出票情况推导（不变量 60）。
作业只改券状态；订单状态由履约路径重算。

表与函数：

| 位置 | 干什么 |
|---|---|
| `fn_expire_vouchers` | 唯一实现：把过了有效期的 `issued` 券推进到 `expired`（幂等，可反复跑） |
| `fn_delivered_voucher_statuses` | 「交付过」的共享读法：`issued` / `used` / `expired` |
| `v_voucher_expiry_overdue` | 作业漏跑时的现状：到期却还停在 `issued` 的券数与分布 |
| `v_invariant_checks_voucher_expiry` | 凭证过期作业侧不变量（120-121） |

Go 侧不变：`internal/redemption` 只拼参数、只读结果。
CLI：`tc-connect redeem expire`（跑作业）、`tc-connect redeem overdue`（看现状）。
回归测试 `TestExpireOverdueAdvancesIssuedVouchersAndIsIdempotent`、
`TestExpireOverdueEmitsVoucherExpiredEvent`、
`TestExpireOverdueLeavesOtherStatusesAlone` 钉住契约。

---

### 5.25 作业调度的口径

**这件事是什么**：库里有一批批处理作业（凭证过期 `fn_expire_vouchers`、
预占过期 `fn_expire_holds`、组合同步 `fn_sync_combo_calendar`、
读模型刷新 `fn_refresh_read_models`）。作业在库里，但**没有人调它，作业就只是库里一个
没人跑函数** ——「券过期了由作业统一改」这句话就落空了。所以这里给作业一个入口：
`tc-connect jobs` 一次跑完全部作业，跑完退出。

**为什么要有这条命令**：没有入口的作业等于没有作业。上一节落地了
`fn_expire_vouchers`，判据、幂等、事件全对，但只要没人调它，券的状态就还是停在
`issued` —— 那个状态洞原样存在。补作业而不补调度，是把「没人跑」这件事从
「没人知道」变成「以为有人跑」。

**唯一实现**：`cmd/tc-connect/cmd_jobs.go` 的 `tc-connect jobs`，
`make jobs` 是它的包装。

| 位置 | 干什么 |
|---|---|
| `tc-connect jobs` | 唯一入口：跑一遍全部作业，再做读侧自检 |
| `make jobs` | 包装（`--db $(PGDATABASE)`） |
| `fn_expire_vouchers` / `fn_expire_holds` | 作业本体：判据在库里（§5.24 / §5.9） |
| `fn_sync_combo_calendar` + `fn_refresh_read_models` | 组合同步与读模型刷新（§5.14 / §5.11） |
| `v_c_readmodel_drift` | 刷新后仍对不上的卡片（漂移） |
| `v_voucher_expiry_overdue` | 到期却还停在 `issued` 的券数与分布 |

**几条口径写死**：

- **一次跑完就退出，不常驻、不自己排期。** 命令是批处理，不是守护进程。
  常驻进程要处理信号、重启、漂移、跨库切换 —— 那些是调度器的活，不是这个命令的活。
- **间隔不写在代码里。** 多久跑一次是运维的决定，写死在代码里就成了**第二份口径**：
  改的时候要改两处，而且改漏一处没人知道。交给系统 cron 或 k8s CronJob：

  ```
  */5 * * * * cd /srv/ticket-center && ./bin/tc-connect jobs --db ticket_center
  ```

  失败重试也交给调度器：命令失败时**非零退出**，调度器按自己的策略重试。
- **作业本身是幂等的，重跑一遍不会多改什么。** 幂等靠的是
  「`UPDATE ... WHERE status = 'issued'`」这个形状，不是靠调度器的自觉。
  限批（`--limit`，默认 500）是同一件事的另一半：本批没改完的，下一轮接着改。
- **刷新后仍漂移 = 硬事实，非零退出。** 读模型刚刷新过还对不上，说明有东西不对，
  必须让人看见。（这条是**防御性断言**：刷新本身就是修复机制，
  手改出来的漂移会被刷新修好 —— 所以它是最后一道防线，不是常规路径。）
- **仍有券停在 `issued`（到期却没改）→ 只报告，不失败。** 这可能是本批的余量
  （到期券比 `--limit` 多），也可能是漏跑；漏跑是**运行状态**，不是数据违规 ——
  §5.24 的口径是「看得见但不挡门禁」。让这一项挡住调度，会把一条告警变成一个死循环。
- **这条命令不重算任何业务结论。** 判据全在库里，Go 侧只拼参数、只读结果。

Go 侧不变：`internal/redemption` / `internal/inventory` / `internal/readmodel`
各自只拼参数、只读结果，作业的口径仍在库里的函数与视图。

CLI：`tc-connect jobs [--db name] [--limit n]`。

---

### 5.26 值进 SQL 的口径（2026-11-13 落地）

**这件事是什么**：psql 是子进程，没有 `$1` 占位符，SQL 全是拼出来的。
所以值进 SQL 的唯一防线是「记得调 `store.Quote`」—— 而「记得」是**约定不是机制**，
约定迟早被漏掉一次，漏掉的那一次就是注入。一次注入就是一次数据泄露，
而「记得转义」这件事在被赶工的时候是第一个被省掉的。

**两条路**：

| 位置 | 干什么 |
|---|---|
| `store.NewSQL(...).Bind(v).And(...).MustString()` | 拼查询：绑定时转义，调用方拿到的是已经转义好的字面量 |
| `store.Quote(v)` / `store.QuoteIdent(v)` | 拼字面量：字符串字面量与标识符是两件事，不能混用 |
| `internal/sqllint` + `cmd/tc-lint` | 门禁：扫 AST，把没转义的值报出来 |
| `make lint` | 门禁入口（挂在 `make check` 与 CI 上） |

**几条口径写死**：

- **绑定时就转义。** 调用方拿到的是已经转义好的字面量，不给自己留「忘了再转一次」
  的机会。
- **非标量直接报错。** 绑 map / slice 这类值时返回错误并指路 `BindJSON`，
  不许悄悄写个 `NULL` 糊过去 —— 糊过去的地方正是数据悄悄丢的地方。
- **标识符不能走 `Quote`。** `QuoteIdent` 把它渲染成标识符，`Quote` 渲染成字符串
  字面量 —— 表名与列名要用后者，这是两件事。
- **门禁盯带引号的位置，放过裸数值位置。** `WHERE name = '%s'` 里插进来的值会闭合
  引号，是真问题，门禁报；`WHERE id = %s` 里插进来的值不带引号，字符串内容打断不了
  它 —— 但它同样不是转义过的字面量。门禁放过它是**判据宁放过不误伤**的取舍，
  不是漏洞。写查询优先用 `store.NewSQL`，它不留这个口子。
- **包级常量与编译期字面量不算问题。** 门禁噪音多了就没人看了。
- **门禁是第一道不是唯一一道。** 它会放过裸数值位置，所以真正的防线是写查询时
  走绑定机制。

CI 上这条门禁与不变量门禁同级：漏掉一次转义就是一次数据泄露，
让它在 `make check` 里失败比让人记住要可靠。

---

### 4.28 同步落库侧不变量（2026-11-14 补充）

**这一节守的不是业务规则，是「同步作业不许把事实写坏」**。
四个问题（幂等边界 / 游标在哪 / 规范层主数据从哪来 / `pending_review` 死枚举）
在 §5.27 里定口径；这里只写**它们各自要挡住的那类数据违规**。

门禁住在 `v_invariant_checks_sync` 里。

| # | 不变量 |
|---|---|
| 127 | 同步作业落下的源商品必须挂在某个源下（`supplier_product.supplier_id` 不许为空） |
| 128 | 源商品的外部标识不许为空（空标识 = 重放一次就多落一个商品） |
| 129 | 源变体必须挂在某个源商品下（`supplier_variant.supplier_product_id` 不许为空） |
| 130 | 源票种必须挂在某个源商品下（`supplier_ticket_type.supplier_product_id` 不许为空） |
| 131 | 源场次必须挂在某个源商品下（`supplier_session.supplier_product_id` 不许为空） |
| 132 | 待审核的源商品不许挂着有效的规范映射（`pending_review` 的源商品不能有 `active` 的 `product_mapping`） |
| 133 | 待审核的规范映射不许出现在有效的覆盖关系里（`pending_review` 的 `product_mapping` 不能有 `active` 的 `supplier_variant_mapping`） |

- **127-131 是「不许有孤儿」。** 源层的每一行都必须能追到一个源商品，
  源商品必须能追到一个源。孤儿行是同步作业写了一半崩掉的残留 ——
  它不属于任何源，却能被 `supplier_variant_mapping` 引用，于是
  「这个可售单元由谁履约」这个问题有一个指向空处的答案。
- **128 是「不许有匿名商品」。** `supplier_product_uk` 是
  `(supplier_id, external_id)`，外部标识为空时这一对唯一键**不区分两个不同的商品** ——
  重放一次同步就多落一行同名空标识的商品，
  而这条唯一键恰恰拦不住它（两行都合法）。
- **132-133 是「待审核不许漏进可用路径」。** `pending_review` 是给
  「机器认出来了但人还没认」的事实准备的中间态（§5.27 第四条）。
  一个还等着人看的源商品，不许已经挂在规范商品上卖；
  一个还等着人看的映射，不许已经声明「这个源能履约这个可售单元」——
  那就等于没审核就上架了。

这七条对应的表结构约束是**结构性的**（外键 + NOT NULL），
门禁守的是**别让某次迁移把它们放松掉**，以及**别让一条 NULL 或空串绕过去**。

口径在 §5.27。

---

### 5.27 同步落库的口径（2026-11-14 落地）

**这件事是什么**：接入层已经能把源侧抓下来、归一化好（`internal/layertest`
的 L2→L6 跑通了「抓 → 归一化 → 路由」），但**归一化结果从来没被写进库**。
源层的表（`supplier_product` / `supplier_variant` / `supplier_session` /
`supplier_price_calendar`）全是空的，规范层的 `product_mapping` 也只��种子里那几行。
`scripts/mapping_dryrun.py` 是目前**唯一**一条端到端落库的路 ——
它是 Python 脚本，自己拼 SQL，自己写 `lit()` 做转义（只做 `'` → `''`），
绕开了 `internal/store` 的转义机制。

**这一段有四条口径，写在前面。** 它们回答评审提的四个问题。

#### 第一条：幂等边界 = 现有的唯一键 + `ON CONFLICT DO UPDATE`

重放一次同步作业，会不会多落一个商品？**不会。**
每张目标表已经有一个确定性的唯一锚点，写入路径不需要新增任何列：

| 目标表 | 幂等锚点 |
|---|---|
| `supplier_product` | `(supplier_id, external_id)` |
| `supplier_ticket_type` | `(supplier_product_id, external_id)` |
| `supplier_session` | `(supplier_product_id, external_id)` |
| `supplier_variant` | `(supplier_product_id, external_variant_id)` |
| `product_mapping` | `(supplier_product_id, product_id)` |
| `supplier_variant_mapping` | `(supplier_variant_id, product_variant_id)` |
| `product_session` | `(product_id, session_date, slot_key)` |
| `product_session_source` | `(product_session_id, supplier_session_id)` |

**变更检测靠 `supplier_product.content_hash`。**
报文内容没变 → 哈希没变 → 这一行不更新（`stats.skipped`）。
变了 → 哈希变了 → `DO UPDATE` 盖上新的报文与 `last_synced_at`。
**盖的不是整列**：源侧撤下来的事实要**退役而不是删除**
（`internal/compose/compose.go` 里已经有这个形状：成分掉了就 `status='retired'`，
不 `DELETE`）—— 卖过的历史订单还指着它，删了就查不出来了。

**一次同步是一个事务。** 多表写入要么全成要么全不成，
否则一次崩掉会留下「源商品落了、报价没落」的半截状态。
用 `store.ExecScript`（一个 psql 会话里跑多语句）而不是逐条 `Exec`。

**幂等键不另造。** 同步作业的幂等键就是**内容本身** ——
同样的源报文重放一次，落库结果与上一次逐字节相同。
这比另设一个 `idempotency_key` 列强：那个列记的是「请求过」，
而这里记的是「落过什么」。

#### 第二条：游标住在 `sync_job_log.scope` / `stats`，正式列留给下一次迁移

`sync_job_log` 现在只有种子写（`db/seed.sql` 四行），
它有 `scope JSONB` 与 `stats JSONB` 两列，**没有游标列，也没有幂等键列**。
（硬约束 3：已应用的迁移文件不可改，所以加列只能新增迁移文件。）

**现在的口径**：游标住在 `scope` 里 —— 记这次同步扫到哪、
上次拿到的源侧水位是什么。`scope` 是 JSONB，装得下一个结构化的水位，
不需要为此改表。

**正式列留给下一次迁移**：等到游标的口径稳定下来
（源侧增量接口的分页/水位语义确定了），再新增一列把它变成结构化字段。
在那之前**不许把游标散落到别处**（配置文件、代码里的常量、
另一个表）—— 一散落就有第二份口径。

**游标今天还是空的，因为源侧的增量接口还没确认。**
Trip.com 的 `listAllProducts`（`configs/api_config.json` 里 `icode_prod: null`）
拿不到生产 ICODE，这条接口**待商务确认**（硬约束 13）。
所以今天能跑的增量路径是 `listProducts` → `getProduct` → `getPriceCalendar`
（L2→L3→L4，全都有生产 ICODE），**这条路没有源侧水位可存** ——
每次全量拉，幂等靠第一条的唯一键兜住。
`listAllProducts` 一旦确认，`scope` 里的游标字段才有东西可写。

**读不到游标 = 没有约束，不许猜。** 与硬约束 22 / 34 同一条口径：
源侧没给水位，就是没有水位，不拿别的东西顶上。

#### 第三条：规范层主数据是**人工撰写的**，源层是**机器推导的**

这不是「从源报文推」与「人工审核后落」的二选一 —— **两层的主数据来源本来就不同**：

- **规范层**（`product` / `product_variant` / `product_axis` / `product_axis_option` /
  `ticket_type` / `product_session`）是**我们写的**：一个可售单元是
  「人群 × 票种 × 园区范围 × 加购件」的组合，这是我们的商业定义，
  源侧不报这个组合。`fixtures/canonical_catalog.json` 是它的来源，
  `scripts/mapping_dryrun.py` 的阶段 ① 把它落库。
- **源层**（`supplier_product` / `supplier_variant` / `supplier_session` /
  `supplier_price_calendar`）是**从源报文推出来的**：源侧报什么就是什么，
  落进 `raw_payload` 与 `content_hash`。

**衔接处是 `product_mapping`。** 它把「机器推导出来的源商品」指向
「我们写好的规范商品」—— 这层映射是**判断**，不是推导：
源侧报了一个我们没定义过的商品，或者我们定义的商品源侧还没报，
这两个方向都要人来定。

**所以审批流要留，但只有一处。**
「源侧新来的商品要不要进我们的目录」这道判断在 `product_mapping` 上，
不在源层。源层的机器推导**不需要审批** —— 源侧报了就是事实。
审批的对象是**映射**，不是**源商品**。

#### 第四条：`pending_review` 接上，不删

这个枚举**恰好住在四张表上**：`supplier_product.status`、
`product_mapping.status`、`supplier_variant.status`、
`supplier_variant_mapping.status`。这四张表正好是那道缝的两端 ——
源侧与规范侧。

它今天**没有任何生产者**：种子不写它，Go 侧不读它，
仓库里没有一条路径能产出它。这叫**死枚举** ——
枚举本身没错，缺的是**谁往里写**。

**接上的口径**（不删 —— 删它要一次 `DROP CONSTRAINT` 迁移，
而它标的那个状态是真实存在的）：

| 事实 | 落哪个状态 | 为什么 |
|---|---|---|
| 源侧新来的商品，规范层还没有对应的 | `supplier_product.status='pending_review'` | 它已经存在（事实），但还没进我们的目录（判断没做） |
| 源商品挂到了规范商品上，但这个映射的覆盖关系还没核过 | `product_mapping.status='pending_review'` | 映射是判断，判断没做完 |
| 源变体还没有对应的规范变体 | `supplier_variant.status='pending_review'` | 同上 |
| 源变体与规范变体的覆盖关系还没核过 | `supplier_variant_mapping.status='pending_review'` | 同上 |

**待审核的事实不许漏进可用路径**（不变量 132-133）：
`pending_review` 的源商品不许有 `active` 的 `product_mapping`；
`pending_review` 的映射不许有 `active` 的 `supplier_variant_mapping`。

**同步作业只做机器能做的判定，不替人做判断。**
它把「源侧报了一个我们没定义过的商品」这件事落成 `pending_review` ——
这是**事实**（源侧确实报了一个我们目录里没有的东西）。
「它该对应我们哪个商品」是**判断**，同步作业不做，
人做（或者映射规则做，规则在 `configs/mapping_rules.json` 里）。

**所以 `pending_review` 的生产者是同步作业，不是审批流。**
审批流处理的是从 `pending_review` 走到 `active` 或 `rejected` ——
那一半今天还没有界面，但**枚举先接上**，否则接的时候要改四张表的约束。

#### 落库写者的形状

| 位置 | 干什么 |
|---|---|
| `tc-connect jobs` | 唯一入口（§5.25）；同步作业是它的一个分支 |
| `internal/sync` | 落库写者：抓 → 归一化 → 落库（复用 `internal/layertest` 的抓取阶段） |
| `internal/normalize` | 归一化（**唯一实现**，硬约束 14） |
| `sync_job_log` | 作业台账：开跑时 `running`，跑完 `success` / `partial` / `failed` |
| `v_supplier_sync_health` | 源健康视图（今天没人写 `sync_job_log`，它永远不会告警） |

**`sync_job_log` 的写口径**（`db/seed.sql` 里种子写的那四行定了词汇）：

- 开跑时 `INSERT` 一行 `status='running'`、`started_at=now()`。
- 跑完 `UPDATE` 成 `success` / `partial` / `failed`，
  落 `finished_at` 与 `stats`（失败时落 `error`）。
- `stats` 的键只用种子里那五个：`scanned` / `created` / `updated` /
  `skipped` / `failed`。
- `finished_at >= started_at` 是表上的 CHECK，写的时候要满足它。

**这一条补上一个洞**：`v_supplier_sync_health.last_sync_at` 与
`failed_jobs_24h` 今天永远读不到东西，因为**没有任何生产代码往
`sync_job_log` 写**（只有种子写）。视图能算，但它算的是空气。

**一个源一行台账**（`supplier_id` + `job_type`），跑一次更新一行，
不追加 —— 追加会让「最近一次同步是什么时候」变成
「在这么多行里找最大的那个」。

**写者的形状守三条硬约束**：

- **凭证只从环境变量读**（硬约束 12）。没有凭证就明确报「缺哪个环境变量」，
  不猜、不硬编码、不用假值糊过去。
- **报文先归档再落库**（硬约束 8）：`supplier_raw_payload` 里落的是脱敏后的原文。
  **源行必须挂在一个存在的 `supplier` 上** —— `store.NewArchiver(db, supplierID, enabled)`
  在 `supplierID <= 0` 时**静默关掉归档**，所以同步作业要**按 `supplier.code` 解析**
  （`supplier.code` 上有 UNIQUE 约束），解析不到就**当场报错**，不许静默跳过 ——
  静默跳过等于这次同步什么也没记，源健康视图上还看着一切正常。
- **值进 SQL 走 `store.NewSQL(...).Bind(v)` 与 `store.Quote`**（硬约束 40）。
  **不许把 `scripts/mapping_dryrun.py` 的 `lit()` 抄过来** ——
  那个 `lit()` 只做 `'` → `''`，不是 `internal/store` 的转义机制。

**Trip.com 没有种子行。** `db/seed.sql` 里只有五个源
（ingresso / fonticket / goodfellows_jtb / globaltix / piaofutong，id 1-5），
**Trip.com 不在里面**。所以同步作业按 `supplier.code` 解析源行，
解析不到就报错 —— 不许假设 id、不许自己插一行源（插源行是商务决定，
不是同步作业的决定）。

#### 这条路今天走通的样子

**只做 Trip.com 一个源。** 理由不是偏好：
另外六个源里，GlobalTix 的适配器是抛 `EndpointUnconfirmed` 的空壳，
其余五个落在 `pending.Adapter` 里 —— **只有 Trip.com 能真的抓**。
所以「先做一个源」不是取舍，是只有这一条路可走。

端到端一条链：**抓 → 归一化 → 落源层 → 落规范层 → 刷读模型 → C 端可见**。
跑通这一条，其余六源是**复制这一条**，不是重新设计。

**作业不重算任何业务结论**（与 §5.25 同一条口径）：
覆盖判定在 `fn_variant_covered`、定价在 `fn_price_variant`、
读模型刷新在 `fn_refresh_read_models()` ——
同步作业**不重算**这三样，它只负责把事实落下去，然后调刷新。

---
