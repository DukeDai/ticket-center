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
cmd/tc-connect/              CLI：sources / layers / mock / normalize
internal/
  apperr/                    错误四分类 + 缺失凭证 + 端点未确认
  credential/                凭证解析（环境变量优先 → supplier.auth_config）
  transport/                 HTTP 客户端：退避重试 / Retry-After / 脱敏
  config/                    传输层配置（端点 / ICODE / 错误码映射）
  normalize/                 归一化核心（配置驱动，无按源分支）
  store/                     DB 访问（psql 子进程）+ 报文归档 + 幂等
  supplier/                  端口定义与公共基类
    tripcom/                 Trip.com 分销侧适配器
    globaltix/               GlobalTix Supply API 适配器（端点待商务确认）
    pending/                 接口细节未核实的源的占位适配器
  registry/                  supplier.code → 适配器
  layertest/                 分层测试引擎 + 离线自检 + 协议自检
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
