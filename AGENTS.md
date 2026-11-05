# AGENTS.md — ticket-center

多源票券中心（OTA 票券中台）。PostgreSQL 15+。

## 这是什么

一个把多个 GDS / 票务平台（Ingresso、FonTicket、Goodfellows·JTB、GlobalTix、票付通…）的票券
归一化成统一模型，同时支撑 **B 端分销**与 **C 端自营**售卖的中台。

**当前阶段聚焦领域模型与物理模型**，API / Web 尚未实施；
**接入层已用 Go 实现**（`cmd/tc-connect` + `internal/`）：Trip.com 分销侧协议已完整核对，
GlobalTix 端点待商务确认，其余五源待文档。**Go 1.23+ 是本仓库的必备工具链。**

## 硬约束

1. **SPEC.md 是合同。** 改任何业务行为，必须同步改 `SPEC.md` 对应章节；改领域模型必须同步改
   `docs/ddd.md`；改表结构必须同步改 `docs/schema-design.md`。规格里列的 38 条不变量不得在改动中丢失。
2. **不变量是门禁。** `v_invariant_checks` 里任何一条 `actual > 0` 即为数据违规，
   `db/verify.sql` 必须全绿才能提交。
3. **DDL 只增不改。** 已发布的表结构用 `ALTER TABLE ... ADD` 演进，
   不要直接改 `db/schema.sql` 里已经建好的列 —— 那会让新库和存量库结构分叉。
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

## 目录

```
SPEC.md                      业务合同（范围/流程/不变量/状态机/验收标准）
docs/ddd.md                   领域模型：限界上下文、聚合、事件、状态机
docs/c-end-model.md           C 端：读模型、展示内容、购买漏斗
docs/schema-design.md         物理模型：选型论证、表清单、索引策略、演进路线
docs/connector-contract.md    供应源接入端口契约 + 七源差异矩阵 + §9 接入层实现现状
docs/integrations.md          接入层（Go）：包结构、设计纪律、CLI 用法
db/schema.sql                 全部 DDL（69 表 / 14 视图 / 198 索引 / 18 触发器）
db/seed.sql                   种子数据（7 源 / 6 规范商品 / 10 映射 / 3 源冗余场次 / 5 订单 / 8 读模型卡片 / 16 变体 / 24 源变体）
db/verify.sql                 验收查询（15 组视图 + 38 条不变量断言）
cmd/tc-connect/               接入层 CLI：sources / layers / mock / normalize
internal/
  apperr/                     错误四分类 + 缺失凭证 + 端点未确认
  credential/                 凭证解析（环境变量优先 → supplier.auth_config）
  transport/                  HTTP 客户端：退避重试 / Retry-After / 脱敏
  config/                     传输层配置加载与校验
  normalize/                  归一化核心（配置驱动）—— 唯一实现
  store/                      DB 访问（psql 子进程）+ 报文归档 + 幂等
  supplier/tripcom/           Trip.com 分销侧适配器（21 接口全配置驱动）
  supplier/globaltix/         GlobalTix Supply API 适配器（端点待商务确认）
  supplier/pending/           其余五源的占位适配器（接口细节未核对）
  registry/                   supplier.code → 适配器
  layertest/                  分层测试引擎 + 离线自检 + 协议自检
  mock/                       Trip.com 分销侧协议 mock（标准库 net/http）
configs/api_config.json       传输层配置：端点 / 21 接口 ICODE / 凭证口径 / 错误码映射
configs/mapping_rules.json    映射规则配置（演练器与接入层共用）
fixtures/                     真实报文结构的样例（canonical / trip_com / globaltix）
scripts/mapping_dryrun.py     无凭证集成演练（源报文 → 归一化 → 路由 → 报告）
scripts/poc_page.py           前端 POC 渲染器
Makefile                      build / test / mock / layers / dryrun / db / check
```

## 常用命令

本机 PostgreSQL 15（brew，`postgresql@15`），默认监听 5432，超级用户为当前 OS 用户。

```bash
export PATH=/opt/homebrew/opt/postgresql@15/bin:$PATH

# 重建（会清库）
psql -h 127.0.0.1 -d postgres -c "DROP DATABASE IF EXISTS ticket_center;" \
                       -c "CREATE DATABASE ticket_center;"

# 建表
psql -h 127.0.0.1 -d ticket_center -v ON_ERROR_STOP=1 -f db/schema.sql

# 灌种子
psql -h 127.0.0.1 -d ticket_center -v ON_ERROR_STOP=1 -f db/seed.sql

# 验收（必须全绿）
psql -h 127.0.0.1 -d ticket_center -v ON_ERROR_STOP=1 -f db/verify.sql
```

无凭证集成演练（拿不到源的 key/id/token 时，先用真实报文结构验证 mapping → 路由；
建独立演练库 ticket_center_dryrun，不动主库）。归一化由 Go 实现提供，
演练器通过 `tc-connect normalize` 消费它的输出：

```bash
make dryrun                                  # 演练 + 终端报告（38 条不变量自检）
python3 scripts/mapping_dryrun.py --poc scripts/poc/index.html    # 生成前端 POC
```

接入层（Go 1.23+；无凭证也能跑 L0 连通性 + 离线自检 + 协议级 mock 自检）：

```bash
make build                          # 构建 bin/tc-connect
make test                           # 单元测试（7 个包）
make mock                           # 协议级自检（本地 mock，14 项断言）
make layers                         # 分层连通性测试（连通→认证→目录→详情→价格→映射→路由）
make check                          # 提交前完整自检（vet + test + mock + 演练器）
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
psql -h 127.0.0.1 -d postgres -c "DROP DATABASE IF EXISTS ticket_center;" -c "CREATE DATABASE ticket_center;" && \
psql -h 127.0.0.1 -d ticket_center -v ON_ERROR_STOP=1 -f db/schema.sql && \
psql -h 127.0.0.1 -d ticket_center -v ON_ERROR_STOP=1 -f db/seed.sql && \
psql -h 127.0.0.1 -d ticket_center -v ON_ERROR_STOP=1 -f db/verify.sql
```

## 沙箱注意（本机实测）

- `bash` 里**不能写 heredoc**（`cat <<EOF` 会报 `cannot create temp file for here document: Operation not permitted`）。
  写多行内容用 `write` 工具，脚本用文件 + `python3 file.py`。
- 临时脚本放 `/tmp` 可以，但 `/tmp` 下的文件删除会被沙箱拒绝，别为清理它阻塞交付。

## 改完 schema 后的自检清单

- [ ] `db/schema.sql` 在空库零错误执行
- [ ] `db/seed.sql` 完整装载
- [ ] `db/verify.sql` 全部视图正常输出
- [ ] `v_invariant_checks` 38 条全 PASS（`db/verify.sql` 的 F 段会 `RAISE EXCEPTION`）
- [ ] `make test` 全绿（Go 单元测试）
- [ ] `make mock` 协议自检 14/14 全 PASS
- [ ] `python3 scripts/mapping_dryrun.py` 演练库 38/38 全 PASS
- [ ] `SPEC.md` 变更记录追加一行
- [ ] `docs/schema-design.md` 的表清单/索引统计数字同步更新
- [ ] `docs/ddd.md` 若涉及聚合边界或状态机，同步更新
- [ ] 改动 C 端展示或购买链路 → `docs/c-end-model.md` 同步更新
- [ ] 改动接入层 / 错误分类 / 幂等口径 → `docs/connector-contract.md` §9 与 `docs/integrations.md` 同步更新
