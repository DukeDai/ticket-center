# ticket-center — 多源票券中心

面向 OTA 的票券中台：把来自多个 GDS / 票务平台（Ingresso、FonTicket、Goodfellows·JTB、GlobalTix、票付通、Zowoyoo 自由行、Trip.com…）
的票券归一化成**一套规范商品模型**，对外以同一套商品/价格/库存/订单模型同时支撑 **B 端分销**与 **C 端自营**。

> **当前阶段：领域模型 + 物理模型 + 验收查询 + 接入层（Go）。**
> 接入层已用 Go 实现（`cmd/tc-connect` + `internal/`）：Trip.com 分销侧协议完整核对，
> GlobalTix 端点待商务确认，其余五源待文档。拿到凭证即可直接跑分层连通性测试；
> API / Web 与业务编排尚未实施。

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

psql -h 127.0.0.1 -d postgres -c "DROP DATABASE IF EXISTS ticket_center;" \
                       -c "CREATE DATABASE ticket_center;" && \
psql -h 127.0.0.1 -d ticket_center -v ON_ERROR_STOP=1 -f db/schema.sql && \
psql -h 127.0.0.1 -d ticket_center -v ON_ERROR_STOP=1 -f db/seed.sql && \
psql -h 127.0.0.1 -d ticket_center -v ON_ERROR_STOP=1 -f db/verify.sql
```

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
| 表 / 视图 / 索引 / 触发器 / CHECK | 69 / 14 / 198 / 18 / 87 |
| 种子数据 | 7 源 · 11 源商品 · 7 规范商品 · 11 跨源映射 · 13 场次源绑定 · 6 订单 · 7 明细 · 6 预订 · 7 凭证 · 2 结算单 · 9 读模型卡片 · 9 日历格子 · 4 优惠券 · 4 购物车 · 4 库存预占 · 11 结算规格 · 10 持票人 · 6 评价 · 17 变体 · 25 源变体 · 29 覆盖映射 |
| 不变量断言 | **38 / 38 PASS**（含按团报价与价格保护三条定价门禁） |

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
| Go 单元测试 | **7 个包全绿**（config / credential / normalize / store / transport / layertest / tripcom） |
| 依赖 | 零第三方依赖（标准库 `net/http` + `psql` 子进程） |

---

## 目录

| 文件 | 内容 |
|---|---|
| [`SPEC.md`](SPEC.md) | 业务合同：范围、角色、流程、**38 条不变量**、状态机、验收标准 |
| [`docs/ddd.md`](docs/ddd.md) | 限界上下文、聚合边界、领域事件、归一化与路由机制、**变体与覆盖语义** |
| [`docs/c-end-model.md`](docs/c-end-model.md) | **C 端：读模型、展示内容、购买漏斗、变体选择器** |
| [`docs/schema-design.md`](docs/schema-design.md) | SQL / 半 SQL / NoSQL 选型论证、表清单、**变体模型（§5）**、索引策略、演进路线 |
| [`docs/connector-contract.md`](docs/connector-contract.md) | 供应源接入端口、错误四分类、幂等重试、七源差异矩阵、**§9 接入层实现现状** |
| [`docs/integrations.md`](docs/integrations.md) | **接入层（Go）**：包结构、设计纪律、CLI 用法、拿到授权后的验证清单 |
| [`db/schema.sql`](db/schema.sql) | 全部 DDL |
| [`db/seed.sql`](db/seed.sql) | 种子数据 |
| [`db/verify.sql`](db/verify.sql) | 验收查询 + 不变量断言 |
| [`cmd/tc-connect/`](cmd/tc-connect/) | **接入层 CLI**：`sources` / `layers` / `mock` / `normalize` |
| [`internal/`](internal/) | **接入层实现**：传输层 / 凭证 / 归一化 / 各源适配器 / 归档幂等 / mock |
| [`configs/`](configs/) | 传输层配置（端点 / ICODE / 凭证口径 / 错误码）+ 映射规则（单一真相） |
| [`fixtures/`](fixtures/) | 真实报文结构的样例（canonical / trip_com / globaltix） |
| [`scripts/mapping_dryrun.py`](scripts/mapping_dryrun.py) | **无凭证集成演练**：用真实报文结构跑一遍 mapping → 路由（归一化调用 Go 实现） |
| [`scripts/poc/index.html`](scripts/poc/index.html) | 前端 POC：变体矩阵 / 覆盖语义匹配 / 变体级路由 / 模型缺口（演练生成物） |
| [`Makefile`](Makefile) | build / test / mock / layers / dryrun / db / check |
| [`AGENTS.md`](AGENTS.md) | 仓库级硬约束与命令约定 |

---

## 下一个阶段

- [ ] **拿到 Trip.com 分销侧凭证**（`aid` / `sid` / `key`）→ 跑沙箱 + 生产分层测试，核对 4 个待确认点（见 `docs/integrations.md`）
- [ ] 拿到 **GlobalTix 接口文档** → 填 `configs/api_config.json` 的端点与请求体 → 启用适配器
- [ ] 其余五源（Ingresso / JTB / Zowoyoo / FonTicket / 票付通）的接口文档到位后逐个实现
- [ ] **组合履约表** `supplier_variant_bundle`（GlobalTix 的 `A|2+B|1` 表达不了，待拍板）
- [ ] 接入层之上的**业务编排**（同步作业 / 下单 / 退订 / 改派 / 自动补报）
- [ ] B 端管理台：商品/上架/路由/映射审核/异常单
- [ ] C 端链路：搜索 → 详情 → 选场次 → 下单 → 出券 → 核销
- [ ] 订单表分区、只读副本、源报文冷热分离（方案见 `docs/schema-design.md` §9）
