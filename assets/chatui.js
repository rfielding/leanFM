/* LeanFM ChatUI. Requirement refs: root_workbench, argue_requirements, inspect_task_model. */
(() => {
  "use strict";
  const $ = selector => document.querySelector(selector);
  const $$ = selector => [...document.querySelectorAll(selector)];
  let me = null, projects = [], project = null, grammar = [], selectedTask = null, grammarSection = "productions";
  let grammarZoom = 1, diagramTask = null, diagramKind = "interaction";

  async function request(path, options = {}) {
    const response = await fetch(path, {...options, headers: {Accept: "application/json", ...(options.headers || {})}});
    const text = await response.text();
    let body;
    try { body = JSON.parse(text); } catch { body = {error: text.trim() || `HTTP ${response.status}`}; }
    if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`);
    return body;
  }
  const formBody = form => new URLSearchParams(new FormData(form)).toString();
  const make = (tag, className, text) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
  };

  function showAuth(register = false) {
    $("#auth").classList.remove("hidden");
    $("#loginForm").classList.toggle("hidden", register);
    $("#registerForm").classList.toggle("hidden", !register);
    $("#showLogin").classList.toggle("active", !register);
    $("#showRegister").classList.toggle("active", register);
    $("#authError").textContent = "";
  }
  const hideAuth = () => $("#auth").classList.add("hidden");

  function renderProjects() {
    const box = $("#projects");
    box.replaceChildren();
    for (const item of projects) {
      const row = make("div", "project-row");
      const button = make("button", `project${project?.project_id === item.project_id ? " active" : ""}`, item.display_name);
      if (item.read_only) button.append(make("span", "project-kind", "read-only"));
      button.onclick = () => selectProject(item);
      row.append(button);
      if (item.read_only) {
        box.append(row);
        continue;
      }
      const remove = make("button", "project-delete", "Delete");
      remove.title = `Delete ${item.display_name}`;
      remove.setAttribute("aria-label", `Delete project ${item.display_name}`);
      remove.onclick = async event => {
        event.stopPropagation();
        const confirmation = prompt(`Permanently delete project "${item.display_name}" and everything beneath its project root?\n\nType the project name to confirm:`);
        if (confirmation === null) return;
        try {
          await request(`/api/projects/${item.project_id}`, {method: "DELETE", headers: {"Content-Type": "application/x-www-form-urlencoded"}, body: new URLSearchParams({confirmation}).toString()});
          if (project?.project_id === item.project_id) {
            project = null;
            localStorage.removeItem("leanfm-project");
          }
          await loadProjects();
        } catch (error) { alert(error.message); }
      };
      row.append(remove);
      box.append(row);
    }
  }
  async function loadProjects() {
    const data = await request("/api/projects");
    projects = data.projects || [];
    renderProjects();
    if (!project) {
      const rememberedId = localStorage.getItem("leanfm-project");
      const remembered = projects.find(item => item.project_id === rememberedId && !item.read_only);
      const editable = remembered || projects.find(item => !item.read_only);
      if (editable) await selectProject(editable);
      else {
        localStorage.removeItem("leanfm-project");
        $("#projectTitle").textContent = "Select a project";
      }
    }
  }
  async function selectProject(item) {
    project = item;
    if (item.read_only) localStorage.removeItem("leanfm-project");
    else localStorage.setItem("leanfm-project", item.project_id);
    selectedTask = null;
    diagramTask = null;
    grammarSection = "productions";
    $("#projectTitle").textContent = item.display_name;
    $("#prompt").disabled = !!item.read_only;
    $("#composer button").disabled = !!item.read_only;
    $("#prompt").placeholder = item.read_only ? "Read-only workspace project" : "Message LeanFM";
    renderProjects();
    await Promise.all([loadConversation(), loadGrammar()]);
    await loadArtifacts();
  }

  function message(role, text, usage, messageId) {
    $("#messages .empty")?.remove();
    const element = make("article", `message ${role}`);
    element.append(make("div", "message-text", text));
    if (usage) {
      const percentage = usage.context_window_tokens ? ` · ${Math.round(100 * usage.total_tokens / usage.context_window_tokens)}% context` : "";
      element.append(make("div", "usage", `${usage.input_tokens} input · ${usage.cached_input_tokens} cached · ${usage.output_tokens} output · ${usage.total_tokens} total${percentage} · billed to your API key`));
    }
    if (messageId) {
      const remove = make("button", "message-delete", "Delete");
      remove.title = "Delete this message";
      remove.onclick = async () => {
        if (!confirm("Delete this message from the project conversation?")) return;
        try {
          await request(`/api/projects/${project.project_id}/conversation/messages/${encodeURIComponent(messageId)}`, {method: "DELETE"});
          await loadConversation();
        } catch (error) { alert(error.message); }
      };
      element.append(remove);
    }
    $("#messages").append(element);
    $("#messages").scrollTop = $("#messages").scrollHeight;
  }
  async function loadConversation() {
    if (!project) return;
    if (project.read_only) {
      $("#messages").innerHTML = '<div class="empty"><div><h2>Read-only workspace</h2><p>Inspect LeanFM\'s grammar and artifacts without mixing them into another project.</p></div></div>';
      return;
    }
    const data = await request(`/api/projects/${project.project_id}/conversation`);
    $("#messages").replaceChildren();
    if (!(data.messages || []).length) {
      const empty = make("div", "empty");
      empty.innerHTML = "<div><h2>What are we building?</h2><p>Argue requirements into checked tasks, diagrams, protobuf traces, and a one-shot PR.</p></div>";
      $("#messages").append(empty);
    } else for (const item of data.messages) message(item.role, item.text, item.usage, item.message_id);
  }

  function directionClass(transition) {
    const pair = `${transition.source_actor}:${transition.destination_actor}`;
    if (pair === "UserBrowser:LeanFMServer") return "browser-server";
    if (pair === "LeanFMServer:UserBrowser") return "server-browser";
    return "provider";
  }
  function renderTaskDirectory() {
    const box = $("#grammarTasks");
    box.replaceChildren();
    if (selectedTask) {
      const back = make("button", "directory-back", "← tasks/");
      back.onclick = renderOverview;
      box.append(back, make("div", "spec-id directory-path", `tasks/${selectedTask.id}/`));
      for (const [section, count] of [
        ["productions", selectedTask.transitions.length], ["states", selectedTask.states.length],
        ["properties", selectedTask.properties.length], ["where_", selectedTask.constraints.length]
      ]) {
        const child = make("button", `task-button directory-child${grammarSection === section ? " active" : ""}`);
        child.append(make("strong", "", `▸ ${section}/`), make("span", "", `${count} entries`));
        child.onclick = () => showGrammarSection(section);
        box.append(child);
      }
      return;
    }
    box.append(make("div", "spec-id directory-path", "tasks/"));
    for (const task of grammar) {
      const button = make("button", `task-button${selectedTask?.id === task.id ? " active" : ""}`);
      button.append(make("strong", "", `▸ ${task.title}`), make("span", "", `${task.transitions.length} productions`));
      button.onclick = () => selectGrammarTask(task);
      box.append(button);
    }
  }
  function renderInspector(task) {
    const box = $("#grammarInspector");
    box.replaceChildren();
    box.append(make("h2", "", task.title));
    box.append(make("div", "spec-id", `${task.id}/`));
    box.append(make("p", "", `Entry ${task.entry}; terminal ${task.terminals.join(", ") || "none"}. Its residual machine has ${task.states.length} states and ${task.transitions.length} edges.`));
    box.append(make("h3", "", "states/"));
    const states = make("ul", "constraint-list");
    for (const state of task.states) states.append(make("li", "spec-id", `${state.id}/ · ${state.group} · ${state.label}${state.terminal ? " · terminal" : ""}`));
    box.append(states);
    box.append(make("h3", "", "Temporal properties"));
    if (!task.properties.length) box.append(make("p", "", "No task-local temporal properties."));
    for (const property of task.properties) {
      const row = make("div", "property");
      const title = make("strong");
      title.append(make("span", "checked", "checked"), document.createTextNode(`${property.mode} · ${property.name}`));
      row.append(title, make("div", "spec-id", property.expression));
      box.append(row);
    }
    box.append(make("h3", "", "where_/"));
    const list = make("ul", "constraint-list");
    for (const constraint of task.constraints) list.append(make("li", "spec-id", constraint));
    if (!task.constraints.length) list.append(make("li", "", "No task-local constraints."));
    box.append(list);
  }
  function inspectGrammarNode(title, path, rows) {
    const box = $("#grammarInspector");
    box.replaceChildren();
    box.append(make("h2", "", title), make("div", "spec-id", path));
    for (const [label, value] of rows) {
      const row = make("div", "inspector-row");
      row.append(make("strong", "", label), make("div", "spec-id", String(value)));
      box.append(row);
    }
  }
  async function inspectGrammarDiagram(title, path, source, rows) {
    const box = $("#grammarInspector");
    box.replaceChildren();
    box.append(make("h2", "", title), make("div", "spec-id", path));
    const host = make("div", "grammar-diagram");
    host.textContent = "Rendering diagram…";
    box.append(host);
    for (const [label, value] of rows) {
      const row = make("div", "inspector-row");
      row.append(make("strong", "", label), make("div", "spec-id", String(value)));
      box.append(row);
    }
    if (!window.mermaid) {
      host.replaceChildren(make("pre", "", source));
      return;
    }
    try {
      mermaid.initialize({startOnLoad: false, theme: "dark", securityLevel: "strict"});
      const {svg} = await mermaid.render(`leanfm-grammar-${Date.now()}-${Math.random().toString(16).slice(2)}`, source);
      host.innerHTML = svg;
    } catch (error) {
      host.replaceChildren(make("pre", "", source), make("p", "error", String(error)));
    }
  }
  function updateVisibleActors(taskNode) {
    const strip = taskNode.querySelector(".visible-actors");
    if (!strip) return;
    const actors = new Set();
    if (taskNode.open) taskNode.querySelectorAll("[data-message-production]").forEach(node => {
      actors.add(node.dataset.sourceActor);
      actors.add(node.dataset.destinationActor);
    });
    strip.replaceChildren();
    if (actors.size < 2) {
      strip.hidden = true;
      return;
    }
    strip.hidden = false;
    for (const actor of actors) strip.append(make("span", "active-actor", actor));
  }
  function renderTaskGrammar(task, expanded = true) {
    const graph = $("#grammarGraph");
    graph.replaceChildren();
    const root = make("section", "grammar-root");
    root.append(make("h2", "", `${task.id}/`), make("p", "", `${task.entry}/ → ${task.terminals.map(x => `${x}/`).join(" | ")}`));
    graph.append(root);
    const productions = make("div", "production-list");
    task.transitions.forEach((transition, index) => {
      const row = make("div", `production${expanded ? "" : " collapsed"}`);
      const node = make("button", `message-node ${directionClass(transition)}`);
      node.append(make("strong", "", transition.message));
      node.append(make("span", "actors", `message from ${transition.source_actor} to ${transition.destination_actor}`));
      node.append(make("span", "state-edge", `${String(index + 1).padStart(2, "0")}/  ${transition.src}/ → ${transition.dst}/`));
      node.onclick = () => row.classList.toggle("collapsed");
      const detail = make("div", "production-detail");
      detail.append(make("div", "spec-id", `production/${String(index + 1).padStart(2, "0")}/`));
      detail.append(make("p", "", `State ${transition.src}/ → ${transition.dst}/. Message from ${transition.source_actor} to ${transition.destination_actor}. Probability ${transition.probability || "1/1"}; dwell ${transition.dwell_ms || 0} ms.`));
      detail.append(make("strong", "", "protobuf fields/"));
      const fields = make("ol", "field-list");
      for (const field of transition.fields || []) fields.append(make("li", "spec-id", `${field.number}: ${field.name} · ${field.type}`));
      if (!(transition.fields || []).length) fields.append(make("li", "", "No payload fields."));
      detail.append(fields, make("p", "", `After this atom is consumed, the no-backtracking residual grammar continues from ${transition.dst}/.`));
      row.append(node, detail);
      productions.append(row);
    });
    graph.append(productions);
  }
  function selectGrammarTask(task) {
    selectedTask = task;
    grammarSection = "productions";
    renderInspector(task);
  }
  function renderGrammarEntries(title, entries, renderEntry) {
    const graph = $("#grammarGraph");
    graph.replaceChildren();
    const root = make("section", "grammar-root");
    root.append(make("h2", "", `tasks/${selectedTask.id}/${title}/`), make("p", "", `${entries.length} entries from the checked task specification`));
    graph.append(root);
    const grid = make("div", "deep-entry-list");
    entries.forEach((entry, index) => grid.append(renderEntry(entry, index)));
    if (!entries.length) grid.append(make("div", "deep-entry", "This directory is empty."));
    graph.append(grid);
  }
  function showGrammarSection(section) {
    if (!selectedTask) return;
    grammarSection = section;
    renderTaskDirectory();
    if (section === "productions") return renderTaskGrammar(selectedTask, true);
    if (section === "states") return renderGrammarEntries("states", selectedTask.states, state => {
      const card = make("article", "deep-entry");
      card.append(make("strong", "", `${state.id}/`), make("div", "spec-id", `${state.group}${state.terminal ? " · terminal" : ""}`), make("p", "", state.label));
      return card;
    });
    if (section === "properties") return renderGrammarEntries("properties", selectedTask.properties, property => {
      const card = make("article", "deep-entry");
      card.append(make("strong", "", property.name), make("div", "spec-id", property.mode), make("p", "", property.expression));
      return card;
    });
    renderGrammarEntries("where_", selectedTask.constraints, (constraint, index) => {
      const card = make("article", "deep-entry");
      card.append(make("strong", "", `constraint-${String(index + 1).padStart(2, "0")}`), make("p", "spec-id", constraint));
      return card;
    });
  }
  function renderOverview() {
    selectedTask = null;
    grammarSection = "productions";
    const graph = $("#grammarTasks");
    graph.replaceChildren(make("div", "spec-id directory-path", "tasks/"));
    const grid = make("div", "overview-grid grammar-tree");
    for (const task of grammar) {
      const card = make("details", "overview-card canvas-task");
      const summary = make("summary");
      summary.append(make("strong", "", `${task.id}/`), make("span", "", `${task.transitions.length} productions · ${task.states.length} states · ${task.constraints.length} where_`));
      summary.onclick = () => renderInspector(task);
      card.append(summary);
      const children = make("div", "canvas-children");
      const actors = make("div", "visible-actors");
      actors.setAttribute("aria-label", "Actors interacting in this scenario");
      actors.hidden = true;
      children.append(actors);
      const productions = make("details", "canvas-directory");
      const productionsSummary = make("summary", "", `productions/ (${task.transitions.length})`);
      productionsSummary.onclick = () => inspectGrammarNode("Productions", `tasks/${task.id}/productions/`, [["count", task.transitions.length], ["ordering", "scenario transition order"], ["derived view", "Open Tasks → Productions"]]);
      productions.append(productionsSummary);
      const productionChildren = make("div", "canvas-children");
      task.transitions.forEach((transition, index) => {
        const production = make("details", "canvas-leaf");
        production.dataset.messageProduction = transition.message;
        production.dataset.sourceActor = transition.source_actor;
        production.dataset.destinationActor = transition.destination_actor;
        const productionSummary = make("summary", "", `${String(index + 1).padStart(2, "0")}/ ${transition.message}`);
        productionSummary.onclick = () => inspectGrammarNode(transition.message, `tasks/${task.id}/productions/${String(index + 1).padStart(2, "0")}/`, [
          ["states", `${transition.src}/ → ${transition.dst}/`], ["message direction", `${transition.source_actor} → ${transition.destination_actor}`],
          ["probability", transition.probability || "1/1"], ["dwell", `${transition.dwell_ms || 0} ms`], ["protobuf fields", (transition.fields || []).length]
        ]);
        production.append(productionSummary);
        const body = make("div", "canvas-leaf-body");
        body.append(make("div", "spec-id", `${transition.src}/ → ${transition.dst}/`));
        body.append(make("p", "", `Message from ${transition.source_actor} to ${transition.destination_actor}. Probability ${transition.probability || "1/1"}; dwell ${transition.dwell_ms || 0} ms.`));
        const fields = make("details", "canvas-directory");
        const fieldsSummary = make("summary", "", `fields/ (${(transition.fields || []).length})`);
        fieldsSummary.onclick = () => inspectGrammarNode("Protobuf fields", `tasks/${task.id}/productions/${String(index + 1).padStart(2, "0")}/fields/`, [["count", (transition.fields || []).length], ["message", transition.message]]);
        fields.append(fieldsSummary);
        const fieldList = make("ol", "field-list");
        for (const field of transition.fields || []) {
          const item = make("li", "spec-id selectable-node", `${field.number}: ${field.name} · ${field.type}`);
          item.tabIndex = 0;
          item.onclick = event => { event.stopPropagation(); inspectGrammarNode(field.name, `tasks/${task.id}/productions/${String(index + 1).padStart(2, "0")}/fields/${field.number}`, [["field number", field.number], ["type", field.type], ["message", transition.message]]); };
          fieldList.append(item);
        }
        if (!(transition.fields || []).length) fieldList.append(make("li", "", "No payload fields."));
        fields.append(fieldList); body.append(fields); production.append(body); productionChildren.append(production);
      });
      productions.append(productionChildren); children.append(productions);
      for (const [name, entries, describe] of [
        ["states", task.states, state => `${state.id}/ · ${state.group} · ${state.label}${state.terminal ? " · terminal" : ""}`],
        ["properties", task.properties, property => `${property.mode} · ${property.name}: ${property.expression}`],
        ["where_", task.constraints, constraint => constraint]
      ]) {
        const directory = make("details", "canvas-directory");
        const directorySummary = make("summary", "", `${name}/ (${entries.length})`);
        directorySummary.onclick = () => inspectGrammarNode(`${name}/`, `tasks/${task.id}/${name}/`, [["count", entries.length], ["task", task.id], ...(name === "states" ? [["derived view", "Open Tasks → States"]] : [])]);
        directory.append(directorySummary);
        const list = make("div", "canvas-children");
        entries.forEach((entry, index) => {
          const value = make("button", "canvas-value spec-id selectable-node", `${String(index + 1).padStart(2, "0")}/ ${describe(entry)}`);
          value.onclick = event => { event.stopPropagation(); inspectGrammarNode(`${name} ${String(index + 1).padStart(2, "0")}`, `tasks/${task.id}/${name}/${String(index + 1).padStart(2, "0")}/`, [["value", describe(entry)], ["task", task.id]]); };
          list.append(value);
        });
        if (!entries.length) list.append(make("div", "canvas-value", "Empty"));
        directory.append(list); children.append(directory);
      }
      card.append(children);
      card.addEventListener("toggle", () => updateVisibleActors(card), true);
      grid.append(card);
    }
    graph.append(grid);
    $("#grammarInspector").innerHTML = "<h2>Grammar directory</h2><div class=\"spec-id\">tasks/</div><p>Select any node in the tree to inspect it. Opening and closing branches only changes the tree; this panel contains details for the current selection.</p>";
  }
  function renderGrammarExpression(expr, path) {
    if (!expr) return make("div", "grammar-terminal", "missing grammar body");
    if (expr.kind === "event") {
      const atom = make("button", `grammar-terminal message-node ${directionClass({source_actor: expr.src, destination_actor: expr.dst})}`);
      atom.append(make("strong", "", expr.message), make("span", "actors", `${expr.src} → ${expr.dst}`));
      atom.onclick = () => inspectGrammarNode(expr.message, path, [["terminal", "message atom"], ["task", expr.task], ["source", expr.src], ["destination", expr.dst]]);
      return atom;
    }
    if (expr.kind === "empty") {
      const epsilon = make("button", "grammar-terminal grammar-epsilon", "ε");
      epsilon.onclick = () => inspectGrammarNode("ε", path, [["meaning", "empty production; consumes no event"]]);
      return epsilon;
    }
    if (expr.kind === "ref") {
      const ref = make("button", "grammar-terminal grammar-reference", `↪ ${expr.task}`);
      ref.onclick = () => {
        inspectGrammarNode(expr.task, path, [["nonterminal reference", expr.task], ["resolution", `LeanFM/${expr.task}`]]);
        const target = $$("[data-grammar-task]").find(item => item.dataset.grammarTask === expr.task);
        if (target) { target.open = true; target.scrollIntoView({block: "nearest"}); }
      };
      return ref;
    }
    const names = {seq: "then · sequence", choice: "one of · choice", parallel: "in parallel", thresholdJoin: `${expr.required} of ${(expr.children || []).length} · join`, guard: `where_ ${expr.predicate}`, repeat: "repeat"};
    const node = make("details", `grammar-ast-node grammar-${expr.kind}`);
    const summary = make("summary", "", names[expr.kind] || expr.kind);
    summary.onclick = () => inspectGrammarNode(names[expr.kind] || expr.kind, path, [["grammar constructor", expr.kind], ["children", (expr.children || []).length], ...(expr.predicate ? [["predicate", expr.predicate]] : [])]);
    node.append(summary);
    const children = make("div", "grammar-ast-children");
    (expr.children || []).forEach((child, index) => children.append(renderGrammarExpression(child, `${path}/${String(index + 1).padStart(2, "0")}`)));
    node.append(children);
    return node;
  }
  function renderFaithfulGrammar() {
    selectedTask = null;
    const tree = $("#grammarTasks");
    tree.replaceChildren();
    const root = make("details", "grammar-production grammar-root-production");
    root.open = true;
    const rootSummary = make("summary", "", "LeanFM ::= task/scenario production");
    rootSummary.onclick = () => inspectGrammarNode("LeanFM", "LeanFM/", [["kind", "start production"], ["alternatives", grammar.length], ["parser", "typed forward grammar; no UI reconstruction from transitions"]]);
    root.append(rootSummary);
    const tasks = make("div", "grammar-ast-children");
    for (const task of grammar) {
      const production = make("details", "grammar-production");
      production.dataset.grammarTask = task.id;
      const summary = make("summary");
      summary.append(make("strong", "", `${task.id} ::=`), make("span", "", task.title));
      summary.onclick = () => inspectGrammarNode(task.id, `LeanFM/${task.id}`, [["kind", "named task/scenario production"], ["entry state", task.entry], ["terminal states", task.terminals.join(", ")]]);
      production.append(summary, renderGrammarExpression(task.grammar, `LeanFM/${task.id}/body`));
      tasks.append(production);
    }
    root.append(tasks); tree.append(root);
    $("#grammarInspector").innerHTML = "<h2>LeanFM</h2><div class=\"spec-id\">start production</div><p>This is the accepted GrammarExpr tree. Named task/scenario productions resolve into the literal sequence, choice, parallel, join, guard, reference, repetition, empty, and message constructors used by the forward parser.</p>";
  }
  async function loadGrammar() {
    if (!project) return;
    const data = await request(`/api/projects/${project.project_id}/tasks`);
    grammar = data.tasks || [];
    const validation = data.validation || {errors: 0, warnings: 0};
    $("#grammarMeta").textContent = `LeanFM start production resolving to ${grammar.length} named task/scenario productions from ${data.source || "the accepted specification"} · validation: ${validation.errors} errors, ${validation.warnings} warnings`;
    renderFaithfulGrammar();
  }

  async function loadArtifacts() {
    if (!project) return;
    if (!diagramTask && grammar.length) diagramTask = grammar[0];
    renderDiagramTasks();
    if (diagramTask) renderSelectedDiagram();
  }

  function renderDiagramTasks() {
    const box = $("#diagramTasks");
    box.replaceChildren();
    for (const task of grammar) {
      const button = make("button", `diagram-task${diagramTask?.id === task.id ? " active" : ""}`);
      button.append(make("strong", "", task.title), make("span", "", `${task.transitions.length} productions · ${task.states.length} states`));
      button.onclick = () => { diagramTask = task; renderDiagramTasks(); renderSelectedDiagram(); };
      box.append(button);
    }
  }

  async function renderSelectedDiagram() {
    if (!diagramTask) return;
    const stage = $("#diagramStage");
    const directory = {interaction: "productions", state: "states", properties: "properties", constraints: "where_"}[diagramKind];
    stage.replaceChildren(make("h2", "", diagramTask.title), make("div", "spec-id", `tasks/${diagramTask.id}/${directory}/`));
    if (diagramKind === "properties") {
      const list = make("div", "task-clause-list");
      for (const property of diagramTask.properties) {
        const clause = make("article", "task-clause");
        clause.append(make("strong", "", `${property.mode} · ${property.name}`), make("pre", "", property.expression));
        list.append(clause);
      }
      if (!diagramTask.properties.length) list.append(make("p", "", "No task-local temporal properties."));
      stage.append(list); return;
    }
    if (diagramKind === "constraints") {
      const list = make("div", "task-clause-list");
      for (const constraint of diagramTask.constraints) {
        const clause = make("article", "task-clause");
        clause.append(make("strong", "", "where_"), make("pre", "", constraint));
        list.append(clause);
      }
      if (!diagramTask.constraints.length) list.append(make("p", "", "No task-local context-sensitive guards."));
      stage.append(list); return;
    }
    const host = make("div", "large-diagram", "Rendering diagram…");
    stage.append(host);
    const source = diagramKind === "interaction" ? diagramTask.interaction_mermaid : diagramTask.state_mermaid;
    try {
      mermaid.initialize({startOnLoad: false, theme: "dark", securityLevel: "strict"});
      const {svg} = await mermaid.render(`leanfm-task-${Date.now()}-${Math.random().toString(16).slice(2)}`, source);
      host.innerHTML = svg;
    } catch (error) { host.replaceChildren(make("pre", "", source), make("p", "error", String(error))); }
  }

  async function boot() {
    try {
      me = await request("/api/me");
      $("#identity").textContent = me.username;
      hideAuth();
      await loadProjects();
    } catch { showAuth(false); }
  }

  $("#showLogin").onclick = () => showAuth(false);
  $("#showRegister").onclick = () => showAuth(true);
  $("#loginForm").onsubmit = async event => {
    event.preventDefault();
    try { await request("/api/login", {method: "POST", headers: {"Content-Type": "application/x-www-form-urlencoded"}, body: formBody(event.target)}); await boot(); }
    catch (error) { $("#authError").textContent = error.message; }
  };
  $("#registerForm").onsubmit = async event => {
    event.preventDefault();
    $("#authError").textContent = "Verifying your API key…";
    try { await request("/api/accounts", {method: "POST", headers: {"Content-Type": "application/x-www-form-urlencoded"}, body: formBody(event.target)}); await boot(); }
    catch (error) { $("#authError").textContent = error.message; }
  };
  $("#newProject").onclick = () => $("#projectDialog").showModal();
  $("#projectForm").onsubmit = async event => {
    event.preventDefault();
    try {
      const data = await request("/api/projects", {method: "POST", headers: {"Content-Type": "application/x-www-form-urlencoded"}, body: formBody(event.target)});
      $("#projectDialog").close(); event.target.reset(); await loadProjects();
      const item = projects.find(candidate => candidate.project_id === data.project_id);
      if (item) await selectProject(item);
    } catch (error) { $("#projectError").textContent = error.message; }
  };
  $("#composer").onsubmit = async event => {
    event.preventDefault();
    if (!project) return $("#projectDialog").showModal();
    if (project.read_only) return;
    const prompt = $("#prompt").value.trim();
    if (!prompt) return;
    $("#prompt").value = ""; message("user", prompt); message("assistant", "Thinking…");
    const pending = $("#messages").lastElementChild;
    try {
      const data = await request(`/api/projects/${project.project_id}/chat`, {method: "POST", headers: {"Content-Type": "application/x-www-form-urlencoded"}, body: new URLSearchParams({prompt}).toString()});
      pending.remove(); await loadConversation(); loadArtifacts();
    } catch (error) { pending.remove(); await loadConversation(); message("assistant", `Request failed: ${error.message}`); }
  };
  $$('[data-pane]').forEach(button => button.onclick = () => {
    $$('[data-pane]').forEach(item => item.classList.toggle("active", item === button));
    for (const name of ["chat", "grammar", "artifacts", "markerboard"]) $("#" + name + "Pane").classList.toggle("hidden", name !== button.dataset.pane);
  });
  $("#grammarSearch").oninput = event => {
    const query = event.target.value.trim().toLowerCase();
    if (!query) return renderFaithfulGrammar();
    const task = grammar.find(item => item.id.toLowerCase().includes(query) || item.title.toLowerCase().includes(query) || item.transitions.some(edge => edge.message.toLowerCase().includes(query)));
    if (task) {
      renderFaithfulGrammar();
      const taskNode = $$("#grammarTasks [data-grammar-task]").find(node => node.textContent.toLowerCase().includes(query));
      if (taskNode) {
        taskNode.open = true;
        taskNode.querySelectorAll("details").forEach(node => { if (node.textContent.toLowerCase().includes(query)) node.open = true; });
        for (let parent = taskNode.parentElement; parent; parent = parent.parentElement) if (parent.tagName === "DETAILS") parent.open = true;
        taskNode.scrollIntoView({block: "nearest"});
      }
      selectGrammarTask(task);
    }
  };
  $("#grammarExpand").onclick = () => $$("#grammarTasks details").forEach(node => node.open = true);
  $("#grammarCollapse").onclick = () => {
    $$("#grammarTasks details").forEach(node => node.open = false);
    $("#grammarTasks .grammar-root-production").open = true;
  };
  $("#grammarOverview").onclick = renderFaithfulGrammar;
  function setZoom(value) { grammarZoom = Math.max(.65, Math.min(1.5, value)); $("#grammarTasks").style.setProperty("zoom", grammarZoom); }
  $("#grammarZoomIn").onclick = () => setZoom(grammarZoom + .1);
  $("#grammarZoomOut").onclick = () => setZoom(grammarZoom - .1);
  $("#showInteraction").onclick = () => {
    selectTaskView("interaction", $("#showInteraction"));
  };
  $("#showStateMachine").onclick = () => {
    selectTaskView("state", $("#showStateMachine"));
  };
  function selectTaskView(kind, button) {
    diagramKind = kind;
    $$(".diagram-kind button").forEach(item => item.classList.toggle("active", item === button));
    renderSelectedDiagram();
  }
  $("#showProperties").onclick = event => selectTaskView("properties", event.currentTarget);
  $("#showConstraints").onclick = event => selectTaskView("constraints", event.currentTarget);
  $$('[data-font]').forEach(button => button.onclick = () => {
    const scales = {small: .85, normal: 1, large: 1.2};
    document.documentElement.style.setProperty("--font-scale", scales[button.dataset.font]);
    $$('[data-font]').forEach(item => item.classList.toggle("active", item === button));
  });
  $("#previewMermaid").onclick = async () => {
    const source = $("#mermaidSource").value, host = $("#mermaidPreview"); host.replaceChildren();
    if (window.mermaid) {
      try { mermaid.initialize({startOnLoad: false, theme: "dark", securityLevel: "strict"}); const {svg} = await mermaid.render("leanfm-mermaid-" + Date.now(), source); host.innerHTML = svg; }
      catch (error) { host.textContent = String(error); }
    } else host.append(make("pre", "", source));
  };
  $("#prompt").onkeydown = event => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); $("#composer").requestSubmit(); } };
  boot();
})();
