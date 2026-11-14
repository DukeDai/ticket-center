# 交叉评审纪要 — 归一化商品模型（2026-11-14）

> 这是一次**缺陷验证**评审，不是设计评审。目的是回答一个问题：
> 上一轮 review 对「归一化商品模型」提出的 6 个缺陷指控，哪些是真问题。
>
> 评审**只读**，全程未修改仓库任何文件。结论是**待办清单**，不是已完成的改动。
> 实现顺序见本文末尾「实施顺序」。

---

## 1. 评审怎么做

### 1.1 为什么交叉评审

这个仓库已经过多轮 review。新提的批评必须先证明是**真实缺陷**，而不是分析产物或夸大，
否则就是往一个已经收敛的地方加噪音。

### 1.2 方法

三名 reviewer，同一份提示词，各自独立取证。提示词的核心要求是**先假定指控可能是错的**：

- 现象在代码里**确实存在**吗（自己重新定位行号，不相信指控里给的行号）。
- 现象存在的话，**真的造成业务危害**吗，还是「可以做得更好」。
- 指控的**因果链**完整吗（前提是不是都成立）。

每条指控三选一判定：`CONFIRMED`（现象真实 + 危害成立 + 因果链完整）、
`PARTIAL`（现象真实，但危害或因果链被夸大 / 只在部分情况下成立）、
`REFUTED`（现象不存在，或前提是错的）。

判定「零读者 / 死表 / 无写者」这类**否定性主张**时，必须穷举所有候选写者再逐个排除。
判定「结构上不可达」时，必须说明**为什么**不可达（哪条约束让违规值不可能存在），
而不是「种子里恰好没有违规数据」。

### 1.3 评审者与落选

| 评审者 | 模型 | 产出 |
|---|---|---|
| A | `claude:opus@max`（原生 lane） | 7 条判定 + 13 条遗漏事实 |
| B | 配置为 `codex:gpt-6.1-sol@max`，**不可用** | 见下 |
| C | `grok:grok-4.7@xhigh`，**硬落选** | 无 |

**B 的降级必须如实记录**：codex CLI 指向的 provider 目录里没有 OpenAI 模型，
`gpt-6.1-sol` 这个 model id 解析不了。**不静默回退到别的模型**——
跨 provider 的一致性是这次评审的全部价值，换了模型结论就不再可比。
实际执行用的是该 CLI 自己的 provider 模型 `MiniMax-M3.1-Flash-Preview`，
`codex exec --sandbox read-only` 跑了 230+ 条只读命令。
它的 `psql` 被本机网络策略挡住，所以它的 DB 侧结论是**静态 SQL 推导 + schema 交叉验证**，
不是运行时读库。

**C 是硬落选**：本机没有 grok CLI，启动器也缺 `bun`。没有产出。

两家有产出的模型对 6 条指控**没有一条正面冲突**。分歧在推理，不在事实。

### 1.4 各自纠正了什么

这次评审里，**纠正的价值高于新发现**：

- 评审者 B 纠正了主审上一轮的错判：`supplier_variant_mapping.confidence` 不是零读者。
  实测有 3 个读者（见 §3.6）。主审已撤回该主张。
- 评审者 B 纠正了「只有 `db/seed.sql` 在写规范层」的不准确表述，并指出了
  `scripts/mapping_dryrun.py` 这条被漏掉的规范层写者（见 §3.5）。
- 评审者 B 把指控 1 的因果链推翻了，主审独立复核后确认它更准确（见 §3.1）。

---

## 2. 结论速览

6 条指控**没有一条是分析噪音**，但 3 条的因果链与严重度需要修正。

| # | 指控 | 判定 | 严重度 | 事实层 |
|---|---|---|---|---|
| 1 | 源侧更窄的权益无处表达 | **PARTIAL** | warning | 成立，但因果链要重写 |
| 2 | 规范层只有种子在写 / `attribute_mapping_rule` 死表 | **PARTIAL** | warning | 死表成立，「只有种子在写」不准确 |
| 3 | 没有落库的写者 | **CONFIRMED** | **critical** | 完全成立 |
| 4 | 映射质量没有机制 | **PARTIAL** | nit | 成立，但严重度被夸大 |
| 5 | 场次跨源不一致没有对账 | **CONFIRMED** | warning | 完全成立 |
| 6 | 硬约束 4/11 只靠自觉 | **CONFIRMED**（缺门禁，非泄漏） | nit | 成立 |
| 7 | GlobalTix `validityDays` 断链（附带发现） | **CONFIRMED** | warning | 完全成立，且比描述更严重 |

