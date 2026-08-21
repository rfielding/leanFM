(()=>{
  const cv=document.getElementById('subjectGraph'), ctx=cv.getContext('2d'), title=document.getElementById('subjectTitle'), summary=document.getElementById('subjectSummary'), artifacts=document.getElementById('subjectArtifacts'), cutBox=document.getElementById('subjectCutEdges'), zoomIn=document.getElementById('subjectZoomIn'), zoomOut=document.getElementById('subjectZoomOut'), zoomReset=document.getElementById('subjectZoomReset'), zoomLabel=document.getElementById('subjectZoomLabel');
  cutBox.checked=localStorage.getItem('leanfm.subject.cutEdges')!=='false';
  cutBox.addEventListener('change', ()=>localStorage.setItem('leanfm.subject.cutEdges', cutBox.checked?'true':'false'));
  const empty={
    id:'empty', task:'No active draft', actors:[], messages:[], properties:[], reducers:[], markdown:''
  };
  let model=JSON.parse(localStorage.getItem('leanfm.subject')||'null')||empty;
  function esc(s){
    return String(s).replace(/[&<>]/g, c=>({
      '&':'&amp;', '<':'&lt;', '>':'&gt;'
    }
    [c]));

  }
  function lines(text, max){
    const words=String(text).split(/\s+/), out=[];
    let line='';
    for(const w of words){
      if((line+' '+w).trim().length>max){
        if(line)out.push(line);
        line=w;

      }
      else line=(line+' '+w).trim();

    }
    if(line)out.push(line);
    return out.length?out:[''];

  }
  function msgParts(m){
    const mm=String(m).match(/^\s*([^\s]+)\s*->\s*([^\s]+)\s+([^\s]+)\s*(.*)$/);
    return mm?{
      src:mm[1], dst:mm[2], proto:mm[3], fields:mm[4]
    }
    :{
      src:'?', dst:'?', proto:String(m), fields:''
    };

  }
  function rect(x, y, w, h, label, color){
    ctx.fillStyle='#000';
    ctx.strokeStyle=color||'#fff';
    ctx.lineWidth=2;
    ctx.fillRect(x, y, w, h);
    ctx.strokeRect(x, y, w, h);
    ctx.fillStyle='#fff';
    ctx.font='13px sans-serif';
    ctx.textAlign='center';
    const ls=lines(label, Math.max(12, Math.floor(w/8))).slice(0, 4);
    ls.forEach((t, i)=>ctx.fillText(t, x+w/2, y+h/2-(ls.length-1)*8+i*16));

  }
  function arrow(x1, y1, x2, y2, color, dashed){
    ctx.strokeStyle=color||'#93c5fd';
    ctx.fillStyle=color||'#93c5fd';
    ctx.lineWidth=2;
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
  function overlapsRect(a, b){
    return a.x<b.x+b.w&&a.x+a.w>b.x&&a.y<b.y+b.h&&a.y+a.h>b.y;

  }
  function clampValue(v, lo, hi){
    return Math.max(lo, Math.min(hi, v));

  }
  function labelBox(x, y, text, color, w, avoid){
    const lw=w||210, ls=lines(text, Math.floor(lw/8)).slice(0, 3), h=18+ls.length*15;
    const offsets=[[0, 0], [0, -54], [0, 54], [170, 0], [-170, 0], [170, -54], [-170, -54], [170, 54], [-170, 54], [0, -96], [0, 96]];
    const pad=120, minX=lw/2+pad, maxX=cv.width-lw/2-pad, minY=h/2+pad, maxY=cv.height-h/2-pad;
    let bx=clampValue(x, minX, maxX), by=clampValue(y, minY, maxY);
    for(const [ox, oy] of offsets){
      const cx=clampValue(x+ox, minX, maxX), cy=clampValue(y+oy, minY, maxY);
      const r={
        x:cx-lw/2, y:cy-h/2, w:lw, h
      };
      if(!(avoid||[]).some(a=>overlapsRect(r, a))){
        bx=cx;
        by=cy;
        break;

      }

    }
    ctx.font='11px sans-serif';
    ctx.textAlign='center';
    ctx.lineWidth=4;
    ctx.strokeStyle='#000';
    ctx.fillStyle=color||'#fff';
    ls.forEach((t, i)=>{
      const ty=by-(ls.length-1)*7+i*14+4;
      ctx.strokeText(t, bx, ty);
      ctx.fillText(t, bx, ty);

    });

  }
  function group(x, y, w, h, label){
    ctx.fillStyle='#111827';
    ctx.strokeStyle='#777';
    ctx.lineWidth=2;
    ctx.fillRect(x, y, w, h);
    ctx.strokeRect(x, y, w, h);
    ctx.fillStyle='#fff';
    ctx.font='16px sans-serif';
    ctx.textAlign='left';
    ctx.fillText(label, x+14, y+24);

  }
  let openGroups=new Set(JSON.parse(localStorage.getItem('leanfm.subject.open')||'[]'));
  let nodes=[], edges=[], hit=[], childById=new Map(), drag=null, pan=null, hover=null, started=false;
  let view=JSON.parse(localStorage.getItem('leanfm.subject.view')||'null')||{
    x:0, y:0, z:1
  };
  function saveView(){
    localStorage.setItem('leanfm.subject.view', JSON.stringify(view));

  }
  function clampView(){
    view.z=Math.max(.25, Math.min(3.5, view.z));
    view.x=Math.max(-cv.width*2, Math.min(cv.width*2, view.x));
    view.y=Math.max(-cv.height*2, Math.min(cv.height*2, view.y));

  }
  function updateZoomLabel(){
    if(zoomLabel)zoomLabel.textContent=Math.round(view.z*100)+'%';

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
    zoomAt(factor, cv.width/2, cv.height/2);

  }
  function mdLines(){
    return String(model.markdown||'').split(/\n+/).map(s=>s.replace(/^#+\s*/, '').trim()).filter(Boolean).slice(0, 8);

  }
  function groupChildren(n){
    const msgs=(model.messages||[]).map(msgParts), props=model.properties||[], reducers=model.reducers||[], md=mdLines();
    if(n.id==='pre')return md.length&&!msgs.length?md:['entry request', 'auth/proof preconditions', 'queue/readiness'];
    if(n.id==='exchange')return msgs.length?['state 0: ready'].concat(msgs.map((m, i)=>'state '+(i+1)+': after '+m.proto)).concat(['terminal observation']):(md.length?md:['Markdown-only requirement']);
    if(n.id==='terminal')return msgs.length?['postcondition', 'cleanup task', 'terminal observation']:(md.length?['requirement accepted', 'no temporal machine required']:['postcondition']);
    if(n.id==='annotations')return['actors: '+(model.actors||[]).join(', ')].concat(props.slice(0, 3)).concat(reducers.slice(0, 2)).concat(md.slice(0, 3));
    return[];

  }
  function groupSize(n){
    if(!openGroups.has(n.id))return{
      w:230, h:82
    };
    const kids=groupChildren(n), baseW=n.id==='exchange'?560:360, baseH=Math.max(260, 118+kids.length*58);
    const cols=Math.max(1, Math.ceil(Math.sqrt(kids.length)));
    const rows=Math.max(1, Math.ceil(kids.length/cols));
    return{
      w:Math.max(baseW, 340+292*(cols-1)), h:Math.max(baseH, 162+66*(rows-1))
    };

  }
  function rectPort(a, b){
    const s=groupSize(a), dx=b.x-a.x, dy=b.y-a.y, m=Math.min((s.w/2+10)/Math.max(1, Math.abs(dx)), (s.h/2+10)/Math.max(1, Math.abs(dy)));
    return{
      x:a.x+dx*m, y:a.y+dy*m
    };

  }
  function drawArrowLabel(a, b, label, color){
    const p1=rectPort(a, b), p2=rectPort(b, a);
    arrow(p1.x, p1.y, p2.x, p2.y, color);
    labelBox((p1.x+p2.x)/2, (p1.y+p2.y)/2-16, label, color, 260);

  }
  function concreteEdges(){
    const msgs=(model.messages||[]).map(msgParts), out=[['pre|entry request', 'exchange|state 0: ready', 'instantiate task FSM from queued request', 'struct']];
    for(let i=0;
    i<msgs.length;
    i++){
      const m=msgs[i];
      out.push(['exchange|state '+i+': '+(i===0?'ready':'after '+msgs[i-1].proto), 'exchange|state '+(i+1)+': after '+m.proto, m.src+' -> '+m.dst+' '+m.proto, 'msg']);

    }
    if(msgs.length)out.push(['exchange|state '+msgs.length+': after '+msgs[msgs.length-1].proto, 'terminal|postcondition', 'terminal cleanup / task completes', 'struct']);
    out.push(['terminal|postcondition', 'annotations|CTL over visible states', 'optional CTL / reducers over visible fields', 'optional']);
    return out;

  }
  function build(){
    const msgs=(model.messages||[]).map(msgParts);
    const old=new Map(nodes.map(n=>[n.id, n]));
    function node(id, label, rank, color, x){
      const o=old.get(id);
      return{
        id, label, rank, color, x:o?o.x:x, y:o?o.y:160+rank*260, vx:o?o.vx:0, vy:o?o.vy:0, pinned:o?o.pinned:false
      };

    }
    nodes=[node('pre', 'preconditions', 0, '#93c5fd', 250), node('exchange', 'message exchange', 1, '#fbbf24', 560), node('terminal', 'terminal / cleanup', 2, '#22c55e', 560), node('annotations', 'properties / reducers', 1, '#a78bfa', 930)];
    edges=msgs.length?[['pre', 'exchange', msgs[0].src+' -> '+msgs[0].dst+' '+msgs[0].proto], ['exchange', 'terminal', 'terminal cleanup / task completes'], ['terminal', 'annotations', 'CTL over visible fields']]:[['pre', 'exchange', 'entry'], ['exchange', 'terminal', 'terminal cleanup / task completes'], ['terminal', 'annotations', 'CTL over visible fields']];

  }
  function resizeCanvas(){
    let area=0, maxW=0, maxH=0;
    for(const n of nodes){
      const s=groupSize(n);
      area+=s.w*s.h;
      maxW=Math.max(maxW, s.w);
      maxH=Math.max(maxH, s.h);

    }
    const wantW=Math.max(1380, maxW+900, Math.ceil(Math.sqrt(area))*2+820), wantH=Math.max(900, maxH+660, 360+nodes.length*260, Math.ceil(Math.sqrt(area))*2+620);
    if(cv.width!==wantW||cv.height!==wantH){
      const ox=cv.width/2, oy=cv.height/2;
      cv.width=wantW;
      cv.height=wantH;
      for(const n of nodes){
        n.x+=wantW/2-ox;
        n.y+=wantH/2-oy;

      }

    }

  }
  function clamp(n){
    const s=groupSize(n), m=180;
    n.x=Math.max(s.w/2+m, Math.min(cv.width-s.w/2-m, n.x));
    n.y=Math.max(s.h/2+m, Math.min(cv.height-s.h/2-m, n.y));

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
  function separateRects(){
    for(let pass=0;
    pass<16;
    pass++){
      let moved=false;
      for(let i=0;
      i<nodes.length;
      i++)for(let j=i+1;
      j<nodes.length;
      j++){
        const a=nodes[i], b=nodes[j], as=groupSize(a), bs=groupSize(b);
        moved=overlapPush(a, b, as.w, as.h, bs.w, bs.h, cv.width/2, cv.height/2, 150, ()=>clamp(a), ()=>clamp(b))||moved;

      }
      if(!moved)break;

    }

  }
  function flowWeights(ids, es){
    let w=new Map(ids.map(id=>[id, 1])), out=new Map(ids.map(id=>[id, 0]));
    for(const e of es)out.set(e[0], (out.get(e[0])||0)+1);
    for(let k=0;
    k<14;
    k++){
      const next=new Map(ids.map(id=>[id, .18]));
      for(const e of es){
        const share=(w.get(e[0])||1)/Math.max(1, out.get(e[0])||1);
        next.set(e[1], (next.get(e[1])||.18)+.82*share);

      }
      w=next;

    }
    return w;

  }
  function edgeCorridors(by){
    if(!cutBox.checked)return;
    for(const e of edges){
      const a=by.get(e[0]), b=by.get(e[1]);
      if(!a||!b)continue;
      const ax=a.x, ay=a.y, bx=b.x, byy=b.y, ex=bx-ax, ey=byy-ay, len2=Math.max(1, ex*ex+ey*ey);
      for(const n of nodes){
        if(n.id===a.id||n.id===b.id||n.pinned)continue;
        const s=groupSize(n), t=Math.max(0, Math.min(1, ((n.x-ax)*ex+(n.y-ay)*ey)/len2)), px=ax+ex*t, py=ay+ey*t, dx=n.x-px, dy=n.y-py, d=Math.max(1, Math.sqrt(dx*dx+dy*dy)), corridor=Math.max(s.w, s.h)/2+92;
        if(d<corridor){
          const f=(corridor-d)*0.028;
          n.vx+=dx/d*f;
          n.vy+=dy/d*f;

        }

      }

    }

  }
  function stepForce(){
    const by=new Map(nodes.map(n=>[n.id, n])), cx=cv.width/2, weight=flowWeights(nodes.map(n=>n.id), edges);
    for(const n of nodes){
      if(n.pinned)continue;
      const w=weight.get(n.id)||1;
      n.vx+=(cx-n.x)*0.00045;
      n.vy+=(170+n.rank*280+w*74-n.y)*(0.0022+Math.min(w, 4)*0.00045);

    }
    for(const e of edges){
      const a=by.get(e[0]), b=by.get(e[1]);
      if(!a||!b)continue;
      const bw=weight.get(b.id)||1, as=groupSize(a), bs=groupSize(b), dx=b.x-a.x, dy=b.y-a.y, d=Math.max(1, Math.sqrt(dx*dx+dy*dy));
      const targetY=(as.h+bs.h)/2+210+bw*54, targetX=Math.max((as.w+bs.w)/2+190, 340);
      const fy=(dy-targetY)*(0.013+Math.min(bw, 4)*0.0025), fx=(Math.abs(dx)-targetX)*0.0015*Math.sign(dx||1);
      if(!a.pinned){
        a.vy+=fy;
        a.vx+=fx;

      }
      if(!b.pinned){
        b.vy-=fy;
        b.vx-=fx;

      }
      if(b.y<a.y+targetY){
        const push=(a.y+targetY-b.y)*(0.034+Math.min(bw, 4)*0.006);
        if(!a.pinned)a.vy-=push;
        if(!b.pinned)b.vy+=push;

      }

    }
    edgeCorridors(by);
    for(let i=0;
    i<nodes.length;
    i++)for(let j=i+1;
    j<nodes.length;
    j++){
      const a=nodes[i], b=nodes[j], as=groupSize(a), bs=groupSize(b);
      let dx=b.x-a.x, dy=b.y-a.y;
      if(Math.abs(dx)<1&&Math.abs(dy)<1){
        dx=7;
        dy=5;

      }
      const d2=Math.max(1, dx*dx+dy*dy), d=Math.sqrt(d2), near=Math.max((as.w+bs.w)/2+230, (as.h+bs.h)/2+210), rep=(near*near*0.34)/d2, rx=rep*dx/d, ry=rep*dy/d;
      if(!a.pinned){
        a.vx-=rx;
        a.vy-=ry;

      }
      if(!b.pinned){
        b.vx+=rx;
        b.vy+=ry;

      }

    }
    separateRects();
    for(const n of nodes){
      if(n.pinned){
        n.vx=0;
        n.vy=0;

      }
      else{
        n.vx=Math.max(-22, Math.min(22, n.vx*0.34));
        n.vy=Math.max(-22, Math.min(22, n.vy*0.34));
        n.x+=n.vx;
        n.y+=n.vy;

      }
      clamp(n);

    }
    separateRects();

  }
  function clampSubjectChild(c, parent){
    const s=groupSize(parent);
    c.x=Math.max(parent.x-s.w/2+145, Math.min(parent.x+s.w/2-145, c.x));
    c.y=Math.max(parent.y-s.h/2+76, Math.min(parent.y+s.h/2-46, c.y));

  }
  function separateSubjectChildren(parent, kids){
    for(let pass=0;
    pass<16;
    pass++){
      let moved=false;
      for(let i=0;
      i<kids.length;
      i++)for(let j=i+1;
      j<kids.length;
      j++){
        const a=kids[i], b=kids[j];
        moved=overlapPush(a, b, 260, 40, 260, 40, parent.x, parent.y, 32, ()=>clampSubjectChild(a, parent), ()=>clampSubjectChild(b, parent))||moved;

      }
      if(!moved)break;

    }

  }
  function childState(parent, id, i, total){
    const key=parent.id+'|'+id;
    let c=childById.get(key);
    const s=groupSize(parent), cols=Math.max(1, Math.ceil(Math.sqrt(total))), rows=Math.max(1, Math.ceil(total/cols)), col=i%cols, row=Math.floor(i/cols);
    const left=parent.x-s.w/2+170, right=parent.x+s.w/2-170;
    const top=parent.y-s.h/2+96, bottom=parent.y+s.h/2-66;
    const tx=cols<=1?parent.x:left+(col/(cols-1))*(right-left);
    const ty=rows<=1?(top+bottom)/2:top+(row/(rows-1))*(bottom-top);
    if(!c){
      c={
        id, key, x:tx, y:ty, vx:0, vy:0, pinned:false, parent:parent.id
      };
      childById.set(key, c);

    }
    if(!c.pinned){
      c.vx+=(tx-c.x)*0.018;
      c.vy+=(ty-c.y)*0.018;
      c.vx=Math.max(-8, Math.min(8, c.vx*0.38));
      c.vy=Math.max(-8, Math.min(8, c.vy*0.38));
      c.x+=c.vx;
      c.y+=c.vy;

    }
    clampSubjectChild(c, parent);
    return c;

  }
  function hasMsgIncident(key){
    return concreteEdges().some(e=>e[3]==='msg'&&(e[0]===key||e[1]===key));

  }
  function drawNode(n){
    const s=groupSize(n), x=n.x-s.w/2, y=n.y-s.h/2;
    ctx.fillStyle=openGroups.has(n.id)?'#111827':'#000';
    ctx.strokeStyle=n.color;
    ctx.lineWidth=2;
    ctx.fillRect(x, y, s.w, s.h);
    ctx.strokeRect(x, y, s.w, s.h);
    ctx.fillStyle='#fff';
    ctx.font='15px sans-serif';
    ctx.textAlign='center';
    ctx.fillText(n.label, n.x, y+26);
    ctx.font='12px sans-serif';
    ctx.fillText(openGroups.has(n.id)?'open: click to collapse':'closed: click to expand', n.x, y+47);
    hit.push({
      kind:'group', id:n.id, x, y, w:s.w, h:s.h
    });
    if(openGroups.has(n.id)){
      const labels=groupChildren(n), kids=labels.map((st, i)=>childState(n, st, i, labels.length));
      separateSubjectChildren(n, kids);
      kids.forEach((c, i)=>{
        const color=i===0?'#93c5fd':i===labels.length-1?'#22c55e':n.color;
        rect(c.x-130, c.y-20, 260, 40, labels[i], color);
        if(!hasMsgIncident(c.key)){
          ctx.fillStyle='#9ca3af';
          ctx.font='10px sans-serif';
          ctx.textAlign='right';
          ctx.fillText('no message edge', c.x+124, c.y+17);

        }
        hit.push({
          kind:'child', id:c.key, x:c.x-130, y:c.y-20, w:260, h:40
        });

      });

    }

  }
  function endpoint(id){
    const parent=id.split('|')[0], pn=nodes.find(n=>n.id===parent), child=childById.get(id);
    if(child&&openGroups.has(parent))return{
      kind:'child', id, x:child.x, y:child.y, w:260, h:40, parent
    };
    if(pn){
      const s=groupSize(pn);
      return{
        kind:'group', id:parent, x:pn.x, y:pn.y, w:s.w, h:s.h, parent
      };

    }
    return null;

  }
  function portFrom(ep, to){
    const dx=to.x-ep.x, dy=to.y-ep.y, m=Math.min((ep.w/2+10)/Math.max(1, Math.abs(dx)), (ep.h/2+10)/Math.max(1, Math.abs(dy)));
    return{
      x:ep.x+dx*m, y:ep.y+dy*m
    };

  }
  function edgeStyle(kind){
    return kind==='msg'?{
      c:'#fbbf24', d:false, name:'message send'
    }
    :kind==='optional'?{
      c:'#9ca3af', d:true, name:'optional analysis'
    }
    :{
      c:'#64748b', d:true, name:'structural'
    };

  }
  function drawConcreteEdges(){
    const seen=new Map();
    const blockers=hit.filter(h=>h.kind==='child').map(h=>({
      x:h.x-8, y:h.y-8, w:h.w+16, h:h.h+16
    }));
    for(const e of concreteEdges()){
      const a=endpoint(e[0]), b=endpoint(e[1]);
      if(!a||!b)continue;
      const st=edgeStyle(e[3]);
      const collapsed=a.kind==='group'&&b.kind==='group'&&a.id===b.id;
      if(collapsed){
        const key=a.id+'|'+e[3];
        seen.set(key, {
          gid:a.id, kind:e[3], labels:(seen.get(key)?.labels||[]).concat(e[2])
        });
        continue;

      }
      const p1=portFrom(a, b), p2=portFrom(b, a);
      arrow(p1.x, p1.y, p2.x, p2.y, st.c, st.d);
      labelBox((p1.x+p2.x)/2, (p1.y+p2.y)/2-16, st.name+': '+e[2], st.c, 300, blockers);

    }
    for(const item of seen.values()){
      const n=nodes.find(x=>x.id===item.gid);
      if(!n)continue;
      const st=edgeStyle(item.kind);
      labelBox(n.x, n.y+18, item.labels.length+' '+st.name+' edge(s) inside: '+item.labels.slice(0, 2).join(' | '), st.c, 340);

    }

  }
  function edgeTouchesHover(e){
    if(!hover)return false;
    if(hover.kind==='child')return e[0]===hover.id||e[1]===hover.id;
    if(hover.kind==='group'){
      const gid=hover.id+'|';
      return e[0].startsWith(gid)||e[1].startsWith(gid);

    }
    return false;

  }
  function drawHighlightedEdges(){
    if(!hover)return;
    const blockers=hit.filter(h=>h.kind==='child').map(h=>({
      x:h.x-8, y:h.y-8, w:h.w+16, h:h.h+16
    }));
    for(const e of concreteEdges()){
      if(!edgeTouchesHover(e))continue;
      const a=endpoint(e[0]), b=endpoint(e[1]);
      if(!a||!b)continue;
      const st=edgeStyle(e[3]);
      if(a.kind==='group'&&b.kind==='group'&&a.id===b.id){
        labelBox(a.x, a.y+54, st.name+': '+e[2], '#38bdf8', 320, blockers);
        continue;

      }
      const p1=portFrom(a, b), p2=portFrom(b, a);
      arrow(p1.x, p1.y, p2.x, p2.y, '#38bdf8', st.d);
      labelBox((p1.x+p2.x)/2, (p1.y+p2.y)/2-24, st.name+': '+e[2], '#38bdf8', 320, blockers);

    }

  }
  function drawLegend(){
    ctx.textAlign='left';
    ctx.font='12px sans-serif';
    ctx.fillStyle='#fbbf24';
    ctx.fillText('solid amber = concrete src -> dst message send', 18, 24);
    ctx.fillStyle='#9ca3af';
    ctx.fillText('dashed gray = structural or optional non-message edge', 18, 42);

  }
  function render(){
    if(!nodes.length)build();
    if(!drag)resizeCanvas();
    stepForce();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.fillStyle='#111';
    ctx.fillRect(0, 0, cv.width, cv.height);
    ctx.setTransform(view.z, 0, 0, view.z, view.x, view.y);
    title.textContent=model.label||model.task||model.id||'Current draft';
    summary.textContent='Persistent browser model: '+(model.actors||[]).length+' actors, '+(model.messages||[]).length+' visible messages, '+(model.properties||[]).length+' properties. Click composite states to open or close them.';
    hit=[];
    for(const n of nodes)drawNode(n);
    drawConcreteEdges();
    drawHighlightedEdges();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    drawLegend();
    requestAnimationFrame(render);

  }
  function save(next){
    model=Object.assign({

    }, empty, next);
    localStorage.setItem('leanfm.subject', JSON.stringify(model));
    build();

  }
  function textCard(title, text){
    const d=document.createElement('details');
    d.open=true;
    d.innerHTML='<summary>'+esc(title)+'</summary><pre>'+esc(text)+'</pre>';
    artifacts.prepend(d);

  }
  function linkCard(title, links){
    const d=document.createElement('details');
    d.open=true;
    d.innerHTML='<summary>'+esc(title)+'</summary>'+links.map(x=>'<p><a href="'+esc(x.href)+'">'+esc(x.label)+'</a></p>').join('');
    artifacts.prepend(d);

  }
  function latexHtml(s){
    return esc(s).replace(/\\cdot/g, '&middot;').replace(/\\alpha/g, 'alpha').replace(/\\beta/g, 'beta').replace(/\\lambda/g, 'lambda').replace(/([A-Za-z0-9)]+)\^\{([^}]+)\}/g, '$1<sup>$2</sup>').replace(/([A-Za-z0-9)]+)_\{([^}]+)\}/g, '$1<sub>$2</sub>');

  }
  function mdInline(s){
    const parts=String(s).split(/(\$[^$]+\$)/g);
    return parts.map(p=>p.startsWith('$')&&p.endsWith('$')?'<span style="font-family:ui-serif,serif;border:1px solid #333;background:#050505;padding:.05rem .25rem">'+latexHtml(p.slice(1, -1))+'</span>':esc(p)).join('');

  }
  function renderMarkdownCard(title, md){
    const blocks=String(md).split(/(\$\$[\s\S]*?\$\$)/g);
    const html=blocks.map(block=>{
      if(block.startsWith('$$')&&block.endsWith('$$')){
        return '<div style="font-family:ui-serif,serif;background:#050505;border:1px solid #333;padding:.75rem;margin:.6rem 0;text-align:center">'+latexHtml(block.slice(2, -2).trim())+'</div>';

      }
      return block.split(/\n/).map(line=>{
        if(/^###\s+/.test(line))return '<h4>'+mdInline(line.replace(/^###\s+/, ''))+'</h4>';
        if(/^##\s+/.test(line))return '<h3>'+mdInline(line.replace(/^##\s+/, ''))+'</h3>';
        if(/^#\s+/.test(line))return '<h2>'+mdInline(line.replace(/^#\s+/, ''))+'</h2>';
        if(/^-\s+/.test(line))return '<p style="margin:.35rem 0 0 1rem">- '+mdInline(line.replace(/^-\s+/, ''))+'</p>';
        if(!line.trim())return '';
        return '<p>'+mdInline(line)+'</p>';

      }).join('');

    }).join('');
    const d=document.createElement('details');
    d.open=true;
    d.innerHTML='<summary>'+esc(title)+'</summary><div style="padding:1rem">'+html+'</div>';
    artifacts.prepend(d);

  }
  function screenPoint(ev){
    const r=cv.getBoundingClientRect();
    return{
      x:(ev.clientX-r.left)*cv.width/r.width, y:(ev.clientY-r.top)*cv.height/r.height
    };

  }
  function point(ev){
    const p=screenPoint(ev);
    return{
      x:(p.x-view.x)/view.z, y:(p.y-view.y)/view.z
    };

  }
  function hitAt(p){
    return hit.filter(h=>p.x>=h.x-12&&p.x<=h.x+h.w+12&&p.y>=h.y-12&&p.y<=h.y+h.h+12).sort((a, b)=>(a.w*a.h)-(b.w*b.h))[0];

  }
  cv.style.touchAction='none';
  cv.style.cursor='grab';
  cv.addEventListener('wheel', ev=>{
    ev.preventDefault();
    const p=screenPoint(ev);
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
  if(zoomIn)zoomIn.addEventListener('click', ()=>zoomCenter(1.25));
  if(zoomOut)zoomOut.addEventListener('click', ()=>zoomCenter(0.8));
  if(zoomReset)zoomReset.addEventListener('click', ()=>{
    view={
      x:0, y:0, z:1
    };
    saveView();
    updateZoomLabel();

  });
  cv.addEventListener('pointerdown', ev=>{
    ev.preventDefault();
    const p=point(ev), h=hitAt(p);
    if(!h){
      const s=screenPoint(ev);
      pan={
        x:s.x, y:s.y, viewX:view.x, viewY:view.y
      };
      cv.setPointerCapture(ev.pointerId);
      cv.style.cursor='grabbing';
      return;

    }
    if(h.kind==='child'){
      const c=childById.get(h.id);
      if(!c)return;
      c.pinned=true;
      c.vx=0;
      c.vy=0;
      drag={
        kind:'child', node:c, offX:p.x-c.x, offY:p.y-c.y, moved:false
      };

    }
    else{
      const n=nodes.find(x=>x.id===h.id);
      if(!n)return;
      n.pinned=true;
      n.vx=0;
      n.vy=0;
      drag={
        kind:'group', node:n, offX:p.x-n.x, offY:p.y-n.y, moved:false
      };

    }
    cv.setPointerCapture(ev.pointerId);
    cv.style.cursor='grabbing';

  });
  cv.addEventListener('pointermove', ev=>{
    const p=point(ev);
    if(pan){
      ev.preventDefault();
      const s=screenPoint(ev);
      view.x=pan.viewX+s.x-pan.x;
      view.y=pan.viewY+s.y-pan.y;
      clampView();
      saveView();
      return;

    }
    if(!drag){
      hover=hitAt(p)||null;
      cv.style.cursor=hover?'grab':'default';
      return;

    }
    ev.preventDefault();
    drag.moved=true;
    drag.node.x=p.x-drag.offX;
    drag.node.y=p.y-drag.offY;
    drag.node.vx=0;
    drag.node.vy=0;
    if(drag.kind==='group')clamp(drag.node);

  });
  cv.addEventListener('pointerup', ev=>{
    if(pan){
      ev.preventDefault();
      try{
        cv.releasePointerCapture(ev.pointerId);

      }
      catch(e){

      }
      pan=null;
      cv.style.cursor='grab';

    }
    if(drag){
      ev.preventDefault();
      try{
        cv.releasePointerCapture(ev.pointerId);

      }
      catch(e){

      }
      if(!drag.moved&&drag.kind==='group'){
        openGroups.has(drag.node.id)?openGroups.delete(drag.node.id):openGroups.add(drag.node.id);
        localStorage.setItem('leanfm.subject.open', JSON.stringify([...openGroups]));

      }
      drag=null;
      cv.style.cursor='grab';

    }

  });
  cv.addEventListener('pointercancel', ev=>{
    drag=null;
    pan=null;
    cv.style.cursor='grab';

  });
  cv.addEventListener('pointerleave', ev=>{
    if(!drag&&!pan)hover=null;

  });
  cv.addEventListener('dblclick', ev=>{
    ev.preventDefault();
    const p=point(ev), h=hitAt(p);
    if(!h)return;
    if(h.kind==='child'){
      const c=childById.get(h.id);
      if(c)c.pinned=false;

    }
    else{
      const n=nodes.find(x=>x.id===h.id);
      if(n)n.pinned=false;

    }

  });
  window.LeanFMUI={
    setSubject:save, renderText:textCard, renderLinks:linkCard, renderMarkdown:renderMarkdownCard, getSubject:()=>model
  };
  build();
  updateZoomLabel();
  render();

})();
