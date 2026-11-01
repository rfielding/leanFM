// Requirement refs: property:Analysis is local. The Lab's max^n UCT search worker, run in the viewer's browser.
importScripts('./engine.js');
// ===== max^n UCT search worker =====
var g=null;
self.onmessage=function(e){var d=e.data;if(d.cmd==='search')search(d);};
function search(d){
  if(!g||g.N!==d.N)g=makeGeom(d.N);
  var r0=d.state,root={k:r0.k,cells:Int8Array.from(r0.cells),losses:Int32Array.from(r0.losses),toMove:r0.toMove,passes:r0.passes,ko:r0.ko,koColor:r0.koColor,koUntil:r0.koUntil,moveNo:r0.moveNo,hash:r0.hash>>>0,koOn:!!r0.koOn,out:r0.out|0,pm:r0.pm|0,to:r0.to|0};
  var k=root.k,P=d.params,hist=new Set(d.history),rng=mulberry32(d.seed);
  var R={move:-2,parent:null,children:[],untried:genMoves(g,root),n:0,W:new Float64Array(k+1),key:stateKey(g,root)};
  var scoreSum=new Float64Array(k+1),t0=performance.now(),stopAt=t0+P.budget,iters=0,lastPost=t0;
  var nodes=1,NODE_CAP=700000;
  function repeats(key,node){if(hist.has(key))return true;for(var p=node;p;p=p.parent)if(p.key===key)return true;return false;}
  function iterate(){
    var s=cloneState(root),node=R,path=[R];
    while(node.untried&&node.untried.length===0&&node.children.length>0){
      var p=s.toMove,lnN=Math.log(node.n),best=null,bv=-1e18;
      for(var i=0;i<node.children.length;i++){var ch=node.children[i],v=ch.W[p]/ch.n+P.C*Math.sqrt(lnN/ch.n);if(v>bv){bv=v;best=ch;}}
      node=best;play(g,s,node.move);path.push(node);
    }
    if(!isTerminal(g,s)){
      if(node.untried===null&&nodes<NODE_CAP)node.untried=genMoves(g,s);
      while(nodes<NODE_CAP&&node.untried&&node.untried.length>0){
        var u=node.untried,j=(rng()*u.length)|0,m=u[j];u[j]=u[u.length-1];u.pop();
        var s2=cloneState(s);play(g,s2,m);var key=stateKey(g,s2);
        if(m>=0&&root.koOn&&repeats(key,node))continue;
        var c2={move:m,parent:node,children:[],untried:isTerminal(g,s2)?[]:null,n:0,W:new Float64Array(k+1),key:key};
        node.children.push(c2);nodes++;node=c2;s=s2;path.push(c2);break;
      }
    }
    while(!isTerminal(g,s))play(g,s,playoutMove(g,s,rng));
    var sc=scoreState(g,s,false).scores,rw=rewards(sc,k,P.mode,P.T,P.teams||null);
    for(var a=0;a<path.length;a++){var nd=path[a];nd.n++;for(var b=1;b<=k;b++)nd.W[b]+=rw[b];}
    for(b=1;b<=k;b++)scoreSum[b]+=sc[b];
    if(path.length>1){var c1=path[1];if(!c1.S)c1.S=new Float64Array(k+1);for(b=1;b<=k;b++)c1.S[b]+=sc[b];}
  }
  function summary(done){
    var mover=root.toMove,kids=R.children.slice().sort(function(a,b){return b.n-a.n||b.W[mover]-a.W[mover];});
    var top=kids.slice(0,24).map(function(c){var qs=[],pj=[];for(var i=1;i<=k;i++){qs.push(c.W[i]/c.n);pj.push(c.S?c.S[i]/c.n:0);}return {move:c.move,n:c.n,q:c.W[mover]/c.n,qs:qs,proj:pj};});
    var rootQ=[],proj=[];for(var i=1;i<=k;i++){rootQ.push(R.n?R.W[i]/R.n:0);proj.push(R.n?scoreSum[i]/R.n:0);}
    var move=top.length?top[0].move:-1,guard=false;
    // Pass guard: random playouts capture dead stones "for free", but if everyone passes the real board is scored as it stands.
    // Only pass when the board as it is now already rewards the mover at least as well as the best real move.
    if(done&&move===-1&&!isOut(root,mover)){
      // Cleanup guard: before passing, capture any enemy group sealed inside the mover's area when filling its
      // liberties pays for itself (territory freed under it, minus own territory used up, is at least +1 point).
      var cm=cleanupMove(g,root,mover,P.teams||null);
      if(cm>=0){move=cm;guard=true;}
    }
    return {type:done?'done':'progress',id:d.id,iters:iters,total:R.n,ms:performance.now()-t0,top:top,rootQ:rootQ,proj:proj,mover:mover,move:move,guard:guard};
  }
  // Runs in slices so the same code can also run on the page's main thread when no Worker is allowed.
  function slice(){
    if(self.__stopped)return;
    var sliceEnd=performance.now()+(self.__local?14:250);
    for(;;){
      for(var b=0;b<32;b++){iterate();iters++;}
      var now=performance.now();
      if(now>=stopAt){postMessage(summary(true));return;}
      if(now-lastPost>160){postMessage(summary(false));lastPost=now;}
      if(now>=sliceEnd)break;
    }
    setTimeout(slice,0);
  }
  slice();
}
