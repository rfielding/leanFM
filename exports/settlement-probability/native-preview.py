import json
from pathlib import Path
from html import escape
p=Path(__file__).parent
x=json.loads((p/'native-mcp.json').read_text())['structuredContent']
svg=x['svg']
for c,v in {'#111111':'var(--card)','#e5e7eb':'var(--foreground)','#4b5563':'var(--border)','#93c5fd':'var(--chart-1)','#fbbf24':'var(--chart-2)','#9ca3af':'var(--muted-foreground)','#1f2937':'var(--secondary)'}.items(): svg=svg.replace(c,v)
html='''<!doctype html><html><head><meta charset="utf-8"><style>body{margin:0;font-family:var(--font-sans);color:var(--foreground)}p{font-size:13px;line-height:1.5}.scroll{overflow-x:auto}svg{display:block;width:100%;min-width:680px;height:auto}details{font-size:12px;color:var(--muted-foreground);margin:12px 0}</style></head><body>'''
html+='<p>Native <code>session_mdp</code> result · terminal probability total: <b>'+escape(x['terminalProbability'])+'</b> · violation probability: <b>'+escape(x['violationProbability'])+'</b></p>'
html+='<div class="scroll">'+svg+'</div><details><summary>Scope and provenance</summary><p>'+escape(x['reading'])+'</p><p>'+escape(x['provenance']['boundary'])+'</p></details></body></html>'
(p/'native-preview.html').write_text(html)
