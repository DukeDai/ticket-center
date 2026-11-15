# B 端内部运营台（§5.28）

> 这一节是 B 端运营台的合同正文。
> 索引见 [`../SPEC.md`](../SPEC.md)，总纲见 [`00-overview.md`](00-overview.md)。

## 5.28 B 端内部运营台的口径（2026-11-15 落地）

C 端的读侧开成了 HTTP 接口（[`21-c-end-api.md`](21-c-end-api.md) §5.18），
但**运营侧还什么都没有**：目录、订单、履约缺口、退款、核销、源健康度 ——
这些事只有查库的人看得见。§5.28 把运营侧开成一个**内部运营台**：
`internal/bapi` + `cmd/tc-bapi`，网页与 RESTful API 一套身份。

### 第一件事：这是运营台，不是开放平台

**票到我们这里就自营，没有分销商自助这一层。** 所以 B 端没有「分销商自己登录看自己的货」这件事，
运营台只服务**我们自己的运营人员**。

这条定位决定了三件具体的事：

- **不建分销商账号体系**。有的是内部操作员（`b2b_operator`），一个人一个凭证。
- **不建「我的订单」这种自助视图**。运营台看的是**全渠道** ——
  C 端、分销、企业客户各自的目录与订单，都要在同一屏里比。
  运营要回答的问题是「哪个渠道在堆积、哪个源在掉链子、哪些单付了没出票」，
  这些问题按渠道切开就答不了。
- **不开放给外部**。它连着生产库，身份是硬边界（下面第三条）。

### 边界画在身份上，不是渠道上

C 端公开接口没有调用方身份，边界只能画在渠道（§5.18 第三条）。
运营台**有**身份，所以它可以跨渠道 —— 这正是它存在的意义。

但跨渠道不等于匿名可读：**每个端点都要过身份闸门**。

- **操作员**（`b2b_operator`）：`code`（唯一）、`name`、`role`、`status`、
  `key_hash`（凭证的 sha256）、`session_salt`（会话签发用）。
- **凭证明文不入库**。库里只存 sha256 哈希，明文只在创建时显示一次。
  丢了就重新建一个，不找回（硬约束 12 的精神：不入库、不进仓库、不进日志）。
- **凭证是高熵随机串**，不是人选的密码。24 字节随机 = 192 位熵，
  读成人眼无法准确转录的长度是故意的 —— 抄错就重新生成，不要去猜。
  高熵串用 sha256 没有字典攻击面（本项目零第三方依赖，用不了 bcrypt/scrypt）。
- **会话是 HMAC-SHA256 签的 cookie**：内容是「操作员 id | 签发时刻 | 过期时刻」，
  密钥是「`key_hash` + `session_salt`」。会话 cookie 带 `HttpOnly` 与 `SameSite=Lax`。
- **凭证比对用常量时间**（`crypto/subtle`）。逐字节早退的比较会泄露前缀长度。
- **凭证不对与操作员不存在给同一个答复** —— 不给调用方一个能枚举操作员 code 的探针。
- **停用要立刻生效**：改 `status` 只挡新登录，已签发的会话要靠**换 `session_salt`** 作废
  （换盐 → 旧签名对不上 → 会话失效）。所以停用是两条都做。
- **会话 8 小时过期**。浏览器关掉不登出是常态，一直有效的 cookie 等于把凭证长期摊在磁盘上。

### 三档角色，写操作分级

| 角色 | 能做什么 |
|---|---|
| `viewer` | 只读 |
| `operator` | 下单、支付入账、出券、发起退款 |
| `admin` | 上面全部，外加放行退款与改派 |

**放行退款与改派只给 `admin`**，因为这两个动作要留操作人痕迹 ——
退款放行走 `fn_approve_refund(approved_by)`，改派要往明细快照的 `reassignments` 里留痕。
痕迹是追责的依据，让 `operator` 也能放行，追责就断在「哪个 operator 干的」这一层。

