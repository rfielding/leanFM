#!/usr/bin/env node
// Runs the MCP Apps session view (LeanFM/SessionView.html) in Node against a small stub DOM and a
// stub host, feeds it real tool results, and drives it: the editor, the walk-through, the event
// animation and its detail toggle. Any exception the view throws, or a missing control, fails.
// A syntax check (node --check) cannot see a runtime error; this can, without a browser.
//
//   node scripts/session_view_smoke.js VIEW.html RESULTS.json
//
// RESULTS.json: {"check": <session_check result>, "simulate": ..., "conform": ..., "skeleton": ...,
// "diagram": ..., "next": [<session_next result for 0 events>, <for 1 event>, ...]}
// (each a tools/call result: {content, structuredContent, isError}). Reads only those two files.
"use strict";
const fs = require("fs");
const vm = require("vm");

const [viewPath, resultsPath] = process.argv.slice(2);
if (!viewPath || !resultsPath) { console.error("usage: session_view_smoke.js VIEW.html RESULTS.json"); process.exit(2); }
const html = fs.readFileSync(viewPath, "utf8");
const R = JSON.parse(fs.readFileSync(resultsPath, "utf8"));
const scripts = html.split("<script>");
if (scripts.length !== 2) { console.error("the view must have exactly one script element"); process.exit(1); }
const script = scripts[1].split("</script>")[0];

// ---- a stub DOM: enough of the API the view uses, with text and structure kept for assertions
class Node {
  constructor(tag) { this.tag = tag; this.children = []; this.attrs = {}; this.listeners = {}; this.style = {};
    this.dataset = {}; this._text = ""; this.value = ""; this.disabled = false; this.selectionStart = 0; this.selectionEnd = 0; }
  set textContent(t) { this.children = []; this._text = String(t); }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(""); }
  get innerText() { return this.textContent; }
  set className(c) { this.attrs.class = String(c); } get className() { return this.attrs.class || ""; }
  set id(v) { this.attrs.id = v; } get id() { return this.attrs.id; }
  set type(v) { this.attrs.type = v; } get type() { return this.attrs.type; }
  set min(v) { this.attrs.min = v; } set max(v) { this.attrs.max = v; } set step(v) { this.attrs.step = v; }
  set selected(v) { this.attrs.selected = v; } set tabIndex(v) { this.attrs.tabindex = v; }
  set width(v) { this.attrs.width = v; } set height(v) { this.attrs.height = v; }
  appendChild(c) { if (typeof c === "string") c = new Text(c); this.children.push(c); c.parent = this; return c; }
  append(...cs) { cs.forEach((c) => this.appendChild(c)); }
  replaceChildren(...cs) { this.children = []; this._text = ""; this.append(...cs); }
  setAttribute(k, v) { this.attrs[k] = String(v); } getAttribute(k) { return this.attrs[k]; }
  addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); }
  dispatch(type, extra) { for (const fn of this.listeners[type] || []) fn(Object.assign({ type, target: this, preventDefault() {} }, extra || {})); }
  click() { if (!this.disabled) this.dispatch("click", { clientX: 10, clientY: 10, offsetX: 10, offsetY: 10 }); }
  focus() {} blur() {}
  getBoundingClientRect() { return { left: 0, top: 0, width: 800, height: 420, right: 800, bottom: 420 }; }
  setRangeText(t) { this.value += t; }
  getContext() { return ctx2d; }
  all() { return [this, ...this.children.flatMap((c) => (c.all ? c.all() : []))]; }
}
class Text { constructor(t) { this._t = String(t); } get textContent() { return this._t; } }
const ctx2d = new Proxy({}, { get: (o, k) => k in o ? o[k] : k === "measureText" ? ((t) => ({ width: String(t).length * 7 })) : () => {}, set: (o, k, v) => { o[k] = v; return true; } });

const root = new Node("body");
const byId = {};
for (const id of ["app", "editor", "walk", "results"]) { byId[id] = new Node("div"); byId[id].id = id; }
byId.app.append(byId.editor, byId.walk, byId.results); root.appendChild(byId.app);
const document = {
  body: root, documentElement: new Node("html"),
  getElementById: (id) => byId[id] || null,
  createElement: (t) => new Node(t), createElementNS: (_, t) => new Node(t), createTextNode: (t) => new Text(t),
};
const errors = [];
const viewListeners = [];
const hostSent = [];
const parent = { postMessage: (msg) => { hostSent.push(msg); setTimeout(() => host(msg), 0); } };
const timers = [];
const window = {
  parent, devicePixelRatio: 1,
  addEventListener: (type, fn) => { if (type === "message") viewListeners.push(fn); },
  matchMedia: () => ({ matches: false }),
};
let frames = 0;
const sandbox = {
  window, document, console: { log() {}, warn() {}, error: (...a) => errors.push("console.error: " + a.join(" ")) },
  setTimeout: (f, ms) => { const t = setTimeout(() => { try { f(); } catch (e) { errors.push(String(e && e.stack || e)); } }, Math.min(ms || 0, 50)); timers.push(t); return t; },
  clearTimeout, Blob, performance, Date, Math, JSON, Map, Set, Promise, Number, String, Array, Object, Error, RegExp, Symbol, Boolean,
  getComputedStyle: () => ({ getPropertyValue: () => "#888888" }),
  matchMedia: window.matchMedia,
  requestAnimationFrame: (f) => { if (frames++ > 400) return 0; return sandbox.setTimeout(() => f(performance.now()), 16); },
  cancelAnimationFrame: () => {},
  ResizeObserver: class { constructor(cb) { this.cb = cb; } observe() { setTimeout(() => { try { this.cb([]); } catch (e) { errors.push(String(e && e.stack || e)); } }, 0); } },
};
window.window = window;
const deliver = (data) => { for (const fn of viewListeners) { try { fn({ source: parent, data }); } catch (e) { errors.push(String(e && e.stack || e)); } } };

