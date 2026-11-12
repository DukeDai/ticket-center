-- counts.sql —— 各主题视图各有多少条不变量。
--
-- 分支名从 v_invariant_checks 的定义里抠出来（那是唯一来源），
-- 再逐个数每个分支视图的行数 —— 不手抄分组，手抄必分叉。
--
-- 用法：psql -h 127.0.0.1 -d ticket_center -f scripts/counts.sql

WITH branches AS (
    SELECT DISTINCT m[1] AS name
      FROM regexp_matches(
             pg_get_viewdef('v_invariant_checks'::regclass, true),
             'FROM (v_invariant_checks_[a-z0-9_]+)', 'g') AS m
)
SELECT format('SELECT %L || rpad(%L, 34) || (SELECT count(*) FROM %I) || %L;',
              '    ', name, name, ' 条')
  FROM branches b
 ORDER BY name
\gexec
