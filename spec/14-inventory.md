# 库存预占侧不变量、库存预占写路径、预占的默认 TTL 口径

> 合同的一部分。章节：§4.12 · §5.9 · §5.23。索引见 [`SPEC.md`](../SPEC.md)。
> 本文件是**合同**：改动这里的业务行为，必须同步改这里，并同步 `docs/ddd.md`（领域模型）与 `docs/schema-design.md`（物理模型）。

---

### 4.12 库存预占侧不变量（69-72，2026-11-07 补充）

售出多少是事实，库存口径只有一处：`fn_available_qty`（可售数的唯一实现）、
`fn_reserve_qty`（扣减的唯一实现）。门禁住在 `v_invariant_checks_inventory_flat` 里。

| # | 不变量 |
|---|---|
| 69 | 每条订单明细都要有一条对应的预占记录（卖出多少查得到） |
| 70 | 预占记录与订单明细的量、变体、场次必须对得上 |
| 71 | 预占记录自洽：额度用尽量不许超过数量；作废的预占必须是「卖出后又收回」 |
| 72 | 卖出时的可售数不许超过快照里记的剩余量 |

这四条守的是「我们到底承诺出去多少」。

- 明细有、预占没有（不变量 69）—— 卖出去的东西查不到「占了谁的位置」，
  超卖之后无从追溯是哪一单吃掉了库存。
- 预占的量与明细的量对不上（不变量 70）—— 承诺出去的量和卖出去的量分叉，
  对账时两边数字不一样。
- 作废的预占额度用尽量不等于数量（不变量 71）—— 「卖出后收回」和「从未卖出」
  在账上分不开，退款与超卖的账就永远算不清。
- 卖出去时的可售数超过了当时记下的剩余量（不变量 72）—— 说明扣减口径被改过，
  或者并发下两个订单各卖各的最后一张。

### 5.9 库存预占写路径（2026-11-07 落地）

前面四段写路径都通了，但**可售数是空的**：没有地方算「还剩多少」，
没有地方扣「我们已经承诺出去多少」，也没有地方在并发下防止两个订单卖同一张票。
表现是：源侧快照显示 20 张，我们卖出 18 张，系统仍然按 20 张继续卖。

现在这一段有唯一实现：`fn_available_qty` / `fn_reserve_qty` / `fn_hold_inventory` /
`fn_release_hold` / `fn_expire_holds`（`db/migrations/009_inventory_hold.sql`）。

**这一段有六条口径，写在前面。**

第一，**可售数只有一个实现**：`fn_available_qty` 是「这个源场次还剩多少」的唯一读法，
来源按可信度取：票种级库存快照 → 场次级快照 → 可用性缓存。
**取不到就返回「不知道」（`known = false`），不返回 0** ——
返回 0 意味着「卖完了」，那会让整个商品下架，是比超卖更贵的错。

第二，**源侧快照与我们自己的承诺要对账，不能各算各的**。
源侧快照里的 `sold` 包含了**已经同步到源侧的那些**销量；我们账上的 `consumed`
是全部卖出量。两者差的那部分才是「源侧还不知道、但我们已经卖出去」的量：

```
unreflected = GREATEST(our_sold − source_sold, 0)     源侧尚未反映的销量
committed   = unreflected + active_held               我们承诺出去但还没成交的量
remaining   = GREATEST(available − committed, 0)      还能卖多少
```

**不这么算就会双扣**：每次源侧同步后 `source_sold` 涨一次，我们再扣一次全量 `consumed`，
可售数会一路掉到只剩一半。

第三，**并发靠锁，不靠先查后改**：`fn_reserve_qty` 按 `supplier_session.id` 升序加行锁
（`SELECT ... ORDER BY id FOR UPDATE`），**先锁小的再锁大的**是为了让两个订单不会
互相死锁（A 锁 1 再锁 2、B 锁 2 再锁 1 会死锁）。锁拿到之后再算可售、再判断够不够。

第四，**明知不够就当场报错**。源侧说了还剩 3 张、我们要 5 张 → 直接报
「库存不足：源场次 % 只剩 % 张，要 % 张（源侧状态 %）」。
**不知道（`known = false`）时不拦**，但要把「卖的时候不知道还剩多少」写进明细快照
（`detail_snapshot.availability`）—— 这条记录是事后对账的依据。

第五，**预占是事实，幂等键必填**：`fn_hold_inventory` 的 `hold_no` 是幂等键
（作用域 `hold:<channel_id>`），用 `INSERT ... ON CONFLICT DO NOTHING` 抢键，
**同键异内容当场报错**（重放一次预占等于凭空多占一份）。

第六，**订单关掉就把承诺放掉**。购物车预占有 TTL（`expires_at`，默认 15 分钟，
`fn_expire_holds` 统一过期），订单走到 `cancelled` / `expired` / `refunded` 时
由触发器 `trg_release_holds_on_order_close` 把它的预占置为 `voided`。
**`voided` 与 `released` 是两回事**：`released` 是从未卖出，`voided` 是卖出后又收回
（退款、取消、超时）—— 卖出的事实不许被改写，所以 `voided` 的 `consumed_quantity` 仍然是原数。