「事实层」一列指**现象是否存在**。指控 1/2/4 的现象全部真实存在，
只是描述它们的因果链或严重度需要改写。

**本次评审暴露的系统性模式**：这套系统的失败方向是 **fail-closed**
（不知道就不卖、覆盖不过就排除、拿不到就 `known=false`）。这是对的。
真正的缺陷不是「卖错」，是「**错了不知道**」——静默丢弃、无痕的日志空缺、
承诺没有执行者。后续修复应该优先补**可观测性**，而不是补判定逻辑。

---

## 3. 逐条判定与证据

### 3.1 指控 1：源侧更窄的权益无处表达（PARTIAL / warning）

**原始主张**：选源与定价判定（`fn_route_candidates` / `fn_price_variant`）只考虑轴能力与价格场次，
不考虑源侧承诺的权益是否比规范侧窄，所以「包含项更少 / 不可退 / 有效期更短 / 免费儿童政策更严」
的源仍可能以 `route_rank = 1` 赢下，然后按规范侧的承诺卖出去。

**现象成立**：成立。规范侧的权益承诺（可退、包含项、免费儿童、年龄、有效期规则）
**零业务执行者**。

**因果链不成立**。原论证「更窄的源赢下选源」这条路径**不可达**，
而且方向是反的。`fn_variant_covered`（`db/migrations/012_composite_mapping.sql:203-215`）：

```sql
SELECT NOT EXISTS (
    SELECT 1 FROM fn_variant_requirements(p_variant_id) req
     WHERE NOT (COALESCE(p_coverage->'axes'->req.axis_code, '[]'::jsonb) ? req.option_code)
        OR (COALESCE(p_coverage->'excludes', '[]'::jsonb) ? req.option_code)
);
```

`fn_variant_requirements`（同文件 `:160-198`）只从**规范侧**两张表取值：
`product_variant.ticket_type_id` → `audience`，以及 `product_variant_option` → 各轴取值。

所以**缺一个轴，覆盖判定就失败**（`COALESCE(...) → '[]' → ? option` 为 false
→ `NOT EXISTS` 为 false → 不被覆盖）。轴机制本身就能表达「窄」，
而且表达得对：窄的源被排除。原指控说的「可证明的不对称」不成立。

**主审独立复核的一条补充**（评审者 B 也没说到）：评审者 B 指出
`ResolveAxes` 丢轴是「源比规范窄却被判覆盖得住」的现成路径。**这条也不成立**，
同样是 fail-closed。按 `db/seed.sql` 的实际轴挂载（`db/seed.sql:911-918`）：

| 变体 | 挂载的轴 |
|---|---|
| 9-13 | audience(axis 1) + pass_type(axis 2) |
| 14-15 | audience(axis 1) + pass_type(axis 2) |
| 16 | addon_type(axis 3) |
| 17 | axis 4 |

**没有任何变体要求一条它没挂的轴**，所以丢轴永远导致覆盖失败而非误判通过。

**但 `ResolveAxes` 的缺陷本身是真的**（`internal/normalize/normalize.go:240-270`）：
当源值既不命中 `rule.ValueMap`、也不命中大小写兜底时，`out[rule.AxisCode]` 从不被写入，
**轴从 coverage 里静默消失，无错误、无痕迹**。

这才是指控 1 里真实存在的缺陷。`configs/mapping_rules.json` 的实际取值范围：

- trip_com `pass_type` 的 `value_map` 只有 4 个包名（「一日票 · 单园区」等）
- globaltix `park_scope` 只认 `studio_tour` 与 `studio_tour,snw`

源侧新增一个包名 = 一条静默消失的轴。今天的后果是那个源 SKU 被静默排除
（fail-closed，安全），但**静默**本身是问题：源侧改了个名，我们不报错，
只是这个源悄悄不参与选源了。

**重构后的真实缺陷（更根本，也更便宜修）**：
**规范侧的承诺只有展示，没有执行**。`product.refund_policy`
已经通过 `internal/capi/products.go:56,271` 透明暴露给 C 端
（`refundable` / `refund_fee_percent`），但库里没有任何一条业务路径读取它来判定能不能退。
同类零执行者字段共 12 个，含 `product.validity_rule`、`product.terms`、`ticket_type.age_rule`。

客户看到「可退」，退的时候没有依据。这比「源侧窄权益无处表达」更严重，
因为它影响的是**已经上线给客户的承诺**，而不只是建模的完备性。

