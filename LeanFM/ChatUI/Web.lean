namespace LeanFM.ChatUI.Web

def css : String := include_str "../../assets/chatui.css"
def javascript : String := include_str "../../assets/chatui.js"

def page : String :=
  "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
  "<meta name=\"color-scheme\" content=\"dark only\"><title>LeanFM</title><link rel=\"stylesheet\" href=\"/assets/chatui.css\"></head><body>" ++
  "<div class=\"app\"><aside class=\"sidebar\"><div class=\"brand\">LeanFM</div><button id=\"newProject\" class=\"new-project\">＋ New project</button><div id=\"projects\" class=\"projects\"></div><div class=\"sidebar-footer\"><span id=\"identity\"></span><br>Requirements become software.</div></aside>" ++
  "<main class=\"main\"><header class=\"topbar\"><strong id=\"projectTitle\">LeanFM</strong><nav class=\"tabs\"><button class=\"tab active\" data-pane=\"chat\">Chat</button><button class=\"tab\" data-pane=\"tasks\">Tasks</button><button class=\"tab\" data-pane=\"artifacts\">Diagrams / Artifacts</button><button class=\"tab\" data-pane=\"markerboard\">Markerboard</button></nav></header>" ++
  "<section id=\"chatPane\" class=\"pane chat-pane\"><div id=\"messages\" class=\"messages\"><div class=\"empty\"><div><h2>What are we building?</h2><p>Argue requirements into checked tasks, diagrams, protobuf traces, and a one-shot PR.</p></div></div></div><div class=\"composer-wrap\"><form id=\"composer\" class=\"composer\"><textarea id=\"prompt\" rows=\"1\" placeholder=\"Message LeanFM\"></textarea><button>Send</button></form></div></section>" ++
  "<section id=\"tasksPane\" class=\"pane content-pane hidden\"><h2>Task models</h2><p>Each task owns its interaction diagram, residual state machine, constraints, and protobuf sequence.</p><div id=\"tasks\" class=\"cards\"></div></section>" ++
  "<section id=\"artifactsPane\" class=\"pane content-pane hidden\"><h2>Diagrams / Artifacts</h2><div id=\"artifacts\" class=\"cards\"></div></section>" ++
  "<section id=\"markerboardPane\" class=\"pane content-pane hidden\"><h2>Markerboard</h2><p>Draft Mermaid, then promote an exact revision into candidate requirements.</p><textarea id=\"mermaidSource\" class=\"codebox\" spellcheck=\"false\">stateDiagram-v2\n  [*] --> thinking\n  thinking --> specified: requirement</textarea><button id=\"previewMermaid\" class=\"primary\">Preview</button><div id=\"mermaidPreview\" class=\"card\"><pre></pre></div></section></main></div>" ++
  "<section id=\"auth\" class=\"auth\"><div class=\"auth-card\"><h1>LeanFM</h1><p>Use your own API key. This server has no platform key to bill.</p><div class=\"auth-tabs\"><button id=\"showLogin\" class=\"active\">Log in</button><button id=\"showRegister\">Create account</button></div>" ++
  "<form id=\"loginForm\"><label>Username<input name=\"username\" autocomplete=\"username\" required></label><label>Password<input name=\"password\" type=\"password\" autocomplete=\"current-password\" required></label><button class=\"primary\">Log in</button></form>" ++
  "<form id=\"registerForm\" class=\"hidden\"><label>Username<input name=\"username\" autocomplete=\"username\" required></label><label>Password<input name=\"password\" type=\"password\" minlength=\"8\" autocomplete=\"new-password\" required></label><label>Provider<select name=\"provider\"><option value=\"openai\">OpenAI</option></select></label><label>API key<input name=\"api_key\" type=\"password\" autocomplete=\"off\" required></label><button class=\"primary\">Create account</button></form><div id=\"authError\" class=\"error\"></div></div></section>" ++
  "<dialog id=\"projectDialog\"><form id=\"projectForm\" method=\"dialog\"><h2>Create a project</h2><label>Project name<input name=\"display_name\" required autofocus></label><div class=\"error\" id=\"projectError\"></div><button class=\"primary\">Create project</button></form></dialog>" ++
  "<script src=\"https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js\"></script><script src=\"/assets/chatui.js\"></script></body></html>"

end LeanFM.ChatUI.Web