// ---- the stub host: the MCP Apps handshake, then tools/call answered from RESULTS.json
let nextCalls = 0;
const toolCalls = [];
function host(msg) {
  if (msg.method === "ui/initialize") deliver({ jsonrpc: "2.0", id: msg.id, result: { hostContext: { theme: "dark" } } });
  else if (msg.method === "tools/call") {
    const name = msg.params && msg.params.name;
    toolCalls.push(name);
    const answer = name === "session_next" ? R.next[Math.min(nextCalls++, R.next.length - 1)]
      : name === "session_check" ? R.check : name === "session_simulate" ? R.simulate : name === "session_mdp" ? R.mdp
      : name === "session_actor" ? R.actor : name === "session_dataset" ? R.dataset : name === "session_types" ? R.types
      : name === "session_explore" ? (msg.params.arguments && msg.params.arguments.focus ? R.exploreFocus : R.explore)
      : name === "project_view" && R.projectView ? projectViewAnswer(msg.params.arguments || {}) : null;
    if (answer) deliver({ jsonrpc: "2.0", id: msg.id, result: answer });
    else deliver({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "unexpected tool " + name } });
  } else if (msg.id !== undefined && msg.method) deliver({ jsonrpc: "2.0", id: msg.id, result: {} });
}

// project_view answers from RESULTS.json's projectView: {list, chat, book, requirements, sections: {tasks,
// protocols, clauses, properties, transitions}, protocol, code: [every page of the listing], codeFile}
function projectViewAnswer(a) {
  const P = R.projectView;
  if (a.project === "Maqam" && P.maqam) return a.impl === "rust" ? P.maqam.rust : P.maqam.zig;
  if (!a.stage) return P.list;
  if (a.stage === "requirements") return a.file ? (/\.(leanfm|protocol)$/.test(a.file) ? P.protocol : P.specFile) : a.section ? P.sections[a.section] || null : P.requirements;
  if (a.stage === "code") {
    if (a.file) return P.codeFile;
    const off = a.offset || 0;
    return P.code.find((pg) => (pg.structuredContent.page.offset || 0) === off) || null;
  }
  return P[a.stage] || null;
}

// an error thrown from a promise or timer in the view is a failure, reported plainly
const fail = (e) => { console.error("the view threw: " + String(e && e.message || e)); process.exit(1); };
process.on("uncaughtException", fail);
process.on("unhandledRejection", fail);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const buttons = (under) => under.all().filter((n) => n.tag === "button");
const button = (under, text) => {
  const b = buttons(under).find((n) => n.textContent === text);
  if (!b) throw new Error(`no button "${text}"; have: ${buttons(under).map((n) => n.textContent).join(" | ")}`);
  return b;
};
// a view's button lives under its group tab: open the tab first when the view is not shown
const VIEW_GROUP = { "Whole protocol": "Structure", "Tree": "Structure", "Review": "Structure", "Protobuf": "Structure", "OpenAPI": "Structure",
  "Animate": "Behaviour", "Walk through": "Behaviour", "Decision process": "Behaviour", "Dataset": "Behaviour",
  "CTL": "Properties", "Requirements (SLA)": "Properties", "Instances": "Properties", "Python skeleton": "Code", "TypeScript skeleton": "Code" };
const tabOf = (name) => byId.editor.all().find((n) => n.tag === "button" && n.attrs.role === "tab" && n.textContent === name);
async function view(label) {
  const has = () => buttons(byId.editor).find((n) => n.textContent === label && n.attrs.role !== "tab");
  if (!has()) {
    const t = tabOf(VIEW_GROUP[label] || "Roles");
    if (!t) throw new Error(`no group tab for the view "${label}"`);
    t.click(); await wait(150);
  }
  if (!has()) throw new Error(`the view "${label}" is not under its group tab`);
  return has();
}
const expectText = (label, node, needle) => { if (!node.textContent.includes(needle)) throw new Error(`${label}: "${needle}" not shown in: ${node.textContent.slice(0, 300)}`); console.log("ok: " + label); };
const show = async (result) => { deliver({ jsonrpc: "2.0", method: "ui/notifications/tool-result", params: result }); await wait(120); };

