#!/usr/bin/env bash
# counts.sh —— 打印本仓库各处文档里写的那些数（不变量条数、测试条数、mock 断言数……）。
#
# 为什么要有这个脚本：
#   这些数是**推导出来的**（数一数视图有几条、数一数测试有几个函数），
#   手抄进 SPEC / AGENTS / README 就会有两处：
#   抄的那天是对的，加了一天条目的那天就有一处是旧的 ——
#   而「规格说 118、库里有 119」正是最费时间的一种不一致。
#   抄的地方越多，分叉的机会越多。
#
# 所以：数只在这里数一次，文档只引用这份输出，不自己抄。
# 改了口径就跑 `make counts`，把输出贴进文档；
# 更好的做法是文档里写「见 `make counts`」，连贴都不贴。
#
# 读数口径（每条都注明来源，别猜）：
#   不变量条数     —— 库里的 v_invariant_checks 视图（要一个已迁移的库）
#   主题视图数     —— v_invariant_checks 的 UNION ALL 分支数（pg_get_viewdef）
#   测试函数数     —— 各 *_test.go 里的顶层 Test 函数（子测试另算）
#   有测试的包数   —— 至少有一个 *_test.go 的包
#   mock 断言数    —— `tc-connect mock` 的输出末尾那行「合计」
#   库对象数       —— pg_class / pg_indexes / pg_trigger / pg_constraint（各按它的口径，别换）
#   种子行数       —— 每张种子表的实际行数（表名写全，标签不许含糊）
#
# 用法：
#   scripts/counts.sh              库的部分跳过（没有库也能跑）
#   scripts/counts.sh ticket_center  指定库
set -uo pipefail

cd "$(dirname "$0")/.."
export PATH="/usr/local/go/bin:/opt/homebrew/opt/postgresql@15/bin:$PATH"

DB="${1:-${PGDATABASE:-ticket_center}}"

echo "=== 不变量 ==="

if psql -h 127.0.0.1 -d "$DB" -tAc "SELECT 1 FROM v_invariant_checks LIMIT 1" >/dev/null 2>&1; then
  printf '不变量条数      %s\n' "$(psql -h 127.0.0.1 -d "$DB" -tAc 'SELECT count(*) FROM v_invariant_checks' | tr -d ' ')"
  printf 'check_name 唯一  %s\n' "$(psql -h 127.0.0.1 -d "$DB" -tAc 'SELECT count(*)=count(DISTINCT check_name) FROM v_invariant_checks' | tr -d ' ')"
  printf '主题视图数      %s\n' "$(psql -h 127.0.0.1 -d "$DB" -tAc \
    "SELECT count(DISTINCT m[1]) FROM regexp_matches(pg_get_viewdef('v_invariant_checks'::regclass, true), 'FROM (v_invariant_checks_[a-z0-9_]+)', 'g') m" | tr -d ' ')"
  echo "  分组："
  psql -h 127.0.0.1 -d "$DB" -tA -f scripts/counts.sql
else
  echo "不变量条数      （库 $DB 不可用 —— 先跑 make db）"
fi

echo ""
echo "=== 库对象（口径写在标签后面，别换口径）==="

if psql -h 127.0.0.1 -d "$DB" -tAc "SELECT 1 FROM pg_namespace WHERE nspname='public'" >/dev/null 2>&1; then
  psql -h 127.0.0.1 -d "$DB" -tA -F'|' -c "
    SELECT '业务表', count(*) FROM information_schema.tables
      WHERE table_schema='public' AND table_type='BASE TABLE' AND table_name NOT LIKE 'ops_%'
    UNION ALL SELECT '视图', count(*) FROM information_schema.views WHERE table_schema='public'
    UNION ALL SELECT '索引', count(*) FROM pg_indexes WHERE schemaname='public'
    UNION ALL SELECT '触发器', count(*) FROM pg_trigger t
      JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND NOT t.tgisinternal
    UNION ALL SELECT 'CHECK 约束', count(*) FROM pg_constraint c
      JOIN pg_namespace n ON n.oid=c.connamespace
      WHERE n.nspname='public' AND c.contype='c'
    UNION ALL SELECT '序列', count(*) FROM pg_class c
      JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relkind='S'
    UNION ALL SELECT '函数', count(*) FROM information_schema.routines
      WHERE routine_schema='public' AND routine_type='FUNCTION'
  " | awk -F'|' '{printf "%-12s %s\n", $1, $2}'
else
  echo "（库 $DB 不可用 —— 先跑 make db）"
fi

echo ""
echo "=== 种子行数（表名取自 db/seed.sql 自己的统计段，不另抄一份）==="

if psql -h 127.0.0.1 -d "$DB" -tAc "SELECT 1 FROM pg_namespace WHERE nspname='public'" >/dev/null 2>&1; then
  # db/seed.sql 末尾自带「-- 统计」段，列了它自己灌了哪些表、多少行。
  # 这里直接跑那一段 —— 种子表清单只有一个来源，脚本不另抄一份。
  SEED_STATS="$(awk '/^-- 统计/{f=1;next} f && /^SELECT /{p=1} p{print} p && /;$/{exit}' db/seed.sql)"
  if [ -n "$SEED_STATS" ]; then
    printf '%s\n' "$SEED_STATS" | psql -h 127.0.0.1 -d "$DB" -tA -F'|' 2>/dev/null \
      | awk -F'|' '{printf "  %-22s %s\n", $1, $2}'
  else
    echo "（db/seed.sql 里没找到「-- 统计」段）"
  fi
else
  echo "（库 $DB 不可用 —— 先跑 make db）"
fi

echo ""
echo "=== Go 单元测试 ==="

printf '测试函数数      %s\n' "$(grep -rhoE '^func Test[A-Za-z0-9_]*' --include='*_test.go' . | wc -l | tr -d ' ')"
printf '有测试的包数    %s\n' "$(find . -name '*_test.go' -not -path './.git/*' -exec dirname {} \; | sort -u | wc -l | tr -d ' ')"
printf '全部包数        %s\n' "$(go list ./... 2>/dev/null | wc -l | tr -d ' ')"

echo ""
echo "=== 协议级自检 ==="

if [ -x bin/tc-connect ]; then
  ./bin/tc-connect mock 2>/dev/null | grep -E '^合计' || echo "（跑 make mock 看断言数）"
else
  echo "（先 make build）"
fi
