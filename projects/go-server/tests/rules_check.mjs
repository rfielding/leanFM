import assert from "node:assert/strict";
import {execFileSync} from "node:child_process";
import {writeFileSync,mkdirSync} from "node:fs";
import {initial,apply,score,actions,search,seeded} from "../source/server/web/rules.mjs";
const random=seeded(713),fixtures=[],expected=[];
for(let sample=0;sample<40;sample++){
  const size=[3,5,11,19][sample%4],players=2+sample%5;let state=initial(size,players,200),states=[state],sequence=[];
  for(let i=0;i<60&&!state.finished;i++){const legal=actions(state),action=legal[Math.floor(random()*legal.length)];Object.freeze(state.board);Object.freeze(state.losses);Object.freeze(state.ledger);Object.freeze(state.active);Object.freeze(state);state=apply(state,action);states.push(state);sequence.push(action)}
  fixtures.push({size,players,max_turns:200,actions:sequence});expected.push({states,score:score(state)});
}
const output=execFileSync(".cache/replay",{input:fixtures.map(x=>JSON.stringify(x)).join("\n")+"\n",maxBuffer:32*1024*1024}).toString().trim().split("\n").map(JSON.parse);
output.forEach((actual,i)=>assert.deepEqual(actual,expected[i],`Go/browser mismatch in seeded fixture ${i}`));
let s=initial(3,4);s.board=[0,2,0,3,0,4,0,2,0];let suicide=apply(s,{kind:"move",point:4});assert.equal(suicide.losses[0],1);assert.equal(suicide.ledger[0],-1);assert.equal(suicide.board[4],0);
assert.throws(()=>apply(s,{kind:"move",point:1}));assert.equal(actions(s)[0].kind,"pass");
assert.equal(search(s,{milliseconds:0}).action.kind,"pass");
const a=search(initial(5,4),{milliseconds:60000,iterations:40,seed:42}),b=search(initial(5,4),{milliseconds:60000,iterations:40,seed:42});assert.deepEqual(a.action,b.action);assert.equal(a.iterations,40);assert.ok(a.candidates.length);
assert.equal(search(initial(5,4),{milliseconds:60000,iterations:1}).candidates[0].action.kind,"pass");
assert.equal(search(initial(5,4),{milliseconds:60000,iterations:40,maxNodes:4}).nodeCount,4);
assert.equal(search(initial(5,4),{milliseconds:Infinity,iterations:Infinity}).action.kind,"pass");
mkdirSync("evidence/playable-v1",{recursive:true});writeFileSync("evidence/playable-v1/rules.json",JSON.stringify({revision:"playable-v1",result:"pass",seed:713,fixtures:fixtures.length,transitions:fixtures.reduce((n,f)=>n+f.actions.length,0),checks:["every Go/browser intermediate position matches","score vectors match","immutable input","signed suicide ledger","illegal move rejection","Pass candidate","zero-budget Pass","seeded fixed-work MCTS"]},null,2)+"\n");
console.log(`ok: ${fixtures.length} cross-language games; ${fixtures.reduce((n,f)=>n+f.actions.length,0)} transitions; deterministic MCTS and signed suicide`);
