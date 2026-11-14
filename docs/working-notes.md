# 工作笔记（Working Notes）— 目录 / 常用命令 / 沙箱注意 / 自检清单

> 这份是**操作层面**的手册：目录结构、常用命令、本机沙箱注意、改完 schema 后的自检清单。
> 业务规则不在这里 —— 规则在 [`SPEC.md`](../SPEC.md)（索引）与 [`spec/`](../spec/) 下按主题域拆开的
> 合同文件里；工程纪律在 [`AGENTS.md`](../AGENTS.md) 的硬约束里。
>
> 改这份文件不影响业务行为；改业务行为要改 `spec/` 下的对应文件。

---

## 目录

```
SPEC.md                      业务合同的索引（范围/流程/不变量/状态机/验收标准，按主题域分文件）
spec/                        业务合同正文（每个文件一个主题；§4 不变量与 §5 写路径放同一文件）
docs/ddd.md                   领域模型：限界上下文、聚合、事件、状态机
docs/c-end-model.md           C 端：读模型、展示内容、购买漏斗
docs/schema-design.md         物理模型：选型论证、表清单、索引策略、演进路线
docs/connector-contract.md    供应源接入端口契约 + 七源差异矩阵 + §9 接入层实现现状
docs/integrations.md          接入层（Go）：包结构、设计纪律、CLI 用法
docs/working-notes.md         本文件：目录 / 常用命令 / 沙箱注意 / 自检清单
db/migrations/                全部 DDL（表 / 视图 / 索引 / 触发器 / 函数 的条数见 `make counts`）
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
db/migrations/021_*.sql        三种供给形态对照（v_variant_supply_forms）—— 异构融合读侧的最后一里
db/migrations/022_*.sql        供给形态不许因为源 SKU 下架而缩小（成分行留着只是没价 + 形态不许消失 + 缺口说清）
db/migrations/023_*.sql        可履约源数一个口径（fn_variant_supply_source_count）—— 配方与套装的日历不再写 0
db/migrations/024_*.sql        改派写路径（fn_reassign_order_item）—— 换源重定价，成分行与库存预占跟着源走
db/migrations/025_*.sql        源侧的售卖份数区间（fn_source_quantity_limits / fn_qty_servable）—— 落单与改派都守成团人数与单笔上限
db/migrations/026_*.sql        按团报价的单位价口径（fn_unit_amount）—— 总价 → 单位价只有一个实现，写路径与待改派清单同口径
db/migrations/027_*.sql        预占的默认 TTL 口径（fn_hold_inventory 归一 NULL → 900 秒）—— 默认值住在库里，不住在调用方
db/migrations/028_*.sql        凭证过期作业（fn_expire_vouchers）—— 券过期了由作业统一改，「交付过」口径补上 expired
db/seed.sql                   种子数据（各表行数见 `make counts` 的「种子行数」段；售价金额由定价函数生成）
db/verify.sql                 验收查询（业务视图查询 + 不变量断言，条数见 make counts）
cmd/tc-connect/               CLI：sources / layers / mock / normalize / compose / price / migrate / refresh / jobs / order / fulfill / refund / redeem / stock / hold / variant（order 另有 reassign / stale）
cmd/tc-api/                  C 端只读 API 服务（浏览 / 变体差异 / 套餐构成 / 日历；只读读模型，只服务在营的自营 C 端渠道）
internal/
  apperr/                     错误四分类 + 缺失凭证 + 端点未确认
  credential/                 凭证解析（环境变量优先 → supplier.auth_config）
  transport/                  HTTP 客户端：退避重试 / Retry-After / 脱敏
  config/                     传输层配置加载与校验
  normalize/                  归一化核心（配置驱动）—— 唯一实现
  pricing/                    定价入口（读 fn_price_variant 的结果，不算钱）
  store/                      DB 访问（psql 子进程）+ 报文归档 + 幂等 + 值进 SQL 的转义机制（NewSQL/Bind/Quote）
  supplier/tripcom/           Trip.com 分销侧适配器（21 接口全配置驱动）
  supplier/globaltix/         GlobalTix Supply API 适配器（端点待商务确认）
  supplier/pending/           其余五源的占位适配器（接口细节未核对）
  registry/                   supplier.code → 适配器
  layertest/                  分层测试引擎 + 离线自检 + 协议自检
  migrate/                    迁移引擎：账本 + 内容校验和 + 幂等 + 并发互斥
  readmodel/                  C 端读模型：刷新（口径在库里的 fn_refresh_read_models）与漂移检查
  transaction/                交易域读侧：状态机的合法流转与领域事件
  order/                      下单：拼参数 / 收结果 / 报错原样带出（不重算金额）
  reassign/                   改派：换源重定价（只调库里的 fn_reassign_order_item，不重排源、不重算钱）
  fulfillment/                履约：支付 / 预订 / 出券（只调库里的函数，不自己算状态）
  refund/                     退款：发起 / 放行 / 完成（只调库里的函数，不自己判资格）
  redemption/                 核销：扫票 / 查券（只调库里的函数，不自己判能不能进场、不自己算扣多少额度）
  inventory/                  库存：查可售 / 预占 / 放掉（只调库里的函数，不自己算可售数、不自己判够不够）
  variant/                    异构差异读侧：对照表 / 源覆盖缺口 / C 端读视图 / 套装构成 / 三种供给形态对照（只读视图，不重算有效天数、覆盖判定、成本与份数）
  capi/                       C 端只读 API：路由 / 参数校验 / 读模型查询（不 join 主数据、不重算事实）
  coverage/                   覆盖语义读侧：源变体覆盖住哪些可售单元（判定走库里的 fn_variant_covered）
  compose/                    组合映射写侧：组合表达式 → 配方（核组件、核数量；覆盖判定走库里的 fn_variant_covered）
  mock/                       Trip.com 分销侧协议 mock（标准库 net/http）
  idgen/                      业务 ID 生成（订单号 / 幂等键 / 凭证号等）
  testdb/                     测试用临时库（建库 / 迁移 / 种子 / 清理）
  sqllint/                    SQL 门禁：查「把没转义的值拼进 SQL」的地方（cmd/tc-lint 是入口）
configs/api_config.json       传输层配置：端点 / 21 接口 ICODE / 凭证口径 / 错误码映射
configs/mapping_rules.json    映射规则配置（演练器与接入层共用）
fixtures/                     真实报文结构的样例（canonical / trip_com / globaltix）
scripts/mapping_dryrun.py     无凭证集成演练（源报文 → 归一化 → 路由 → 报告）
scripts/order_demo.py         下单链路端到端演示（自己找有售价的日期，不写死日期）
scripts/poc_page.py           前端 POC 渲染器
scripts/counts.sh + counts.sql 打印各处文档引用的那些数（不变量条数 / 测试条数 / mock 断言数）
Makefile                      build / test / mock / layers / dryrun / db / check / lint / order-demo / jobs / counts
```