**证据**

| 事实 | 位置 |
|---|---|
| 要求集合只含 `(axis_code, option_code)` | `db/migrations/012_composite_mapping.sql:160-198` |
| 覆盖判定只做轴比对 | `db/migrations/012_composite_mapping.sql:203-215` |
| 丢轴导致覆盖失败（fail-closed） | 同上（`COALESCE` → `'[]'` → `?` 为 false） |
| 轴静默消失 | `internal/normalize/normalize.go:240-270` |
| `excludes` 无生产者 | `internal/normalize/normalize.go:546`（`coverageOf` 初始化为 `[]string{}`） |
| 种子每条 coverage 的 `excludes` 都是空 | `db/seed.sql:964-973` |
| 组合分支的五种不可售原因，全不涉及权益 | `db/migrations/017_supplier_bundle.sql:781-786` |
| 套装分支的七种，同上 | `db/migrations/017_supplier_bundle.sql:777-786` |
| `refund_policy` 已暴露给 C 端 | `internal/capi/products.go:56,271` |

### 3.2 指控 2：规范层只有种子在写 / `attribute_mapping_rule` 死表（PARTIAL / warning）

**「死表」成立**。`attribute_mapping_rule`（`db/migrations/001_baseline.sql:212-224`）
与同族的 `attribute_definition`（`:193-211`）**零业务读者**：
全仓库只有 `db/seed.sql:491,862` 两处 INSERT，没有任何 Go / Python / JSON 读取。
`transform` jsonb 列**从未被应用过**。

**「只有 `db/seed.sql` 在写」不准确**。`scripts/mapping_dryrun.py` 是第二个规范层写者，
也是**唯一端到端可跑的归一化路径**——它的 `normalize_via_go()` 调 `tc-connect normalize`，
符合硬约束 14（归一化只有一个实现）。

准确表述是：**Go 生产代码零写入；规范主数据来自手写 fixture，不是从源报文推出来的。**

**而这条路径本身在丢事实**，逐条：

| 丢的东西 | 位置 |
|---|---|
| `product_axis_option.valid_days` 漏写 | `scripts/mapping_dryrun.py:203` |
| `min_qty` / `max_qty` 漏写 | `scripts/mapping_dryrun.py:280-287` |
| `supplier_session_id` 写死为 NULL | `scripts/mapping_dryrun.py:280-287` |
| 规范主数据读手写 fixture | `scripts/mapping_dryrun.py:346` |

`valid_days` 漏写这一条最要紧：它正是硬约束 23 要求「不许写死 `+1`」的那条口径，
而这条唯一可跑的路径没写它。

**`docs/connector-contract.md` 的漂移**：`§5.1` 描述的 6 种 transform
（`direct` / `wrap_min_age` / `minutes` / `currency_convert` / `split_list` / `boolean_coerce`）
一个都没实现；`§6` 的同步作业条目仍未勾选。

**证据**：`db/migrations/001_baseline.sql:193-224`；`db/seed.sql:491,862`；
`internal/normalize/normalize.go`（`import` 只有标准库，不碰 `internal/store`）；
`cmd/tc-connect/compose.go:120`（唯一生产消费者，只取 `CompositeExpressions` + `Variants`，
只写 `supplier_variant_composition`）；`scripts/mapping_dryrun.py:203,280-287,346`。

### 3.3 指控 3：没有落库的写者（CONFIRMED / critical）

**这是最强的一条。** 整个仓库**没有一条路径把源侧数据落成可卖的商品**。

| 事实 | 证据 |
|---|---|
| 16 个子命令里没有抓目录的 | `cmd/tc-connect/`（`sources layers mock normalize price migrate refresh order fulfill refund redeem stock hold variant compose jobs`） |
| 只有 4 个作业 + 2 个只读报告 | `cmd/tc-connect/cmd_jobs.go:41-100` |
| `sync_job_log` 只有种子写 → `v_supplier_sync_health` 永远不会告警 | `db/seed.sql`；生产代码零 INSERT |
| 归一化是纯函数包，不碰 DB | `internal/normalize/normalize.go`（`import` 只有 `encoding/json` / `fmt` / `os` / `sort` / `strconv` / `strings`） |
| `Result.Products` / `Result.Prices` 只在 normalize.go 内部被读 | 同上（`:460,463`） |
| 唯一生产消费者只写一张表 | `cmd/tc-connect/compose.go:120` → `supplier_variant_composition` |
| 全仓库唯一的源侧写入路径是归档 | `internal/store/archive.go:37` |