### 读侧只读运营读模型，不 join 主数据，不重算事实

运营台的读侧打在 `v_ops_*` 视图上（`db/migrations/035_b2b_operator_console.sql`）。
这些视图是已有的运营口径视图的**包装**：

| 运营台视图 | 口径来源 |
|---|---|
| `v_ops_channel_overview` | 新建（渠道 + 上架规模 + 订单规模 + 履约缺口条数） |
| `v_ops_product_catalog` | 新建（商品 × 渠道，带上架状态与价格策略） |
| `v_ops_order_list` | 新建（订单 + 明细/预订/券的条数） |
| `v_ops_fulfillment_gap` | `v_order_fulfillment_gap` |
| `v_ops_supply_forms` | `v_variant_supply_forms` |
| `v_ops_refund_ledger` | `sales_refund` |
| `v_ops_redemption_log` | `voucher_redemption` |
| `v_ops_inventory_hold` | `inventory_hold` |
| `v_ops_supplier_health` | `v_supplier_sync_health` |
| `v_ops_settlement_gap` | `v_settlement_gap` |
| `v_ops_reassign_candidates` | `v_reassign_candidates` |

**包装而不是重算**：履约漏斗、供给形态、待改派清单的口径各只有一份，
运营台不重算一遍（重算就会出现两个「漏斗」、两个「该改派的清单」）。
**价格不在视图里算** —— 定价函数的唯一实现是 `fn_price_variant`，
视图里自己按成本加价就会出现「运营看到的价」与「真下单的价」两套。
**份数不许自己数** —— 入场份数来自 `fn_variant_composition`（与 C 端构成读模型同一个来源）。

**订单详情是例外**：列表走读模型，详情才展开明细、预订、券、支付。
那是运营按需钻取主数据，不在列表请求链路里。

### 写侧复用已有的写路径，且必须做渠道归属校验

写侧一律走库里的唯一实现，Go 侧只拼参数、只读结果：

| 端点 | 走的实现 |
|---|---|
| `POST /api/v1/orders` | `fn_place_order` |
| `POST /api/v1/orders/{id}/payments` | `fn_record_payment` |
| `POST /api/v1/bookings/{id}/vouchers` | `fn_issue_voucher` |
| `POST /api/v1/refunds` | `fn_request_refund`（金额向 `fn_refund_policy` 问） |
| `POST /api/v1/refunds/{id}/approval` | `fn_approve_refund(approved_by)` |
| `POST /api/v1/orders/{id}/items/{item}/reassign` | `fn_reassign_order_item` |

**`internal/order` / `internal/fulfillment` / `internal/refund` / `internal/reassign`
只按 id 定位记录，不带权限判断** —— 它们是库函数的薄封装，故意不做权限判断
（那是调用方的责任）。**运营台就是那个调用方。** 所以每个写端点都要先确认
「这个资源属于哪个渠道」，确认不了就拒绝。

少了这一步，运营台一个 id 就能改到别的渠道的单。

**退款金额向库问**：`fn_refund_policy(order_id)` 返回承诺的应付额，
Go 侧不自己判资格、不自己算金额 —— 自己算就是第二份实现，两份实现迟早分叉。
**发起与放行各判一次** —— 发起到放行之间时间在走，截止时长会被吃掉（[`12-refund.md`](12-refund.md) §5.7）。

**幂等键必填**：下单与发起退款都要（重放一次下单 = 落两单；重放一次退款 = 多退一次钱）。
**资源 id 来自路径，不来自请求体** —— 路径是资源的身份；
两处都能写就会「路径说 A、体里说 B」而取了其中一个。

### 写侧的口径摘要

不重算金额、不重排源、不自己算状态、不自己判退款资格、不自己判能不能进场。
这一条与写路径上的其他入口完全一致（硬约束 18-21）。

### 网页与 API 是同一套身份