---

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

C 端只读 API（只读读模型，不 join 主数据；写侧还没开 —— 没有调用方身份）：

```bash
make api                                     # 起服务（默认 :8080，库 ticket_center）
./bin/tc-api --db ticket_center --addr :8080 # 或直接起

curl -s "http://127.0.0.1:8080/api/v1/products?channel_id=1&locale=zh-CN"
curl -s "http://127.0.0.1:8080/api/v1/products/6/variants?channel_id=1"
curl -s "http://127.0.0.1:8080/api/v1/variants/19/composition?channel_id=1"
curl -s "http://127.0.0.1:8080/api/v1/variants/19/calendar?channel_id=1"
```

渠道（`channel_id`）是必答的：C 端读模型按渠道建，不按渠道过滤会把份数数成两遍。

无凭证集成演练（拿不到源的 key/id/token 时，先用真实报文结构验证 mapping → 路由；
建独立演练库 ticket_center_dryrun，不动主库）。归一化由 Go 实现提供，
演练器通过 `tc-connect normalize` 消费它的输出：

```bash
make dryrun                                  # 演练 + 终端报告（不变量自检）
python3 scripts/mapping_dryrun.py --poc scripts/poc/index.html    # 生成前端 POC
```

接入层（Go 1.23+；无凭证也能跑 L0 连通性 + 离线自检 + 协议级 mock 自检）：

