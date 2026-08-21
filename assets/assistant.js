const chatLog=document.getElementById('chatLog'), toolLog=document.getElementById('toolLog'), chatPrompt=document.getElementById('chatPrompt'), chatSend=document.getElementById('chatSend');
let currentDraft=null;
const artifactLinks=[['all canvas renders', '/renders/'], ['worker canvas render', '/renders/worker'], ['get_docs canvas render', '/renders/get_docs'], ['post_review canvas render', '/renders/post_review'], ['task interaction render', '/renders/tasks'], ['prometheus metrics', '/metrics'], ['generated text report', '/report'], ['generated docs', '/docs/'], ['worker DOT text', '/graph.dot'], ['auth DOT text', '/auth.dot'], ['get_docs DOT text', '/get_docs.dot'], ['post_review DOT text', '/post_review.dot'], ['task conversations DOT text', '/tasks.dot'], ['assembled DOT text', '/assembled.dot']];
function esc(s){
  return s.replace(/[&<>]/g, c=>({
    '&':'&amp;', '<':'&lt;', '>':'&gt;'
  }
  [c]));

}
function bubble(role, text){
  const d=document.createElement('div');
  d.className='bubble '+role;
  d.innerHTML=esc(text).replace(/\n/g, '<br>');
  chatLog.appendChild(d);
  chatLog.scrollTop=chatLog.scrollHeight;

}
function tool(name, args){
  const d=document.createElement('div');
  d.className='toolCall';
  d.textContent='tool: '+name+' '+JSON.stringify(args);
  toolLog.prepend(d);

}
function setSubject(s){
  currentDraft=s;
  if(window.LeanFMUI)window.LeanFMUI.setSubject(s);

}
async function callMetrics(){
  tool('get_report', {
    url:'/report'
  });
  const t=await fetch('/report').then(r=>r.text());
  const out=t.split('\n').filter(x=>x.includes('success probability')||x.includes('expected latency')||x.includes('throughput')||x.includes('Per-task FSM')).slice(0, 18).join('\n');
  if(window.LeanFMUI)window.LeanFMUI.renderText('generated metrics text', out);
  return out;

}
function callArtifacts(){
  tool('list_artifacts', {

  });
  const links=artifactLinks.map(a=>({
    label:a[0], href:a[1]
  }));
  if(window.LeanFMUI)window.LeanFMUI.renderLinks('generated render/text artifacts', links);
  return artifactLinks.map(a=>a[0]+': '+location.origin+a[1]).join('\n');

}
function callCharts(){
  tool('list_chart_datasets', {

  });
  return ['cumulative bytes over ordered messages', 'messages by task', 'messages sent by actor', 'task elapsed from ordered message timestamps', 'queue length distribution', 'worker success/failure', 'task success rates', 'expected latency and throughput'].join('\n');

}
async function callScenarioCatalog(){
  tool('scenario_catalog', {
    url:'/tools/scenarios'
  });
  return await fetch('/tools/scenarios').then(r=>r.json());

}
async function callProtocolSketchCatalog(){
  tool('protocol_sketch_catalog', {
    url:'/tools/protocol-sketches'
  });
  return await fetch('/tools/protocol-sketches').then(r=>r.json());

}
function validateSpec(text){
  tool('validate_requirement_sketch', {
    observableFieldsOnly:true
  });
  const needed=['actor', 'task', 'message'];
  const miss=needed.filter(k=>!text.toLowerCase().includes(k));
  const refsHidden=/database|memory|internal variable|private state/i.test(text);
  let out=[];
  if(miss.length)out.push('missing: '+miss.join(', '));
  if(refsHidden)out.push('reject: references hidden implementation state; use visible messages/queues/proofs instead');
  if(/token|proof|cert/i.test(text)&&!/message|field|payload/i.test(text))out.push('warning: capability should name the visible message field where it appears');
  if(!out.length)out.push('well-formed sketch: includes actor/task/message vocabulary and no obvious hidden-state references');
  const r=out.join('\n');
  if(window.LeanFMUI)window.LeanFMUI.renderText('validation result', r);
  return r;

}
function requirementTemplate(){
  tool('spec_template', {
    format:'LeanFM requirement'
  });
  return 'Requirement template\nmarkdown: each nested requirement/state may carry explanatory MD assertions\nactor: <server or monitor actor>\ntask instance: <transaction/task kind selected from a queued message>\nentry message: src -> dst proto.type fields...\nFSM states: unauthorized/authenticated/running/terminal...\nmessages: ordered visible envelopes with concrete src,dst,task,proto fields,ts,dwell\nproperties: optional CTL over visible fields only\nreducers: filter/group over ordered replay for line or pie charts';

}
function markdownLatexExample(){
  tool('markdown_latex_artifact_generate', {
    nestedObject:'requirement/markdown-render/latex'
  });
  const md='# Markdown render LaTeX\nA nested node can be an explanatory artifact rather than a temporal state.\n\n- parent: requirement Kerberos/DH trusted-token sketch\n- child object: markdown artifact with rendered equations\n- checkable references: visible message fields client_dh_share, server_dh_share, dh_commutativity_proof\n\nThe displayed proof obligation can say $client_dh_share = g^{a}$ and $server_dh_share = g^{b}$.\n\n$$\nshared_client = (g^{b})^{a} = g^{ab}\n$$\n\n$$\nshared_server = (g^{a})^{b} = g^{ba}\n$$\n\nSince multiplication in the exponent commutes for this sketch, the visible field dh_commutativity_proof can stand for $g^{ab} = g^{ba}$.';
  const draft={
    id:'markdown_latex_artifact',
    label:'Markdown/LaTeX nested artifact',
    task:'render_requirement_markdown',
    actors:['Author', 'Renderer', 'Verifier'],
    entry:'Author requests markdown render with LaTeX proof notes',
    messages:['Author -> Renderer Markdown.RenderRequest fields={markdown,latex_fragments,requirement_id}', 'Renderer -> Verifier Markdown.RenderedArtifact fields={html,math_tokens,requirement_id}', 'Verifier -> Author Markdown.RenderAccepted fields={artifact_id,requirement_id,status}'],
    properties:['AG rendered math references visible fields only', 'AF artifact accepted or rejected', 'AG accepted artifact has requirement_id'],
    reducers:['render latency by artifact', 'math token count by requirement', 'accepted/rejected pie'],
    markdown:md
  };
  setSubject(draft);
  if(window.LeanFMUI)window.LeanFMUI.renderMarkdown('nested markdown artifact: LaTeX proof notes', md);
  return 'Created a nested markdown artifact requirement. The graph shows the artifact as part of the requirement, and the side panel renders the markdown with LaTeX-style math blocks.\n\n'+md;

}
function wantsScenario(p){
  return /add|build|model|scenario|requirement|task|transaction|upload|download|delete|search|checkout|purchase|review|login/.test(p);

}
function chooseScenario(prompt, catalog){
  const p=prompt.toLowerCase();
  let hit=catalog.find(s=>p.includes(s.id)||p.includes(s.task));
  if(!hit&&/upload|put /.test(p))hit=catalog.find(s=>s.id==='upload_file');
  if(!hit&&/download|get \/files/.test(p))hit=catalog.find(s=>s.id==='download_file');
  if(!hit&&/review/.test(p))hit=catalog.find(s=>s.id==='post_review');
  if(!hit&&/doc|get /.test(p))hit=catalog.find(s=>s.id==='get_docs');
  if(hit)return JSON.parse(JSON.stringify(hit));
  const m=prompt.match(/(?:task|scenario|transaction)\s+([a-zA-Z0-9_/-]+)/);
  const name=(m?m[1]:'new_task').replace(/[^a-zA-Z0-9_]/g, '_').toLowerCase();
  return {
    id:name, task:name, actors:['Client', 'Gateway', 'Worker'], entry:'Client request for '+name, messages:['Client -> Gateway '+name+'.Request fields={request_id,payload}', 'Gateway -> Worker '+name+'.Command fields={request_id,payload}', 'Worker -> Gateway '+name+'.Result fields={status,request_id}', 'Gateway -> Client '+name+'.Response fields={status,request_id}'], properties:['AG no success without auth proof', 'AF terminal', 'AG terminal cleanup'], reducers:['latency by task', 'messages by actor', 'success/failure pie']
  };

}
function previewScenario(s){
  tool('scenario_preview_messages', {
    task:s.task, actors:s.actors
  });
  return 'Draft scenario: '+s.task+'\nentry: '+s.entry+'\nactors: '+s.actors.join(', ')+'\nmessages:\n  '+s.messages.join('\n  ')+'\nproperties:\n  '+s.properties.join('\n  ')+'\ncharts/reducers:\n  '+s.reducers.join('\n  ');

}
function wantsProtocolSketch(p){
  return /kerberos|oauth|openid|tls|protocol sketch|sketch.*protocol|ticket granting|single sign/.test(p);

}
function chooseProtocolSketch(prompt, catalog){
  const p=prompt.toLowerCase();
  let hit=catalog.find(s=>p.includes(s.id)||p.includes(s.label.toLowerCase().split(' ')[0]));
  return hit||catalog[0];

}
function previewProtocolSketch(s){
  tool('protocol_sketch_preview', {
    id:s.id, actors:s.actors
  });
  return 'Protocol sketch: '+s.label+'\nactors: '+s.actors.join(', ')+'\nmessages:\n  '+s.messages.join('\n  ')+'\nterminal states:\n  '+s.terminal.join('\n  ')+'\nproperties:\n  '+s.properties.join('\n  ')+'\nnotes:\n  '+s.notes.join('\n  ')+'\nLean sketch: '+location.origin+'/lean/sketch/'+s.id+'.lean';

}
async function generateProtocolSketch(prompt){
  const catalog=await callProtocolSketchCatalog();
  tool('protocol_sketch_generate', {
    prompt:prompt, crypto:'placeholder visible proof fields'
  });
  const draft=chooseProtocolSketch(prompt, catalog);
  tool('protocol_sketch_validate', {
    observableOnly:true, id:draft.id
  });
  setSubject({
    id:draft.id, label:draft.label, task:draft.id, actors:draft.actors, messages:draft.messages, properties:draft.properties, reducers:['latency by phase', 'messages by actor', 'success/failure pie']
  });
  return previewProtocolSketch(draft)+'\n\nSay "wire it in" when the sketch has the right visible messages and proof fields.';

}
function wireDraft(){
  if(!currentDraft)return 'No current draft. Describe a task or transaction first.';
  tool('scenario_stage_integration', {
    task:currentDraft.task, mode:'message_passing_requirement'
  });
  setSubject(Object.assign({

  }, currentDraft, {
    status:'staged'
  }));
  return 'Staged integration for '+currentDraft.task+'\n1. Add/extend TaskKind and actor task membership.\n2. Add protobuf envelope constructors with src,dst,task,transport,fields,bytes,ts,dwell.\n3. Instantiate one per-task FSM over observable actor states, queues, messages, and auth proof fields.\n4. Add CTL checks over visible message/proof/queue fields only.\n5. Append reducers for chart data and Prometheus metrics.\n6. Re-render nested FSM, interaction diagram, charts, docs, and /metrics.';

}
async function generateScenario(prompt){
  const catalog=await callScenarioCatalog();
  tool('scenario_generate', {
    prompt:prompt
  });
  const draft=chooseScenario(prompt, catalog);
  tool('scenario_validate', {
    observableOnly:true, task:draft.task
  });
  setSubject(draft);
  return previewScenario(draft)+'\n\nSay "wire it in" when this is the shape you want, or describe changes.';

}
async function assistant(prompt){
  const p=prompt.toLowerCase();
  let parts=[];
  if(/wire|accept|agreed|looks good|ship it/.test(p))parts.push(wireDraft());
  if(/markdown|latex|math artifact|render math/.test(p)&&!parts.length)parts.push(markdownLatexExample());
  if(wantsProtocolSketch(p)&&!parts.length)parts.push(await generateProtocolSketch(prompt));
  if(wantsScenario(p)&&!parts.length)parts.push(await generateScenario(prompt));
  if(p.includes('metric')||p.includes('latency')||p.includes('throughput')||p.includes('ctl'))parts.push(await callMetrics());
  if(p.includes('graph')||p.includes('diagram')||p.includes('artifact')||p.includes('image'))parts.push(callArtifacts());
  if(p.includes('chart')||p.includes('pie')||p.includes('line')||p.includes('usl'))parts.push(callCharts());
  if(p.includes('validate')||p.includes('spec'))parts.push(validateSpec(prompt));
  if(p.includes('template')||p.includes('how do i write'))parts.push(requirementTemplate());
  if(parts.length===0){
    tool('route_intent', {
      intent:'design_discussion'
    });
    parts.push('Ask for a protocol sketch, for example: sketch Kerberos with visible proof fields. I will generate message-passing steps, validate the observable fields, and stage it for integration when we agree.');

  }
  return parts.join('\n\n');

}
chatSend.addEventListener('click', async()=>{
  const p=chatPrompt.value.trim();
  if(!p)return;
  bubble('user', p);
  chatPrompt.value='';
  const r=await assistant(p);
  bubble('assistant', r);

});
chatPrompt.addEventListener('keydown', e=>{
  if(e.key==='Enter'&&e.ctrlKey)chatSend.click();

});
bubble('assistant', 'LeanFM workbench ready. Ask for a sketched protocol, for example: Kerberos with proof fields. I will keep crypto as visible placeholder evidence unless you ask for concrete bytes.');

