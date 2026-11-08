#!/usr/bin/env python3
"""下单链路的端到端演示：找一天有售价的日期 → 下单 → 查单。

为什么要有这个脚本：
  - 下单请求里的 visit_date 必须落在有售价的那一天，而种子数据用
    current_date+N 写日期 —— 写死日期的样例文件过几天就失效；
  - 顺便把「幂等」演示一遍：同一个幂等键跑两次，第二次是幂等命中。

只依赖标准库（subprocess + json），不引第三方包。

用法：
    python3 scripts/order_demo.py [--db ticket_center] [--variant 9]
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "bin", "tc-connect")


def psql(db, sql):
    """跑一条 SQL，返回第一列（去掉首尾空白）。"""
    cmd = [
        "psql", "-h", os.environ.get("PGHOST", "127.0.0.1"),
        "-d", db, "-t", "-A", "-c", sql,
    ]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit("psql 失败：%s" % out.stderr.strip())
    return out.stdout.strip()


def priced_date(db, variant_id):
    """该变体第一个有售价的日期。"""
    d = psql(
        db,
        "SELECT date::text FROM price_calendar "
        "WHERE product_variant_id = %d AND status = 'active' "
        "ORDER BY date LIMIT 1;" % variant_id,
    )
    if not d:
        sys.exit("变体 %d 在库里没有售价行，先跑 make db" % variant_id)
    return d


def required_fields(db, variant_id):
    """该变体必填的实名字段。

    先看变体级要求（`checkout_requirement.product_variant_id`）；
    没有就退回商品 + 票种级要求 —— 与 `fn_place_order` 的校验口径一致。
    """
    rows = psql(
        db,
        "SELECT cr.field_code FROM checkout_requirement cr "
        "WHERE cr.required AND cr.product_variant_id = %d ORDER BY cr.sort_order;"
        % variant_id,
    )
    fields = [r for r in rows.splitlines() if r]
    if fields:
        return fields

    rows = psql(
        db,
        "SELECT cr.field_code FROM checkout_requirement cr "
        "JOIN product_variant pv ON pv.product_id = cr.product_id "
        "WHERE cr.required AND pv.id = %d "
        "  AND (cr.ticket_type_id IS NULL "
        "       OR cr.ticket_type_id = pv.ticket_type_id) "
        "ORDER BY cr.sort_order;" % variant_id,
    )
    return [r for r in rows.splitlines() if r]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=os.environ.get("PGDATABASE", "ticket_center"))
    ap.add_argument("--variant", type=int, default=9)
    ap.add_argument("--quantity", type=int, default=2)
    ap.add_argument("--channel", type=int, default=1)
    ap.add_argument("--customer", type=int, default=3)
    args = ap.parse_args()

    if not os.path.exists(BIN):
        sys.exit("先跑 make build（%s 不存在）" % BIN)

    date = priced_date(args.db, args.variant)
    fields = required_fields(args.db, args.variant)
    if not fields:
        sys.exit("变体 %d 没有实名要求，查一下 checkout_requirement" % args.variant)

    holders = []
    for seq in range(1, args.quantity + 1):
        for field in fields:
            holders.append({
                "variant_id": args.variant,
                "sequence": seq,
                "field_code": field,
                "value": "演示值%s%d" % (field, seq),
            })

    request = {
        "channel_id": args.channel,
        "customer_id": args.customer,
        "idempotency_key": "order-demo-%s-%d" % (date, args.variant),
        "items": [{
            "variant_id": args.variant,
            "quantity": args.quantity,
            "visit_date": date,
        }],
        "holders": holders,
        "contact": {"phone": "13800000000"},
        "buyer_note": "",
    }

    print("── 下单请求（变体 %d × %d，访客日 %s）────────────────────" % (
        args.variant, args.quantity, date))
    print(json.dumps(request, ensure_ascii=False, indent=2))

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False,
                                     encoding="utf-8") as f:
        json.dump(request, f, ensure_ascii=False)
        path = f.name

    try:
        print("\n── 第一次下单 ────────────────────────────────────────")
        run([BIN, "order", "place", "--db", args.db, "--request", path])
        print("\n── 重复同一请求（幂等）───────────────────────────────")
        run([BIN, "order", "place", "--db", args.db, "--request", path])
        print("\n── 查单 ────────────────────────────────────────────")
        order_id = latest_order_id(args.db)
        run([BIN, "order", "show", "--db", args.db, "--id", str(order_id)])
    finally:
        os.unlink(path)


def latest_order_id(db):
    return psql(db, "SELECT id FROM sales_order ORDER BY id DESC LIMIT 1;")


def run(cmd):
    out = subprocess.run(cmd, capture_output=True, text=True)
    sys.stdout.write(out.stdout)
    if out.returncode != 0:
        sys.stdout.write(out.stderr)
        sys.exit(out.returncode)


if __name__ == "__main__":
    main()