**GlobalTix 的子指控要降级**：`internal/supplier/globaltix/globaltix.go` 从不发 HTTP 请求
（`:68` Connectivity，`:71-72` 抛 `EndpointUnconfirmed`，`:95/101/123` 同样）。
**没有报文就没有归档义务**——硬约束 13 正在按设计工作，硬约束 8 暂无可违反之处。
准确说法是「适配器是桩」。

### 3.4 指控 5：场次跨源不一致没有对账（CONFIRMED / warning）

种子把 GlobalTix 10:00 特展入口B2、JTB 09:00 特展正门、票付通 10:30 特展入口B2
合并进同一个 `product_session`（id=1），三个源的时间与入口明显不一致，**全绿**。

| 事实 | 证据 |
|---|---|
| `product_session_source` 零触发器、零 CHECK | `db/migrations/001_baseline.sql:388-424`（对比：组合与套装都有守卫触发器） |
| 121 条不变量无一覆盖场次时间或集合点 | `v_invariant_checks` 全量 |
| 出券写的是**规范侧**场次，源侧按另一个时间执行 | `fn_issue_voucher` → `voucher.session_id` |
| 今天的暴露为零 | C 端不渲染场次时间与集合点 |
| `slot_key` 就是为这个粒度设计的，种子没用 | `db/migrations/001_baseline.sql:388-424`（`slot_key TEXT DEFAULT 'default'`） |

套装路径已经有**日期级**的先例（`db/migrations/017_supplier_bundle.sql:2290-2294`），
所以场次级对账有现成的做法可循，不是从零设计。

### 3.5 指控 4：映射质量没有机制（PARTIAL / nit）

**成立的部分**：

- `pending_review` 是**死枚举**。全仓库只有 4 处提到它，全是 CHECK 约束
  （`db/migrations/001_baseline.sql:268,341,1966,1994`）。没有地方把它写进去或读出来。
  `docs/ddd.md:155` 还在承诺一个审批流。
- `match_evidence` / `match_type` **零读者**。
- `canonical_key` **零读者**（`db/migrations/001_baseline.sql:163,183`，非唯一索引）。
  它有两套互不兼容的推导——种子手打 slug（`db/seed.sql:96,873,1170`）
  vs `scripts/mapping_dryrun.py:190-193` 的 `product_code.lower()`——
  但因为零读者，**两套推导今天不冲突**。
- 不变量 2 **结构上不可达**：`ux_map_single_primary`
  （`db/migrations/001_baseline.sql:350-351`）在 INSERT/UPDATE 时就拒绝第二行，
  所以 `HAVING count(*) > 1` 永远不成立。这是**约束重复**的 nit，不是数据漏洞。

**主审撤回的错误**：我上一轮说 `supplier_variant_mapping.confidence` 零读者，**这是错的**。
它有 3 个真实读者：

- `db/migrations/005_fulfillment.sql:301`
- `db/migrations/014_booking_unit_source_sku.sql:288`
- `db/migrations/017_supplier_bundle.sql:2032`

三处都是 `ORDER BY svm.confidence DESC, svm.id LIMIT 1`（建预订时选源变体）。

### 3.6 指控 6：硬约束 4/11 只靠自觉（CONFIRMED / nit）

**性质是「缺门禁」，不是「已泄漏」**。

- **约束 11 完全守住**：无 `require` 块、无 `go.sum`、零非标准库 import。
- **约束 4 实质守住**：零硬编码 supplier ID，业务与请求链路零源字面量。
  但「唯一分支在 `internal/registry/registry.go`」不准确——
  `internal/layertest/checks.go:127,140,142,156,281` 有 4 处功能硬编码 `"trip_com"`，
  那个文件**不是** `_test.go`，会进二进制；另有 `cmd/tc-connect/cmd_source.go:112`。

`internal/sqllint` + `cmd/tc-lint` 只检查 SQL 转义，**没有源分支门禁**。
这就是硬约束 40 的机制化在约束 4 上的缺失。

### 3.7 附带发现：GlobalTix `validityDays` 断链（CONFIRMED / warning）

**比描述更严重。** `configs/mapping_rules.json` 的 globaltix `/skus/axes` 只有三条轴规则：

| axis_code | value_path |
|---|---|
| `pass_type` | `passType` |
| `park_scope` | `parks` |
| `addon_type` | `addon` |

