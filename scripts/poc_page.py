#!/usr/bin/env python3
"""
前端 POC 渲染器：把演练结果渲染成单文件 HTML（数据内嵌，离线可看）。

用法：python3 scripts/mapping_dryrun.py --poc scripts/poc/index.html
"""

import json

CSS = """
*{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#0b1020; --bg2:#121a2e; --card:#161f36; --card2:#1b2540;
  --line:#26324f; --line2:#33415f;
  --fg:#dbe4f5; --fg2:#93a3c4; --fg3:#63739a;
  --accent:#5aa2ff; --accent2:#7c5cff;
  --ok:#3fd08a; --warn:#f0b429; --bad:#ff6b6b;
  --tc:#4d8dff; --gt:#ff9f43;
  --mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,monospace;
}
body{background:radial-gradient(1200px 700px at 12% -8%,#1b2a4d 0%,transparent 60%),var(--bg);
  color:var(--fg);font:14px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft Yahei",Segoe UI,sans-serif;
  padding:28px 32px 60px;max-width:1560px;margin:0 auto}
a{color:var(--accent);text-decoration:none}
header{display:flex;justify-content:space-between;align-items:flex-end;gap:24px;flex-wrap:wrap;
  padding-bottom:18px;border-bottom:1px solid var(--line);margin-bottom:22px}
h1{font-size:23px;font-weight:650;letter-spacing:.2px}
h1 .dot{display:inline-block;width:9px;height:9px;border-radius:50%;background:var(--ok);
  margin-right:10px;box-shadow:0 0 12px var(--ok);vertical-align:middle}
.sub{color:var(--fg2);font-size:13px;margin-top:7px}
.sub code{font-family:var(--mono);background:var(--card);padding:1px 6px;border-radius:5px;color:var(--accent);font-size:12px}
.stats{display:flex;gap:9px;flex-wrap:wrap}
.stat{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:9px 15px;min-width:86px}
.stat b{display:block;font-size:20px;font-family:var(--mono);letter-spacing:-.4px}
.stat span{font-size:11px;color:var(--fg3)}
.stat.ok b{color:var(--ok)} .stat.bad b{color:var(--bad)} .stat.warn b{color:var(--warn)}
.tabs{display:flex;gap:8px;margin-bottom:20px;flex-wrap:wrap}
.tab{background:var(--card);border:1px solid var(--line);color:var(--fg2);padding:8px 16px;border-radius:9px;
  cursor:pointer;font-size:13px;transition:.15s;user-select:none}
.tab:hover{border-color:var(--line2);color:var(--fg)}
.tab.on{background:var(--card2);border-color:var(--accent);color:var(--fg);box-shadow:0 0 0 1px rgba(90,162,255,.15)}
.tab .n{font-family:var(--mono);color:var(--fg3);margin-left:6px;font-size:12px}
.tab.on .n{color:var(--accent)}
.grid{display:grid;grid-template-columns:minmax(430px,1fr) minmax(520px,1.25fr);gap:18px;align-items:start}
@media(max-width:1180px){.grid{grid-template-columns:1fr}}
.card{background:var(--card);border:1px solid var(--line);border-radius:13px;overflow:hidden;margin-bottom:18px}
.card>h2{font-size:13px;font-weight:600;padding:13px 17px;border-bottom:1px solid var(--line);
  color:var(--fg);display:flex;justify-content:space-between;align-items:center;gap:12px;background:var(--card2)}
.card>h2 .hint{font-weight:400;color:var(--fg3);font-size:11.5px;font-family:var(--mono)}
.pad{padding:14px 17px}
.prod{margin-bottom:16px}
.prod:last-child{margin-bottom:0}
.prod-h{font-size:13px;color:var(--fg);font-weight:600;margin-bottom:4px;display:flex;align-items:center;gap:8px}
.prod-h code{font-family:var(--mono);font-size:11px;color:var(--fg3);background:var(--bg2);padding:1px 7px;border-radius:5px}
.prod-sub{font-size:11.5px;color:var(--fg3);margin-bottom:9px}
.vrow{display:grid;grid-template-columns:1fr auto;gap:10px;align-items:center;
  padding:9px 11px;background:var(--bg2);border:1px solid var(--line);border-radius:9px;margin-bottom:7px}
.vrow:hover{border-color:var(--line2)}
.vrow .vk{font-family:var(--mono);font-size:12px;color:var(--fg);word-break:break-all}
.vrow .vt{font-size:11.5px;color:var(--fg3);margin-top:2px}
.chips{display:flex;gap:5px;flex-wrap:wrap;margin-top:6px}
.chip{font-size:10.5px;font-family:var(--mono);padding:2px 8px;border-radius:999px;
  background:rgba(90,162,255,.12);color:#9cc6ff;border:1px solid rgba(90,162,255,.25)}
.chip.ax{background:rgba(124,92,255,.12);color:#c1b0ff;border-color:rgba(124,92,255,.28)}
.badge{font-size:10px;padding:2px 7px;border-radius:5px;font-family:var(--mono);white-space:nowrap}
.b-ok{background:rgba(63,208,138,.13);color:var(--ok);border:1px solid rgba(63,208,138,.3)}
.b-lock{background:rgba(240,180,41,.13);color:var(--warn);border:1px solid rgba(240,180,41,.3)}
.b-bad{background:rgba(255,107,107,.13);color:var(--bad);border:1px solid rgba(255,107,107,.3)}
.b-mut{background:rgba(99,115,154,.15);color:var(--fg3);border:1px solid rgba(99,115,154,.3)}
.b-src{font-family:var(--mono);font-size:10.5px;padding:2px 7px;border-radius:5px}
.s-trip{background:rgba(77,141,255,.15);color:var(--tc);border:1px solid rgba(77,141,255,.32)}
.s-gt{background:rgba(255,159,67,.14);color:var(--gt);border:1px solid rgba(255,159,67,.3)}
table{width:100%;border-collapse:collapse;font-size:12.5px}
th{text-align:left;font-weight:500;color:var(--fg3);font-size:11px;padding:8px 10px;border-bottom:1px solid var(--line);
  text-transform:uppercase;letter-spacing:.4px}
td{padding:8px 10px;border-bottom:1px solid rgba(38,50,79,.55);vertical-align:top}
tr:last-child td{border-bottom:none}
tr:hover td{background:rgba(90,162,255,.045)}
td.mono,th.mono{font-family:var(--mono);font-size:11.5px}
.num{text-align:right;font-family:var(--mono);font-size:11.5px}
.rk{display:inline-block;width:17px;height:17px;line-height:16px;text-align:center;border-radius:5px;
  font-family:var(--mono);font-size:10.5px;background:var(--bg2);color:var(--fg3);border:1px solid var(--line2)}
.rk.r1{background:rgba(63,208,138,.16);color:var(--ok);border-color:rgba(63,208,138,.4)}
.gap{background:rgba(255,107,107,.06);border:1px solid rgba(255,107,107,.26);border-radius:11px;padding:15px 17px;margin-bottom:18px}
.gap h3{font-size:13.5px;color:var(--bad);margin-bottom:9px;display:flex;align-items:center;gap:8px}
.gap .mp{font-family:var(--mono);font-size:11.5px;color:var(--warn);background:rgba(240,180,41,.08);
  border:1px solid rgba(240,180,41,.22);border-radius:7px;padding:9px 11px;margin:7px 0;word-break:break-all}
.gap ul{margin:7px 0 0 17px;color:var(--fg2);font-size:12px}
.gap li{margin:3px 0}
.inv{display:grid;grid-template-columns:repeat(auto-fill,minmax(255px,1fr));gap:5px;padding:13px 17px}
.i{display:flex;gap:8px;align-items:center;font-size:11.5px;padding:4px 8px;background:var(--bg2);border-radius:6px;border:1px solid var(--line)}
.i .no{font-family:var(--mono);color:var(--fg3);font-size:10.5px;min-width:18px}
.i.pass .dot{background:var(--ok)} .i.fail .dot{background:var(--bad)}
.i .dot{width:6px;height:6px;border-radius:50%;flex:0 0 6px}
.i.fail{color:var(--bad);border-color:rgba(255,107,107,.3)}
footer{margin-top:26px;padding-top:16px;border-top:1px solid var(--line);color:var(--fg3);font-size:11.5px;
  display:flex;justify-content:space-between;gap:18px;flex-wrap:wrap}
.legend{display:flex;gap:13px;flex-wrap:wrap;font-size:11px;color:var(--fg3);margin-top:9px}
.legend i{display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:5px;vertical-align:middle}
"""