(async () => {
  try { vm.runInNewContext(script, sandbox, { filename: "SessionView.html" }); }
  catch (e) { console.error("the view's script throws while loading: " + (e && e.stack || e)); process.exit(1); }
  await wait(200);
  if (!hostSent.some((m) => m.method === "ui/notifications/initialized")) throw new Error("the view never finished the handshake");
  console.log("ok: the view completes the MCP Apps handshake");

  await show(R.check);
  {
    // the views bar is nested tabs: the group tabs, then only the shown group's views
    const tabs = byId.editor.all().filter((n) => n.tag === "button" && n.attrs.role === "tab").map((n) => n.textContent).join(" ");
    if (tabs !== "Structure Roles Behaviour Properties Code") throw new Error("the views bar's group tabs are " + tabs);
    if (!tabOf("Structure").attrs.class.includes("on")) throw new Error("a session_check result does not show the Structure group");
    if (buttons(byId.editor).some((b) => b.textContent === "Animate")) throw new Error("the Behaviour views show while Structure is the shown group");
    const before = hostSent.length;
    tabOf("Properties").click(); await wait(100);
    if (hostSent.slice(before).some((m) => m.method === "tools/call")) throw new Error("a group never looked at opened a view by itself");
    if (!buttons(byId.editor).some((b) => b.textContent === "CTL")) throw new Error("the Properties tab does not show its views");
    console.log("ok: the views bar is group tabs over the shown group's views, and a new group opens nothing by itself");
    tabOf("Behaviour").click(); await wait(100);
    const box = byId.editor.all().find((n) => n.tag === "input" && String(n.attrs["aria-label"] || "").startsWith("How many sessions Animate"));
    if (!box) throw new Error("no session count beside Animate");
    box.value = "500"; box.dispatch("change"); await wait(10);
    if (box.value !== "200") throw new Error("the Animate count is not clamped to 200");
    box.value = "3"; box.dispatch("change"); await wait(10);
    (await view("Animate")).click(); await wait(200);
    const sent = hostSent.filter((m) => m.method === "tools/call" && m.params.name === "session_simulate").pop();
    if (sent?.params.arguments.instances !== 3 || sent?.params.arguments.maxEvents !== 600) throw new Error("Animate did not send the chosen number of sessions");
    console.log("ok: Animate generates the number of sessions set beside it, clamped to 1..200");
  }
  if (R.mdp) {
    await show(R.mdp);
    expectText("native MDP graph renders", byId.results, "Decision process under the supplied policy");
    expectText("terminal mass is visible", byId.results, "Terminal probability total: 1");
    if (!byId.results.all().some(n => n.tag === "svg")) throw new Error("MDP SVG missing");
    (await view("Decision process")).click(); await wait(120);
    const sent = hostSent.filter(m => m.method === "tools/call" && m.params.name === "session_mdp").pop();
    if (sent?.params.arguments.overlay?.name !== "test-layer") throw new Error("MDP redraw lost overlay");
  }
  if (R.timed) {
    await show(R.timed);
    expectText("timed layer renders", byId.results, "Generation assumptions");
    expectText("deadline monitoring renders", byId.results, "fulfilled");
    (await view("Animate")).click(); await wait(120);
    const sent = hostSent.filter(m => m.method === "tools/call" && m.params.name === "session_simulate").pop();
    if (sent?.params.arguments.overlay?.name !== "test-layer")
      throw new Error("editor lost the external overlay");
    console.log("ok: editor retains the external probability layer");
  }

  await show(R.check);
  expectText("session_check result renders its typestates", byId.results, "typestate");
  expectText("session_check result renders the diagram panel", byId.results, "Sequence diagram, generated from the protocol");
  if (!byId.results.all().some((n) => n.tag === "svg")) throw new Error("no SVG diagram drawn");
  console.log("ok: the diagram is drawn as SVG");

  (await view("Walk through")).click(); await wait(120);
  expectText("the walk-through starts at the protocol's first step", byId.walk, "after 0 events");
  const first = buttons(byId.walk).find((b) => b.attrs.class && b.attrs.class.includes("step"));
  if (!first) throw new Error("the walk-through offers no step");
  first.click(); await wait(120);
  expectText("a step taken is listed", byId.walk, ": " + first.textContent.split(" → ")[0]);
  expectText("a role with several steps is shown choosing", byId.walk, "Desk chooses");
  expectText("the roles waiting are named", byId.walk, "Member, Librarian wait");
  button(byId.walk, "Undo").click(); await wait(120);
  // the view is read-only: no sketching by clicking lifelines, no Add button
  if (byId.editor.all().some((n) => n.attrs && n.attrs["data-role"])) throw new Error("the read-only view still offers the sketch");
  if (buttons(byId.editor).some((b) => b.textContent === "Add")) throw new Error("the read-only view still offers Add");
  console.log("ok: the view is read-only: no sketch");
  button(byId.walk, "Close").click(); await wait(50);
  if (byId.walk.children.length) throw new Error("Close leaves the walk-through open");
  console.log("ok: undo and close work");

  // navigation: each role's view, the payloads, a dataset, and back to the whole protocol
  if (R.actor && R.dataset && R.types) {
    await show(R.check);
    (await view("Member")).click(); await wait(150);
    const asked = hostSent.filter((m) => m.method === "tools/call" && m.params.name === "session_actor").pop();
    if (asked?.params.arguments.role !== "Member") throw new Error("the role button did not ask for that role's view");
    expectText("a role's view lists what it sends and receives", byId.results, "What Member sends and receives");
    // a successful call says what LeanFM answered, never that the host returned nothing
    if (byId.editor.textContent.includes("The host returned no result")) throw new Error("a successful call was reported as returning no result");
    console.log("ok: a successful call is not reported as an empty one");
    expectText("a role's view draws only its steps", byId.results, "Sequence diagram: only the steps Member takes part in");
    expectText("a role's view shows the payloads", byId.results, "Payloads (protobuf");
    if (!byId.results.all().some((n) => n.tag === "svg")) throw new Error("no SVG drawn for the role's view");
    if (!button(byId.editor, "Member").attrs.class.includes("on")) throw new Error("the role's button is not marked as the current view");
    // back to Behaviour: the view last looked at there (Walk through) opens again
    const nexts = () => hostSent.filter((m) => m.method === "tools/call" && m.params.name === "session_next").length;
    const nextsBefore = nexts();
    tabOf("Behaviour").click(); await wait(200);
    if (nexts() <= nextsBefore || !button(byId.editor, "Walk through").attrs.class.includes("on")) throw new Error("returning to Behaviour did not open Walk through again");
    console.log("ok: returning to a group opens the view last looked at there");
    const count = byId.editor.all().find((n) => n.tag === "input" && n.attrs.type === "number" && String(n.attrs["aria-label"] || "").includes("dataset"));
    if (!count) throw new Error("no dataset size field");
    count.value = "99999"; count.dispatch("change");
    if (count.value !== "10000") throw new Error("the dataset size is not capped at 10000");
    count.value = "500"; count.dispatch("change");
    (await view("Dataset")).click(); await wait(150);
    const askedData = hostSent.filter((m) => m.method === "tools/call" && m.params.name === "session_dataset").pop();
    if (askedData?.params.arguments.sessions !== 500) throw new Error("the dataset button did not send the size");
    expectText("a dataset charts its paths", byId.results, "Paths taken");
    expectText("a dataset charts each role's load", byId.results, "Load per role");
    expectText("a dataset says where its numbers come from", byId.results, "Where these numbers come from");
    expectText("a dataset without probabilities says what its frequencies mean", byId.results, "describe the walker, not the system");
    (await view("Protobuf")).click(); await wait(150);
    expectText("the payloads view shows the proto file", byId.results, "Message types and envelope (protobuf)");
    (await view("Whole protocol")).click(); await wait(150);
    expectText("back to the whole protocol", byId.results, "Sequence diagram, generated from the protocol");
    console.log("ok: the navigation reaches each role, the payloads and a dataset");
  }

  // the tree: a list of rows like a file explorer, folded, opened by its arrows and keys, a node's
  // source and its protocol's diagram beside it
  if (R.explore && R.exploreFocus) {
    await show(R.explore);
    if (byId.results.all().some((n) => n.tag === "canvas" && n.className.includes("tree"))) throw new Error("the tree is still a canvas");
    const list = byId.results.all().find((n) => n.className.split(" ").includes("ftree"));
    if (!list) throw new Error("the tree is not a list");
    await wait(80);
    const rows = () => list.children.filter((n) => n.className.split(" ").includes("frow"));
    const sel = () => rows().find((r) => r.className.includes("sel"));
    expectText("the tree selects the main protocol at the start", byId.results, "the main protocol");
    expectText("the selected node shows its source lines", byId.results, "Source");
    const n0 = rows().length;
    if (!sel() || rows()[0] !== sel()) throw new Error("the first row is not the selected root");
    // the first closed folder opens with its arrow, and closes again with Left
    const folder = rows().find((r) => r.getAttribute("aria-expanded") === "false");
    if (!folder) throw new Error("no closed folder to open");
    folder.children.find((c) => c.className === "twisty").click(); await wait(30);
    if (rows().length <= n0) throw new Error("the arrow did not open the folder");
    if (sel().getAttribute("aria-expanded") !== "true") throw new Error("the opened folder is not selected and open");
    list.dispatch("keydown", { key: "ArrowLeft" }); await wait(30);
    if (rows().length !== n0) throw new Error("Left did not close the folder");
    for (const key of ["ArrowDown", "ArrowRight", "ArrowRight", "ArrowUp", "End", "Home", "Enter", "Enter"]) { list.dispatch("keydown", { key }); await wait(30); }
    rows()[1].click(); await wait(30);
    if (sel() !== rows()[1]) throw new Error("a click did not select the row");
    button(byId.results, "Open one more level").click(); await wait(50);
    if (rows().length <= n0) throw new Error("Open one more level opened nothing");
    button(byId.results, "Close all").click(); await wait(50);
    if (rows().length !== n0) throw new Error("Close all left folders open");
    // an included protocol's row draws that protocol's diagram
    button(byId.results, "Open one more level").click(); await wait(50);
    button(byId.results, "Open one more level").click(); await wait(50);
    const inc = rows().find((r) => /include|definition/.test(r.textContent) && r.textContent.includes("Lending"));
    if (inc) { inc.click(); await wait(150); }
    const asked = hostSent.filter((m) => m.method === "tools/call" && m.params.name === "session_explore").pop();
    if (!asked?.params.arguments.focus) throw new Error("selecting a protocol did not ask for its diagram");
    if (!byId.results.all().some((n) => n.tag === "svg")) throw new Error("the protocol's diagram is not drawn");
    if (!(await view("Tree")).attrs.class.includes("on")) throw new Error("the Tree view is not marked current");
    console.log("ok: the tree lists like a file explorer, opens, closes, moves by keys and shows a protocol's diagram");
    // walking the grammar from the main protocol: the global machine grows, the tree lights the step
    await show(R.explore); await wait(80);
    button(byId.results, "Close all").click(); await wait(50);   // the tree kept the last selection; back to the root
    button(byId.results, "Walk the grammar").click(); await wait(150);
    expectText("the grammar walk starts", byId.results, "Walk the grammar: the global state machine");
    const machine = byId.results.all().find((n) => n.tag === "canvas" && n.className.includes("machine"));
    if (!machine) throw new Error("the walk is not drawn on a canvas");
    const firstMove = buttons(byId.results).find((b) => b.textContent.includes(" → "));
    if (!firstMove) throw new Error("the walk offers no step");
    firstMove.click(); await wait(700);
    const walked = hostSent.filter((m) => m.method === "tools/call" && m.params.name === "session_next").pop();
    if (!walked || !Array.isArray(walked.params.arguments.events) || walked.params.arguments.events.length !== 1) throw new Error("the step was not sent to session_next");
    button(byId.results, "Undo").click(); await wait(150);
    button(byId.results, "Restart").click(); await wait(150);
    console.log("ok: the grammar walk takes a step, undoes it and restarts");
  }
  if (R.exploreStates && R.exploreMessage) {
    await show(R.exploreStates); await wait(80);
    expectText("a role's state machine is drawn", byId.results, "State machine of Desk");
    if (!byId.results.all().some((n) => n.tag === "canvas" && n.className.includes("machine"))) throw new Error("the state machine is not a canvas");
    const t = buttons(byId.results).find((b) => b.textContent.includes(" → "));
    if (!t) throw new Error("the state machine offers no transition");
    t.click(); await wait(600);
    expectText("taking a transition moves the current state", byId.results, "current:");
    await show(R.exploreMessage); await wait(50);
    expectText("a message shows its example JSON", byId.results, "Example JSON");
    expectText("a message shows its protobuf", byId.results, "Protobuf");
    console.log("ok: a role's state machine walks, and a message shows its payload");
  }

  await show(R.simulate);
  await wait(400);
  expectText("session_simulate result shows the event stream", byId.results, "Event stream");
  // the stream opens with more detail on: the button offers less, then more again
  button(byId.results, "Less detail").click(); await wait(100);
  button(byId.results, "More detail").click(); await wait(100);
  console.log("ok: the animation runs and its detail toggle works");
  // clicking an event focuses on its thread: only the events its prior links reach either way stay,
  // and the roles left without an event are named as hidden; Show all events brings the rest back
  {
    const E = R.simulate.structuredContent.events;
    const posOf = new Map(E.map((e, i) => [e.id, i]));
    const kids = E.map(() => []);
    E.forEach((e, i) => (e.prior || []).forEach((q) => { if (posOf.has(q)) kids[posOf.get(q)].push(i); }));
    const reach = (start, next) => { const got = new Set([start]), st = [start]; while (st.length) for (const j of next(st.pop())) if (!got.has(j)) { got.add(j); st.push(j); } return got; };
    const pickAt = 2;
    const want = new Set([...reach(pickAt, (i) => (E[i].prior || []).filter((q) => posOf.has(q)).map((q) => posOf.get(q))), ...reach(pickAt, (i) => kids[i])]);
    const rowsNow = () => byId.results.all().filter((n) => n.className.split(" ").includes("evrow"));
    const cv = root.all().find((n) => n.tag === "canvas");
    const before = rowsNow().length;
    // rows are 48 px apart in full detail, the first at 76 px
    cv.dispatch("click", { clientX: 100, clientY: 76 + pickAt * 48 }); await wait(200);
    if (rowsNow().length !== want.size) throw new Error(`focusing on event ${pickAt} shows ${rowsNow().length} events, its thread has ${want.size}`);
    expectText("a focused thread says whose it is", byId.results, "Thread of e");
    button(byId.results, "Show all events").click(); await wait(200);
    if (rowsNow().length !== before) throw new Error("Show all events did not bring the stream back");
    console.log(`ok: clicking an event focuses on its thread (${want.size} of ${before} events) and Show all events brings the rest back`);
  }
  // the derived sessions (clause selfhost.session.derived-sessions): one button per session LeanFM
  // derived; picking one shows only its events in the log
  {
    const d = R.simulate.structuredContent.derivedSessions;
    if (!d || !Array.isArray(d.sessions) || !d.sessions.length) throw new Error("session_simulate derived no sessions");
    const first = d.sessions[0];
    const sb = buttons(byId.results).find((b) => b.textContent === `${first.key} · ${first.count}`);
    if (!sb) throw new Error("no button for the derived session " + first.key + "; have: " + buttons(byId.results).map((b) => b.textContent).join(" | "));
    const rowsNow = () => byId.results.all().filter((n) => n.className.split(" ").includes("evrow"));
    const before = rowsNow().length;
    sb.click(); await wait(200);
    if (rowsNow().length !== first.count) throw new Error(`picking ${first.key} shows ${rowsNow().length} events, not its ${first.count} (of ${before})`);
    expectText("a picked session says which it is", byId.results, "Session " + first.key);
    button(byId.results, `all · ${R.simulate.structuredContent.events.length}`).click(); await wait(200);
    if (rowsNow().length !== before) throw new Error("all does not bring every event back");
    console.log("ok: the stream filters to one derived session and back to all");
  }

  await show(R.conform);
  expectText("session_conform shows where the run breaks the protocol", byId.results, "Where the run breaks the protocol");
  await show(R.diagram);
  expectText("session_diagram result renders", byId.results, "Sequence diagram");
  // calls fold (clause selfhost.session.diagram.folds): depth 2 and below start folded; folding the
  // top call hides the role used only inside it, and its name in the hidden note brings it back
  {
    const svgAll = () => byId.results.all();
    const hotNamed = (prefix) => svgAll().filter((n) => n.tag === "rect" && String(n.attrs["aria-label"] || "").startsWith(prefix));
    const calls = R.diagram.structuredContent.diagram.calls;
    const deep = calls.filter((c) => c.depth >= 2);
    if (!deep.length) throw new Error("the lending diagram has no nested call to fold");
    if (hotNamed("Open the call").length !== deep.length) throw new Error(`${hotNamed("Open the call").length} folded calls drawn, expected ${deep.length}`);
    for (const c of deep) if (!svgAll().some((n) => n.tag === "text" && n.textContent === "▸ " + c.label)) throw new Error("no folded arrow labelled " + c.label);
    console.log("ok: calls at depth 2 and below start folded, each drawn as one labelled arrow");
    const shapesBefore = JSON.stringify(R.diagram.structuredContent.diagram.shapes);
    hotNamed("Open the call")[0].dispatch("click", { stopPropagation() {} }); await wait(30);
    if (hotNamed("Open the call").length !== deep.length - 1) throw new Error("opening a call did not open it");
    hotNamed("Fold the call " + deep[0].label)[0].dispatch("click", { stopPropagation() {} }); await wait(30);
    if (hotNamed("Open the call").length !== deep.length) throw new Error("the ▾ control did not fold the call again");
    const lifelines = () => svgAll().filter((n) => n.tag === "line" && n.attrs.class === "lifeline").length;
    const lanes = R.diagram.structuredContent.diagram.lanes.length;
    if (lifelines() !== lanes) throw new Error(`${lifelines()} lifelines with the top call open, expected ${lanes}`);
    const top = calls.find((c) => c.depth === 1);
    hotNamed("Fold the call " + top.label)[0].dispatch("click", { stopPropagation() {} }); await wait(30);
    const note = svgAll().find((n) => String(n.className).includes("hidden-note"));
    const gone = R.diagram.structuredContent.diagram.lanes.map((l) => l.role).filter((r) => r !== top.caller && r !== top.callee);
    if (!note || !note.textContent.startsWith("hidden:")) throw new Error("folding the top call hides no role");
    for (const r of gone) if (!buttons(note).some((b) => b.textContent === r)) throw new Error(r + " is not in the hidden note");
    if (lifelines() !== lanes - gone.length) throw new Error(`${lifelines()} lifelines with ${gone.join(", ")} hidden`);
    console.log("ok: a role used only inside a folded call loses its lifeline and is named in the hidden note");
    button(note, gone[0]).click(); await wait(30);
    if (lifelines() !== lanes || note.textContent.includes(gone[0])) throw new Error("clicking a hidden name did not bring it back");
    if (JSON.stringify(R.diagram.structuredContent.diagram.shapes) !== shapesBefore) throw new Error("folding changed the shapes LeanFM sent");
    console.log("ok: a hidden role's name opens its calls again, and the shapes are unchanged");
  }
  if (R.ctl) {
    await show(R.ctl);
    expectText("session_ctl shows its counterexample path", byId.results, "Counterexample: the steps that break it");
    // the property reads as CTL symbols, not as JSON
    expectText("session_ctl heads the property with its CTL notation", byId.results, "AG (Approved → AG ¬Waitlisted)");
  }
  if (R.compat) {
    await show(R.compat);
    expectText("session_compat shows which roles can upgrade", byId.results, "Which roles can upgrade on their own");
  }
  await show(R.skeleton);
  expectText("session_skeleton result renders its reading", byId.results, "typestate as classes");

  // the navigator (clause selfhost.mcp.session.navigator): project and implementation, then book, spec, impl, code
  if (R.projectView) {
    const bar = root.all().find((n) => n.tag === "nav" && n.className.includes("stagenav"));
    if (!bar) throw new Error("no navigator bar");
    const order = buttons(bar).map((b) => b.textContent).join(" ");
    if (order !== "book spec impl code") throw new Error("the navigator's stages are " + order);
    const pick = bar.all().find((n) => n.tag === "select");
    if (!pick || !pick.children.some((o) => o.textContent === "LeanFM") || pick.value !== "LeanFM") throw new Error("the project picker does not default to LeanFM");
    if (!pick.children.some((o) => o.textContent === "GoServer")) throw new Error("the project picker does not list GoServer from project_view");
    if (bar.children[0] !== bar.all().find((n) => n.className === "picks")) throw new Error("the pickers are not the bar's first row");
    console.log("ok: the navigator shows the project picker first, then book, spec, impl, code");
    const navSent = () => hostSent.filter((m) => m.method === "tools/call" && m.params.name === "project_view").pop();
    button(bar, "book").click(); await wait(200);
    if (navSent()?.params.arguments.stage !== "book" || navSent()?.params.arguments.project !== "LeanFM") throw new Error("book did not ask project_view for LeanFM's book");
    const img = byId.results.all().find((n) => n.tag === "img");
    if (!img || !/^data:image\/(png;base64,iVBOR|jpeg;base64,\/9j\/)/.test(String(img.attrs.src || ""))) throw new Error("the book stage draws no PNG or JPEG page");
    expectText("the book stage says which page", byId.results, "page 2 of");
    button(byId.results, "Next ▶").click(); await wait(200);
    if (navSent()?.params.arguments.page !== 3) throw new Error("Next did not ask for the next page");
    button(bar, "spec").click(); await wait(200);
    if (navSent()?.params.arguments.stage !== "requirements") throw new Error("spec did not ask project_view for the requirements");
    // spec lands in the explorer on the primary protocol, not on text
    const primary = R.projectView.requirements.structuredContent.primary;
    if (primary !== "LeanFM/LLMGenerated/LeanFM.leanfm") throw new Error("LeanFM's spec overview names no primary protocol: " + primary);
    await wait(300);
    const landed = hostSent.filter((m) => m.method === "tools/call" && m.params.name === "session_explore" && m.params.arguments.file).pop();
    if (!landed || landed.params.arguments.file !== primary || landed.params.arguments.project !== "LeanFM")
      throw new Error("the spec stage did not open its primary protocol in session_explore");
    if (!byId.results.all().some((n) => n.className.split(" ").includes("ftree"))) throw new Error("the spec stage does not land on the protocol's tree");
    const specRow2 = bar.all().find((n) => n.className.split(" ").includes("specrow"));
    if (!specRow2 || !button(specRow2, "explorer · LeanFM.leanfm").className.includes("on")) throw new Error("the spec row does not mark the explorer");
    const stageTabs = buttons(bar).filter((b) => b.attrs.role === "tab");
    if (stageTabs.map((b) => b.textContent).slice(0, 4).join(" ") !== "book spec impl code") throw new Error("the stages are not tabs");
    if (stageTabs.find((b) => b.textContent === "spec").attrs["aria-selected"] !== "true") throw new Error("the spec tab is not the selected stage");
    if (specRow2.attrs.role !== "tablist" || button(specRow2, "files & sections").attrs.role !== "tab") throw new Error("explorer and index are not tabs nested under spec");
    console.log("ok: the stages are tabs, with explorer and index as tabs nested under spec");
    console.log("ok: the spec stage lands in the explorer on LeanFM.leanfm");
    button(specRow2, "files & sections").click(); await wait(200);
    if (navSent()?.params.arguments.stage !== "requirements" || navSent()?.params.arguments.file) throw new Error("files & sections did not ask for the overview");
    const specRow = byId.results.all().find((n) => n.className.split(" ").includes("frow") && n.textContent.includes("SelfHosting.lean"));
    if (!specRow) throw new Error("the spec stage does not list the specification's own file");
    if (!byId.results.all().some((n) => n.className.split(" ").includes("frow") && n.textContent.includes(".leanfm"))) throw new Error("the spec stage does not list the protocols directly");
    specRow.click(); await wait(200);
    if (navSent()?.params.arguments.file !== "LeanFM/LLMGenerated/SelfHosting.lean") throw new Error("a spec file row did not ask for that file");
    expectText("a spec file shows its text a page at a time", byId.results, "characters 1 to");
    expectText("a spec file's text is the requirements", byId.results, "selfhost.revision");
    console.log("ok: the spec stage opens the specification's own text in one click");
    button(bar, "impl").click(); await wait(200);
    if (navSent()?.params.arguments.stage !== "impl") throw new Error("impl did not ask project_view for the implementation mapping");
    expectText("the impl stage shows the implementation mapping", byId.results, "LeanFM/LLMGenerated/Implementation.lean");
    console.log("ok: the impl stage shows the implementation mapping");
    button(bar, "spec").click(); await wait(300);
    button(bar.all().find((n) => n.className.split(" ").includes("specrow")), "files & sections").click(); await wait(200);
    const sectionButton = (name) => buttons(byId.results).find((b) => b.textContent.startsWith(name + " ("));
    for (const name of ["tasks", "clauses", "protocols"]) if (!sectionButton(name)) throw new Error("the requirements stage has no " + name + " section");
    if (byId.results.textContent.includes("selfhost_workflow")) throw new Error("the requirements overview carries the tasks themselves");
    console.log("ok: the requirements stage lists its sections with their counts, not the items");
    sectionButton("tasks").click(); await wait(200);
    if (navSent()?.params.arguments.section !== "tasks") throw new Error("the tasks section was not asked for");
    expectText("the tasks section lists LeanFM's workflow task", byId.results, "selfhost_workflow");
    const propsButton = buttons(byId.results).find((b) => b.textContent.endsWith("properties · CTL") && !b.disabled);
    propsButton.click(); await wait(200);
    if (navSent()?.params.arguments.section !== "properties" || !navSent()?.params.arguments.task) throw new Error("a task's properties were not asked for with the task");
    expectText("a task's properties show their CTL", byId.results, "AG ¬(");
    button(byId.results, "Index").click(); await wait(200);
    sectionButton("clauses").click(); await wait(200);
    expectText("the clauses section shows a page of clauses", byId.results, "selfhost.revision");
    button(byId.results, "Next page ▶");
    console.log("ok: the clauses section offers its next page");
    button(byId.results, "Index").click(); await wait(200);
    sectionButton("protocols").click(); await wait(200);
    const prow = byId.results.all().find((n) => n.className.split(" ").includes("frow"));
    if (!prow) throw new Error("no protocol row");
    prow.click(); await wait(300);
    // (the tree then asks for its focus diagram with the text it got back, a later call)
    const explored = hostSent.filter((m) => m.method === "tools/call" && m.params.name === "session_explore" && m.params.arguments.file).pop();
    // the server reads the file: the view sends the project and the file, never the text
    if (!explored || !explored.params.arguments.file || explored.params.arguments.project !== "LeanFM" || "lean" in explored.params.arguments)
      throw new Error("the protocol was not opened in session_explore by project and file: " + JSON.stringify(explored && explored.params.arguments).slice(0, 200));
    if (!byId.results.all().some((n) => n.className.split(" ").includes("ftree"))) throw new Error("the protocol's tree is not shown");
    console.log("ok: a protocol from the requirements stage opens in the tree");
    // the opened protocol replaces the one shown, so Animate and Whole protocol work on it
    const area = byId.editor.all().find((n) => n.tag === "textarea");
    if (!area || area.value !== R.explore.structuredContent.lean) throw new Error("the protocol opened from the navigator did not replace the source the views use");
    expectText("the view says where the diagram and the animation are", byId.editor, "Animate plays its event stream");
    button(bar, "code").click(); await wait(900);
    expectText("the code stage shows the source tree", byId.results, "traceability mappings");
    const offsets = hostSent.filter((m) => m.method === "tools/call" && m.params.name === "project_view" && m.params.arguments.stage === "code").map((m) => m.params.arguments.offset || 0);
    if (R.projectView.code.length > 1 && !offsets.includes(R.projectView.code[1].structuredContent.page.offset)) throw new Error("the view did not ask for the listing's next page");
    console.log(`ok: the code stage asked for every page of the listing (${offsets.length} pages)`);
    const dir = byId.results.all().find((n) => n.className.split(" ").includes("frow") && n.textContent.includes("LeanFM/"));
    if (!dir) throw new Error("no LeanFM/ folder in the source tree");
    dir.click(); await wait(50);
    const frow = byId.results.all().find((n) => n.className.split(" ").includes("frow") && n.textContent.startsWith("ProjectView.lean"));
    if (!frow) throw new Error("no ProjectView.lean row after opening LeanFM/");
    frow.click(); await wait(200);
    if (navSent()?.params.arguments.file !== "LeanFM/ProjectView.lean") throw new Error("a file row did not ask for that file");
    expectText("a picked file shows its traceability", byId.results, "Traceability for LeanFM/ProjectView.lean");
    expectText("a picked file shows the clause it implements", byId.results, "clause:selfhost.mcp.session.navigator");
    console.log("ok: the code stage opens a file with its traceability");
    if (R.projectView.maqam) {
      // a project with several implementations: an implementation picker, and code follows it
      const pick2 = bar.all().find((n) => n.tag === "select" && n.attrs && n.attrs["aria-label"] === "Project") || bar.all().find((n) => n.tag === "select");
      pick2.value = "Maqam"; pick2.dispatch("change"); await wait(1200);
      const ipick = bar.all().find((n) => n.tag === "select" && n.children.some((o) => o.textContent === "rust"));
      if (!ipick || ipick.value !== "zig") throw new Error("Maqam's code stage shows no implementation picker defaulting to zig");
      expectText("the code stage names the implementation it shows", byId.results, "code · zig");
      expectText("the code stage shows the implementation's check against the specification", byId.results, "against the one specification");
      ipick.value = "rust"; ipick.dispatch("change"); await wait(300);
      if (navSent()?.params.arguments.impl !== "rust" || navSent()?.params.arguments.stage !== "code") throw new Error("picking rust did not ask project_view for the rust code");
      expectText("the code stage switches to the picked implementation", byId.results, "code · rust");
      const zbar = root.all().find((n) => n.tag === "nav" && n.className.includes("stagenav"));
      const zpick = zbar.all().find((n) => n.tag === "select" && n.children.some((o) => o.textContent === "rust"));
      if (!zpick || zpick.value !== "rust") throw new Error("the implementation picker does not keep rust");
      console.log("ok: an implementation picker switches the code stage between Maqam's rust and zig");
    }
  }

  for (const t of timers) clearTimeout(t);
  if (errors.length) { console.error("the view threw:\n" + errors.join("\n")); process.exit(1); }
  console.log(`ok: the session view ran every tool result without an error (${toolCalls.length} tool calls)`);
  process.exit(0);
})().catch((e) => { console.error(String(e && e.message || e)); if (errors.length) console.error(errors.join("\n")); process.exit(1); });