**没有 `validityDays` 的规则**，所以源侧 `fixtures/globaltix_catalog.json` 的
`validityDays: 1` 从未到达 `product_axis_option.valid_days`。

关键在于 `passType` 与 `validityDays` 是**源侧两个独立字段**，系统只认前一个。
源侧发 `passType="2d"` + `validityDays=1` 时：

- 我们按 2 天卖、按 2 天出券（`fn_variant_validity_days` 读轴选项）
- 源侧只认 1 天
- 客户到门口是 **expired**

这正是 `db/migrations/010_validity_window.sql:14-27` 要根治的那类 bug。
同类断链还有 `pricingType` / `groupMin` / `groupMax` 无规则，
且 `scripts/mapping_dryrun.py:280-287` 不写 `min_qty` / `max_qty`。

**这一条不需要新表就能修**，是四条里最便宜的。

---

## 4. 评审者补充的遗漏事实

以下是评审过程中查出、**原始指控没写**、且改变结论的事实。

### 4.1 规范侧的承诺本身零执行者（12 个字段）

`product.refund_policy`、`product.validity_rule`、`product.terms`、`ticket_type.age_rule` 等
共 12 个字段没有任何业务读者。其中 `refund_policy` 已经挂到 C 端。

这条把指控 1 从「建模不完备」重构成「**承诺无执行者**」——
影响面更大，但也更便宜修（补执行路径，不必扩模型）。

### 4.2 `coverage.excludes` 有载体、无写者

`coverageOf`（`internal/normalize/normalize.go:546`）初始化 `Excludes: []string{}`，
种子里每条 coverage 字面量都是 `'excludes':[]`。载体已备好，等着有人写。
注意 `fn_variant_covered` 与 `fn_variant_coverage_gaps` **已经在读它**——
判定逻辑写好了，缺的是生产者。

### 4.3 `confidence` 有 3 个读者

见 §3.5。纠正了主审的错判。

### 4.4 `scripts/mapping_dryrun.py` 是规范层写者，且是唯一可跑的端到端路径

见 §3.2。纠正了「只有种子在写」的不准确表述。

### 4.5 那条路径本身在丢事实

`valid_days` / `min_qty` / `max_qty` / `supplier_session_id`。见 §3.2。

### 4.6 `fn_route_candidates` 从不 join 场次

`db/migrations/001_baseline.sql:2284-2286` 的 WHERE 只有三条
（`fn_variant_covered` + 两个汇率非空），从不 join `supplier_session` / `product_session`。
它做的是**产品级选源**，场次级绑定不在它职责内——这是设计边界，不是缺陷。

### 4.7 `product_session_source` 零守卫，而组合与套装都有

见 §3.4。说明这是**遗漏**，不是「设计上就不需要」。

### 4.8 `v_supplier_sync_health` 永远不会告警

`sync_job_log` 只有种子写 → 这个健康视图永远绿。见 §3.3。

### 4.9 `ResolveAxes` 静默丢轴

见 §3.1。**但可达性被主审复核推翻**（丢轴导致 fail-closed，不是误判通过）。

### 4.10 文档漂移比指控列的更广

`docs/connector-contract.md:145-156` 的 6 种 transform 全未实现；
`:133,274,286-287,398-401,579` 把「定时拉取落库」「我们的同步作业」「增量游标」
描述成已存在；`:6` 的同步作业条目仍未勾选。

### 4.11 `c_product_card.age_min` 是死事实

读模型里的字段没有来源。

### 4.12 `layertest` 的 4 处 `"trip_com"` 会进二进制

见 §3.6。

### 4.13 `db/verify.sql` 的两处缺口

`:47-56` 打印跨源场次但**不 assert**；`:941-957` 只数 `v_invariant_checks` 的条数。

---

## 5. 实施顺序

按「**便宜的先修 + 客诉级的先修 + 结构性缺口最后做**」排。
每一步都要同步改对应合同文件（硬约束 1）。

### 第 1 步：GlobalTix `validityDays` 断链（warning，最便宜，客诉级）

- 补 `configs/mapping_rules.json` 的 `validityDays` → `valid_days` 规则
- 补 `scripts/mapping_dryrun.py:203` 的 `valid_days` 写入
- 核对 `passType` 与 `validityDays` 冲突时的口径（源侧两个字段不一致怎么办）
- 同步 [`spec/15-validity.md`](../spec/15-validity.md)

**验收**：源侧 `validityDays: 1` 到达 `product_axis_option.valid_days`，
`fn_variant_validity_days` 返回 1；`c_variant_calendar.valid_to` 随之正确。