预占状态：`active`（占着）/ `consumed`（已卖出）/ `released`（放过，从未卖出）/
`expired`（TTL 到）/ `voided`（卖出后收回）。

下单侧与预占侧的接缝：`fn_place_order` 在落明细之后，为每条明细写一条预占记录 ——
有匹配的购物车预占就把它消费掉（`active → consumed`，承诺量不变，不会重复扣），
没有就新建一条 `consumed` 的（`hold_no = 'HOLD' || 订单号 || '-' || 序号`）。
**卖出多少是事实，必须查得到**（不变量 69）。

函数清单：

| 函数 | 干什么 | 幂等口径 |
|---|---|---|
| `fn_available_qty` | 算这个源场次还剩多少（源侧快照与我们账对账后的结果） | 只读 |
| `fn_reserve_qty` | 锁场次 → 算可售 → 不够当场报错 | 加锁后判断，不靠先查后改 |
| `fn_hold_inventory` | 建预占（购物车占位），返回扣减后的可售数 | `hold_no` 幂等键，同键异内容报错 |
| `fn_release_hold` | 放掉一张预占 | 幂等：重复调用返回「已放过」，不报错 |
| `fn_expire_holds` | TTL 过期作业 | 幂等：只动已过期且仍 `active` 的 |
| `fn_release_holds_for_order` | 订单关掉时放掉它的预占（触发器调用） | 幂等：只动仍 `active` 的 |

Go 侧新增 `internal/inventory`：拼参数、收结果、把库的报错原样带出去。
**不在 Go 里算可售数，不在 Go 里判断够不够，不在 Go 里改预占状态** ——
理由与 `internal/order` / `internal/fulfillment` / `internal/refund` / `internal/redemption` 相同。
CLI 是 `tc-connect stock show` 与 `tc-connect hold create|release|expire|show`。

### 5.23 预占的默认 TTL 口径（2026-11-13 落地）

**这件事是什么**：预占的存活时长有一个默认值（900 秒 = 15 分钟）。
「调用方没指定」和「调用方指定了 900」**是同一件事**，
但以前只有后者成立 —— 前者会在第一步就炸。

**错在哪**：Go 侧把「没指定 TTL」编码成 SQL `NULL` 传进 `fn_hold_inventory`，
而 PostgreSQL 的 `DEFAULT` **只在省略实参时生效** —— 显式传 `NULL` 拿到的是 `NULL`。
`NULL` 顺着哈希链把 `idempotency_record.request_hash`（`NOT NULL`）撑成 `NULL`，
预占在写幂等记录那一步就炸：

```
ERROR: null value in column "request_hash" of relation "idempotency_record"
       violates not-null constraint
```

`tc-connect hold create` 不带 `--ttl` 时就是这个结果 ——
**README 自己给的示例命令是跑不通的**。

唯一实现：默认值**住在库里**。
`fn_hold_inventory` 开头把 `p_ttl_seconds` 归一：
`v_ttl := COALESCE(p_ttl_seconds, 900)`。
哈希、`expires_at` 都用 `v_ttl`，不再用原参数。
落点：`db/migrations/027_hold_ttl_default.sql`（`CREATE OR REPLACE FUNCTION`，
已发布的 009 不动 —— 硬约束 3）。

三条口径写死：

- **默认值住在库里，不住在调用方。** 任何一个调用方（Go、psql、别的接入层）
  省略 TTL 或传 `NULL`，拿到的都是同一个 900。
  默认值写在调用方 = 每多一个调用方就多一个默认值，
  三处默认值总有一处忘了改 —— 那是 §8 里那份「同一份规则被抄在三处」的病，
  在数值上复发。
- **`DEFAULT` 不是归一，是「省略才生效」。** PostgreSQL 的 `DEFAULT` 只在**省略实参**时生效；
  显式传 `NULL` 拿到的是 `NULL`。凡是「参数可以不给」的函数，
  归一都得在函数体里显式写，不靠调用方自觉。
- **幂等口径不变，但「不指定」与「指定 900」现在落同一张预占。**
  同一个 `hold_no`、同一个哈希 = 幂等命中，不新建。
  同键异内容（份数不同、TTL 不同）仍然当场报错 ——
  重放一次预占等于凭空多占一份。

表与函数：

| 位置 | 干什么 |
|---|---|
| `fn_hold_inventory` | 唯一实现：把 `NULL` 的 TTL 归一成 900，哈希与到期时间都用归一后的值 |
| `v_invariant_checks_hold_ttl` | 预占到期时间侧不变量（119） |

Go 侧不变：`internal/inventory` 仍然只拼参数、只读结果，
「没指定」仍然编成 `NULL` 传过去 —— 归一是库的事。
回归测试 `TestHoldWithoutTTLMeansDefaultTTL` 钉住契约：
不指定 TTL 与指定 900 必须落在**同一张预占**上（同一个 hash）。
