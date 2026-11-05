#!/usr/bin/env python3
"""
无凭证集成演练（mapping dry-run）+ POC 数据导出

目的：在拿不到 aid/sid/key、Reseller ID/API Key 之前，先把「源报文 → 归一化 → 变体映射 → 路由」
这条链路用**真实报文结构**跑通一遍，并暴露当前模型表达不了的源侧结构。

分工（对应 AGENTS.md 硬约束 4 与 14）：
  - **归一化在 Go 侧**（internal/normalize，唯一实现）。本脚本通过
    `tc-connect normalize` 消费它的输出，不自己再写一份归一化；
  - 本脚本只负责：把归一化结果**落库**（演练库 ticket_center_dryrun）、
    读回路由与不变量、出报告、导出 JSON / 渲染前端 POC；
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

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FIXTURES = os.path.join(ROOT, 'fixtures')
RULES_PATH = os.path.join(ROOT, 'configs', 'mapping_rules.json')
DB = os.environ.get('DRYRUN_DB', 'ticket_center_dryrun')
PSQL = os.environ.get('PSQL_BIN', 'psql')
HOST = os.environ.get('PGHOST', '127.0.0.1')

TODAY = '2026-11-16'   # 演练基准日期（与 mapping_rules.json 的 base_date 一致）

_TC_CONNECT = None


# ---------------------------------------------------------------- 归一化（委托 Go 实现）
def tc_connect_bin():
    """找（或现场构建）tc-connect 二进制。

    归一化的**唯一实现**在 Go 侧（internal/normalize）。演练器通过 CLI 消费它的输出，
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


# ---------------------------------------------------------------- 覆盖语义（镜像 fn_variant_covered）
def covers(coverage, variant):
    """源变体的覆盖声明是否覆盖规范变体（镜像数据库函数 fn_variant_covered）。"""
    axes = (coverage or {}).get('axes', {}) or {}
    excludes = (coverage or {}).get('excludes', []) or []
    required = []
    if variant.get('audience'):
        required.append(('audience', variant['audience']))
    for axis, opt in (variant.get('axes') or {}).items():
        required.append((axis, opt))
    for axis, opt in required:
        if opt not in (axes.get(axis) or []):
            return False
        if opt in excludes:
            return False
    return True


def coverage_gaps(coverage, variant):
    """列出覆盖缺口（诊断用，不用于判定）。"""
    axes = (coverage or {}).get('axes', {}) or {}
    excludes = (coverage or {}).get('excludes', []) or []
    required = []
    if variant.get('audience'):
        required.append(('audience', variant['audience']))
    for axis, opt in (variant.get('axes') or {}).items():
        required.append((axis, opt))
    gaps = []
    for axis, opt in required:
        if opt not in (axes.get(axis) or []):
            gaps.append('%s:%s' % (axis, opt))
        elif opt in excludes:
            gaps.append('%s:%s(excluded)' % (axis, opt))
    return gaps


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
    stmts = []
    ids = {'product': 100, 'axis': 200, 'option': 300, 'ticket_type': 400, 'variant': 500}
    canon, canon_variants, product_ids = {}, {}, {}
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
            stmts.append(
                "INSERT INTO product_variant (id, product_id, variant_code, variant_key, title, variant_role, ticket_type_id, status, sort_order) "
                "VALUES (%d, %d, %s, %s, %s, 'base', %s, 'active', %d);" % (
                    vid, pid, lit(v['key'].replace(':', '-')), lit(v['key']),
                    lit(v.get('title', v['key'])), lit(ttid), vid))
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
            }
    return stmts, canon, canon_variants, product_ids