### 第 2 步：规范侧承诺的执行者（warning，影响已上线的 C 端）

先定清楚**哪几个承诺要有执行者**（`refund_policy` 最急，因为它已经展示给客户了），
再逐个补执行路径。`refund_policy` 的执行者应该是 `fn_request_refund` / `fn_approve_refund`
（放行时按承诺判定资格），而不是在 C 端或 Go 侧判。

- 同步 [`spec/12-refund.md`](../spec/12-refund.md) 与
  [`docs/ddd.md`](../docs/ddd.md)
- 若要新增字段，走**新增迁移**（硬约束 3）

**验收**：C 端展示 `refundable` 的商品，退款路径按同一条承诺判定，不一致时当场报错。

### 第 3 步：没有落库的写者（critical，最大的结构性缺口）

这项工作量最大，但**要先定契约**，不能直接开写。至少要先决定：

- 同步作业的**幂等边界**（重放一次会不会重复落商品）
- 源侧游标**存在哪**（`sync_job_log` 现在只有种子写）
- 规范层主数据是**从源报文推**还是**人工审核后落**（这决定审批流的去留）
- `pending_review` 这个死枚举是**删掉**还是**接上**

工作模型建议：**先做 Trip.com 一个源**（凭证最齐、协议已核对），
端到端跑通「抓 → 归一化 → 落规范层 → 落源层 → 读模型刷新 → C 端可见」，
再谈其余六源。

- 同步 [`spec/00-overview.md`](../spec/00-overview.md) 与
  [`docs/connector-contract.md`](../docs/connector-contract.md) §6 / §9

### 第 4 步：场次跨源对账（warning）

- 种子合并了三个源的时间与入口。先决定这是**数据错了**（拆成三个 `product_session`）
  还是**规范有意合并**（那就得有一致性口径）
- 给 `product_session_source` 加守卫触发器（对齐组合 / 套装的既有做法）
- 补一条不变量覆盖场次时间与集合点
- `db/verify.sql:47-56` 的打印改成 assert

- 同步 [`docs/schema-design.md`](../docs/schema-design.md) 与
  [`spec/00-overview.md`](../spec/00-overview.md)

---

## 6. 明确不动的部分

以下几项已判定为 nit 或不是缺陷，**本轮不做**，理由记在这里以免下次 review 又提一遍：

| 项 | 不做的理由 |
|---|---|
| 不变量 2 | `ux_map_single_primary` 让它结构上不可达，是约束重复，不是数据漏洞 |
| `confidence` 加门禁 | 它有 3 个读者，是活字段 |
| `canonical_key` 加唯一索引 | 零读者，今天不冲突；等它有读者再说 |
| `match_evidence` / `match_type` | 归一化还没产出这些值，落库写者做完（第 3 步）再谈 |
| `pending_review` | 归第 3 步一起决定是删还是接 |
| GlobalTix 报文归档 | 适配器是桩，不发 HTTP 请求，没有报文可归档；等适配器启用再说 |
| `c_product_card.age_min` | 等第 3 步落库写者补上来源 |
| `layertest` 的 `"trip_com"` | 功能性硬编码，非业务链路泄漏；第 3 步之后连同源分支门禁一起处理 |
| 文档漂移专项清单 | 见下方待定项 |

---

## 7. 待定项

- **文档漂移要不要单独做一份清单**（`docs/connector-contract.md` 的 6 种 transform、
  同步作业描述、`db/verify.sql` 的两处缺口），
  还是并入第 3 步一起改。硬约束 37 的「推导出来的数不许手抄」在**文档漂移**这一项上
  目前没有对应的门禁。
- **源分支门禁**（约束 4 的 AST 检查）要不要单独排在第 4 步之后，
  还是等第 3 步把归一化写者落地后再加。晚做的理由是：门禁要在有真实分支可查时才不会误伤。

---

## 8. 关联

- 硬约束全文：[`AGENTS.md`](../AGENTS.md)
- 业务合同索引：[`SPEC.md`](../SPEC.md)，正文在 [`spec/`](../spec/)
- 领域模型：[`docs/ddd.md`](../docs/ddd.md)
- 物理模型：[`docs/schema-design.md`](../docs/schema-design.md)
- 接入层契约：[`docs/connector-contract.md`](../docs/connector-contract.md)
- 接入层实现：[`docs/integrations.md`](../docs/integrations.md)
- C 端模型：[`docs/c-end-model.md`](../docs/c-end-model.md)
