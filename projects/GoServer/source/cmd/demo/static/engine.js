// Requirement refs: property:Analysis is local; property:play_move rules.
// The N-Player Go Lab engine, unchanged: geometry, rules, scoring, rewards and cleanup.
// The server engine (source/engine.go) is a port of this file.
// ===== shared engine (runs in page and in the search worker) =====
var MAXP = 8, WALL = -1, OPEN = 0;
function mulberry32(a){return function(){a|=0;a=a+0x6D2B79F5|0;var t=Math.imul(a^a>>>15,1|a);t=t+Math.imul(t^t>>>7,61|t)^t;return((t^t>>>14)>>>0)/4294967296;};}
function makeGeom(N){
  var W=N+2, A=W*W, cells0=new Int8Array(A).fill(WALL), pts=[];
  for(var y=0;y<N;y++)for(var x=0;x<N;x++){var i=(y+1)*W+x+1;cells0[i]=OPEN;pts.push(i);}
  var r=mulberry32(0x5EED+N), zob=new Uint32Array(A*(MAXP+1)), zt=new Uint32Array(MAXP+1);
  for(var j=0;j<zob.length;j++)zob[j]=(r()*4294967296)>>>0;
  for(j=0;j<zt.length;j++)zt[j]=(r()*4294967296)>>>0;
  return {N:N,W:W,A:A,cells0:cells0,zob:zob,zt:zt,pts:Int32Array.from(pts),
    mark:new Int32Array(A),lmark:new Int32Array(A),stamp:0,stack:new Int32Array(A),scratch:new Int32Array(A),off:[-1,1,-W,W]};
}
function newState(g,k,ko){return {k:k,cells:g.cells0.slice(),losses:new Int32Array(MAXP+1),toMove:1,passes:0,ko:-1,koColor:0,koUntil:0,moveNo:0,hash:0,koOn:ko===undefined?k<=2:!!ko,out:0,pm:0,to:0};}
function cloneState(s){return {k:s.k,cells:s.cells.slice(),losses:s.losses.slice(),toMove:s.toMove,passes:s.passes,ko:s.ko,koColor:s.koColor,koUntil:s.koUntil,moveNo:s.moveNo,hash:s.hash,koOn:s.koOn,out:s.out,pm:s.pm,to:s.to};}
function stateKey(g,s){return (s.hash^g.zt[s.toMove])>>>0;}
var RESIGN=-3,TIMEOUT=-4;
// The game ends when every player still in it has actually passed since the last stone was played.
// Timeouts leave the board unchanged but neither count toward the end nor reset it. Resigned seats are left out.
// A full round in which every player still in the game times out means the game was abandoned: it ends, scored as it stands.
function activeCount(s){var n=0;for(var q=1;q<=s.k;q++)if(!(s.out&(1<<q)))n++;return n;}
function isAbandoned(s){return s.to>0&&s.to>=activeCount(s);}
function isTerminal(g,s){var all=(1<<(s.k+1))-2;return ((s.pm|s.out)&all)===all || isAbandoned(s) || s.moveNo>=g.N*g.N*3;}
function isOut(s,p){return (s.out&(1<<p))!==0;}
function libsUpTo(g,s,p,limit){
  var c=s.cells,st=++g.stamp,col=c[p],stack=g.stack,mark=g.mark,lm=g.lmark,off=g.off,sp=0,libs=0;
  stack[sp++]=p;mark[p]=st;
  while(sp){var q=stack[--sp];for(var d=0;d<4;d++){var n=q+off[d],v=c[n];
    if(v===0){if(lm[n]!==st){lm[n]=st;if(++libs>=limit)return libs;}}
    else if(v===col&&mark[n]!==st){mark[n]=st;stack[sp++]=n;}}}
  return libs;
}
function removeGroup(g,s,p){
  var c=s.cells,col=c[p],st=++g.stamp,stack=g.stack,mark=g.mark,off=g.off,sp=0,cnt=0,Z=MAXP+1;
  stack[sp++]=p;mark[p]=st;
  while(sp){var q=stack[--sp];c[q]=0;s.hash^=g.zob[q*Z+col];cnt++;
    for(var d=0;d<4;d++){var n=q+off[d];if(c[n]===col&&mark[n]!==st){mark[n]=st;stack[sp++]=n;}}}
  return cnt;
}
function isLegal(g,s,m){
  if(m<0)return true;
  if(isOut(s,s.toMove))return false;
  if(s.cells[m]!==0)return false;
  if(m===s.ko&&s.toMove===s.koColor&&s.moveNo<s.koUntil)return false;
  return true;
}
function play(g,s,m){
  var c=s.toMove,cells=s.cells,res={captured:0,suicide:0,victims:null};
  if(isOut(s,c)&&(m>=0||m===TIMEOUT))m=-1; // a resigned player can only pass
  // abandonment count: consecutive timeouts; a resigned seat's automatic pass doesn't interrupt it
  if(m===TIMEOUT)s.to++;else if(!isOut(s,c))s.to=0;
  if(m===TIMEOUT){s.ko=-1;res.timeout=true;}
  else if(m===RESIGN){s.out|=1<<c;s.passes++;s.ko=-1;res.resigned=true;}
  else if(m<0){s.passes++;s.pm|=1<<c;s.ko=-1;}
  else{
    s.passes=0;s.pm=0;cells[m]=c;s.hash^=g.zob[m*(MAXP+1)+c];
    var capPt=-1,victim=0;
    for(var d=0;d<4;d++){var n=m+g.off[d],v=cells[n];
      if(v>0&&v!==c&&libsUpTo(g,s,n,1)===0){var cnt=removeGroup(g,s,n);s.losses[v]+=cnt;res.captured+=cnt;capPt=n;victim=v;
        if(!res.victims)res.victims={};res.victims[v]=(res.victims[v]||0)+cnt;}}
    if(res.captured===0){
      if(libsUpTo(g,s,m,1)===0){res.suicide=removeGroup(g,s,m);s.losses[c]+=res.suicide;}
      s.ko=-1;
    }else{
      var solo=true;for(d=0;d<4;d++)if(cells[m+g.off[d]]===c)solo=false;
      if(s.koOn&&res.captured===1&&solo&&libsUpTo(g,s,m,2)===1){s.ko=capPt;s.koColor=victim;s.koUntil=s.moveNo+s.k;}else s.ko=-1;
    }
  }
  s.moveNo++;s.toMove=s.toMove%s.k+1;
  return res;
}
function isOwnEye(g,s,p,c){for(var d=0;d<4;d++){var v=s.cells[p+g.off[d]];if(v!==c&&v!==WALL)return false;}return true;}
// True when p lies in an empty region bordered only by colour c (and Wall): c's own territory.
// Filling it can only cost c points, so simulated (playout) players never do it.
function inOwnRegion(g,s,p,c){
  var cl=s.cells,st=++g.stamp,mark=g.mark,stack=g.stack,off=g.off,sp=0,own=false;
  stack[sp++]=p;mark[p]=st;
  while(sp){var q=stack[--sp];for(var d=0;d<4;d++){var n=q+off[d],v=cl[n];
    if(v===0){if(mark[n]!==st){mark[n]=st;stack[sp++]=n;}}
    else if(v>0){if(v!==c)return false;own=true;}}}
  return own;
}
// Endgame cleanup: find an enemy group enclosed by the mover (its liberty regions border only the mover and that
// group's colour), fill all its liberties as if nobody answers, and keep it if the mover's margin over its strongest
// rival (team totals when declared) grows by at least 1 point, counting own territory filled, territory freed and
// the victim's lost stones, and the mover loses no stones. Returns the first liberty to play, or -1.
function cleanupMove(g,s,c,teams){
  var cl=s.cells,off=g.off,done=new Uint8Array(g.A),best=-1,bestGain=0.5;
  // margin = own (or own team's) points minus the strongest rival's (or rival team's) points
  function tm(q){return teams?teams[q]:q;}
  function margin(sc){var tot={};for(var q=1;q<=s.k;q++)tot[tm(q)]=(tot[tm(q)]||0)+sc[q];
    var me=tot[tm(c)],rival=-1e9;for(var t in tot)if(+t!==tm(c))rival=Math.max(rival,tot[t]);return rival===-1e9?me:me-rival;}
  var base=margin(scoreState(g,s,false).scores);
  for(var pi=0;pi<g.pts.length;pi++){var p=g.pts[pi],v=cl[p];
    if(v<=0||v===c||done[p]||(teams&&teams[v]===teams[c]))continue;
    var grp=[],libs=[],seenL={},stk=[p],sealed=true;done[p]=1;
    while(stk.length){var q=stk.pop();grp.push(q);for(var d=0;d<4;d++){var n=q+off[d],w=cl[n];
      if(w===v&&!done[n]){done[n]=1;stk.push(n);}
      else if(w===0&&!seenL[n]){seenL[n]=1;libs.push(n);}
      else if(w>0&&w!==v&&w!==c)sealed=false;}}
    if(!sealed||libs.length>4)continue;
    // each liberty's empty region may touch only the mover and this colour
    for(var li=0;li<libs.length&&sealed;li++){var stk2=[libs[li]],vis={};vis[libs[li]]=1;
      while(stk2.length&&sealed){var r=stk2.pop();for(d=0;d<4;d++){var n2=r+off[d],w2=cl[n2];
        if(w2===0&&!vis[n2]){vis[n2]=1;stk2.push(n2);}else if(w2>0&&w2!==c&&w2!==v)sealed=false;}}}
    if(!sealed)continue;
    var s2=cloneState(s),ok=true,first=-1;
    for(li=0;li<libs.length;li++){var L=libs[li];if(s2.cells[L]!==0)continue;s2.toMove=c;s2.passes=0;s2.pm=0;
      if(!isLegal(g,s2,L)){ok=false;break;}
      var t=cloneState(s2);t.toMove=c;play(g,t,L);
      if(t.losses[c]!==s.losses[c]){ok=false;break;} // would lose own stones (suicide / self-capture)
      if(first<0){ // first stone must not be left in atari unless it captures
        if(!(t.cells[grp[0]]===0)&&libsUpTo(g,t,L,2)<2){continue;}
        first=L;}
      s2=t;}
    if(!ok||first<0||s2.cells[grp[0]]!==0)continue;
    var gain=margin(scoreState(g,s2,false).scores)-base;
    if(gain>bestGain){bestGain=gain;best=first;}
  }
  return best;
}
function wouldSuicide(g,s,p,c){
  for(var d=0;d<4;d++){var n=p+g.off[d],v=s.cells[n];
    if(v===0)return false;
    if(v===c){if(libsUpTo(g,s,n,2)>=2)return false;}
    else if(v>0){if(libsUpTo(g,s,n,2)===1)return false;}}
  return true;
}
function genMoves(g,s){var out=[-1],p=g.pts;if(isOut(s,s.toMove))return out;for(var i=0;i<p.length;i++)if(isLegal(g,s,p[i]))out.push(p[i]);return out;}
function playoutMove(g,s,rng){
  var sc=g.scratch,n=0,p=g.pts,c=s.toMove;
  if(isOut(s,c))return -1;
  for(var i=0;i<p.length;i++)if(s.cells[p[i]]===0)sc[n++]=p[i];
  while(n>0){var j=(rng()*n)|0,m=sc[j];sc[j]=sc[--n];
    if(isLegal(g,s,m)&&!isOwnEye(g,s,m,c)&&!wouldSuicide(g,s,m,c)&&!inOwnRegion(g,s,m,c))return m;}
  return -1;
}
function scoreState(g,s,wantOwner){
  var terr=new Int32Array(MAXP+1),c=s.cells,st=++g.stamp,mark=g.mark,stack=g.stack,off=g.off,p=g.pts;
  var owner=wantOwner?new Int8Array(g.A):null;
  for(var i=0;i<p.length;i++){var q0=p[i];if(c[q0]!==0||mark[q0]===st)continue;
    var sp=0,size=0,mask=0,start=sp;stack[sp++]=q0;mark[q0]=st;var region=wantOwner?[]:null;
    while(sp){var q=stack[--sp];size++;if(region)region.push(q);
      for(var d=0;d<4;d++){var n=q+off[d],v=c[n];if(v===0){if(mark[n]!==st){mark[n]=st;stack[sp++]=n;}}else if(v>0)mask|=1<<v;}}
    if(mask&&!(mask&(mask-1))){var o=31-Math.clz32(mask);terr[o]+=size;if(region)for(var r=0;r<region.length;r++)owner[region[r]]=o;}}
  var scores=new Int32Array(MAXP+1);for(i=1;i<=s.k;i++)scores[i]=terr[i]-s.losses[i];
  return {terr:terr,scores:scores,owner:owner};
}
function rewards(sc,k,mode,T,teams){
  var r=new Float64Array(MAXP+1),i,j;
  if(teams){ // allies share one reward: their summed Territory - Losses against rival teams
    var ids=[],ts={};for(i=1;i<=k;i++){var t=teams[i];if(!(t in ts)){ts[t]=0;ids.push(t);}ts[t]+=sc[i];}
    if(ids.length===1){for(i=1;i<=k;i++)r[i]=1/(1+Math.exp(-ts[ids[0]]/T));return r;}
    var tsc=new Float64Array(MAXP+1);for(j=0;j<ids.length;j++)tsc[j+1]=ts[ids[j]];
    var tr=rewards(tsc,ids.length,mode,T,null);for(i=1;i<=k;i++)r[i]=tr[ids.indexOf(teams[i])+1];return r;}
  if(mode==='win'){var mx=-1e9,n=0;for(i=1;i<=k;i++)if(sc[i]>mx)mx=sc[i];for(i=1;i<=k;i++)if(sc[i]===mx)n++;for(i=1;i<=k;i++)r[i]=sc[i]===mx?1/n:0;}
  else if(mode==='rank'){for(i=1;i<=k;i++){var above=0,eq=0;for(j=1;j<=k;j++){if(sc[j]>sc[i])above++;else if(j!==i&&sc[j]===sc[i])eq++;}r[i]=k>1?1-(above+eq/2)/(k-1):1;}}
  else{for(i=1;i<=k;i++){var best=-1e9;for(j=1;j<=k;j++)if(j!==i&&sc[j]>best)best=sc[j];r[i]=1/(1+Math.exp(-(sc[i]-best)/T));}}
  return r;
}