```bash
make build                          # 构建 bin/tc-connect
make test                           # 单元测试
make mock                           # 协议级自检（本地 mock）
make counts                         # 打印各处文档引用的那些数（不变量条数 / 测试条数 / mock 断言数）
make layers                         # 分层连通性测试（连通→认证→目录→详情→价格→映射→路由）
make lint                           # SQL 门禁：查「把没转义的值拼进 SQL」的地方
make check                          # 提交前完整自检（vet + test + mock + lint + 演练器）
make migrate                        # 应用待应用的迁移（存量库升级用这个，别重建）
make dbstatus                       # 看迁移状态（哪些已应用、哪些待应用）
make refresh                        # 刷新 C 端读模型并查漂移
make jobs                           # 跑一遍批处理作业（凭证过期 / 预占过期 / 读模型刷新）—— 一次性命令，跑完退出
./bin/tc-connect jobs --db ticket_center --sync   # 顺带跑目录同步作业（抓 → 归一化 → 落库），要凭证
make order-demo                     # 下单链路端到端演示（下单 → 幂等重放 → 查单）
./bin/tc-connect fulfill show --db ticket_center --order 7   # 查履约状态（支付/预订/出券）
./bin/tc-connect refund show --db ticket_center --refund 1    # 查退款单状态
./bin/tc-connect redeem scan  --db ticket_center --code TKT-001  # 扫一次票
./bin/tc-connect redeem show  --db ticket_center --voucher 3    # 查这张券和它的核销流水
./bin/tc-connect redeem overdue --db ticket_center              # 看有几张券到期却还停在 issued（过期作业漏跑）
./bin/tc-connect redeem expire  --db ticket_center              # 跑凭证过期作业（issued → expired）
./bin/tc-connect stock show  --db ticket_center --supplier-session 1   # 查这个源场次还剩多少
./bin/tc-connect variant feed    --db ticket_center --channel 1   # 看 C 端读模型里的变体行（顺带看哪天有售价）
./bin/tc-connect hold create --db ticket_center --no HOLD001 --channel 1 --variant 11 --qty 2 --date <日期>
./bin/tc-connect hold expire --db ticket_center            # 跑 TTL 过期作业
./bin/tc-connect variant compare --db ticket_center --product 6   # 看这个商品的可售单元差在哪
./bin/tc-connect variant coverage --db ticket_center --variant 14 # 看哪些源能供、缺什么
./bin/tc-connect variant bundle  --db ticket_center --variant 21   # 看套装（源侧把整套当一个 SKU 卖）由谁组成
./bin/tc-connect variant supply  --db ticket_center --variant 18   # 看单张 / 配方 / 套装三种供给形态的对照
./bin/tc-connect compose plan    --db ticket_center --source globaltix --fixture fixtures/globaltix_catalog.json   # 组合配方能不能解出来
```

批处理作业交给**外部调度器**按 cron 调（间隔不写在代码里，硬约束 39）：

```
*/5 * * * * cd /srv/ticket-center && ./bin/tc-connect jobs --db ticket_center
```

目录同步是同一条命令的一个分支（`--sync`），走自己的 cron 行 ——
它要连外部源、要凭证，而凭证过期 / 预占过期 / 读模型刷新是纯库内维护：

```
17 * * * * cd /srv/ticket-center && ./bin/tc-connect jobs --db ticket_center --sync
```

`<日期>` 要**现查现用**：种子里所有日期是 `current_date + N`（`db/seed.sql`），
写死的绝对日期会随灌库那天烂掉 —— 文档里的示例日期不等于运行时的日期。
`hold create` 不带 `--ttl` 用默认 900 秒（不变量 119）。

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

---

## 沙箱注意（本机实测）

- `bash` 里**不能写 heredoc**（`cat <<EOF` 会报 `cannot create temp file for here document: Operation not permitted`）。
  写多行内容用 `write` 工具，脚本用文件 + `python3 file.py`。
- 临时脚本放 `/tmp` 可以，但 `/tmp` 下的文件删除会被沙箱拒绝，别为清理它阻塞交付。

---

## 改完 schema 后的自检清单

> 「同步改 `SPEC.md` §N」现在指**改 `spec/` 下对应主题的那个文件**（§ 号保持不变，
> 用来定位；文件路径用链接给出）。合同的索引在 [`SPEC.md`](../SPEC.md)。

