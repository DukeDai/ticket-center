# ticket-center — 供应源接入层（Go）
#
# 常用：
#   make build     构建 tc-connect
#   make test      跑单元测试
#   make check     vet + test + 协议自检 + 演练器（提交前跑这个）
#   make mock      协议级自检（本地 mock，14 项断言）
#   make layers    分层连通性测试（真实端点）
#   make dryrun    无凭证集成演练（建演练库 + 38 条不变量自检）
#   make db        重建主库并验收
#   make poc       生成前端 POC 页面

SHELL := /bin/bash
GO ?= go
PSQL ?= psql
PGHOST ?= 127.0.0.1
PGDATABASE ?= ticket_center
BIN := bin/tc-connect

export PATH := /usr/local/go/bin:$(PATH)

.PHONY: all build test vet fmt check mock layers dryrun poc db verify sources clean

all: build

build:
	@mkdir -p bin
	$(GO) build -o $(BIN) ./cmd/tc-connect
	@echo "已构建 $(BIN)"

test:
	$(GO) test ./... -timeout 120s

vet:
	$(GO) vet ./...

fmt:
	$(GO) fmt ./...

# 提交前的完整自检
check: vet test build mock dryrun

mock: build
	./$(BIN) mock

layers: build
	./$(BIN) layers

sources: build
	./$(BIN) sources

dryrun:
	python3 scripts/mapping_dryrun.py

poc:
	python3 scripts/mapping_dryrun.py --json scripts/poc/data.json --poc scripts/poc/index.html

# 重建主库（会清库）并跑验收
db:
	$(PSQL) -h $(PGHOST) -d postgres -c "DROP DATABASE IF EXISTS $(PGDATABASE);" \
	                   -c "CREATE DATABASE $(PGDATABASE);"
	$(PSQL) -h $(PGHOST) -d $(PGDATABASE) -v ON_ERROR_STOP=1 -f db/schema.sql
	$(PSQL) -h $(PGHOST) -d $(PGDATABASE) -v ON_ERROR_STOP=1 -f db/seed.sql
	$(PSQL) -h $(PGHOST) -d $(PGDATABASE) -v ON_ERROR_STOP=1 -f db/verify.sql

verify:
	$(PSQL) -h $(PGHOST) -d $(PGDATABASE) -v ON_ERROR_STOP=1 -f db/verify.sql

clean:
	rm -rf bin
