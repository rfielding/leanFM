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
      : name === "session_check" ? R.check : name === "session_simulate" ? R.simulate : null;
    if (answer) deliver({ jsonrpc: "2.0", id: msg.id, result: answer });
    else deliver({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "unexpected tool " + name } });
  } else if (msg.id !== undefined && msg.method) deliver({ jsonrpc: "2.0", id: msg.id, result: {} });
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
const expectText = (label, node, needle) => { if (!node.textContent.includes(needle)) throw new Error(`${label}: "${needle}" not shown in: ${node.textContent.slice(0, 300)}`); console.log("ok: " + label); };
const show = async (result) => { deliver({ jsonrpc: "2.0", method: "ui/notifications/tool-result", params: result }); await wait(120); };

(async () => {
  try { vm.runInNewContext(script, sandbox, { filename: "SessionView.html" }); }
  catch (e) { console.error("the view's script throws while loading: " + (e && e.stack || e)); process.exit(1); }
  await wait(200);
  if (!hostSent.some((m) => m.method === "ui/notifications/initialized")) throw new Error("the view never finished the handshake");
  console.log("ok: the view completes the MCP Apps handshake");

  await show(R.check);
  expectText("session_check result renders its typestates", byId.results, "typestate");
  expectText("session_check result renders the diagram panel", byId.results, "Sequence diagram, generated from the protocol");
  if (!byId.results.all().some((n) => n.tag === "svg")) throw new Error("no SVG diagram drawn");
  console.log("ok: the diagram is drawn as SVG");

  button(byId.editor, "Walk through").click(); await wait(120);
  expectText("the walk-through starts at the protocol's first step", byId.walk, "after 0 events");
  const first = buttons(byId.walk).find((b) => b.attrs.class && b.attrs.class.includes("step"));
  if (!first) throw new Error("the walk-through offers no step");
  first.click(); await wait(120);
  expectText("a step taken is listed", byId.walk, ": " + first.textContent.split(" → ")[0]);
  expectText("a role with several steps is shown choosing", byId.walk, "Desk chooses");
  expectText("the roles waiting are named", byId.walk, "Member, Librarian wait");
  button(byId.walk, "Undo").click(); await wait(120);
  // the sketch: click two lifelines, label the message, and it is added to the protocol text
  const lanes = byId.editor.all().filter((n) => n.attrs && n.attrs["data-role"]);
  if (lanes.length < 2) throw new Error("the sketch shows no lifelines");
  const before = byId.editor.all().find((n) => n.tag === "textarea").value;
  lanes[0].click(); await wait(20); lanes[1].click(); await wait(20);
  const labelIn = byId.editor.all().find((n) => n.tag === "input" && n.dataset && n.dataset.field === "label");
  if (!labelIn) throw new Error("the sketch asks for no label");
  labelIn.value = "Ping";
  button(byId.editor, "Add").click(); await wait(120);
  const after = byId.editor.all().find((n) => n.tag === "textarea").value;
  if (!after.includes(`Ping from ${lanes[0].attrs["data-role"]} to ${lanes[1].attrs["data-role"]};`) || after.length <= before.length)
    throw new Error("the sketch did not add its message to the text");
  console.log("ok: the sketch adds a message by clicking two lifelines");
  button(byId.walk, "Close").click(); await wait(50);
  if (byId.walk.children.length) throw new Error("Close leaves the walk-through open");
  console.log("ok: undo and close work");

  await show(R.simulate);
  await wait(400);
  expectText("session_simulate result shows the event stream", byId.results, "Event stream");
  button(byId.results, "More detail").click(); await wait(100);
  button(byId.results, "Less detail").click(); await wait(100);
  console.log("ok: the animation runs and its detail toggle works");

  await show(R.conform);
  expectText("session_conform shows where the run breaks the protocol", byId.results, "Where the run breaks the protocol");
  await show(R.diagram);
  expectText("session_diagram result renders", byId.results, "Sequence diagram");
  if (R.ctl) {
    await show(R.ctl);
    expectText("session_ctl shows its counterexample path", byId.results, "Counterexample: the steps that break it");
  }
  if (R.compat) {
    await show(R.compat);
    expectText("session_compat shows which roles can upgrade", byId.results, "Which roles can upgrade on their own");
  }
  await show(R.skeleton);
  expectText("session_skeleton result renders its reading", byId.results, "typestate as classes");

  for (const t of timers) clearTimeout(t);
  if (errors.length) { console.error("the view threw:\n" + errors.join("\n")); process.exit(1); }
  console.log(`ok: the session view ran every tool result without an error (${toolCalls.length} tool calls)`);
  process.exit(0);
})().catch((e) => { console.error(String(e && e.message || e)); if (errors.length) console.error(errors.join("\n")); process.exit(1); });
