# ticket-center — 供应源接入层（Go）
#
# 常用：
#   make build     构建 tc-connect
#   make test      跑单元测试
#   make check     vet + test + 协议自检 + 演练器 + SQL 门禁（提交前跑这个）
#   make lint      SQL 门禁：查「把没转义的值拼进 SQL」的地方
#   make mock      协议级自检（本地 mock，14 项断言）
#   make layers    分层连通性测试（真实端点）
#   make dryrun    无凭证集成演练（建演练库 + 不变量自检，条数见 make counts）
#   make db        重建主库并验收
#   make migrate   应用待应用的迁移（存量库）
#   make dbstatus  看迁移状态
#   make refresh   刷新 C 端读模型并查漂移
#   make jobs      跑一遍批处理作业（交给外部调度器按 cron 调）
#   make order-demo 下单链路端到端演示（找有售价的日期 → 下单 → 幂等重放 → 查单）
#   make api       起 C 端只读 API（只读读模型）
#   make poc       生成前端 POC 页面
#   make counts    打印各处文档引用的那些数（不变量条数 / 测试条数 / mock 断言数）

SHELL := /bin/bash
GO ?= go
PSQL ?= psql
PGHOST ?= 127.0.0.1
PGDATABASE ?= ticket_center
BIN := bin/tc-connect
API := bin/tc-api
API_ADDR ?= :8080

export PATH := /usr/local/go/bin:$(PATH)

.PHONY: all build test vet fmt check mock layers dryrun poc db verify sources clean migrate dbstatus dbcheck refresh jobs order-demo api counts lint

all: build

build:
	@mkdir -p bin
	$(GO) build -o $(BIN) ./cmd/tc-connect
	$(GO) build -o $(API) ./cmd/tc-api
	@echo "已构建 $(BIN) $(API)"

test:
	$(GO) test ./... -timeout 120s

# 门禁下的测试：数据库不可用算失败，不算跳过。
# 「没有数据库所以全绿」是一道假绿，check 与 CI 必须走这个。
test-strict:
	TC_REQUIRE_DB=1 $(GO) test ./... -timeout 180s

vet:
	$(GO) vet ./...

fmt:
	$(GO) fmt ./...

# 提交前的完整自检
# dbcheck 必须进 check：不变量是门禁，不是「有空跑一下」的报告（条数见 make counts）
# lint 也必须进 check：「值进 SQL 要先转义」是约定，靠自觉迟早漏一次 ——
# 漏掉的那一次就是注入。这道门禁把约定变成机制。
# writelint 同理：「机器不许洗掉人的判断」「源标识写之前要校验」也是约定，
# 靠自觉迟早漏一次 —— 漏掉的那一次，人工写的判定依据被洗掉、
# 空标识落进库，都是靠事后门禁才发现的（那时已经不知道是谁干的）。
check: vet test-strict build mock lint writelint dbcheck dryrun

# SQL 门禁：查「把没转义的值拼进 SQL」的地方。
#
# psql 是子进程，没有 $1 占位符，SQL 全是拼出来的 ——
# 唯一的防线是「记得调 store.Quote」，而「记得」是约定不是机制。
# 这个门禁扫 AST：值拼进 SQL 的引号位置（'%s'）且没经过
# store.Quote / store.QuoteIdent，就报出来。
lint:
	$(GO) run ./cmd/tc-lint .

# 写路径门禁：查「机器写的路径动了它不该动的字段」。
#
# 两条规则：
#   规则 1 判断表上的 upsert 不许无条件覆盖人的判断列
#          （人工写的判定依据不许被机器洗掉）
#   规则 2 写了源侧表的包必须校验标识不为空
#          （空标识落进库只能靠事后门禁发现，那时已经不知道是谁干的）
#
# 表与列的清单在 internal/writelint 里，各只有一份。
writelint:
	$(GO) run ./cmd/tc-writelint .

mock: build
	./$(BIN) mock

layers: build
	./$(BIN) layers

sources: build
	./$(BIN) sources

dryrun: build
	python3 scripts/mapping_dryrun.py

poc:
	python3 scripts/mapping_dryrun.py --json scripts/poc/data.json --poc scripts/poc/index.html

# 门禁：在一次性库里跑 迁移 → seed → verify.sql，任一步失败即非零退出
# 不碰主库 ticket_center
CIBASE ?= ticket_center_ci
dbcheck: build
	@$(PSQL) -h $(PGHOST) -d postgres -c "DROP DATABASE IF EXISTS $(CIBASE);" \
	                     -c "CREATE DATABASE $(CIBASE);"
	@./$(BIN) migrate --db $(CIBASE)
	@$(PSQL) -h $(PGHOST) -d $(CIBASE) -v ON_ERROR_STOP=1 -f db/seed.sql > /dev/null
	@$(PSQL) -h $(PGHOST) -d $(CIBASE) -v ON_ERROR_STOP=1 \
	         -v TC_VERIFY_SQL="$(CURDIR)/db/verify.sql" -f db/verify.sql > /dev/null
	@echo "门禁通过：$(CIBASE) 的不变量全绿（条数见 make counts）"

# 应用待应用的迁移（存量库用这个，不要重建）
migrate: build
	./$(BIN) migrate --db $(PGDATABASE)

# 看迁移状态（哪些已应用、哪些待应用）
dbstatus: build
	./$(BIN) migrate --db $(PGDATABASE) --status

# 刷新 C 端读模型并查漂移（口径在库里的 fn_refresh_read_models）
refresh: build
	./$(BIN) refresh --db $(PGDATABASE)

# 跑一遍批处理作业（凭证过期 / 预占过期 / 读模型刷新）。
# 一次性命令，跑完退出 —— 多久跑一次交给外部调度器（cron / CronJob），
# 间隔不写在代码里。失败非零退出，调度器按自己的策略重试；作业本身幂等。
jobs: build
	./$(BIN) jobs --db $(PGDATABASE)

# 下单链路端到端演示：脚本自己找有售价的日期，不写死日期
order-demo: build
	python3 scripts/order_demo.py --db $(PGDATABASE)

# 起 C 端只读 API（只读读模型，不 join 主数据）
api: build
	./$(API) --db $(PGDATABASE) --addr $(API_ADDR)

# 重建主库（会清库）并跑验收
db: build
	$(PSQL) -h $(PGHOST) -d postgres -c "DROP DATABASE IF EXISTS $(PGDATABASE);" \
	                   -c "CREATE DATABASE $(PGDATABASE);"
	./$(BIN) migrate --db $(PGDATABASE)
	$(PSQL) -h $(PGHOST) -d $(PGDATABASE) -v ON_ERROR_STOP=1 -f db/seed.sql
	$(PSQL) -h $(PGHOST) -d $(PGDATABASE) -v ON_ERROR_STOP=1 -f db/verify.sql

verify:
	$(PSQL) -h $(PGHOST) -d $(PGDATABASE) -v ON_ERROR_STOP=1 -f db/verify.sql

# 打印各处文档引用的那些数（不变量条数 / 测试条数 / mock 断言数）
# 文档里的数一律以这个脚本的输出为准，不要自己抄一遍。
counts: build
	./scripts/counts.sh $(PGDATABASE)

clean:
	rm -rf bin
