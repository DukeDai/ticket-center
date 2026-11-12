#!/usr/bin/env python3
"""
无凭证集成演练（mapping dry-run）+ POC 数据导出

目的：在拿不到 aid/sid/key、Reseller ID/API Key 之前，先把「源报文 → 归一化 → 变体映射 → 路由」
这条链路用**真实报文结构**跑通一遍，并暴露当前模型表达不了的源侧结构。

分工（对应 AGENTS.md 硬约束 4、14 与「一份事实只写一处」）：
  - **归一化在 Go 侧**（internal/normalize，唯一实现）。本脚本通过
    `tc-connect normalize` 消费它的输出，不自己再写一份归一化；
  - **覆盖判定在数据库里**（fn_variant_covered / fn_variant_coverage_gaps）。
    本脚本不判断「源变体覆盖得住哪些规范变体」—— 它只把覆盖声明交给库，
    由库返回映射与缺口。曾经这里有一份 Python 镜像（covers / coverage_gaps），
    三份实现各自自洽，改了一份另外两份不动 ——
    分叉的后果是「源侧说覆盖得住、我们的门禁说覆盖不住」；
  - **组合映射在 Go 侧**（internal/compose，唯一实现）。本脚本通过
    `tc-connect compose apply` 消费它的输出；
  - 本脚本只负责：把数据落库、读回结果、出报告、导出 JSON / 渲染前端 POC；
  - 映射规则全部来自 configs/mapping_rules.json（与接入层共用），
    **本文件不出现任何按源分支的代码**；新接一个源 = 在规则文件里加一段配置。

依赖：Go 1.23+（会自动 go build 出 tc-connect，或用 PATH 里的 tc-connect）。

用法：
  python3 scripts/mapping_dryrun.py                     # 跑演练并打印报告
  python3 scripts/mapping_dryrun.py --json out.json     # 额外导出结构化结果（给前端 POC 用）
  python3 scripts/mapping_dryrun.py --poc scripts/poc/index.html   # 直接生成单文件 POC 页面
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
from decimal import Decimal

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FIXTURES = os.path.join(ROOT, 'fixtures')
RULES_PATH = os.path.join(ROOT, 'configs', 'mapping_rules.json')
DB = os.environ.get('DRYRUN_DB', 'ticket_center_dryrun')
PSQL = os.environ.get('PSQL_BIN', 'psql')
HOST = os.environ.get('PGHOST', '127.0.0.1')

TODAY = None   # 演练基准日期：唯一来源是 configs/mapping_rules.json 的 base_date（run() 里读）

_TC_CONNECT = None


# ---------------------------------------------------------------- 归一化（委托 Go 实现）
def tc_connect_bin():
    """找（或现场构建）tc-connect 二进制。

    归一化与组合映射的**唯一实现**都在 Go 侧。演练器通过 CLI 消费它们的输出，
    避免两套规则实现漂移。
    """
    global _TC_CONNECT
    if _TC_CONNECT:
        return _TC_CONNECT
    found = shutil.which('tc-connect')
    if found:
        _TC_CONNECT = found
        return found
    build_dir = os.path.join(tempfile.gettempdir(), 'ticket-center-tools')
    os.makedirs(build_dir, exist_ok=True)
    bin_path = os.path.join(build_dir, 'tc-connect')
    r = subprocess.run(['go', 'build', '-o', bin_path, './cmd/tc-connect'],
                       cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit('构建 tc-connect 失败（需要 Go 1.23+）：\n' + r.stderr[:2000])
    _TC_CONNECT = bin_path
    return bin_path


def normalize_via_go(src_key, fixture_path):
    """调 Go 侧的归一化：源报文 → 源变体 + 覆盖声明 + 报价行。"""
    r = subprocess.run([tc_connect_bin(), 'normalize', '--source', src_key, '--fixture', fixture_path],
                       cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit('归一化失败（%s）：%s' % (src_key, r.stderr[:2000] or r.stdout[:2000]))
    return json.loads(r.stdout)


def compose_via_go(src_key, fixture_path):
    """调 Go 侧的组合映射：组合表达式 → 配方（写库）。

    返回 (是否成功, 输出文本)。失败不算演练失败 —— 组合映射解不出来是
    「模型或声明缺一块」，要在报告里说清楚，不是静默吞掉。
    """
    r = subprocess.run([tc_connect_bin(), 'compose', 'apply',
                        '--source', src_key, '--fixture', fixture_path, '--db', DB],
                       cwd=ROOT, capture_output=True, text=True)
    return r.returncode == 0, (r.stdout or '') + (r.stderr or '')


# ---------------------------------------------------------------- 基础工具
def load_json(path):
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def psql(sql, db=DB):
    cmd = [PSQL, '-h', HOST, '-d', db, '-v', 'ON_ERROR_STOP=1', '-q', '-t', '-A', '-F', '\x1f', '-c', sql]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print('SQL FAILED:\n' + r.stderr.strip()[:2000])
        sys.exit(1)
    return r.stdout.strip()


def q(sql):
    out = psql(sql)
    return [line.split('\x1f') for line in out.splitlines() if line.strip()]


def lit(v):
    if v is None:
        return 'NULL'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, (int, float)):
        return str(v)
    return "'" + str(v).replace("'", "''") + "'"


def money(s):
    """读金额。

    库里的金额是 NUMERIC，直接 float() 会掉精度（122.93 可能是 122.92999999）。
    先经 Decimal 读成精确十进制，再转成 float 只为渲染/序列化 —— 计算不在这里做。
    """
    if not s:
        return 0.0
    return float(Decimal(s))


def run_sql(stmts, label):
    """执行一批语句（一个阶段一批）。

    分阶段执行是有意的：覆盖判定要用到规范变体，组合映射要用到源变体，
    所以顺序是「规范 → 源 → 映射/报价 → 组合 → 上架 → 售价骨架」。
    """
    if not stmts:
        return
    path = os.path.join(tempfile.gettempdir(), 'dryrun_%s.sql' % label)
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(stmts) + '\n')
    r = subprocess.run([PSQL, '-h', HOST, '-d', DB, '-v', 'ON_ERROR_STOP=1', '-q', '-f', path],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print('演练数据落库失败（%s）：\n%s\n（语句在 %s）' % (label, r.stderr[:3000], path))
        sys.exit(1)


# ---------------------------------------------------------------- 落库
IDENTITY_TABLES = {
    'product', 'product_axis', 'product_axis_option', 'ticket_type', 'product_variant',
    'supplier', 'supplier_product', 'supplier_variant', 'supplier_variant_mapping',
    'supplier_price_calendar', 'price_calendar', 'channel', 'channel_listing',
}


def with_identity(stmts):
    out = []
    for s in stmts:
        up = s.strip().upper()
        if up.startswith('INSERT INTO '):
            tbl = up.split('INSERT INTO ', 1)[1].split('(', 1)[0].strip().lower()
            if tbl in IDENTITY_TABLES and ' VALUES ' in s:
                s = s.replace(' VALUES ', ' OVERRIDING SYSTEM VALUE VALUES ', 1)
        out.append(s)
    return out


def build_canonical(catalog):
    """规范侧（我们自己的商品与可售单元）。

    组合套餐（variant_role='combo'）在这里声明组件与数量 ——
    「2 大 1 小」的「几份」是套餐的本质的一部分，不能只写「包含哪些」。
    """
    stmts = []
    ids = {'product': 100, 'axis': 200, 'option': 300, 'ticket_type': 400, 'variant': 500}
    canon, canon_variants, product_ids = {}, {}, {}
    relations = []   # 组合声明：最后统一插（子变体可能还没建）
    for p in catalog['products']:
        pid = ids['product']; ids['product'] += 1
        product_ids[p['product_code']] = pid
        stmts.append(
            "INSERT INTO product (id, product_code, title, product_type, status, canonical_key, attributes) "
            "VALUES (%d, %s, %s, %s, 'active', %s, '{}'::jsonb);" % (
                pid, lit(p['product_code']), lit(p['title']), lit(p.get('product_type', 'ticket')),
                lit(p['product_code'].lower())))
        for ax in p.get('axes', []):
            aid = ids['axis']; ids['axis'] += 1
            stmts.append(
                "INSERT INTO product_axis (id, product_id, axis_code, axis_name, axis_kind, is_required, is_pricing, sort_order, status) "
                "VALUES (%d, %d, %s, %s, 'enum', true, true, %d, 'active');" % (
                    aid, pid, lit(ax['code']), lit(ax['name']), ax.get('sort_order', 10)))
            for opt in ax.get('options', []):
                oid = ids['option']; ids['option'] += 1
                stmts.append(
                    "INSERT INTO product_axis_option (id, axis_id, option_code, option_name, option_attrs, sort_order, status) "
                    "VALUES (%d, %d, %s, %s, '{}'::jsonb, %d, 'active');" % (
                        oid, aid, lit(opt['code']), lit(opt['name']), opt.get('sort_order', 10)))
                canon.setdefault((p['product_code'], ax['code']), {})[opt['code']] = (aid, oid)
        tt_ids = {}
        for tt in p.get('ticket_types', []):
            tid = ids['ticket_type']; ids['ticket_type'] += 1
            tt_ids[tt['code']] = tid
            stmts.append(
                "INSERT INTO ticket_type (id, product_id, code, name, age_rule, stock_mode, sort_order, status) "
                "VALUES (%d, %d, %s, %s, %s, 'per_session', 1, 'active');" % (
                    tid, pid, lit(tt['code']), lit(tt['name']), lit(json.dumps(tt.get('age_rule', {})))))
        for v in p.get('variants', []):
            vid = ids['variant']; ids['variant'] += 1
            ttid = tt_ids.get(v.get('ticket_type')) if v.get('ticket_type') else None
            role = v.get('variant_role', 'base')
            stmts.append(
                "INSERT INTO product_variant (id, product_id, variant_code, variant_key, title, variant_role, ticket_type_id, status, sort_order) "
                "VALUES (%d, %d, %s, %s, %s, %s, %s, 'active', %d);" % (
                    vid, pid, lit(v['key'].replace(':', '-')), lit(v['key']),
                    lit(v.get('title', v['key'])), lit(role), lit(ttid), vid))
            for axis_code, opt_code in (v.get('axes') or {}).items():
                key = (p['product_code'], axis_code)
                if key in canon and opt_code in canon[key]:
                    aid, oid = canon[key][opt_code]
                    stmts.append(
                        "INSERT INTO product_variant_option (product_variant_id, axis_id, axis_option_id) VALUES (%d, %d, %d);" % (
                            vid, aid, oid))
            canon_variants[v['key']] = {
                'id': vid, 'product_id': pid, 'product_code': p['product_code'],
                'product_title': p['title'], 'audience': v.get('ticket_type'),
                'axes': v.get('axes') or {}, 'title': v.get('title', v['key']),
                'role': role,
            }
            for comp in v.get('components') or []:
                relations.append((v['key'], comp['variant'], comp.get('quantity', 1)))

    # 组件声明：父变体与子变体都得先存在，所以放在所有变体之后
    for parent_key, child_key, qty in relations:
        if parent_key not in canon_variants:
            raise SystemExit('组合 %s 的组件声明找不到父变体' % parent_key)
        if child_key not in canon_variants:
            raise SystemExit('组合 %s 的组件 %s 在规范目录里不存在' % (parent_key, child_key))
        stmts.append(
            "INSERT INTO product_variant_relation (parent_variant_id, child_variant_id, relation_type, quantity, price_policy, sort_order) "
            "VALUES (%d, %d, 'included', %s, '{}'::jsonb, 10);" % (
                canon_variants[parent_key]['id'], canon_variants[child_key]['id'], lit(qty)))
    return stmts, canon, canon_variants, product_ids


# ---------------------------------------------------------------- 判定交给数据库
def mapping_sql(sv_id, coverage):
    """源变体 → 规范变体的映射：判定在库里（fn_variant_covered）。

    这条语句不替库做判断：它把「哪些规范变体被覆盖住了」交给函数算，
    自己只负责把命中的那些写成映射行。精确匹配（is_exact）也由库判
    （fn_variant_coverage_is_exact）—— 「这个源 SKU 恰好等于这个可售单元」
    还是「这个源 SKU 更宽」是同一条规则，不在脚本里重写一遍。

    组合变体（variant_role='combo'）跳过：组合的供给走配方，
    直接挂源映射会让定价函数用**一个**源 SKU 的成本给整张套餐定价。
    库里还有守卫触发器兜底，这里先跳过是为了不让批量插入整条失败。
    """
    cov = lit(json.dumps(coverage, ensure_ascii=False))
    return (
        "INSERT INTO supplier_variant_mapping (supplier_variant_id, product_variant_id, coverage, is_exact, match_type, confidence, status) "
        "SELECT %d, pv.id, %s::jsonb, fn_variant_coverage_is_exact(%s::jsonb, pv.id), "
        "  'rule', 0.95, 'active' "
        "FROM product_variant pv "
        "WHERE pv.status = 'active' "
        "  AND pv.variant_role <> 'combo' "
        "  AND fn_variant_covered(%s::jsonb, pv.id);" % (sv_id, cov, cov, cov))


def price_sql(sp_id, sv_id, pr):
    """源报价行：写到它覆盖住的每个规范变体上（哪些被覆盖由库里的映射行说了算）。"""
    return (
        "INSERT INTO supplier_price_calendar (supplier_product_id, supplier_session_id, product_id, date, currency, "
        "supplier_price, net_price, status, product_variant_id, supplier_variant_id) "
        "SELECT %d, NULL::bigint, pv.product_id, %s, %s, %s, %s, 'available', m.product_variant_id, %d "
        "FROM supplier_variant_mapping m "
        "JOIN product_variant pv ON pv.id = m.product_variant_id "
        "WHERE m.supplier_variant_id = %d AND m.status = 'active';" % (
            sp_id, lit(pr['date']), lit(pr['currency']),
            lit(pr['sale_price']), lit(pr['net_price']), sv_id, sv_id))


def product_mapping_sql():
    """源商品 → 规范商品：一个（商品，供应商）只留一个 primary（不变量 2）。"""
    return (
        "INSERT INTO product_mapping (supplier_product_id, supplier_id, product_id, match_type, confidence, "
        "match_evidence, is_primary, status, created_by) "
        "WITH targets AS ("
        "  SELECT DISTINCT ON (sp.supplier_id, pv.product_id)"
        "         sp.supplier_id, sv.supplier_product_id, pv.product_id"
        "    FROM supplier_variant_mapping svm"
        "    JOIN supplier_variant sv ON sv.id = svm.supplier_variant_id"
        "    JOIN supplier_product sp ON sp.id = sv.supplier_product_id"
        "    JOIN product_variant pv ON pv.id = svm.product_variant_id"
        "   WHERE svm.status = 'active'"
        "   ORDER BY sp.supplier_id, pv.product_id, sv.supplier_product_id)"
        "SELECT supplier_product_id, supplier_id, product_id, 'rule', 0.95, "
        "       '{\"decoded_by\":\"mapping_dryrun\"}', true, 'active', 'dryrun' FROM targets;")


def listing_sql(price_policy):
    """上架：同一规范商品只建一个上架（不变量 15：每个 online 上架必须绑源）。"""
    return (
        "INSERT INTO channel_listing (channel_id, product_id, status, price_policy, stock_policy, booking_policy, "
        "min_order_qty, max_order_qty, sort_weight, published_at) "
        "SELECT 1, t.product_id, 'online', %s, '{\"mode\":\"full\"}', '{\"mode\":\"instant\"}', 1, 10, 50, now() "
        "  FROM (SELECT DISTINCT product_id FROM product_mapping WHERE status = 'active' ORDER BY product_id) t;" % lit(
            json.dumps(price_policy, ensure_ascii=False)))


def listing_source_sql():
    """上架 ↔ 源商品：一个源商品在它的规范商品的上架里排一个优先级。"""
    return (
        "INSERT INTO channel_listing_source (channel_listing_id, supplier_product_id, supplier_id, priority, "
        "fallback_order, min_margin, max_daily_qty, enabled) "
        "SELECT cl.id, pm.supplier_product_id, pm.supplier_id, "
        "       10 * row_number() OVER (ORDER BY pm.supplier_id, pm.supplier_product_id), "
        "       row_number() OVER (ORDER BY pm.supplier_id, pm.supplier_product_id), "
        "       0, NULL, true "
        "  FROM product_mapping pm "
        "  JOIN channel_listing cl ON cl.product_id = pm.product_id AND cl.channel_id = 1 "
        " WHERE pm.status = 'active';")


def price_calendar_sql(base_currency):
    """对客售价骨架：只写「卖哪一行」，金额一律交给数据库里的定价函数。"""
    return (
        "INSERT INTO price_calendar (product_id, session_id, ticket_type_id, channel_id, date, currency, status, source, product_variant_id) "
        "SELECT DISTINCT pv.product_id, NULL::bigint, NULL::bigint, NULL::bigint, spc.date, %s, 'active', 'sync', spc.product_variant_id "
        "  FROM supplier_price_calendar spc "
        "  JOIN product_variant pv ON pv.id = spc.product_variant_id "
        " WHERE spc.status = 'available';" % lit(base_currency))


# ---------------------------------------------------------------- 主流程
def run():
    global TODAY
    rules = load_json(RULES_PATH)
    catalog = load_json(os.path.join(FIXTURES, 'canonical_catalog.json'))
    pricing_rule = rules.get('pricing', {})
    TODAY = rules.get('base_date')
    if not TODAY:
        raise SystemExit('configs/mapping_rules.json 缺 base_date —— 演练基准日期只有一个来源，不猜')

    # ---- ① 规范侧先落库：覆盖判定要用到规范变体
    stmts, canon, canon_variants, product_ids = build_canonical(catalog)
    stmts.append(
        "INSERT INTO channel (id, code, name, channel_type, settlement_mode, commission_rate, default_currency, tax_policy, status, config) "
        "VALUES (1,'C2C','OTA 自营 C 端','b2c_own','prepaid',0,'CNY','{\"included\":true,\"rate\":0.06}','active','{}'::jsonb);")

    # 全局口径：基准币种、锁价口径。这些以前散在 Python 里，现在是数据库里的配置。
    base_currency = 'CNY'
    stmts.append(
        "INSERT INTO app_setting (key, value, description) "
        "VALUES ('base_currency', %s, '演练库：跨币种比价的基准币种'), "
        "       ('price_locked_uses_source_list_price', %s, '演练库：源侧价格保护时售价锁定为源挂牌价');" % (
            lit(base_currency),
            lit('true' if pricing_rule.get('price_locked_uses_source_list_price') else 'false')))
    run_sql(with_identity(stmts), 'canonical')

    # ---- ② 源侧逐个落库：源 → 源商品 → 源变体 → 映射（库里判） → 报价（库里判）
    sid = 600
    sp_id = 700
    sv_id = 600
    src_report = []
    source_variants_out = []
    compose_out = []

    for src_key, rule in rules['sources'].items():
        fixture_path = os.path.join(FIXTURES, rule['fixture'])
        sid += 1
        stmts = [
            "INSERT INTO supplier (id, code, name, short_name, country_code, default_currency, timezone, status, capability, sync_policy, connector_version) "
            "VALUES (%d, %s, %s, %s, 'CN', %s, 'Asia/Shanghai', 'active', "
            "'{\"product\":true,\"price\":true,\"session\":true,\"availability\":\"live\",\"booking\":true,\"cancel\":true}', "
            "'{\"catalog\":\"daily\"}','dryrun');" % (
                sid, lit(rule['supplier_code']), lit(rule['supplier_name']),
                lit(rule['supplier_code'][:3].upper()), lit(rule.get('currency', 'CNY')))
        ]

        # 归一化交给 Go 实现（唯一实现）：演练器只负责落库与报告
        norm = normalize_via_go(src_key, fixture_path)
        for doc_idx, product in enumerate(norm['products']):
            doc = product.get('raw') or {}
            ext_pid = product.get('external_id')
            ext_pname = product.get('name')

            sp_id += 1
            stmts.append(
                "INSERT INTO supplier_product (id, supplier_id, external_id, external_code, raw_title, raw_payload, source_attributes, availability_mode, content_hash, status, last_synced_at) "
                "VALUES (%d, %d, %s, %s, %s, %s, %s, 'live', 'dry-%s-%s', 'active', now());" % (
                    sp_id, sid, lit(ext_pid), lit(ext_pid), lit(ext_pname),
                    lit(json.dumps(doc, ensure_ascii=False)),
                    lit(json.dumps(doc, ensure_ascii=False)), src_key, doc_idx))

            variants = product.get('variants') or []
            prices = product.get('prices') or {}
            if not variants:
                continue

            sv_index = {}
            for sv in variants:
                sv_id += 1
                sv_index[sv['external_id']] = sv_id
                stmts.append(
                    "INSERT INTO supplier_variant (id, supplier_product_id, external_variant_id, title, variant_attrs, raw_payload, status, is_price_locked) "
                    "VALUES (%d, %d, %s, %s, %s, %s, 'active', %s);" % (
                        sv_id, sp_id, lit(sv['external_id']), lit(sv['title']),
                        lit(json.dumps(sv['attrs'], ensure_ascii=False)),
                        lit(json.dumps(sv['raw'], ensure_ascii=False)), lit(sv['price_locked'])))

            # 变体级覆盖语义匹配与源报价：都交给数据库判
            for sv in variants:
                stmts.append(mapping_sql(sv_index[sv['external_id']], sv['coverage']))
                for pr in (prices.get(sv['external_id']) or []):
                    stmts.append(price_sql(sp_id, sv_index[sv['external_id']], pr))
                source_variants_out.append({
                    'source': rule['supplier_code'], 'source_product': str(ext_pid),
                    'source_product_name': ext_pname,
                    'external_id': sv['external_id'], 'title': sv['title'],
                    'coverage': sv['coverage'], 'price_locked': sv['price_locked'],
                })

            src_report.append({'source': rule['supplier_code'], 'sp_id': sp_id,
                                'external_id': str(ext_pid), 'name': ext_pname,
                                'variants': len(variants)})

        run_sql(with_identity(stmts), 'source_' + src_key)

        # ---- ③ 组合映射（方向 B）：交给 Go 实现
        ok, text = compose_via_go(src_key, fixture_path)
        compose_out.append({
            'source': rule['supplier_code'],
            'ok': ok,
            'output': text.strip(),
            'expressions': [e for e in norm.get('composite_expressions') or [] if e['is_composite']],
        })

    # ---- ④ 商品映射与上架：源商品能供哪些规范商品，读回库里的映射结果
    run_sql([product_mapping_sql()], 'product_mapping')
    run_sql([listing_sql({"mode": "cost_plus",
                          "percent": pricing_rule.get('markup_percent', 10.0)}),
             listing_source_sql()], 'listing')

    # ---- ⑤ 对客售价：只写骨架（卖哪一行），金额一律交给数据库里的定价函数
    #
    # 以前这里在 Python 里算钱：float() 算成本、跨币种直接比大小、还把不同日期的报价
    # 混在一起挑一个最便宜的。那是「同一批源数据、三个地方、三个价格」的来源之一。
    # 现在：骨架行（变体 × 日期）写进 price_calendar，落库后调 fn_reprice_rows()，
    # 成本 / 售价 / 划线价 / 锁价 / 汇率留痕全部由 fn_price_variant 算（唯一实现）。
    run_sql([price_calendar_sql(base_currency)], 'price_calendar')

    # ---- ⑥ 定价：调数据库里的唯一实现（fn_price_variant）
    #     这一步之前演练器在 Python 里自己算价。现在成本、售价、锁价、汇率留痕
    #     全部由 SQL 算，演练器只负责喂数据和读结果。
    repriced = q("SELECT fn_reprice_rows();")
    repriced_rows = int(repriced[0][0]) if repriced else 0
    unpriced = q("""SELECT format('变体%s@%s', product_variant_id, date)
                      FROM price_calendar
                     WHERE status = 'active' AND product_variant_id IS NOT NULL
                       AND (sell_price IS NULL OR cost_price IS NULL)
                     ORDER BY id;""")
    if unpriced:
        print('以下售价行没有定价（缺源报价 / 缺上架关系 / 缺汇率快照）：')
        for row in unpriced:
            print('  %s' % row[0])

    # ---- ⑦ 读回结果（报告与 POC 用）
    matched_by_source = {}
    for row in q("""SELECT sup.code, sv.external_variant_id, pv.variant_key
                      FROM supplier_variant_mapping svm
                      JOIN supplier_variant sv ON sv.id = svm.supplier_variant_id
                      JOIN supplier_product sp ON sp.id = sv.supplier_product_id
                      JOIN supplier sup ON sup.id = sp.supplier_id
                      JOIN product_variant pv ON pv.id = svm.product_variant_id
                     WHERE svm.status = 'active';"""):
        matched_by_source.setdefault((row[0], row[1]), []).append(row[2])

    gaps_by_source = load_gaps(source_variants_out)
    for sv in source_variants_out:
        sv['matched'] = matched_by_source.get((sv['source'], sv['external_id']), [])
        sv['near_miss'] = gaps_by_source.get(sv['external_id'], [])[:6]

    mappings_out = []
    for row in q("""SELECT sup.code, sp.external_id, sv.external_variant_id, sv.title,
                           pv.variant_key, pv.title, p.product_code, p.title, svm.coverage
                      FROM supplier_variant_mapping svm
                      JOIN supplier_variant sv ON sv.id = svm.supplier_variant_id
                      JOIN supplier_product sp ON sp.id = sv.supplier_product_id
                      JOIN supplier sup ON sup.id = sp.supplier_id
                      JOIN product_variant pv ON pv.id = svm.product_variant_id
                      JOIN product p ON p.id = pv.product_id
                     WHERE svm.status = 'active'
                     ORDER BY sup.code, p.id, pv.sort_order;"""):
        cov = json.loads(row[8]) if row[8] else {'axes': {}, 'excludes': []}
        locked = any(s['source'] == row[0] and s['external_id'] == row[2] and s['price_locked']
                     for s in source_variants_out)
        mappings_out.append({
            'source': row[0], 'source_product': row[1],
            'source_variant': row[2], 'source_variant_title': row[3],
            'canonical_variant': row[4], 'canonical_variant_title': row[5],
            'canonical_product': row[6], 'canonical_product_title': row[7],
            'coverage': cov, 'price_locked': locked,
        })

    compositions = []
    for row in q("""SELECT variant_key, component_variant_key, source_quantity,
                           declared_quantity, external_variant_id, supplier_code
                      FROM v_variant_composition
                     ORDER BY variant_key, source_quantity DESC;"""):
        compositions.append({
            'our_variant': row[0], 'component': row[1],
            'source_quantity': row[2], 'declared_quantity': row[3],
            'source_variant': row[4], 'source': row[5],
        })

    # 组合不走方向 A（组合的供给走配方）。但「某个源 SKU 覆盖得住这个组合」
    # 这件事要报出来 —— 源侧也许是把整套套餐当一个 SKU 卖的，
    # 那是我们现在接不了的情况（宁可少卖，不可卖错），得让人知道。
    combo_direct = []
    if source_variants_out:
        values = ", ".join(
            "(%s, %s, %s)" % (lit(sv['source']), lit(sv['external_id']),
                               lit(json.dumps(sv['coverage'], ensure_ascii=False)))
            for sv in source_variants_out)
        for row in q(
                "SELECT v.source, v.external_id, pv.variant_key "
                "FROM (VALUES %s) AS v(source, external_id, coverage) "
                "JOIN supplier_variant sv ON sv.external_variant_id = v.external_id "
                "JOIN supplier_product sp ON sp.id = sv.supplier_product_id "
                "JOIN supplier sup ON sup.id = sp.supplier_id AND sup.code = v.source "
                "CROSS JOIN product_variant pv "
                "WHERE pv.variant_role = 'combo' AND pv.status = 'active' "
                "  AND fn_variant_covered(v.coverage::jsonb, pv.id);" % values):
            combo_direct.append({'source': row[0], 'source_variant': row[1], 'our_variant': row[2]})

    # ---- 从库里把结果读出来（POC 用）
    routing = []
    for row in q("""SELECT pv.variant_key, pv.title, p.product_code, p.title, sup.code, sv.external_variant_id,
                           vrc.net_price, vrc.cost_base, vrc.route_rank, vrc.source_currency,
                           pc.sell_price, pc.price_locked, pc.date
                      FROM v_variant_routing_candidates vrc
                      JOIN product_variant pv ON pv.id = vrc.product_variant_id
                      JOIN product p ON p.id = pv.product_id
                      JOIN supplier_variant sv ON sv.id = vrc.supplier_variant_id
                      JOIN supplier_product sp ON sp.id = sv.supplier_product_id
                      JOIN supplier sup ON sup.id = sp.supplier_id
                      JOIN price_calendar pc ON pc.product_variant_id = pv.id AND pc.date = vrc.date
                     ORDER BY pv.sort_order, vrc.route_rank;"""):
        routing.append({
            'variant_key': row[0], 'variant_title': row[1], 'product_code': row[2], 'product_title': row[3],
            'supplier': row[4], 'source_variant': row[5], 'net_price': money(row[6]),
            'cost_base': money(row[7]), 'route_rank': int(row[8]), 'currency': row[9],
            'sell_price': money(row[10]), 'price_locked': row[11] == 't', 'date': row[12],
        })

    invariants = []
    for row in q("SELECT seq, check_name, actual, result FROM v_invariant_checks ORDER BY seq;"):
        invariants.append({'seq': int(row[0]), 'name': row[1], 'actual': int(row[2]), 'result': row[3]})

    canonical_out = []
    for p in catalog['products']:
        for v in p['variants']:
            canonical_out.append({
                'key': v['key'], 'title': v.get('title', v['key']),
                'product_code': p['product_code'], 'product_title': p['title'],
                'audience': v.get('ticket_type'),
                'axes': v.get('axes') or {},
                'variant_role': v.get('variant_role', 'base'),
                'components': v.get('components') or [],
                'axis_names': {a['code']: a['name'] for a in p.get('axes', [])},
                'option_names': {o['code']: o['name'] for a in p.get('axes', []) for o in a['options']},
            })

    gaps = []
    for c in compose_out:
        if c['ok']:
            continue
        for e in c['expressions']:
            gaps.append({
                'source': c['source'], 'our_variant': e['our_variant'],
                'mapping_id': e['mapping_id'], 'parts': e['parts'],
                'resolved': False,
                'detail': c['output'],
            })

    return {
        'generated_at': TODAY,
        'base_date': TODAY,
        'sources': rules['sources'],
        'canonical_products': [
            {'code': p['product_code'], 'title': p['title'], 'axes': p.get('axes', []),
             'ticket_types': p.get('ticket_types', []), 'variant_count': len(p['variants'])}
            for p in catalog['products']],
        'canonical_variants': canonical_out,
        'source_variants': source_variants_out,
        'mappings': mappings_out,
        'routing': routing,
        'compositions': compositions,
        'combo_direct': combo_direct,
        'gaps': gaps,
        'invariants': invariants,
        'repriced_rows': repriced_rows,
        'counts': {
            'source_products': len(src_report),
            'source_variants': len(source_variants_out),
            'mappings': len(mappings_out),
            'canonical_variants': len(canonical_out),
            'routing_rows': len(routing),
            'compositions': len(compositions),
            'combo_direct': len(combo_direct),
            'gaps': len(gaps),
            'invariant_failures': len([i for i in invariants if i['result'] != 'PASS']),
        },
    }


def load_gaps(source_variants_out):
    """覆盖缺口：判定与缺口都在库里（fn_variant_coverage_gaps）。

    脚本只负责把每个源变体的覆盖声明递进去、把缺口读出来。
    """
    if not source_variants_out:
        return {}
    values = ", ".join(
        "(%s, %s)" % (lit(sv['external_id']), lit(json.dumps(sv['coverage'], ensure_ascii=False)))
        for sv in source_variants_out)
    sql = ("SELECT v.external_id, pv.variant_key, "
           "array_to_string(fn_variant_coverage_gaps(v.coverage::jsonb, pv.id), ',') "
           "FROM (VALUES %s) AS v(external_id, coverage) "
           "CROSS JOIN product_variant pv "
           "WHERE pv.status = 'active' AND NOT fn_variant_covered(v.coverage::jsonb, pv.id);" % values)
    out = {}
    for row in q(sql):
        gaps = row[2].split(',') if row[2] else []
        out.setdefault(row[0], []).append({'variant': row[1], 'gaps': gaps})
    return out


def print_report(d):
    print('=' * 82)
    print('无凭证集成演练：源报文 → 归一化 → 变体映射 → 组合映射 → 路由')
    print('演练库：%s   基准日期：%s' % (DB, d['base_date']))
    print('=' * 82)
    c = d['counts']
    print('源商品 %d · 源变体 %d · 变体映射 %d · 规范变体 %d · 路由候选 %d · 组合配方 %d · 解不出的组合 %d · 不变量违规 %d'
          % (c['source_products'], c['source_variants'], c['mappings'], c['canonical_variants'],
             c['routing_rows'], c['compositions'], c['gaps'], c['invariant_failures']))
    print()
    print('── ① 源报文 → 源变体与覆盖声明 ─────────────────────────────')
    by_src = {}
    for sv in d['source_variants']:
        by_src.setdefault(sv['source'], []).append(sv)
    for src, svs in by_src.items():
        print('  源 %s' % src)
        for sv in svs:
            print('     %-26s %-28s %s%s' % (
                sv['external_id'], (sv['title'] or '')[:26],
                json.dumps(sv['coverage']['axes'], ensure_ascii=False),
                '  [价格保护]' if sv['price_locked'] else ''))
    print()
    print('── ② 覆盖语义匹配（判定在库里的 fn_variant_covered）────────')
    for m in d['mappings']:
        print('  %-24s ← %-10s %-26s%s' % (m['canonical_variant'], m['source'], m['source_variant'],
                                          '  [价格保护]' if m['price_locked'] else ''))
    print()
    print('── ③ 变体级路由（route_rank=1 = 首选源）────────────────────')
    for r in d['routing']:
        print('  %-26s %-10s ← %-10s %-26s net=%-9s rank=%s%s' % (
            r['date'], r['variant_key'], r['supplier'], r['source_variant'], r['net_price'], r['route_rank'],
            '  [锁价]' if r['price_locked'] else ''))
    print()
    print('── ④ 组合映射（方向 B：一个可售单元由多个源 SKU 组成）────')
    if not d['compositions'] and not d['gaps']:
        print('  （无）')
    for comp in d['compositions']:
        print('  %-22s = %-22s × %-4s ← 源 SKU %s（%s）' % (
            comp['our_variant'], comp['component'], comp['source_quantity'],
            comp['source_variant'], comp['source']))
    for g in d['gaps']:
        parts = ' + '.join('%s×%d' % (p['sku_id'], p['qty']) for p in g['parts'])
        print('  ✗ %s · 我们的变体 %s' % (g['source'], g['our_variant']))
        print('      mappingId = %s' % g['mapping_id'])
        print('      拆解 = %s' % parts)
        print('      → %s' % (g['detail'].strip().splitlines()[0] if g['detail'].strip() else '解不出来'))
    for cd in d.get('combo_direct') or []:
        print('  ! 源 SKU %s（%s）覆盖得住组合 %s，但组合不走方向 A（供给走配方）—— 接不了'
              % (cd['source_variant'], cd['source'], cd['our_variant']))
    print()
    print('── ⑤ 不变量自检 ─────────────────────────────────────────')
    bad = [i for i in d['invariants'] if i['result'] != 'PASS']
    print('  共 %d 条，违规 %d 条' % (len(d['invariants']), len(bad)))
    for i in bad:
        print('  ✗ %s %s actual=%s' % (i['seq'], i['name'], i['actual']))
    print()
    print('演练库 %s 已保留。' % DB)


def main():
    args = sys.argv[1:]
    json_out = None
    poc_out = None
    if '--json' in args:
        json_out = args[args.index('--json') + 1]
    if '--poc' in args:
        poc_out = args[args.index('--poc') + 1]

    subprocess.run([PSQL, '-h', HOST, '-d', 'postgres', '-q', '-c',
                    "DROP DATABASE IF EXISTS %s;" % DB], capture_output=True, text=True)
    subprocess.run([PSQL, '-h', HOST, '-d', 'postgres', '-q', '-c',
                    "CREATE DATABASE %s;" % DB], capture_output=True, text=True)
    # 建结构走迁移引擎（db/migrations），不是手搓一份 DDL。
    r = subprocess.run([tc_connect_bin(), 'migrate', '--db', DB],
                       cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        print('迁移失败:\n' + (r.stderr or r.stdout)[:2000]); sys.exit(1)

    data = run()
    print_report(data)

    if json_out:
        path = json_out if os.path.isabs(json_out) else os.path.join(ROOT, json_out)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        print('JSON 已导出：%s' % path)

    if poc_out:
        from poc_page import render
        path = poc_out if os.path.isabs(poc_out) else os.path.join(ROOT, poc_out)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w', encoding='utf-8') as f:
            f.write(render(data))
        print('POC 页面已生成：%s' % path)

    # 不变量违规必须让命令失败，否则 `make check` 会带着红灯放行。
    failed = data['counts']['invariant_failures']
    if failed:
        print()
        print('演练失败：%d 条不变量违规。' % failed)
        sys.exit(1)


if __name__ == '__main__':
    sys.path.insert(0, os.path.join(ROOT, 'scripts'))
    main()
