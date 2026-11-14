# 预占到期时间侧不变量、凭证过期作业侧不变量、凭证过期作业、作业调度、值进 SQL

> 合同的一部分。章节：§4.26-4.27 · §5.24-5.26。索引见 [`SPEC.md`](../SPEC.md)。
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