- [ ] `db/migrations/` 里的迁移在空库零错误执行（`tc-connect migrate`）
- [ ] 新增/改动的迁移文件是**新增**的，不是改了已发布的那个
- [ ] `tc-connect migrate --status` 里没有「内容漂移」
- [ ] `db/seed.sql` 完整装载
- [ ] `db/verify.sql` 全部视图正常输出
- [ ] `v_invariant_checks` 全 PASS（`db/verify.sql` 的 F 段会 `RAISE EXCEPTION`；条数见 `make counts`）
- [ ] 改动状态机 → `state_transition` 表 + [`spec/00-overview.md`](../spec/00-overview.md) §5 同步更新，且非法流转仍被触发器挡住
- [ ] 改动下单口径 → `fn_place_order` + [`spec/10-ordering.md`](../spec/10-ordering.md) §5.5 同步更新，且幂等与实名校验仍生效
- [ ] 改动履约口径 → `005/006` 迁移 + [`spec/11-fulfillment.md`](../spec/11-fulfillment.md) §5.6 同步更新，且幂等、重复收款、票码张数、源场次绑定仍生效
- [ ] 改动退款口径 → `007` 迁移 + [`spec/12-refund.md`](../spec/12-refund.md) §5.7 同步更新，且幂等、金额等于实付、事实同步改、失败可退回仍生效
- [ ] 改动核销口径 → `008` 迁移 + [`spec/13-redemption.md`](../spec/13-redemption.md) §5.8 同步更新，且重复扫码、额度用尽、订单在退款不认核销仍生效
- [ ] 改动可售数口径 → `009` 迁移 + [`spec/14-inventory.md`](../spec/14-inventory.md) §5.9 同步更新，且「不知道不拦、明知不够报错、源侧快照与承诺对账不双扣、订单关掉放掉预占」仍生效
- [ ] 改动有效期口径 → `010` 迁移 + [`spec/15-validity.md`](../spec/15-validity.md) §5.10 同步更新，且「有效期读轴选项、券不短于承诺、源覆盖得住」仍生效
- [ ] 改动读模型口径 → `011` 迁移 + [`spec/16-readmodel.md`](../spec/16-readmodel.md) §5.11 同步更新，且「读模型不与主数据分叉、日历有效期终点不被算错」仍生效
- [ ] 改动组合售卖口径 → `013` 迁移 + [`spec/17-composition.md`](../spec/17-composition.md) §5.13 同步更新，且「成本 = Σ 成分单价 × 数量、成分源取自配方不重选、成分各订各券、超卖按场次总需求、整单退款改全部成分事实」仍生效
- [ ] 改动预订单位口径 → `014` 迁移 + [`spec/11-fulfillment.md`](../spec/11-fulfillment.md) §5.6 与 [`spec/17-composition.md`](../spec/17-composition.md) §5.13 同步更新，且「一个源 SKU 一条预订、成分由 fn_booking_components 推出来、票码数仍等于应发张数」仍生效
- [ ] 改动组合在 C 端的口径 → `015` 迁移 + [`spec/17-composition.md`](../spec/17-composition.md) §5.14 同步更新，且「有效期 = 成分窗口的并集、人群只带编码、构成不许与主数据分叉、格子必须带价格」仍生效
- [ ] 改动放行或出券的口径 → `016` 迁移 + [`spec/17-composition.md`](../spec/17-composition.md) §4.18 与 [`spec/11-fulfillment.md`](../spec/11-fulfillment.md) §5.6 / [`spec/12-refund.md`](../spec/12-refund.md) §5.7 同步更新，且「退款必须先放行、终态退款单放行痕迹齐全、票码不许是券号派生的」仍生效
- [ ] 改动套装口径 → `017` 迁移 + [`spec/18-bundle.md`](../spec/18-bundle.md) §4.19 / §5.15 同步更新，且「形态唯一、成分与声明对得上、有效期盖住成分窗口、成本分摊守恒、入场份数守恒」仍生效
- [ ] 改动预订请求报文的口径 → `018` 迁移 + [`spec/11-fulfillment.md`](../spec/11-fulfillment.md) §5.6 同步更新，且「我们写的事实不许被接入层发的报文覆盖」仍生效
- [ ] 改动套装缺口天数的口径 → `019` 迁移 + [`spec/18-bundle.md`](../spec/18-bundle.md) §5.15 同步更新，且「缺口天数只数真卖不掉的那几天」仍生效
- [ ] 改动套装库存池的口径 → `020` 迁移 + [`spec/18-bundle.md`](../spec/18-bundle.md) §4.19 / §5.15 同步更新，且「池子不跨源票种相加、需求按池子加总、不知道不拦但留痕」仍生效
- [ ] 改动供给形态对照的口径 → `021` 迁移 + [`spec/18-bundle.md`](../spec/18-bundle.md) §4.20 / §5.16 同步更新，且「形态不消失、成本与定价函数一致、份数与 C 端构成读模型一致、能供时不报缺口」仍生效
- [ ] 改动成分/套装解析的口径 → `022` 迁移 + [`spec/18-bundle.md`](../spec/18-bundle.md) §4.21 / §5.17 同步更新，且「源下架时成分行仍在只是没价、形态仍出现在对照视图里、缺口说清、源下架时定价函数不给价」仍生效
- [ ] 改动可履约源数的口径 → `023` 迁移 + [`spec/18-bundle.md`](../spec/18-bundle.md) §4.22 / §5.19 同步更新，且「源数不是成分数、不是价格行数、单张按路由算、日历 source_count 与对照视图 supplier_count 不混」仍生效
- [ ] 改动改派的口径 → `024` 迁移 + [`spec/19-reassign.md`](../spec/19-reassign.md) §4.23 / §5.20 同步更新，且「改派 = 重新选源 + 重新定价、只发生在未收款未预订的单张形态上、成分行与库存预占跟着源走、留痕写进明细快照」仍生效
- [ ] 改动份数区间的口径 → `025` 迁移 + [`spec/19-reassign.md`](../spec/19-reassign.md) §4.24 / §5.21 同步更新，且「区间唯一读法、份数的单位 = 源侧售卖单位、同源 SKU 按总份数判、接不住当场报错、不按份数换源、改派也守这条、区间进明细快照」仍生效
- [ ] 改动按团单位价的口径 → `026` 迁移 + [`spec/19-reassign.md`](../spec/19-reassign.md) §4.25 / §5.22 同步更新，且「总价 → 单位价只有一个实现、按团的人均只是分摊不是价、明细里记的是分摊后的数、清单与写路径同口径」仍生效
- [ ] 改动预占默认 TTL 的口径 → `027` 迁移 + [`spec/14-inventory.md`](../spec/14-inventory.md) §4.26 / §5.23 同步更新，且「默认值住在库里、不指定与指定 900 落同一张预占、预占必须有确定的到期时间」仍生效
- [ ] 改动凭证过期的口径 → `028` 迁移 + [`spec/20-jobs.md`](../spec/20-jobs.md) §4.27 / §5.24 同步更新，且「只动 issued、判据是券自己的 valid_to、幂等、限批默认 500、事件由触发器自动落」仍生效
- [ ] 改动作业调度的口径 → [`spec/20-jobs.md`](../spec/20-jobs.md) §5.25 同步更新，且「一次跑完就退出、间隔不写在代码里、失败非零退出、作业幂等、漂移非零退出但到期未改只报告」仍生效
- [ ] 改动「交付过」的口径 → `fn_delivered_voucher_statuses()` 是唯一读法，且「expired 算交付过、void/refunded 不算、履约推导 / 改派守卫 / 出券判定三处口径一致」仍生效
- [ ] `make test` 全绿（Go 单元测试）
- [ ] `make mock` 协议自检全 PASS
- [ ] `make lint` SQL 门禁通过（值进 SQL 都要先转义）
- [ ] `python3 scripts/mapping_dryrun.py` 演练库不变量全 PASS
- [ ] `make counts` 的数与文档里写的数一致（文档只引用，不自己抄）
- [ ] [`spec/00-overview.md`](../spec/00-overview.md) §8 变更记录追加一行
- [ ] `docs/schema-design.md` 的表清单与主题视图条数同步更新（条数跑 `make counts`，不要手抄）
- [ ] `docs/ddd.md` 若涉及聚合边界或状态机，同步更新
- [ ] 改动 C 端展示或购买链路 → `docs/c-end-model.md` 同步更新
- [ ] 改动公开读接口的渠道口径 → [`spec/21-c-end-api.md`](../spec/21-c-end-api.md) §5.18 第三条同步更新，且「只服务在营的自营 C 端、渠道不存在与不对外服务给同一个答复、四个端点共用一个闸门」仍生效
- [ ] 改动接入层 / 错误分类 / 幂等口径 → `docs/connector-contract.md` §9 与 `docs/integrations.md` 同步更新