# ---------------------------------------------------------------- 主流程
def run():
    global TODAY
    rules = load_json(RULES_PATH)
    catalog = load_json(os.path.join(FIXTURES, 'canonical_catalog.json'))
    pricing_rule = rules.get('pricing', {})
    TODAY = rules.get('base_date', TODAY)

    stmts, canon, canon_variants, product_ids = build_canonical(catalog)
    stmts.append(
        "INSERT INTO channel (id, code, name, channel_type, settlement_mode, commission_rate, default_currency, tax_policy, status, config) "
        "VALUES (1,'C2C','OTA 自营 C 端','b2c_own','prepaid',0,'CNY','{\"included\":true,\"rate\":0.06}','active','{}'::jsonb);")

    sid = 600
    sp_id = 700
    sv_id = 600
    listing_id = 800
    seen_listings = set()
    primary_assigned = set()
    price_candidates = {}
    src_report = []
    unmapped = []
    source_variants_out = []
    mappings_out = []

    for src_key, rule in rules['sources'].items():
        fixture_path = os.path.join(FIXTURES, rule['fixture'])
        sid += 1
        stmts.append(
            "INSERT INTO supplier (id, code, name, short_name, country_code, default_currency, timezone, status, capability, sync_policy, connector_version) "
            "VALUES (%d, %s, %s, %s, 'CN', %s, 'Asia/Shanghai', 'active', "
            "'{\"product\":true,\"price\":true,\"session\":true,\"availability\":\"live\",\"booking\":true,\"cancel\":true}', "
            "'{\"catalog\":\"daily\"}','dryrun');" % (
                sid, lit(rule['supplier_code']), lit(rule['supplier_name']),
                lit(rule['supplier_code'][:3].upper()), lit(rule.get('currency', 'CNY'))))

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

            # 解析该源商品的源变体 + 价格
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

            # 变体级覆盖语义匹配：源变体 → 所有规范变体
            for sv in variants:
                matched_keys = []
                for vkey, v in canon_variants.items():
                    if covers(sv['coverage'], v):
                        matched_keys.append(vkey)
                        stmts.append(
                            "INSERT INTO supplier_variant_mapping (supplier_variant_id, product_variant_id, coverage, is_exact, match_type, confidence, status) "
                            "VALUES (%d, %d, %s, %s, 'rule', 0.95, 'active');" % (
                                sv_index[sv['external_id']], v['id'],
                                lit(json.dumps(sv['coverage'], ensure_ascii=False)),
                                lit(len(sv['coverage']['axes']) == len([a for a in v['axes']] ) + (1 if v['audience'] else 0))))
                        mappings_out.append({
                            'source': rule['supplier_code'], 'source_product': str(ext_pid),
                            'source_product_name': ext_pname,
                            'source_variant': sv['external_id'], 'source_variant_title': sv['title'],
                            'canonical_product': v['product_code'], 'canonical_product_title': v['product_title'],
                            'canonical_variant': vkey, 'canonical_variant_title': v['title'],
                            'coverage': sv['coverage'], 'price_locked': sv['price_locked'],
                        })
                gaps_for = []
                for vkey, v in canon_variants.items():
                    if vkey not in matched_keys:
                        g = coverage_gaps(sv['coverage'], v)
                        if g:
                            gaps_for.append({'variant': vkey, 'gaps': g})
                source_variants_out.append({
                    'source': rule['supplier_code'], 'source_product': str(ext_pid),
                    'source_product_name': ext_pname,
                    'external_id': sv['external_id'], 'title': sv['title'],
                    'coverage': sv['coverage'], 'price_locked': sv['price_locked'],
                    'matched': matched_keys, 'near_miss': gaps_for[:6],
                })

                # 源成本价：一行 = 源变体 × 规范变体 × 日期（一个变体可有多天报价）
                for pr in (prices.get(sv['external_id']) or []):
                    for vkey in matched_keys:
                        v = canon_variants[vkey]
                        stmts.append(
                            "INSERT INTO supplier_price_calendar (supplier_product_id, supplier_session_id, product_id, date, currency, supplier_price, net_price, status, product_variant_id, supplier_variant_id) "
                            "VALUES (%d, NULL, %d, %s, %s, %s, %s, 'available', %d, %d);" % (
                                sp_id, v['product_id'], lit(pr['date']), lit(pr['currency']),
                                lit(pr['sale_price']), lit(pr['net_price']),
                                v['id'], sv_index[sv['external_id']]))
                        price_candidates.setdefault(v['id'], []).append({
                            'sp_id': sp_id, 'sv_id': sv_index[sv['external_id']],
                            'date': pr['date'], 'currency': pr['currency'],
                            'sale_price': pr['sale_price'], 'net_price': pr['net_price'],
                            'locked': sv['price_locked'], 'supplier': rule['supplier_code'],
                            'source_variant': sv['external_id'],
                        })

            # 商品级映射（由变体匹配反推）：一个源商品可映射到多个规范商品
            tgt_products = []
            for vkey in {m['canonical_variant'] for m in mappings_out if m['source_product'] == str(ext_pid) and m['source'] == rule['supplier_code']}:
                pc = canon_variants[vkey]['product_code']
                if pc not in tgt_products:
                    tgt_products.append(pc)
            for pc in tgt_products:
                # 不变量 2：同一规范商品在同一供应商下最多一个 primary 映射
                key = (product_ids[pc], sid)
                is_primary = key not in primary_assigned
                if is_primary:
                    primary_assigned.add(key)
                stmts.append(
                    "INSERT INTO product_mapping (supplier_product_id, supplier_id, product_id, match_type, confidence, match_evidence, is_primary, status, created_by) "
                    "VALUES (%d, %d, %d, 'rule', 0.95, '{\"decoded_by\":\"mapping_dryrun\",\"source\":\"%s\"}', %s, 'active', 'dryrun');" % (
                        sp_id, sid, product_ids[pc], rule['supplier_code'], lit(is_primary)))

            # 上架（同一规范商品只建一个上架）
            for pc in tgt_products:
                if product_ids[pc] not in seen_listings:
                    seen_listings.add(product_ids[pc])
                    listing_id += 1
                    stmts.append(
                        "INSERT INTO channel_listing (id, channel_id, product_id, status, price_policy, stock_policy, booking_policy, min_order_qty, max_order_qty, sort_weight, published_at) "
                        "VALUES (%d, 1, %d, 'online', '{}', '{\"mode\":\"full\"}', '{\"mode\":\"instant\"}', 1, 10, 50, now());" % (
                            listing_id, product_ids[pc]))
                stmts.append(
                    "INSERT INTO channel_listing_source (channel_listing_id, supplier_product_id, supplier_id, priority, fallback_order, min_margin, max_daily_qty, enabled) "
                    "SELECT (SELECT cl.id FROM channel_listing cl WHERE cl.product_id = %d LIMIT 1), %d, %d, %d, %d, 0.10, NULL, true;" % (
                        product_ids[pc], sp_id, sid, 10 * len(src_report) + 10, len(src_report) + 1))
            src_report.append({'source': rule['supplier_code'], 'sp_id': sp_id,
                                'external_id': str(ext_pid), 'name': ext_pname,
                                'variants': len(variants)})

        # 组合表达式（Go 侧解析，语法已核实：SKU / SKU|2 / A|2+B|1）
        for expr in norm.get('composite_expressions') or []:
            if not expr['is_composite']:
                continue
            union = {'axes': {}, 'excludes': []}
            for part in expr['parts']:
                src_sv = next((x for x in source_variants_out
                               if x['source'] == rule['supplier_code'] and x['external_id'] == part['sku_id']), None)
                if not src_sv:
                    continue
                for ax, opts in src_sv['coverage']['axes'].items():
                    union['axes'].setdefault(ax, [])
                    for o in opts:
                        if o not in union['axes'][ax]:
                            union['axes'][ax].append(o)
            hit = [vkey for vkey, v in canon_variants.items() if covers(union, v)]
            unmapped.append({'source': rule['supplier_code'], 'our_variant': expr['our_variant'],
                             'mapping_id': expr['mapping_id'], 'parts': expr['parts'],
                             'union': union, 'would_cover': hit})

    # ---- 对客售价：一个变体一行，取采纳成本最低的源
    for tgt, cands in price_candidates.items():
        best = min(cands, key=lambda c: (float(c['net_price'] or 0), c['supplier']))
        net = best['net_price'] or 0
        if best['locked'] and pricing_rule.get('price_locked_uses_source_list_price'):
            sell, locked = best['sale_price'], True
        else:
            sell = round(float(net) * (1 + pricing_rule.get('markup_percent', 10.0) / 100.0), 2)
            locked = False
        v = next(v for v in canon_variants.values() if v['id'] == tgt)
        stmts.append(
            "INSERT INTO price_calendar (product_id, session_id, ticket_type_id, channel_id, date, currency, cost_price, cost_source_product_id, sell_price, list_price, discount_pct, rule, status, source, product_variant_id, price_locked) "
            "VALUES (%d, NULL, NULL, NULL, %s, %s, %s, %d, %s, %s, 0, '{}', 'active', 'sync', %d, %s);" % (
                v['product_id'], lit(best['date']), lit(best['currency']), lit(net), best['sp_id'],
                lit(sell), lit(sell), tgt, lit(locked)))

    stmts = with_identity(stmts)
    script = '\n'.join(stmts)
    with open('/tmp/dryrun_seed.sql', 'w', encoding='utf-8') as f:
        f.write(script)
    r = subprocess.run([PSQL, '-h', HOST, '-d', DB, '-v', 'ON_ERROR_STOP=1', '-q', '-f', '/tmp/dryrun_seed.sql'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print('演练数据落库失败:\n' + r.stderr[:3000]); sys.exit(1)

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
            'supplier': row[4], 'source_variant': row[5], 'net_price': float(row[6] or 0),
            'cost_base': float(row[7] or 0), 'route_rank': int(row[8]), 'currency': row[9],
            'sell_price': float(row[10] or 0), 'price_locked': row[11] == 't', 'date': row[12],
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
                'axis_names': {a['code']: a['name'] for a in p.get('axes', [])},
                'option_names': {o['code']: o['name'] for a in p.get('axes', []) for o in a['options']},
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
        'gaps': unmapped,
        'invariants': invariants,
        'counts': {
            'source_products': len(src_report),
            'source_variants': len(source_variants_out),
            'mappings': len(mappings_out),
            'canonical_variants': len(canonical_out),
            'routing_rows': len(routing),
            'gaps': len(unmapped),
            'invariant_failures': len([i for i in invariants if i['result'] != 'PASS']),
        },
    }


def print_report(d):
    print('=' * 82)
    print('无凭证集成演练：源报文 → 归一化 → 变体映射 → 路由')
    print('演练库：%s   基准日期：%s' % (DB, d['base_date']))
    print('=' * 82)
    c = d['counts']
    print('源商品 %d · 源变体 %d · 变体映射 %d · 规范变体 %d · 路由候选 %d · 模型缺口 %d · 不变量违规 %d'
          % (c['source_products'], c['source_variants'], c['mappings'], c['canonical_variants'],
             c['routing_rows'], c['gaps'], c['invariant_failures']))
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
    print('── ② 覆盖语义匹配 ────────────────────────────────────────')
    for m in d['mappings']:
        print('  %-24s ← %-10s %-26s%s' % (m['canonical_variant'], m['source'], m['source_variant'],
                                          '  [价格保护]' if m['price_locked'] else ''))
    print()
    print('── ③ 变体级路由（route_rank=1 = 首选源）────────────────────')
    for r in d['routing']:
        print('  %-26s ← %-10s %-26s net=%-9s rank=%s%s' % (
            r['variant_key'], r['supplier'], r['source_variant'], r['net_price'], r['route_rank'],
            '  [锁价]' if r['price_locked'] else ''))
    print()
    print('── ④ 当前模型表达不了的源侧结构 ──────────────────────────')
    if not d['gaps']:
        print('  （无）')
    for u in d['gaps']:
        parts = ' + '.join('%s×%d' % (p['sku_id'], p['qty']) for p in u['parts'])
        print('  ✗ %s · 我们的变体 %s' % (u['source'], u['our_variant']))
        print('      mappingId = %s' % u['mapping_id'])
        print('      拆解 = %s' % parts)
        print('      并集覆盖 = %s' % json.dumps(u['union']['axes'], ensure_ascii=False))
        print('      可覆盖 = %s' % ', '.join(u['would_cover']))
        print('      → 一个可售单元由 %d 个源 SKU 组成，单个 supplier_variant 无法表达' % len(u['parts']))
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
    r = subprocess.run([PSQL, '-h', HOST, '-d', DB, '-v', 'ON_ERROR_STOP=1', '-q', '-f',
                        os.path.join(ROOT, 'db', 'schema.sql')], capture_output=True, text=True)
    if r.returncode != 0:
        print('schema.sql 执行失败:\n' + r.stderr[:2000]); sys.exit(1)

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
    # 模型缺口（组合表达式表达不了）不算失败，那是已知待办，在报告 ④ 里单独列。
    failed = data['counts']['invariant_failures']
    if failed:
        print()
        print('演练失败：%d 条不变量违规。' % failed)
        sys.exit(1)


if __name__ == '__main__':
    sys.path.insert(0, os.path.join(ROOT, 'scripts'))
    main()