JS = """
const D = window.__DATA__;
let filter = 'ALL';

const srcCls = s => s === 'trip_com' ? 's-trip' : 's-gt';
const srcName = s => s === 'trip_com' ? 'Trip.com' : 'GlobalTix';
const money = n => (n==null?0:n).toFixed(2);

function variantRow(v){
  const chips = Object.entries(v.axes||{}).map(([a,o])=>
      `<span class="chip ax">${a}=${o}</span>`).join('');
  const aud = v.audience ? `<span class="chip">${v.audience}</span>` : '';
  const routes = D.routing.filter(r=>r.variant_key===v.key);
  const isCombo = v.variant_role === 'combo';
  const comps = isCombo ? D.compositions.filter(c=>c.our_variant===v.key) : [];
  const rk = isCombo
    ? `<span class="badge b-ok">组合 · ${comps.length} 成分</span>`
    : (routes.length ? `<span class="badge b-ok">${routes.length} 源可履约</span>` : `<span class="badge b-bad">无源可履约</span>`);
  const gap = D.gaps.find(g=>g.our_variant===v.key);
  const gapb = gap ? `<span class="badge b-bad">组合解不出来</span>` : '';
  const compList = isCombo
    ? `<div class="chips">${(v.components||[]).map(c=>`<span class="chip ax">${c.variant} × ${c.quantity}</span>`).join('')}</div>`
    : '';
  return `<div class="vrow">
    <div>
      <div class="vk">${v.key}</div>
      <div class="vt">${v.title||''}</div>
      <div class="chips">${aud}${chips}</div>
      ${compList}
    </div>
    <div style="text-align:right;display:flex;flex-direction:column;gap:5px;align-items:flex-end">${rk}${gapb}</div>
  </div>`;
}

function matrixHTML(){
  const prods = D.canonical_products;
  return prods.map(p=>{
    const vs = D.canonical_variants.filter(v=>v.product_code===p.code);
    const axes = p.axes.map(a=>`<span class="chip">${a.code}: ${a.options.map(o=>o.code).join(' / ')}</span>`).join('');
    return `<div class="prod">
      <div class="prod-h">${p.title} <code>${p.code}</code></div>
      <div class="prod-sub">${vs.length} 个可售变体 · ${p.ticket_types.length} 个人群 · 维度：${axes}</div>
      ${vs.map(variantRow).join('')}
    </div>`;
  }).join('');
}

function matchHTML(){
  const rows = D.mappings.filter(m=>filter==='ALL'||m.source===filter)
    .slice().sort((a,b)=> a.canonical_variant.localeCompare(b.canonical_variant)
                       || a.source.localeCompare(b.source));
  if(!rows.length) return '<div class="pad" style="color:var(--fg3)">该源没有变体级映射</div>';
  return `<table><thead><tr>
      <th>规范变体</th><th>源</th><th>源变体</th><th>覆盖声明 coverage.axes</th><th>判定</th>
    </tr></thead><tbody>` + rows.map(m=>`
      <tr>
        <td class="mono">${m.canonical_variant}</td>
        <td><span class="badge b-src ${srcCls(m.source)}">${srcName(m.source)}</span></td>
        <td class="mono">${m.source_variant}<div style="color:var(--fg3);font-size:10.5px">${(m.source_variant_title||'')}</div></td>
        <td class="mono" style="font-size:10.5px;color:var(--fg2)">${JSON.stringify(m.coverage.axes)}</td>
        <td>${m.price_locked?'<span class="badge b-lock">价格保护</span>':'<span class="badge b-ok">可履约</span>'}</td>
      </tr>`).join('') + '</tbody></table>';
}

function routingHTML(){
  const rows = D.routing.filter(m=>filter==='ALL'||m.supplier===filter);
  if(!rows.length) return '<div class="pad" style="color:var(--fg3)">该源没有路由候选</div>';
  return `<table><thead><tr>
      <th></th><th>规范变体</th><th>源</th><th>源变体</th>
      <th class="num">源净价</th><th class="num">折算成本</th><th class="num">对客售价</th><th>状态</th>
    </tr></thead><tbody>` + rows.map(r=>`
      <tr>
        <td><span class="rk ${r.route_rank===1?'r1':''}">${r.route_rank}</span></td>
        <td class="mono">${r.variant_key}</td>
        <td><span class="badge b-src ${srcCls(r.supplier)}">${srcName(r.supplier)}</span></td>
        <td class="mono" style="font-size:10.5px">${r.source_variant}</td>
        <td class="num">${money(r.net_price)}</td>
        <td class="num" style="color:var(--fg2)">${money(r.cost_base)}</td>
        <td class="num" style="color:var(--ok)">${money(r.sell_price)}</td>
        <td>${r.price_locked?'<span class="badge b-lock">锁价</span>':'<span class="badge b-mut">可定价</span>'}</td>
      </tr>`).join('') + '</tbody></table>';
}

function composeHTML(){
  if(!D.compositions.length && !D.gaps.length) return '';
  const byCombo = {};
  D.compositions.forEach(c=>{
    (byCombo[c.our_variant] = byCombo[c.our_variant] || []).push(c);
  });
  const ok = Object.keys(byCombo).map(k=>`
    <div class="gap">
      <h3 style="color:var(--ok)">✓ 组合映射已解出配方</h3>
      <div style="font-size:12.5px;color:var(--fg2)">
        规范变体 <code style="font-family:var(--mono);color:var(--accent)">${k}</code>
        由 ${byCombo[k].length} 个源 SKU 组成（方向 B）：
      </div>
      <ul>
        ${byCombo[k].map(c=>`<li>${c.component} × ${c.source_quantity}
          ← 源 SKU <span class="mono">${c.source_variant}</span>（${srcName(c.source)}）
          ${Number(c.source_quantity)===Number(c.declared_quantity)?'':'<span style="color:var(--bad)">与声明数量不一致</span>'}</li>`).join('')}
      </ul>
    </div>`).join('');
  const bad = D.gaps.map(g=>`
    <div class="gap">
      <h3 style="color:var(--bad)">⚠ 解不出来的组合</h3>
      <div style="font-size:12.5px;color:var(--fg2)">
        源 <b style="color:var(--gt)">${srcName(g.source)}</b> 用一个组合表达式表达我们的变体
        <code style="font-family:var(--mono);color:var(--accent)">${g.our_variant}</code>：
      </div>
      <div class="mp">${g.mapping_id}</div>
      <ul>
        <li>拆解：${g.parts.map(p=>p.sku_id+' × '+p.qty).join('  +  ')}</li>
        <li style="color:var(--bad)">${(g.detail||'').trim().split('\n')[0]||'解不出来'}</li>
      </ul>
    </div>`).join('');
  return ok + bad;
}

function invariantsHTML(){
  return `<div class="inv">` + D.invariants.map(i=>`
    <div class="i ${i.result==='PASS'?'pass':'fail'}">
      <span class="no">${i.seq}</span><span class="dot"></span>
      <span>${i.name}</span>
    </div>`).join('') + '</div>';
}

function render(){
  const c = D.counts;
  document.getElementById('stats').innerHTML = `
    <div class="stat"><b>${c.source_products}</b><span>源商品</span></div>
    <div class="stat"><b>${c.source_variants}</b><span>源变体</span></div>
    <div class="stat"><b>${c.canonical_variants}</b><span>规范变体</span></div>
    <div class="stat"><b>${c.mappings}</b><span>变体映射</span></div>
    <div class="stat"><b>${c.routing_rows}</b><span>路由候选</span></div>
    <div class="stat ${c.gaps?'warn':'ok'}"><b>${c.compositions}</b><span>组合配方</span></div>
    <div class="stat ${c.gaps?'warn':'ok'}"><b>${c.gaps}</b><span>解不出的组合</span></div>
    <div class="stat ${c.invariant_failures?'bad':'ok'}"><b>${D.invariants.length - c.invariant_failures}/${D.invariants.length}</b><span>不变量</span></div>`;

  document.getElementById('tabs').innerHTML =
    `<div class="tab ${filter==='ALL'?'on':''}" data-f="ALL">全部<span class="n">${D.source_variants.length}</span></div>` +
    Object.keys(D.sources).map(k=>{
      const n = D.source_variants.filter(s=>s.source===D.sources[k].supplier_code).length;
      const m = D.mappings.filter(s=>s.source===D.sources[k].supplier_code).length;
      return `<div class="tab ${filter===D.sources[k].supplier_code?'on':''}" data-f="${D.sources[k].supplier_code}">${D.sources[k].supplier_name}<span class="n">${n} 变体 / ${m} 映射</span></div>`;
    }).join('');
  document.querySelectorAll('.tab').forEach(el=>el.onclick=()=>{filter=el.dataset.f;render();});

  document.getElementById('matrix').innerHTML = matrixHTML();
  document.getElementById('match').innerHTML = matchHTML();
  document.getElementById('routing').innerHTML = routingHTML();
  document.getElementById('gaps').innerHTML = composeHTML();
  document.getElementById('inv').innerHTML = invariantsHTML();
}
render();
"""


