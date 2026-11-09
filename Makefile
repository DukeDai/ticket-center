# ticket-center — 供应源接入层（Go）
#
# 常用：
#   make build     构建 tc-connect
#   make test      跑单元测试
#   make check     vet + test + 协议自检 + 演练器（提交前跑这个）
#   make mock      协议级自检（本地 mock，14 项断言）
#   make layers    分层连通性测试（真实端点）
#   make dryrun    无凭证集成演练（建演练库 + 99 条不变量自检）
#   make db        重建主库并验收
#   make migrate   应用待应用的迁移（存量库）
#   make dbstatus  看迁移状态
#   make refresh   刷新 C 端读模型并查漂移
#   make order-demo 下单链路端到端演示（找有售价的日期 → 下单 → 幂等重放 → 查单）
#   make poc       生成前端 POC 页面

SHELL := /bin/bash
GO ?= go
PSQL ?= psql
PGHOST ?= 127.0.0.1
PGDATABASE ?= ticket_center
BIN := bin/tc-connect

export PATH := /usr/local/go/bin:$(PATH)

.PHONY: all build test vet fmt check mock layers dryrun poc db verify sources clean migrate dbstatus dbcheck refresh order-demo

all: build

build:
	@mkdir -p bin
	$(GO) build -o $(BIN) ./cmd/tc-connect
	@echo "已构建 $(BIN)"

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
# dbcheck 必须进 check：99 条不变量是门禁，不是「有空跑一下」的报告
check: vet test-strict build mock dbcheck dryrun

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
	@$(PSQL) -h $(PGHOST) -d $(CIBASE) -v ON_ERROR_STOP=1 -f db/verify.sql > /dev/null
	@echo "门禁通过：$(CIBASE) 的 99 条不变量全绿"

# 应用待应用的迁移（存量库用这个，不要重建）
migrate: build
	./$(BIN) migrate --db $(PGDATABASE)

# 看迁移状态（哪些已应用、哪些待应用）
dbstatus: build
	./$(BIN) migrate --db $(PGDATABASE) --status

# 刷新 C 端读模型并查漂移（口径在库里的 fn_refresh_read_models）
refresh: build
	./$(BIN) refresh --db $(PGDATABASE)

# 下单链路端到端演示：脚本自己找有售价的日期，不写死日期
order-demo: build
	python3 scripts/order_demo.py --db $(PGDATABASE)

# 重建主库（会清库）并跑验收
db: build
	$(PSQL) -h $(PGHOST) -d postgres -c "DROP DATABASE IF EXISTS $(PGDATABASE);" \
	                   -c "CREATE DATABASE $(PGDATABASE);"
	./$(BIN) migrate --db $(PGDATABASE)
	$(PSQL) -h $(PGHOST) -d $(PGDATABASE) -v ON_ERROR_STOP=1 -f db/seed.sql
	$(PSQL) -h $(PGHOST) -d $(PGDATABASE) -v ON_ERROR_STOP=1 -f db/verify.sql

verify:
	$(PSQL) -h $(PGHOST) -d $(PGDATABASE) -v ON_ERROR_STOP=1 -f db/verify.sql

clean:
	rm -rf bin
