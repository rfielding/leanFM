const graphCanvas=document.getElementById('aggGraph');
const gctx=graphCanvas.getContext('2d');
const aggInfo=document.getElementById('aggInfo');
const aggCutBox=document.getElementById('aggCutEdges');
const aggZoomIn=document.getElementById('aggZoomIn'), aggZoomOut=document.getElementById('aggZoomOut'), aggZoomReset=document.getElementById('aggZoomReset'), aggZoomLabel=document.getElementById('aggZoomLabel');
aggCutBox.checked=localStorage.getItem('leanfm.agg.cutEdges')!=='false';
aggCutBox.addEventListener('change', ()=>localStorage.setItem('leanfm.agg.cutEdges', aggCutBox.checked?'true':'false'));
function readAggregateModel(){
  const el=document.getElementById('aggGraphModel');
  if(!el)return{
    nodes:[], edges:[]
  };
  try{
    const model=JSON.parse(el.textContent||'{}');
    return{
      nodes:Array.isArray(model.nodes)?model.nodes:[],
      edges:Array.isArray(model.edges)?model.edges:[]
    };

  }
  catch(e){
    return{
      nodes:[], edges:[]
    };

  }

}
const aggregateModel=readAggregateModel();
const gNodes=aggregateModel.nodes;
const gEdges=aggregateModel.edges.map(e=>Array.isArray(e)?e:[e.src, e.dst, e.label]);
let openGroups=new Set();
let simGroups=[];
let simById=new Map();
let groupEdges=[];
let rankByGroup=new Map();
let rankByNode=new Map();
let hit=[];
let childById=new Map();
let drag=null;
let pan=null;
let hover=null;
let dragMoved=false;
let view=JSON.parse(localStorage.getItem('leanfm.agg.view')||'null')||{
  x:0, y:0, z:1
};
function saveView(){
  localStorage.setItem('leanfm.agg.view', JSON.stringify(view));

}
function clampView(){
  view.z=Math.max(.25, Math.min(3.5, view.z));
  view.x=Math.max(-graphCanvas.width*2, Math.min(graphCanvas.width*2, view.x));
  view.y=Math.max(-graphCanvas.height*2, Math.min(graphCanvas.height*2, view.y));

}
function updateZoomLabel(){
  if(aggZoomLabel)aggZoomLabel.textContent=Math.round(view.z*100)+'%';

}
function zoomAt(factor, sx, sy){
  const before={
    x:(sx-view.x)/view.z, y:(sy-view.y)/view.z
  };
  view.z*=factor;
  clampView();
  view.x=sx-before.x*view.z;
  view.y=sy-before.y*view.z;
  clampView();
  saveView();
  updateZoomLabel();

}
function zoomCenter(factor){
  zoomAt(factor, graphCanvas.width/2, graphCanvas.height/2);

}
function bucket(n){
  return n.group;

}
function groups(){
  const m=new Map();
  for(const n of gNodes){
    const b=bucket(n);
    if(!m.has(b))m.set(b, []);
    m.get(b).push(n);

  }
  return [...m.entries()].map(([key, nodes])=>({
    key, nodes
  }));

}
function subKey(g, n){
  return g.key+'|'+n.sub;

}
function subGroups(g){
  const m=new Map();
  for(const n of g.nodes){
    const k=n.sub;
    if(!m.has(k))m.set(k, []);
    m.get(k).push(n);

  }
  return [...m.entries()].map(([key, nodes])=>({
    key, id:g.key+'|'+key, nodes
  }));

}
function localRadius(n){
  return n<=1?0:Math.max(150, Math.ceil(Math.sqrt(n))*135);

}
function isPlainTop(g){
  return g.key==='unauthenticated'||g.key==='authenticated session';

}
function escHtml(s){
  return String(s).replace(/[&<>"']/g, c=>({
    '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'
  }[c]));

}
function groupMarkdown(g){
  if(g.key==='unauthenticated')return [
    '# unauthenticated',
    '',
    'Initial visible state. The client has no login proof and may only ask for authentication.',
    '',
    '$$',
    'login_proof = none',
    '$$',
    '',
    '- allowed outbound: Auth.LookupRequest',
    '- rejected requirement: no task message may succeed from this state'
  ].join('\n');
  if(g.key==='authenticated session')return [
    '# authenticated session',
    '',
    'A successful authentication exchange produced a visible proof artifact that later tasks must carry.',
    '',
    '$$',
    'login_proof \\in message.fields',
    '$$',
    '',
    '- enabled tasks: get_docs, post_review',
    '- CTL sketch: AG(task_success -> prior(login_proof))'
  ].join('\n');
  if(g.key==='get_docs task')return [
    '# get_docs task',
    '',
    'Task instance for `GET /docs/index.html`. The task starts when an authenticated client request is queued and is cleaned up at a terminal state.',
    '',
    '$$',
    'latency = ts_{client_response} - ts_{client_request}',
    '$$',
    '',
    '- actors: Client, Gateway, Worker',
    '- fields: path, request_id, login_proof, status, bytes',
    '- terminal states: get_docs done, get_docs failed'
  ].join('\n');
  if(g.key==='post_review task')return [
    '# post_review task',
    '',
    'Task instance for posting a review. Moderation is a visible message exchange; success and rejection are both terminal observations.',
    '',
    '$$',
    'P(accepted) = accepted / (accepted + rejected)',
    '$$',
    '',
    '- actors: Client, Gateway, Worker',
    '- fields: review_id, item_id, login_proof, decision, status',
    '- terminal states: post_review done, post_review failed'
  ].join('\n');
  const labels=g.nodes.map(n=>n.label).join(', ')||'no child states';
  return [
    '# '+g.key,
    '',
    'Aggregate requirement state.',
    '',
    '$$',
    'states = '+g.nodes.length,
    '$$',
    '',
    labels
  ].join('\n');

}
function groupArtifacts(g){
  return[
    {kind:'md', label:'Markdown/LaTeX', body:groupMarkdown(g)},
    {kind:'img', label:'image', body:'visual explanation'},
    {kind:'canvas', label:'canvas', body:'local chart or diagram'}
  ];

}
function renderGroupInfo(g){
  const md=groupMarkdown(g);
  aggInfo.innerHTML='<h3>'+escHtml(g.key)+'</h3><pre class="artifact-md">'+escHtml(md)+'</pre>';

}
function groupSize(g){
  if(isPlainTop(g))return{
    w:260, h:58
  };
  if(!openGroups.has(g.key))return{
    w:210, h:88
  };
  const ranks=edgeRanks(g.nodes.map(n=>n.id), gEdges.filter(e=>{
    const a=gNodes.find(n=>n.id===e[0]), b=gNodes.find(n=>n.id===e[1]);
    return a&&b&&bucket(a)===g.key&&bucket(b)===g.key;

  }));
  const maxRank=Math.max(0, ...g.nodes.map(n=>ranks.get(n.id)||0));
  let maxRow=1;
  for(let r=0;
  r<=maxRank;
  r++){
    maxRow=Math.max(maxRow, g.nodes.filter(n=>(ranks.get(n.id)||0)===r).length);

  }
  return{
    w:Math.max(660, 420+292*(maxRow-1)), h:Math.max(540, 302+80*maxRank)
  };

}
function edgeRanks(ids, edges){
  const set=new Set(ids);
  const rank=new Map(ids.map(id=>[id, 0]));
  for(let pass=0;
  pass<ids.length*3+3;
  pass++){
    let changed=false;
    for(const e of edges){
      if(!set.has(e[0])||!set.has(e[1])||e[0]===e[1])continue;
      const a=rank.get(e[0])||0, b=rank.get(e[1])||0;
      if(b<a+1){
        rank.set(e[1], a+1);
        changed=true;

      }

    }
    if(!changed)break;

  }
  return rank;

}
function seed(id, i, total){
  const old=simById.get(id);
  if(old)return{
    x:old.x, y:old.y, vx:old.vx||0, vy:old.vy||0, pinned:!!old.pinned, pinX:old.pinX||old.x, pinY:old.pinY||old.y
  };
  const key=id.startsWith('group:')?id.slice(6):id;
  const r=rankByGroup.get(key)||0;
  const same=simGroups.filter(g=>(rankByGroup.get(g.key)||0)===r).length;
  const x=graphCanvas.width/2+(same-(total-1)/2)*260;
  const y=120+r*230;
  return{
    x, y, vx:0, vy:0, pinned:false
  };

}
function resizeGraphCanvas(){
  let area=0, maxW=0, maxH=0;
  for(const g of simGroups){
    const s=groupSize(g);
    area+=s.w*s.h;
    maxW=Math.max(maxW, s.w);
    maxH=Math.max(maxH, s.h);

  }
  const side=Math.ceil(Math.sqrt(area))*2+860;
  const w=Math.max(1400, maxW+940, side);
  const h=Math.max(940, maxH+700, side);
  if(graphCanvas.width!==w||graphCanvas.height!==h){
    const ox=graphCanvas.width/2, oy=graphCanvas.height/2;
    graphCanvas.width=w;
    graphCanvas.height=h;
    for(const g of simGroups){
      g.x+=w/2-ox;
      g.y+=h/2-oy;

    }

  }

}
function clampGroup(n){
  const sz=groupSize(n);
  n.x=Math.max(sz.w/2+180, Math.min(graphCanvas.width-sz.w/2-180, n.x));
  n.y=Math.max(sz.h/2+180, Math.min(graphCanvas.height-sz.h/2-180, n.y));

}
function overlapPush(a, b, aw, ah, bw, bh, cx, cy, pad, clampA, clampB){
  let dx=b.x-a.x, dy=b.y-a.y;
  if(Math.abs(dx)<1&&Math.abs(dy)<1){
    dx=1;
    dy=1;

  }
  const ox=(aw+bw)/2-Math.abs(dx), oy=(ah+bh)/2-Math.abs(dy);
  if(ox<=0||oy<=0)return false;
  const am=a.pinned?0:(b.pinned?1:.5), bm=b.pinned?0:(a.pinned?1:.5);
  if(am===0&&bm===0)return false;
  const axisX=ox<oy, sgn=Math.sign(axisX?dx:dy)||1;
  const exact=Math.min(34, Math.min(ox, oy)+2);
  const depth=Math.max(ox, oy);
  const boost=Math.min(28, (depth*depth)/260);
  const arx=a.x-cx, ary=a.y-cy, brx=b.x-cx, bry=b.y-cy;
  const al=Math.max(1, Math.sqrt(arx*arx+ary*ary)), bl=Math.max(1, Math.sqrt(brx*brx+bry*bry));
  const adx=Math.abs(arx)<1&&Math.abs(ary)<1?-0.707:arx/al, ady=Math.abs(arx)<1&&Math.abs(ary)<1?-0.707:ary/al;
  const bdx=Math.abs(brx)<1&&Math.abs(bry)<1?0.707:brx/bl, bdy=Math.abs(brx)<1&&Math.abs(bry)<1?0.707:bry/bl;
  if(!a.pinned){
    if(axisX)a.x-=exact*am*sgn;
    else a.y-=exact*am*sgn;
    a.x+=adx*boost*am;
    a.y+=ady*boost*am;
    a.vx=0;
    a.vy=0;

  }
  if(!b.pinned){
    if(axisX)b.x+=exact*bm*sgn;
    else b.y+=exact*bm*sgn;
    b.x+=bdx*boost*bm;
    b.y+=bdy*boost*bm;
    b.vx=0;
    b.vy=0;

  }
  clampA();
  clampB();
  return true;

}
function resolveOverlaps(){
  for(let pass=0;
  pass<16;
  pass++){
    let moved=false;
    for(let i=0;
    i<simGroups.length;
    i++){
      for(let j=i+1;
      j<simGroups.length;
      j++){
        const a=simGroups[i], b=simGroups[j], as=groupSize(a), bs=groupSize(b);
        moved=overlapPush(a, b, as.w, as.h, bs.w, bs.h, graphCanvas.width/2, graphCanvas.height/2, 86, ()=>clampGroup(a), ()=>clampGroup(b))||moved;

      }

    }
    if(!moved)break;

  }

}
function rebuildGraph(){
  const gs=groups();
  const seen=new Set();
  groupEdges=[];
  for(const e of gEdges){
    const a=bucket(gNodes.find(n=>n.id===e[0])), b=bucket(gNodes.find(n=>n.id===e[1]));
    if(a===b)continue;
    const k=a+'>'+b;
    if(seen.has(k))continue;
    seen.add(k);
    groupEdges.push(['group:'+a, 'group:'+b]);

  }
  rankByGroup=edgeRanks(gs.map(g=>g.key), groupEdges.map(e=>[e[0].slice(6), e[1].slice(6)]));
  simGroups=gs.map((g, i)=>Object.assign({
    id:'group:'+g.key, key:g.key, label:g.key, nodes:g.nodes, count:g.nodes.length
  }, seed('group:'+g.key, i, gs.length)));
  simById=new Map(simGroups.map(g=>[g.id, g]));
  resizeGraphCanvas();
  for(let i=0;
  i<4;
  i++)resolveOverlaps();
  aggInfo.innerHTML='<p>Fixed hierarchy: edges prefer top-to-bottom layout; each discrete task is a compound node with task super-states and terminal states.</p><ul>'+gs.map(g=>'<li>'+g.key+': '+g.nodes.length+' states</li>').join('')+'</ul>';

}
function groupFlowWeights(){
  const ids=simGroups.map(g=>g.id), out=new Map(ids.map(id=>[id, 0]));
  let w=new Map(ids.map(id=>[id, 1]));
  for(const e of groupEdges)out.set(e[0], (out.get(e[0])||0)+1);
  for(let k=0;
  k<16;
  k++){
    const next=new Map(ids.map(id=>[id, .18]));
    for(const e of groupEdges){
      const share=(w.get(e[0])||1)/Math.max(1, out.get(e[0])||1);
      next.set(e[1], (next.get(e[1])||.18)+.82*share);

    }
    w=next;

  }
  return w;

}
function groupEdgeCorridors(){
  if(!aggCutBox.checked)return;
  for(const e of groupEdges){
    const a=simById.get(e[0]), b=simById.get(e[1]);
    if(!a||!b)continue;
    const ax=a.x, ay=a.y, bx=b.x, by=b.y, ex=bx-ax, ey=by-ay, len2=Math.max(1, ex*ex+ey*ey);
    for(const n of simGroups){
      if(n.id===a.id||n.id===b.id||n.pinned)continue;
      const s=groupSize(n), t=Math.max(0, Math.min(1, ((n.x-ax)*ex+(n.y-ay)*ey)/len2)), px=ax+ex*t, py=ay+ey*t, dx=n.x-px, dy=n.y-py, d=Math.max(1, Math.sqrt(dx*dx+dy*dy)), corridor=Math.max(s.w, s.h)/2+96;
      if(d<corridor){
        const f=(corridor-d)*0.024;
        n.vx+=dx/d*f;
        n.vy+=dy/d*f;

      }

    }

  }

}
function stepForce(){
  const cx=graphCanvas.width/2, weight=groupFlowWeights();
  for(const n of simGroups){
    const r=rankByGroup.get(n.key)||0, w=weight.get(n.id)||1;
    n.vx+=(cx-n.x)*0.00040;
    n.vy+=((120+r*250+w*82)-n.y)*(0.0016+Math.min(w, 4)*0.00042);

  }
  for(const e of groupEdges){
    const a=simById.get(e[0]), b=simById.get(e[1]);
    if(!a||!b)continue;
    const bw=weight.get(b.id)||1, as=groupSize(a), bs=groupSize(b);
    const dx=b.x-a.x, dy=b.y-a.y, d=Math.max(1, Math.sqrt(dx*dx+dy*dy));
    const targetY=(as.h+bs.h)/2+160+bw*58;
    const targetX=Math.max((as.w+bs.w)/2+150, 240);
    const fx=(Math.abs(dx)-targetX)*0.0018*Math.sign(dx||1);
    if(!a.pinned)a.vx+=fx;
    if(!b.pinned)b.vx-=fx;
    const fy=(dy-targetY)*(0.010+Math.min(bw, 4)*0.0022);
    if(!a.pinned)a.vy+=fy;
    if(!b.pinned)b.vy-=fy;
    if(b.y<a.y+targetY){
      const push=(a.y+targetY-b.y)*(0.028+Math.min(bw, 4)*0.006);
      if(!a.pinned)a.vy-=push;
      if(!b.pinned)b.vy+=push;

    }

  }
  groupEdgeCorridors();
  for(let i=0;
  i<simGroups.length;
  i++){
    for(let j=i+1;
    j<simGroups.length;
    j++){
      const a=simGroups[i], b=simGroups[j], as=groupSize(a), bs=groupSize(b);
      let dx=b.x-a.x, dy=b.y-a.y;
      if(Math.abs(dx)<1&&Math.abs(dy)<1){
        dx=5;
        dy=4;

      }
      const d2=Math.max(1, dx*dx+dy*dy), d=Math.sqrt(d2);
      const near=Math.max((as.w+bs.w)/2+220, (as.h+bs.h)/2+180);
      const f=(near*near*0.22)/d2;
      const fx=f*dx/d, fy=f*dy/d;
      a.vx-=fx;
      a.vy-=fy;
      b.vx+=fx;
      b.vy+=fy;

    }

  }
  for(const n of simGroups){
    if(n.pinned){
      n.x=n.pinX;
      n.y=n.pinY;
      n.vx=0;
      n.vy=0;
      clampGroup(n);
      continue;

    }
    n.vx*=0.56;
    n.vy*=0.56;
    n.x+=n.vx;
    n.y+=n.vy;
    clampGroup(n);

  }
  resolveOverlaps();

}
function groupRect(g){
  const s=groupSize(g);
  return{
    x:g.x-s.w/2, y:g.y-s.h/2, w:s.w, h:s.h
  };

}
function innerPortToward(g, other){
  const r=groupRect(g);
  let dx=other.x-g.x, dy=other.y-g.y;
  if(Math.abs(dx)<1&&Math.abs(dy)<1){
    dx=1;
    dy=0;

  }
  const sx=(r.w/2-150)/Math.max(1, Math.abs(dx)), sy=(r.h/2-92)/Math.max(1, Math.abs(dy));
  const s=Math.min(sx, sy);
  return{
    x:g.x+dx*s, y:g.y+dy*s
  };

}
function boundaryPeer(id){
  const n=gNodes.find(x=>x.id===id);
  if(!n)return null;
  const g=simById.get('group:'+bucket(n));
  return g?{
    x:g.x, y:g.y
  }
  :null;

}
function childTarget(g, node){
  const nodes=g.nodes;
  rankByNode=edgeRanks(nodes.map(n=>n.id), gEdges.filter(e=>{
    const a=gNodes.find(n=>n.id===e[0]), b=gNodes.find(n=>n.id===e[1]);
    return a&&b&&bucket(a)===g.key&&bucket(b)===g.key;

  }));
  const r=rankByNode.get(node.id)||0;
  const row=nodes.filter(n=>(rankByNode.get(n.id)||0)===r);
  const idx=row.findIndex(n=>n.id===node.id);
  const rect=groupRect(g);
  const left=rect.x+170, right=rect.x+rect.w-170;
  const top=rect.y+220, bottom=rect.y+rect.h-72;
  const maxRank=Math.max(0, ...nodes.map(n=>rankByNode.get(n.id)||0));
  const x=row.length<=1?g.x:left+(idx/(row.length-1))*(right-left);
  const y=maxRank<=0?(top+bottom)/2:top+(r/maxRank)*(bottom-top);
  return{
    x, y
  };

}
function childState(g, node){
  const id=g.key+'|'+node.id;
  let c=childById.get(id);
  const t=childTarget(g, node);
  if(!c){
    c={
      id, nodeId:node.id, groupKey:g.key, x:t.x, y:t.y, vx:0, vy:0, pinned:false, pinX:t.x, pinY:t.y
    };
    childById.set(id, c);

  }
  return c;

}
function clampChild(c, r){
  const w=260, h=42;
  c.x=Math.max(r.x+w/2+18, Math.min(r.x+r.w-w/2-18, c.x));
  c.y=Math.max(r.y+h/2+178, Math.min(r.y+r.h-h/2-18, c.y));

}
function separateChildren(cs, r){
  for(let pass=0;
  pass<16;
  pass++){
    let moved=false;
    for(let i=0;
    i<cs.length;
    i++){
      for(let j=i+1;
      j<cs.length;
      j++){
        const a=cs[i], b=cs[j];
        moved=overlapPush(a, b, 260, 42, 260, 42, r.x+r.w/2, r.y+r.h/2, 32, ()=>clampChild(a, r), ()=>clampChild(b, r))||moved;

      }

    }
    if(!moved)break;

  }

}
function layoutChildren(g){
  if(!openGroups.has(g.key)||isPlainTop(g))return;
  const r=groupRect(g);
  const cs=g.nodes.map(n=>childState(g, n));
  const byNode=new Map(g.nodes.map((n, i)=>[n.id, cs[i]]));
  for(let pass=0;
  pass<28;
  pass++){
    for(let i=0;
    i<g.nodes.length;
    i++){
      const c=cs[i];
      if(c.pinned)continue;
      const t=childTarget(g, g.nodes[i]);
      c.vx+=(t.x-c.x)*0.012;
      c.vy+=(t.y-c.y)*0.014;
      c.vx+=(g.x-c.x)*0.0002;

    }
    for(const e of gEdges){
      const a=byNode.get(e[0]), b=byNode.get(e[1]);
      if(a&&b){
        const dx=b.x-a.x, dy=b.y-a.y, d=Math.max(1, Math.sqrt(dx*dx+dy*dy));
        const target=250, force=(d-target)*0.010;
        const fx=force*dx/d, fy=force*dy/d;
        if(!a.pinned){
          a.vx+=fx;
          a.vy+=fy;

        }
        if(!b.pinned){
          b.vx-=fx;
          b.vy-=fy;

        }
        const want=110;
        if(!a.pinned)a.vy+=(dy-want)*0.008;
        if(!b.pinned)b.vy-=(dy-want)*0.008;

      }
      else if(a&&!a.pinned){
        const dn=gNodes.find(n=>n.id===e[1]);
        if(dn&&bucket(dn)!==g.key){
          const peer=boundaryPeer(e[1]);
          if(peer){
            const p=innerPortToward(g, peer);
            a.vx+=(p.x-a.x)*0.018;
            a.vy+=(p.y-a.y)*0.018;

          }

        }

      }
      else if(b&&!b.pinned){
        const sn=gNodes.find(n=>n.id===e[0]);
        if(sn&&bucket(sn)!==g.key){
          const peer=boundaryPeer(e[0]);
          if(peer){
            const p=innerPortToward(g, peer);
            b.vx+=(p.x-b.x)*0.010;
            b.vy+=(p.y-b.y)*0.010;

          }

        }

      }

    }
    for(const c of cs){
      if(c.pinned){
        c.x=c.pinX;
        c.y=c.pinY;
        c.vx=0;
        c.vy=0;
        clampChild(c, r);
        c.pinX=c.x;
        c.pinY=c.y;
        continue;

      }
      c.vx*=0.58;
      c.vy*=0.58;
      c.x+=c.vx;
      c.y+=c.vy;
      clampChild(c, r);

    }
    separateChildren(cs, r);

  }

}
function childPos(g, node){
  const c=childState(g, node);
  return{
    x:c.x, y:c.y
  };

}
function hasMessageIncident(id){
  return gEdges.some(e=>e[0]===id||e[1]===id);

}
function drawChild(g, n){
  const p=childPos(g, n);
  const w=260, h=42;
  const x=p.x-w/2, y=p.y-h/2;
  gctx.fillStyle='#0b0b0b';
  gctx.strokeStyle='#93c5fd';
  gctx.lineWidth=1.5;
  gctx.fillRect(x, y, w, h);
  gctx.strokeRect(x, y, w, h);
  gctx.fillStyle='#fff';
  gctx.font='11px sans-serif';
  gctx.textAlign='center';
  gctx.fillText(n.id, p.x, p.y-5);
  gctx.fillText(n.label, p.x, p.y+10);
  if(!hasMessageIncident(n.id)){
    gctx.fillStyle='#9ca3af';
    gctx.font='10px sans-serif';
    gctx.textAlign='right';
    gctx.fillText('no message edge', x+w-6, y+h-6);

  }
  hit.push({
    key:'state:'+n.id, kind:'state', stateId:n.id, groupKey:g.key, x, y, w, h
  });

}
function drawArtifactTile(g, x, y, w, h, a){
  gctx.fillStyle='#050505';
  gctx.strokeStyle='#94a3b8';
  gctx.lineWidth=1.3;
  gctx.fillRect(x, y, w, h);
  gctx.strokeRect(x, y, w, h);
  gctx.fillStyle='#94a3b8';
  gctx.font='10px sans-serif';
  gctx.textAlign='left';
  gctx.fillText(a.kind.toUpperCase(), x+8, y+14);
  gctx.fillStyle='#fff';
  gctx.font='11px sans-serif';
  gctx.fillText(a.label, x+8, y+31);
  if(a.kind==='img'){
    gctx.strokeStyle='#64748b';
    gctx.beginPath();
    gctx.moveTo(x+8, y+h-10);
    gctx.lineTo(x+w*.42, y+h-30);
    gctx.lineTo(x+w*.62, y+h-18);
    gctx.lineTo(x+w-8, y+h-38);
    gctx.stroke();

  }
  else if(a.kind==='canvas'){
    gctx.strokeStyle='#64748b';
    for(let i=0;i<3;i++){
      gctx.beginPath();
      gctx.moveTo(x+12+i*24, y+h-14);
      gctx.lineTo(x+28+i*24, y+h-36);
      gctx.lineTo(x+52+i*24, y+h-22);
      gctx.stroke();

    }

  }
  else{
    const lines=String(a.body).split(/\n/).map(s=>s.trim()).filter(Boolean);
    const preview=[];
    for(let i=0;i<lines.length&&preview.length<4;i++){
      if(lines[i]==='$$')continue;
      preview.push(lines[i].replace(/^#\s*/, '').replace(/^- /, ''));

    }
    gctx.font='10px sans-serif';
    for(let i=0;i<preview.length;i++){
      const line=preview[i].length>34?preview[i].slice(0, 31)+'...':preview[i];
      gctx.fillStyle=line.indexOf('=')>=0||line.indexOf('\\')>=0?'#7dd3fc':'#e5e7eb';
      gctx.fillText(line, x+8, y+49+i*12);

    }

  }

}
function drawArtifactShelf(g, x, y, w){
  const items=groupArtifacts(g), gap=10, tileW=(w-28-gap*2)/3, top=y+62;
  gctx.fillStyle='#cbd5e1';
  gctx.font='11px sans-serif';
  gctx.textAlign='left';
  gctx.fillText('informal artifacts: markdown / images / canvas', x+14, top-10);
  items.forEach((a, i)=>drawArtifactTile(g, x+14+i*(tileW+gap), top, tileW, 82, a));

}
function edgePoint(g, t){
  const sz=groupSize(g);
  const dx=t.x-g.x, dy=t.y-g.y;
  const sx=(sz.w/2+16)/Math.max(1, Math.abs(dx)), sy=(sz.h/2+16)/Math.max(1, Math.abs(dy));
  const s=Math.min(sx, sy);
  return{
    x:g.x+dx*s, y:g.y+dy*s
  };

}
function drawArrow(ctx, x1, y1, x2, y2, color, width, dashed){
  ctx.strokeStyle=color;
  ctx.fillStyle=color;
  ctx.lineWidth=width;
  ctx.setLineDash(dashed?[8, 6]:[]);
  ctx.beginPath();
  ctx.moveTo(x1, y1);
  ctx.lineTo(x2, y2);
  ctx.stroke();
  ctx.setLineDash([]);
  const a=Math.atan2(y2-y1, x2-x1);
  ctx.beginPath();
  ctx.moveTo(x2, y2);
  ctx.lineTo(x2-12*Math.cos(a-.45), y2-12*Math.sin(a-.45));
  ctx.lineTo(x2-12*Math.cos(a+.45), y2-12*Math.sin(a+.45));
  ctx.closePath();
  ctx.fill();

}
function rectPort(from, to, w, h, pad){
  const dx=to.x-from.x, dy=to.y-from.y;
  const sx=(w/2+pad)/Math.max(1, Math.abs(dx)), sy=(h/2+pad)/Math.max(1, Math.abs(dy));
  const s=Math.min(sx, sy);
  return{
    x:from.x+dx*s, y:from.y+dy*s
  };

}
function edgeLabel(e){
  return e[2]||((e[0]||'?')+' -> '+(e[1]||'?'));

}
function clampValue(v, lo, hi){
  return Math.max(lo, Math.min(hi, v));

}
function labelBox(ctx, x, y, text, color){
  const t=text.length>44?text.slice(0, 41)+'...':text;
  const w=Math.max(120, Math.min(330, t.length*7)), h=20, pad=120;
  const bx=clampValue(x, w/2+pad, graphCanvas.width-w/2-pad), by=clampValue(y-6, h/2+pad, graphCanvas.height-h/2-pad);
  ctx.fillStyle=color;
  ctx.font='11px sans-serif';
  ctx.textAlign='center';
  ctx.lineWidth=4;
  ctx.strokeStyle='#000';
  ctx.strokeText(t, bx, by);
  ctx.fillText(t, bx, by);

}
function visibleInnerPos(g, id){
  const n=g.nodes.find(x=>x.id===id);
  return n?childPos(g, n):null;

}
function drawSubBuckets(g){

}
function drawInternalEdges(g){
  if(!openGroups.has(g.key))return;
  for(const e of gEdges){
    const sn=gNodes.find(n=>n.id===e[0]), dn=gNodes.find(n=>n.id===e[1]);
    if(!sn||!dn||bucket(sn)!==g.key||bucket(dn)!==g.key)continue;
    const a=visibleInnerPos(g, e[0]), b=visibleInnerPos(g, e[1]);
    if(!a||!b)continue;
    const pa=rectPort(a, b, 260, 42, 8), pb=rectPort(b, a, 260, 42, 8);
    drawArrow(gctx, pa.x, pa.y, pb.x, pb.y, '#f59e0b', 1.5, false);
    labelBox(gctx, (pa.x+pb.x)/2, (pa.y+pb.y)/2, edgeLabel(e), '#f59e0b');

  }

}
function visibleEndpoint(id){
  const n=gNodes.find(x=>x.id===id);
  if(!n)return null;
  const g=simById.get('group:'+bucket(n));
  if(!g)return null;
  if(!openGroups.has(g.key)){
    return{
      key:'group:'+g.key, kind:'group', x:g.x, y:g.y, w:groupSize(g).w, h:groupSize(g).h
    };

  }
  const p=childPos(g, n);
  return{
    key:'state:'+id, kind:'state', x:p.x, y:p.y, w:260, h:42
  };

}
function visibleNodes(){
  const out=[];
  for(const g of simGroups){
    if(!openGroups.has(g.key)){
      out.push({
        key:'group:'+g.key, kind:'group', x:g.x, y:g.y, w:groupSize(g).w, h:groupSize(g).h
      });
      continue;

    }
    for(const n of g.nodes)out.push(visibleEndpoint(n.id));

  }
  return out.filter(Boolean);

}
function visibleEdgeEndpoints(e){
  const a=visibleEndpoint(e[0]), b=visibleEndpoint(e[1]);
  if(!a||!b||a.key===b.key)return null;
  return{
    a, b
  };

}
function hasVisibleIncoming(v){
  for(const e of gEdges){
    const p=visibleEdgeEndpoints(e);
    if(p&&p.b.key===v.key)return true;

  }
  return false;

}
function hasVisibleOutgoing(v){
  for(const e of gEdges){
    const p=visibleEdgeEndpoints(e);
    if(p&&p.a.key===v.key)return true;

  }
  return false;

}
function drawBoundaryMarkers(){
  for(const v of visibleNodes()){
    if(!hasVisibleIncoming(v)){
      const from={
        x:v.x-v.w/2-42, y:v.y
      }, to={
        x:v.x-v.w/2-6, y:v.y
      };
      drawArrow(gctx, from.x, from.y, to.x, to.y, '#22c55e', 2);
      gctx.fillStyle='#22c55e';
      gctx.font='11px sans-serif';
      gctx.textAlign='right';
      gctx.fillText('start', from.x-4, from.y-6);

    }
    if(!hasVisibleOutgoing(v)){
      gctx.strokeStyle='#ef4444';
      gctx.lineWidth=2;
      gctx.strokeRect(v.x-v.w/2-5, v.y-v.h/2-5, v.w+10, v.h+10);
      gctx.fillStyle='#ef4444';
      gctx.font='11px sans-serif';
      gctx.textAlign='left';
      gctx.fillText('terminal', v.x+v.w/2+8, v.y+4);

    }

  }

}
function drawVisibleEdges(){
  const projected=new Map();
  for(const e of gEdges){
    const sn=gNodes.find(n=>n.id===e[0]), dn=gNodes.find(n=>n.id===e[1]);
    if(!sn||!dn||bucket(sn)===bucket(dn))continue;
    const a=visibleEndpoint(e[0]), b=visibleEndpoint(e[1]);
    if(!a||!b||a.key===b.key)continue;
    const k=a.key+'>'+b.key;
    if(!projected.has(k))projected.set(k, {
      a, b, labels:[]
    });
    const p=projected.get(k);
    const label=edgeLabel(e);
    if(!p.labels.includes(label))p.labels.push(label);

  }
  for(const p of projected.values()){
    const pa=rectPort(p.a, p.b, p.a.w, p.a.h, 12), pb=rectPort(p.b, p.a, p.b.w, p.b.h, 12);
    const color='#f59e0b';
    drawArrow(gctx, pa.x, pa.y, pb.x, pb.y, color, 1.8, false);
    labelBox(gctx, (pa.x+pb.x)/2, (pa.y+pb.y)/2, p.labels.join(' / '), color);

  }

}
function edgeTouchesHover(e){
  if(!hover)return false;
  if(hover.kind==='state')return e[0]===hover.stateId||e[1]===hover.stateId;
  if(hover.kind==='group'||hover.kind==='plain'){
    const g=simById.get('group:'+hover.key);
    if(!g)return false;
    const ids=new Set(g.nodes.map(n=>n.id));
    return ids.has(e[0])||ids.has(e[1]);

  }
  return false;

}
function drawHighlightedEdges(){
  if(!hover)return;
  for(const e of gEdges){
    if(!edgeTouchesHover(e))continue;
    const a=visibleEndpoint(e[0]), b=visibleEndpoint(e[1]);
    if(!a||!b)continue;
    if(a.key===b.key){
      labelBox(gctx, a.x, a.y+54, edgeLabel(e), '#38bdf8');
      continue;

    }
    const pa=rectPort(a, b, a.w, a.h, 14), pb=rectPort(b, a, b.w, b.h, 14);
    drawArrow(gctx, pa.x, pa.y, pb.x, pb.y, '#38bdf8', 3.2, false);
    labelBox(gctx, (pa.x+pb.x)/2, (pa.y+pb.y)/2-10, edgeLabel(e), '#38bdf8');

  }

}
function drawAggLegend(){
  gctx.textAlign='left';
  gctx.font='12px sans-serif';
  gctx.fillStyle='#f59e0b';
  gctx.fillText('solid amber = concrete message send', 18, 24);
  gctx.fillStyle='#22c55e';
  gctx.fillText('green start arrow = no visible incoming message', 18, 42);
  gctx.fillStyle='#ef4444';
  gctx.fillText('red border = no visible outgoing message', 18, 60);
  gctx.fillStyle='#9ca3af';
  gctx.fillText('gray tag = opened state has no message-send edge', 18, 78);

}
function drawAgg(){
  stepForce();
  gctx.setTransform(1, 0, 0, 1, 0, 0);
  gctx.fillStyle='#111';
  gctx.fillRect(0, 0, graphCanvas.width, graphCanvas.height);
  gctx.setTransform(view.z, 0, 0, view.z, view.x, view.y);
  hit=[];
  for(const g of simGroups){
    const sz=groupSize(g);
    const x=g.x-sz.w/2, y=g.y-sz.h/2;
    gctx.fillStyle=openGroups.has(g.key)&&!isPlainTop(g)?'#111827':'#000';
    gctx.strokeStyle='#fff';
    gctx.lineWidth=2;
    gctx.fillRect(x, y, sz.w, sz.h);

  }
  for(const g of simGroups){
    layoutChildren(g);
    drawSubBuckets(g);

  }
  for(const g of simGroups){
    const plain=isPlainTop(g);
    const sz=groupSize(g);
    const x=g.x-sz.w/2, y=g.y-sz.h/2;
    gctx.strokeStyle='#fff';
    gctx.lineWidth=2;
    gctx.strokeRect(x, y, sz.w, sz.h);
    gctx.fillStyle='#fff';
    gctx.font=plain?'14px sans-serif':'16px sans-serif';
    gctx.textAlign='center';
    gctx.fillText(g.label, g.x, plain?g.y+5:y+25);
    if(!plain){
      gctx.font='13px sans-serif';
      gctx.fillText(g.count+' states '+(openGroups.has(g.key)?'open':'closed'), g.x, y+47);

    }
    else{
      gctx.fillStyle='#7dd3fc';
      gctx.font='10px sans-serif';
      gctx.fillText('Markdown / LaTeX', g.x, y+sz.h-10);

    }
    hit.push({
      key:g.key, kind:plain?'plain':'group', x, y, w:sz.w, h:sz.h
    });
    if(openGroups.has(g.key)&&!plain){
      drawArtifactShelf(g, x, y, sz.w);
      for(const n of g.nodes)drawChild(g, n);

    }

  }
  for(const g of simGroups)drawInternalEdges(g);
  drawVisibleEdges();
  drawHighlightedEdges();
  drawBoundaryMarkers();
  gctx.setTransform(1, 0, 0, 1, 0, 0);
  drawAggLegend();
  requestAnimationFrame(drawAgg);

}
function canvasScreenPoint(ev){
  const r=graphCanvas.getBoundingClientRect();
  return{
    x:(ev.clientX-r.left)*graphCanvas.width/r.width, y:(ev.clientY-r.top)*graphCanvas.height/r.height
  };

}
function canvasPoint(ev){
  const p=canvasScreenPoint(ev);
  return{
    x:(p.x-view.x)/view.z, y:(p.y-view.y)/view.z
  };

}
function hitAt(x, y){
  return hit.filter(h=>x>=h.x&&x<=h.x+h.w&&y>=h.y&&y<=h.y+h.h).sort((a, b)=>(a.w*a.h)-(b.w*b.h))[0]||null;

}
graphCanvas.addEventListener('pointerdown', ev=>{
  ev.preventDefault();
  const p=canvasPoint(ev), h=hitAt(p.x, p.y);
  if(!h){
    const s=canvasScreenPoint(ev);
    pan={
      x:s.x, y:s.y, viewX:view.x, viewY:view.y
    };
    graphCanvas.setPointerCapture(ev.pointerId);
    graphCanvas.style.cursor='grabbing';
    return;

  }
  if(h.kind==='state'){
    const c=childById.get(h.groupKey+'|'+h.stateId);
    if(!c)return;
    c.pinned=true;
    c.pinX=c.x;
    c.pinY=c.y;
    drag={
      kind:'state', state:c, offX:p.x-c.x, offY:p.y-c.y
    };
    graphCanvas.setPointerCapture(ev.pointerId);
    graphCanvas.style.cursor='grabbing';

  }
  else if(h.kind==='group'||h.kind==='plain'){
    const g=simById.get('group:'+h.key);
    if(!g)return;
    g.pinned=true;
    g.pinX=g.x;
    g.pinY=g.y;
    drag={
      kind:'group', group:g, offX:p.x-g.x, offY:p.y-g.y
    };
    graphCanvas.setPointerCapture(ev.pointerId);
    graphCanvas.style.cursor='grabbing';

  }

});
graphCanvas.addEventListener('pointermove', ev=>{
  if(pan){
    ev.preventDefault();
    dragMoved=true;
    const s=canvasScreenPoint(ev);
    view.x=pan.viewX+s.x-pan.x;
    view.y=pan.viewY+s.y-pan.y;
    clampView();
    saveView();
    return;

  }
  if(!drag){
    const p=canvasPoint(ev);
    hover=hitAt(p.x, p.y);
    graphCanvas.style.cursor=hover?'grab':'default';
    return;

  }
  ev.preventDefault();
  const p=canvasPoint(ev);
  dragMoved=true;
  if(drag.kind==='state'){
    const c=drag.state;
    c.pinX=p.x-drag.offX;
    c.pinY=p.y-drag.offY;
    c.x=c.pinX;
    c.y=c.pinY;
    c.vx=0;
    c.vy=0;

  }
  else{
    const g=drag.group;
    g.pinX=p.x-drag.offX;
    g.pinY=p.y-drag.offY;
    g.x=g.pinX;
    g.y=g.pinY;
    g.vx=0;
    g.vy=0;

  }

});
graphCanvas.addEventListener('pointerup', ev=>{
  if(pan){
    try{
      graphCanvas.releasePointerCapture(ev.pointerId);

    }
    catch(e){

    }
    pan=null;
    graphCanvas.style.cursor='grab';

  }
  if(drag){
    try{
      graphCanvas.releasePointerCapture(ev.pointerId);

    }
    catch(e){

    }
    drag=null;
    graphCanvas.style.cursor='grab';

  }

});
graphCanvas.addEventListener('pointercancel', ev=>{
  drag=null;
  pan=null;
  graphCanvas.style.cursor='grab';

});
graphCanvas.addEventListener('pointerleave', ev=>{
  if(!drag&&!pan)hover=null;

});
graphCanvas.style.touchAction='none';
graphCanvas.addEventListener('wheel', ev=>{
  ev.preventDefault();
  const p=canvasScreenPoint(ev);
  if(ev.ctrlKey||ev.metaKey){
    zoomAt(Math.exp(-ev.deltaY*0.002), p.x, p.y);
    return;

  }
  else{
    view.x-=ev.deltaX;
    view.y-=ev.deltaY;

  }
  clampView();
  saveView();
  updateZoomLabel();

}, {
  passive:false
});
if(aggZoomIn)aggZoomIn.addEventListener('click', ()=>zoomCenter(1.25));
if(aggZoomOut)aggZoomOut.addEventListener('click', ()=>zoomCenter(0.8));
if(aggZoomReset)aggZoomReset.addEventListener('click', ()=>{
  view={
    x:0, y:0, z:1
  };
  saveView();
  updateZoomLabel();

});
graphCanvas.addEventListener('click', ev=>{
  if(dragMoved){
    dragMoved=false;
    return;

  }
  const p=canvasPoint(ev), h=hitAt(p.x, p.y);
  if(!h||(h.kind!=='group'&&h.kind!=='plain'))return;
  const g=simById.get('group:'+h.key);
  if(g)renderGroupInfo(g);
  if(h.kind==='plain')return;
  openGroups.has(h.key)?openGroups.delete(h.key):openGroups.add(h.key);
  rebuildGraph();
  const next=simById.get('group:'+h.key);
  if(next)renderGroupInfo(next);

});
rebuildGraph();
updateZoomLabel();
drawAgg();
