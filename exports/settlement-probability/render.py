import json
from fractions import Fraction
from html import escape as esc
from pathlib import Path
root=Path(__file__).parent
model=json.loads((root/'model.json').read_text())
paths=model['paths']
def event(e):
 return f'<strong>{esc(e["label"])}</strong><span>{esc(e["src"])} → {esc(e["dst"])}</span>'
def prob(q):
 return f'{q} <span class="muted">({float(q)*100:g}%)</span>'
common=[]
for i,e in enumerate(paths[0]['events']):
 if all(len(p['events'])>i and p['events'][i]==e for p in paths): common.append(e)
 else: break
n=len(common)
groups={}
for p in paths: groups.setdefault(p['events'][n]['label'],[]).append(p)
parts=['<!doctype html><html><head><meta charset="utf-8"><style>']
parts.append('''
:root{color-scheme:light dark}body{font-family:var(--font-sans);color:var(--foreground);margin:0;font-size:14px}*{box-sizing:border-box}.muted,small{color:var(--muted-foreground)}p{line-height:1.5}.flow{display:flex;flex-direction:column;align-items:center}.node{padding:12px 16px;border:1px solid var(--border);border-radius:var(--radius);background:var(--card);text-align:center;min-width:240px}.node span,.leaf span{display:block;margin-top:4px;font-size:12px}.arrow{height:24px;line-height:24px;color:var(--muted-foreground)}.trigger{border-color:var(--chart-1)}.fork{display:flex;gap:16px;width:100%;margin-top:16px;align-items:stretch}.group{flex:1;min-width:0;border-top:2px solid var(--chart-1);padding-top:12px}.branch{text-align:center;margin-bottom:12px;font-size:17px;font-weight:650}.leaves{display:flex;gap:10px}.leaf{flex:1;min-width:0;padding:12px;border:1px solid var(--border);border-radius:var(--radius);background:var(--card);text-align:center}.leaf strong{font-size:12px;overflow-wrap:anywhere}.day{font-size:20px;font-weight:650;margin:10px 0}.ok{color:var(--success)}.bad{color:var(--destructive)}.status{margin-top:12px;font-weight:650}.conditional{font-size:13px;margin-bottom:12px}.mass{margin-top:12px;padding-top:10px;border-top:1px solid var(--border);font-size:12px}.foot{font-size:12px;margin-top:18px}details{font-size:12px;color:var(--muted-foreground);margin-top:12px}summary{cursor:pointer}@media(max-width:520px){.fork{flex-direction:column}.node{min-width:0;width:100%}}
''')
parts.append('</style></head><body><p class="muted">Declared illustrative probabilities · one settlement · fixed 24-hour days</p><div class="flow">')
for e in common: parts.append('<div class="node">'+event(e)+'</div><div class="arrow">↓</div>')
o=paths[0]['obligations'][0]
clock=next(a for a in model['metadata']['annotations'] if a['kind']=='clock')
parts.append(f'<div class="node trigger"><strong>Settlement clock starts</strong><span>max({", ".join("time("+esc(r)+")" for r in clock["refs"])})</span><span>Return deposit or itemize deductions within {(o["deadlineMs"]-o["triggerMs"])//86400000} days</span></div><div class="arrow">↓</div><div>Landlord chooses</div><div class="fork">')
for label,ps in groups.items():
 mass=sum((Fraction(p['probability']) for p in ps),Fraction(0))
 parts.append(f'<section class="group" style="flex:{len(ps)}"><div class="branch">{prob(mass)}</div><div class="leaves">')
 for p in ps:
  q=Fraction(p['probability']);o=p['obligations'][0];cond=q/mass
  parts.append('<div class="leaf">')
  if len(ps)>1: parts.append(f'<div class="conditional">Timing sample<br><b>{prob(cond)}</b></div>')
  for e in p['events'][n:]:
   day=(e['time']-o['triggerMs'])/86400000
   parts.append(f'<div class="day">Day {day:g}</div>'+event(e))
  status=o['status'];parts.append(f'<div class="status {"bad" if status=="violated" else "ok"}">{esc(status.capitalize())}</div><div class="mass">Probability of this path<br><b>{prob(q)}</b></div></div>')
 parts.append('</div></section>')
parts.append('</div></div><p class="foot">The day-25 return remains structurally legal but violates the deadline. The breach is a monitor record, not a message. Probabilities are assumptions, not measured frequencies.</p><details><summary>Model and derivation</summary>')
for k in ['prompt','question','source','reducer','unit','boundary']: parts.append(f'<p><b>{k.capitalize()}:</b> {esc(model[k])}</p>')
parts.append('</details></body></html>')
(root/'diagram.html').write_text(''.join(parts))