def render(data):
    payload = json.dumps(data, ensure_ascii=False).replace('</', '<\\/')
    return """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>票券中台 · 变体映射 POC</title>
<style>%s</style>
</head>
<body>
<header>
  <div>
    <h1><span class="dot"></span>多源票券 · 变体映射 POC</h1>
    <div class="sub">无凭证集成演练：源报文 → 归一化 → <b>覆盖语义匹配</b> → 变体级路由 → <b>组合映射</b>　·　演练库 <code>ticket_center_dryrun</code>　·　基准日期 <code>%s</code></div>
  </div>
  <div class="stats" id="stats"></div>
</header>

<div class="tabs" id="tabs"></div>

<div class="grid">
  <div>
    <div class="card">
      <h2>规范变体矩阵 <span class="hint">product → product_variant → 轴取值</span></h2>
      <div class="pad" id="matrix"></div>
    </div>
  </div>
  <div>
    <div class="card">
      <h2>覆盖语义匹配 <span class="hint">source_variant → product_variant（coverage 判定）</span></h2>
      <div id="match"></div>
    </div>
    <div class="card">
      <h2>变体级路由 <span class="hint">route_rank=1 即该组合的首选源</span></h2>
      <div id="routing"></div>
    </div>
  </div>
</div>

<div class="card">
  <h2>组合映射 <span class="hint">方向 B：一个可售单元由多个源 SKU 按数量组成</span></h2>
  <div id="gaps"></div>
</div>

<div class="card">
  <h2>不变量自检 <span class="hint">演练库实跑 v_invariant_checks</span></h2>
  <div id="inv"></div>
</div>

<footer>
  <div>
    <div class="legend">
      <span><i style="background:var(--ok)"></i>可履约 / 首选源</span>
      <span><i style="background:var(--warn)"></i>锁价（源侧价格保护）</span>
      <span><i style="background:var(--bad)"></i>不可履约 / 模型缺口</span>
      <span><i style="background:var(--tc)"></i>Trip.com</span>
      <span><i style="background:var(--gt)"></i>GlobalTix</span>
    </div>
  </div>
  <div>数据来源：<code>fixtures/*.json</code>（真实报文结构 mock）　·　映射规则：<code>configs/mapping_rules.json</code></div>
</footer>

<script>window.__DATA__=%s;</script>
<script>%s</script>
</body>
</html>""" % (CSS, data.get('base_date', ''), payload, JS)


if __name__ == '__main__':
    import json as _json, sys
    with open(sys.argv[1], encoding='utf-8') as f:
        print(render(_json.load(f)))
