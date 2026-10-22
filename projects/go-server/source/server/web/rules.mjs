// Requirement refs: working-contract.json R1, R2. Differential-tested against Go.
export const colors = ["Black", "White", "Red", "Blue", "Green", "Gold"];
export const inks = ["#171a23", "#fafafa", "#db3a4b", "#3488eb", "#22a772", "#edb930"];
export function initial(size=11, players=4, max_turns=200) {
  if (!Number.isInteger(size)||size<3||size>19||!Number.isInteger(players)||players<2||players>6||!Number.isInteger(max_turns)||max_turns<players||max_turns>512) throw Error("Board 3–19, players 2–6, maximum turns players–512 required.");
  return {size,players,max_turns,board:Array(size*size).fill(0),turn:0,losses:Array(players).fill(0),ledger:Array(players*players).fill(0),active:Array(players).fill(true),passes:0,ply:0,finished:false,last:-1};
}
export function neighbors(point,size) { const out=[];if(point%size)out.push(point-1);if(point%size<size-1)out.push(point+1);if(point>=size)out.push(point-size);if(point<size*(size-1))out.push(point+size);return out; }
function group(board,size,start) { const stones=[start],seen=new Set(stones);let liberty=false;for(let i=0;i<stones.length;i++)for(const p of neighbors(stones[i],size)){if(!board[p])liberty=true;else if(board[p]===board[start]&&!seen.has(p)){seen.add(p);stones.push(p)}}return {stones,liberty}; }
export function apply(old,action) {
  if(old.finished)throw Error("Game has finished.");
  if(!["move","pass","resign"].includes(action.kind))throw Error("Unknown action.");
  if(action.kind==="move"&&(!Number.isInteger(action.point)||action.point<0||action.point>=old.board.length||old.board[action.point]))throw Error("Intersection is occupied or outside the board.");
  const s={...old,board:[...old.board],losses:[...old.losses],ledger:[...old.ledger],active:[...old.active],last:-1,ply:old.ply+1},p=s.turn;
  if(action.kind==="pass")s.passes++;
  if(action.kind==="resign"){s.active[p]=false;s.passes=0}
  if(action.kind==="move"){
    s.passes=0;s.last=action.point;s.board[action.point]=p+1;
    const removed=[],seen=new Set();
    for(const next of neighbors(action.point,s.size))if(s.board[next]&&s.board[next]!==p+1&&!seen.has(next)){const g=group(s.board,s.size,next);g.stones.forEach(x=>seen.add(x));if(!g.liberty)removed.push(...g.stones)}
    for(const point of removed){const victim=s.board[point]-1;s.losses[victim]++;s.ledger[p*s.players+victim]++;s.board[point]=0}
    if(!removed.length){const g=group(s.board,s.size,action.point);if(!g.liberty)for(const point of g.stones){s.board[point]=0;s.losses[p]++;s.ledger[p*s.players+p]--}}
  }
  const active=s.active.filter(Boolean).length;s.finished=active<=1||s.passes>=active||s.ply>=s.max_turns;
  if(!s.finished)do{s.turn=(s.turn+1)%s.players}while(!s.active[s.turn]);
  return s;
}
export function score(s) {
  const territory=Array(s.players).fill(0),seen=new Set();
  for(let point=0;point<s.board.length;point++)if(!s.board[point]&&!seen.has(point)){const region=[point],boundary=new Set();seen.add(point);for(let i=0;i<region.length;i++)for(const n of neighbors(region[i],s.size)){if(s.board[n])boundary.add(s.board[n]);else if(!seen.has(n)){seen.add(n);region.push(n)}}if(boundary.size===1)territory[[...boundary][0]-1]+=region.length}
  return {territory,losses:[...s.losses],total:territory.map((t,p)=>t-s.losses[p])};
}
export function actions(s) { return s.finished?[]:[{kind:"pass",point:0},...s.board.flatMap((stone,point)=>stone?[]:[{kind:"move",point}])]; }
export function seeded(seed) { let n=seed>>>0;return ()=>{n=(Math.imul(1664525,n)+1013904223)>>>0;return n/4294967296}; }
export function search(position,{milliseconds=300,iterations=100000,seed=42,maxNodes=1024}={}) {
  milliseconds=Number.isFinite(milliseconds)?Math.max(0,Math.min(60000,milliseconds)):0;iterations=Number.isFinite(iterations)?Math.max(0,Math.min(100000,iterations)):0;maxNodes=Number.isFinite(maxNodes)?Math.max(1,Math.min(1024,Math.floor(maxNodes))):1;
  const random=seeded(seed),start=performance.now(),root={s:position,children:[],untried:actions(position),visits:0,values:Array(position.players).fill(0)};
  const node=(s,parent,action)=>({s,parent,action,children:[],untried:actions(s),visits:0,values:Array(s.players).fill(0)});
  let completed=0,nodeCount=1;
  while(completed<iterations&&performance.now()-start<milliseconds&&!position.finished){
    let n=root;
    while(!n.untried.length&&n.children.length){const p=n.s.turn;n=n.children.reduce((a,b)=>{const u=c=>c.values[p]/Math.max(1,c.visits)+Math.sqrt(2*Math.log(n.visits+1)/Math.max(1,c.visits));return u(a)>=u(b)?a:b})}
    if(n.untried.length&&nodeCount<maxNodes){const index=n===root&&completed===0?0:Math.floor(random()*n.untried.length),a=n.untried.splice(index,1)[0],child=node(apply(n.s,a),n,a);n.children.push(child);n=child;nodeCount++}
    let rollout=n.s;
    for(let depth=0;depth<48&&!rollout.finished;depth++){if(performance.now()-start>=milliseconds)break;const legal=actions(rollout);rollout=apply(rollout,legal[Math.floor(random()*legal.length)])}
    const totals=score(rollout).total;
    const values=totals.map((value,p)=>(totals.filter(v=>v<value).length+.5*totals.filter(v=>v===value).length)/totals.length);
    for(let cursor=n;cursor;cursor=cursor.parent){cursor.visits++;values.forEach((v,p)=>cursor.values[p]+=v)}completed++;
  }
  const best=[...root.children].sort((a,b)=>b.visits-a.visits||(b.values[position.turn]/b.visits-a.values[position.turn]/a.visits))[0];
  return {action:best?.action||{kind:"pass",point:0},iterations:completed,nodeCount,elapsed:performance.now()-start,candidates:root.children.sort((a,b)=>b.visits-a.visits).slice(0,5).map(c=>({action:c.action,visits:c.visits}))};
}
