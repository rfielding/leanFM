import json
from fractions import Fraction
from html import escape as esc
from pathlib import Path
r=Path(__file__).parent
m=json.loads((r/'model.json').read_text()); paths=m['paths']; groups={}
for p in paths: groups.setdefault(p['events'][2]['label'],[]).append(p)
assert len(groups)==2 and sorted(map(len,groups.values()))==[1,2]
svg=[]
def text(x,y,s,cls='label'):
 svg.append(f'<text x="{x}" y="{y}" text-anchor="middle" class="{cls}">{esc(str(s))}</text>')
def node(x,y,lines,status=''):
 svg.append(f'<rect x="{x-96}" y="{y-34}" width="192" height="68" rx="12" class="state {status}"/>')
 for i,line in enumerate(lines): text(x,y-10+i*20,line,'label '+('good' if status=='fulfilled' and i==len(lines)-1 else 'bad' if status=='violated' and i==len(lines)-1 else ''))
def edge(x1,y1,x2,y2,prob=None,lx=None,ly=None):
 svg.append(f'<path d="M{x1} {y1} L{x2} {y2}" class="edge" marker-end="url(#arr)"/>')
 if prob: text(lx if lx is not None else (x1+x2)/2,ly if ly is not None else (y1+y2)/2,prob,'edgeLabel')
node(360,50,['Lease has ended','Address not yet received'])
edge(360,84,360,176)
text(360,117,'ForwardingAddress · p = 1','edgeLabel')
text(360,142,'settlement = max(time(ended), time(address))','small')
node(360,210,['Settlement pending','Deadline: day 14'])
items=list(groups.items())
for idx,(label,ps) in enumerate(items):
 x=180 if len(ps)==2 else 560
 mass=sum((Fraction(p['probability']) for p in ps),Fraction())
 edge(310 if x==180 else 410,244,x,314)
 text(190 if x==180 else 555,269,f'Policy: {mass}','edgeLabel')
 svg.append(f'<circle cx="{x}" cy="335" r="20" class="action"/>')
 text(x,340,'a'+str(idx+1),'actionLabel')
 text(x,383,'Return deposit' if len(ps)==2 else 'Itemize deductions')
 for j,p in enumerate(ps):
  dest=110 if len(ps)==2 and j==0 else 330 if len(ps)==2 else 560
  q=Fraction(p['probability'])/mass; ev=p['events'][2]; day=ev['time']//86400000
  edge(x,355,dest,466)
  text(64 if dest==110 else 324 if dest==330 else 620,422,f'p = {q}','edgeLabel')
  status=p['obligations'][0]['status']
  node(dest,500,['Deposit returned' if len(ps)==2 else 'Deductions itemized',f'Day {day} · {status}'],status)
  if len(p['events'])>3:
   last=p['events'][3]
   edge(dest,534,dest,626)
   text(dest,575,last['label']+' · p = 1','edgeLabel')
   node(dest,660,['Deposit returned',f'Day {last["time"]//86400000} · {status}'],status)
html='''<!doctype html><html><head><meta charset="utf-8"><style>
body{margin:0;color:var(--foreground);font-family:var(--font-sans)}p{font-size:13px;line-height:1.5;color:var(--muted-foreground)}svg{width:100%;height:auto;display:block;min-width:600px}.canvas{overflow-x:auto}.state{fill:var(--card);stroke:var(--border);stroke-width:1.5}.state.fulfilled{stroke:var(--success)}.state.violated{stroke:var(--destructive)}.label{fill:var(--foreground);font-size:14px}.label,.small{paint-order:stroke;stroke:var(--background);stroke-width:5px;stroke-linejoin:round}.small{fill:var(--muted-foreground);font-size:12px}.good{fill:var(--success)}.bad{fill:var(--destructive)}.action{fill:var(--secondary);stroke:var(--chart-1);stroke-width:2}.actionLabel{fill:var(--foreground);font-size:14px}.edge{stroke:var(--muted-foreground);stroke-width:1.8;fill:none}.edgeLabel{fill:var(--foreground);font-size:13px;paint-order:stroke;stroke:var(--background);stroke-width:5px;stroke-linejoin:round}details{font-size:12px;color:var(--muted-foreground)}summary{cursor:pointer}
</style></head><body><p>Rounded boxes: states · circles: actions · p: transition probability<br>The declared 3/4–1/4 policy overlays the Landlord’s action choice.</p><div class="canvas"><svg viewBox="0 0 720 710" role="img" aria-label="Settlement decision process with action choices, stochastic delays, deterministic transitions, and deadline status"><defs><marker id="arr" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10Z" fill="var(--muted-foreground)"/></marker></defs>'''+''.join(svg)+'''</svg></div><p>Time is measured from settlement. The late return remains a possible transition; the obligation monitor records a violation. Terminal states stop here. All probabilities are illustrative assumptions.</p><details><summary>Derivation</summary><p>Generated from the checked DepositSettlement session type via Generative.compile. Paths are grouped by the first settlement action; branch masses are summed, and each outcome’s conditional probability is its path mass divided by that action’s mass. The initial lease-ending event is omitted. This is a finite timed decision-process view, not a new MDP solver.</p><p>Prompt: render the MDP diagram inline. Source: examples/sessions/DepositSettlement.leanfm. Reducer: compiled paths, action grouping, exact rational conditional masses, obligation reports. Unit: probability and fixed 24-hour days. Boundary: one sequential settlement under its declared policy.</p></details></body></html>'''
(r/'mdp.html').write_text(html)