**两个界面必须共用一个会话 cookie** —— 两套身份就意味着「网页上看不到的东西，
API 能改」。运营台是内部工具，但内部不等于「可以被人塞一个 1GB 的请求体」，
所以请求体有限额。

**页面与 API 的未登录处理不一样**：API 回 401 + JSON；
页面把人送去登录页（303）。浏览器收到 401 的 JSON 会显示一坨裸文本，
而不是让人去登录 —— 那台子就等于废了，而它正是处理线上问题时要用的。

**静态资源与模板用 `go:embed` 编译进二进制**：部署时不用带文件，
也不会出现「模板改了没生效」这种版本错位。静态资源不许穿目录
（`/static/../templates/console.html` 能把模板读出去）。

### 口径纪律的落点

- **金额一律 `NUMERIC`，以字符串出**（硬约束 5）。Go 标准库没有十进制类型。
- **值进 SQL 要先转义**（硬约束 40）：`internal/bapi` 的查询一律走
  `store.NewSQL(...).Bind(...)`；`internal/bapi/where.go` 是一层「拼 WHERE 条件」的包装，
  它知道「第一个条件还没出」（`store.SQL.And` 永远前置 `AND`，第一个条件会拼坏语法）。
- **LIKE 的通配符要转义**：搜「50%」不该匹配到「50」开头的任何字符串。
- **展示层不判业务**：模板里的辅助函数只管「状态对应什么颜色、时间怎么截短」，
  业务口径在库与读模型里。
- **零第三方依赖**（硬约束 11）：HTTP 用 `net/http`，模板用 `html/template`，
  签名用 `crypto/hmac`。

### 运营台不做的事

- **不做分销商自助**。本期范围之外。
- **不做行级退款**。整单退款的口径见 [`12-refund.md`](12-refund.md)。
- **不重算任何业务结论**。成本、份数、可履约、缺口，全是库里的口径。
- **不维护会话表**。会话是无状态的；撤销靠换盐。
- **不做审批流**。放行是一次动作，不是流程。

### 端点清单

网页：

| 端点 | 干什么 |
|---|---|
| `GET /login` | 登录页 |
| `POST /login` | 表单登录（签发会话 cookie） |
| `POST /logout` | 登出 |
| `GET /console?tab=` | 运营台（九个页签） |
| `GET /static/…` | 静态资源 |

九个页签：总览、订单、履约缺口、供给形态、退款、核销、源与结算、库存预占、待改派。

API（读）：

| 端点 | 读什么 |
|---|---|
| `GET /api/v1/channels` | 渠道总览 |
| `GET /api/v1/products` | 商品目录 |
| `GET /api/v1/orders` | 订单列表 |
| `GET /api/v1/orders/{id}` | 订单详情（明细 / 预订 / 券 / 支付） |
| `GET /api/v1/fulfillment/gaps` | 履约漏斗 |
| `GET /api/v1/supply-forms` | 供给形态对照 |
| `GET /api/v1/refunds` | 退款台账 |
| `GET /api/v1/redemptions` | 核销记录 |
| `GET /api/v1/inventory/holds` | 库存预占 |
| `GET /api/v1/suppliers/health` | 源健康度 |
| `GET /api/v1/settlement/gaps` | 结算缺口 |
| `GET /api/v1/reassign/candidates` | 待改派清单 |
| `GET /api/v1/operators` | 操作员列表 |

API（写）：见上面「写侧复用已有的写路径」那张表。

### 操作员的建号在 CLI 里，不在网页上

`tc-connect operator list|create|disable|enable|rotate`。

**凭证管理放在 CLI 而不是网页**：网页上改凭证 = 谁能进网页谁能改凭证，
那就等于没有分级。而「建一个 admin」这件事本身是极少数人该做的事。

`disable` / `enable` **换会话盐**，让已签发的会话当场作废。
`rotate` 换凭证与盐 —— 凭证只显示一次。
