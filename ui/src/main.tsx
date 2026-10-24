import React, {
  FormEvent,
  useCallback,
  useEffect,
  useRef,
  useState
} from "react";
import {createRoot} from "react-dom/client";
import katex from "katex";
import {ApiError, api, formRequest, reportClientError, setClientDiagnosticProject} from "./api";
import type {Billing, GrammarExpr, Message, ModelOption, Project, ProjectMemory, SpecificationState, Task} from "./types";

declare global { interface Window { mermaid?: any } }

type Phase = "chat" | "memory" | "book" | "grammar" | "tasks" | "source";
type ModelAvailability = "loading" | "locked" | "ready" | "error";
type AccountSession = {availability: ModelAvailability; username: string | null; billing: Billing | null; error: string};
const lockedSession: AccountSession = {availability: "locked", username: null, billing: null, error: ""};
type QuestionOption = {value: string; label: string; recommended?: boolean};
type ChatQuestion = {id: string; prompt: string; multiple?: boolean; options: QuestionOption[]};
type QueuedPrompt = {id: string; text: string; model: string; credentialIdentity: string; pendingQuestion?: {id: string; promptLength: number; composerTextLength: number}};
type ImageAttachment = {artifact_id: string; name: string; path: string; media_type: string; frame: string};

type WorkCheckpoint = {id: string; state: string; checkpoint: string; batch: number; continue: boolean; progress: string; requires_resume: boolean};
type WorkStatus = {work: WorkCheckpoint | null; request?: {id: string; prompt: string; model: string}; response?: {text?: string}};
type MathFragment = {source: string; display: boolean; raw: string};

class ClientFaultBarrier extends React.Component<{children: React.ReactNode}, {failed: boolean}> {
  state = {failed: false};
  static getDerivedStateFromError() { return {failed: true}; }
  componentDidCatch(error: Error, info: React.ErrorInfo) {
    const enriched = new Error(`${error.message}\nReact component stack:${info.componentStack}`);
    enriched.name = error.name;
    enriched.stack = `${error.stack || error.message}\nReact component stack:${info.componentStack}`;
    reportClientError("Rendering the LeanFM React application", enriched);
  }
  render() {
    if (this.state.failed) return <main className="auth"><div className="auth-card"><h1>LeanFM client error</h1><p>The browser fault was logged to the server for analysis. Reload the page to restart the client.</p></div></main>;
    return this.props.children;
  }
}

function delimitedMath(fragment: string): MathFragment | undefined {
  if (fragment.startsWith("$$") && fragment.endsWith("$$")) return {source: fragment.slice(2, -2), display: true, raw: fragment};
  if (fragment.startsWith("\\[") && fragment.endsWith("\\]")) return {source: fragment.slice(2, -2), display: true, raw: fragment};
  if (fragment.startsWith("\\(") && fragment.endsWith("\\)")) return {source: fragment.slice(2, -2), display: false, raw: fragment};
  if (fragment.startsWith("$") && fragment.endsWith("$")) return {source: fragment.slice(1, -1), display: false, raw: fragment};
  return undefined;
}

function LatexText({text}: {text: string}) {
  const codeAndProse = text.split(/(```[\s\S]*?```)/g);
  return <>{codeAndProse.map((section, sectionIndex) => {
    if (section.startsWith("```") && section.endsWith("```")) return <React.Fragment key={`code-${sectionIndex}`}>{section}</React.Fragment>;
    const fragments = section.split(/(\$\$[\s\S]+?\$\$|\\\[[\s\S]+?\\\]|\\\([^\n]+?\\\)|\$(?!\s)[^$\n]+?(?<!\s)\$)/g);
    return <React.Fragment key={`text-${sectionIndex}`}>{fragments.map((fragment, fragmentIndex) => {
      const math = delimitedMath(fragment);
      if (!math) return <React.Fragment key={fragmentIndex}>{fragment}</React.Fragment>;
      try {
        const html = katex.renderToString(math.source, {displayMode: math.display, output: "mathml", throwOnError: true, trust: false, strict: "warn"});
        const Tag = math.display ? "div" : "span";
        return <Tag key={fragmentIndex} className={math.display ? "chat-math-display" : "chat-math-inline"} dangerouslySetInnerHTML={{__html: html}} />;
      } catch (error) {
        reportClientError("Rendering LaTeX in an assistant response", error);
        return <code key={fragmentIndex} className="chat-math-error" title={(error as Error).message}>{math.raw}</code>;
      }
    })}</React.Fragment>;
  })}</>;
}

function closeTruncatedJson(source: string): string {
  const open: string[] = [];
  let quoted = false, escaped = false;
  for (const character of source) {
    if (escaped) { escaped = false; continue; }
    if (quoted && character === "\\") { escaped = true; continue; }
    if (character === '"') { quoted = !quoted; continue; }
    if (quoted) continue;
    if (character === "{" || character === "[") open.push(character);
    else if (character === "}" && open.at(-1) === "{") open.pop();
    else if (character === "]" && open.at(-1) === "[") open.pop();
  }
  return source + open.reverse().map(character => character === "{" ? "}" : "]").join("");
}

function extractQuestions(text: string): {text: string; questions: ChatQuestion[]; invalid?: boolean} {
  const match = text.match(/```leanfm-(?:questions|qustions)\s*([\s\S]*?)```/i);
  if (!match) return {text, questions: []};
  const source = match[1].trim();
  for (const candidate of [...new Set([source, closeTruncatedJson(source)])]) {
    try {
      const parsed = JSON.parse(candidate);
      const questions = Array.isArray(parsed.questions) ? parsed.questions.filter((question: ChatQuestion) => question.id && question.prompt && Array.isArray(question.options)) : [];
      return {text: text.replace(match[0], "").trim(), questions};
    } catch { /* try the next bounded repair */ }
  }
  return {text: text.replace(match[0], "").trim(), questions: [], invalid: true};
}

function latestUnansweredQuestion(messages: Message[], answeredIds: Set<string>): ChatQuestion | undefined {
  for (const message of [...messages].reverse()) {
    if (message.role !== "assistant") continue;
    const questions = extractQuestions(message.text).questions;
    for (const question of questions.reverse()) {
      if (!answeredIds.has(question.id)) return question;
    }
  }
  return undefined;
}

function extractResult(text: string): {text: string; status?: "success" | "warn" | "fail"} {
  const match = text.match(/```leanfm-result\s*([\s\S]*?)```/i);
  if (!match) return {text};
  try {
    const status = JSON.parse(match[1]).status;
    return {text: text.replace(match[0], "").trim(), status: ["success", "warn", "fail"].includes(status) ? status : undefined};
  } catch { return {text}; }
}

function projectImagePaths(text: string, projectId: string): string[] {
  const pattern = new RegExp(`(?:data/accounts/[^\\s]+/projects/${projectId}/)?((?:spec/images|artifacts/attachments)/[A-Za-z0-9._/-]+\\.(?:svg|gif|png|jpe?g))`, "gi");
  return [...text.matchAll(pattern)].map(match => match[1]).filter(path => !path.includes(".."))
    .filter((path, index, paths) => paths.indexOf(path) === index);
}

function projectVideoPaths(text: string, projectId: string): string[] {
  const pattern = new RegExp(`(?:data/accounts/[^\\s]+/projects/${projectId}/)?((?:spec/images|spec/media|artifacts|renders)/[A-Za-z0-9._/-]+\\.(?:mp4|webm))`, "gi");
  return [...text.matchAll(pattern)].map(match => match[1]).filter((path, index, paths) => paths.indexOf(path) === index);
}

type RemoteImage = {url: string; source: string; alt: string};
function remoteImages(text: string): RemoteImage[] {
  const found: RemoteImage[] = [];
  for (const match of text.matchAll(/!\[([^\]]*)\]\((https:\/\/[^)\s]+)\)/gi)) found.push({url: match[2], source: match[2], alt: match[1] || "Internet image"});
  for (const match of text.matchAll(/(https:\/\/commons\.wikimedia\.org\/wiki\/File(?:%3A|:)([^)\s]+))/gi)) {
    const filename = decodeURIComponent(match[2]);
    found.push({url: `https://commons.wikimedia.org/wiki/Special:Redirect/file/${encodeURIComponent(filename)}`, source: match[1], alt: filename});
  }
  return found.filter((image, index, images) => images.findIndex(other => other.url === image.url) === index);
}

function CopyImageReference({reference}: {reference: string}) {
  const [copied, setCopied] = useState(false);
  async function copy() {
    try {
      await navigator.clipboard.writeText(reference);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1500);
    } catch (error) {
      reportClientError("Copying an image reference to the clipboard", error);
    }
  }
  return <button type="button" className="copy-image-reference" onClick={copy}>{copied ? "Copied" : "Copy reference"}</button>;
}

function ProjectImage({projectId, path}: {projectId: string; path: string}) {
  const [loaded, setLoaded] = useState(false), [missing, setMissing] = useState(false);
  const src = `/api/projects/${projectId}/files/${path.split("/").map(encodeURIComponent).join("/")}`;
  if (missing) return <div className="request-error"><div className="result-badge fail">FAIL</div><p>Referenced project image does not exist: {path}</p></div>;
  return <figure className="chat-inline-figure" style={!loaded ? {display: "none"} : undefined}><img src={src} alt={`Project figure ${path}`} onLoad={() => setLoaded(true)} onError={() => { setMissing(true); reportClientError("Loading a referenced project image", new Error(`Project image does not exist: ${path}`)); }} /><figcaption><span>{path}</span><CopyImageReference reference={path} /></figcaption></figure>;
}

function extractCanvases(text: string): {text: string; canvases: string[]} {
  const canvases: string[] = [];
  let remaining = text.replace(/```leanfm-canvas\s*([\s\S]*?)```/gi, (_block, source: string) => {
    canvases.push(source.trim());
    return "";
  });
  // Some providers occasionally spell out the requested fence marker instead
  // of emitting backticks. Recover only the tightly bounded canvas+script form;
  // arbitrary HTML remains ordinary escaped chat text.
  remaining = remaining.replace(/(?:^|\n)\s*(?:fenced\s+)?leanfm-canvas\s*\n\s*(<canvas\b[\s\S]*?<\/canvas>\s*<script\b[\s\S]*?<\/script>)/gi, (_block, source: string) => {
    canvases.push(source.trim());
    return "\n";
  });
  return {text: remaining.trim(), canvases};
}

function CanvasAnimation({source}: {source: string}) {
  const [running, setRunning] = useState(true), [revision, setRevision] = useState(0);
  const hasCanvas = /<canvas(?:\s|>)/i.test(source);
  if (!hasCanvas) return <div className="request-error"><div className="result-badge fail">FAIL</div><p>The canvas response did not contain a literal canvas element.</p></div>;
  const document = `<!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="dark"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; connect-src 'none'; form-action 'none'; base-uri 'none'"><style>html,body{margin:0;min-height:100%;overflow:hidden;background:#08141d;color:#e5edf3}body{display:grid;place-items:center}canvas{display:block;max-width:100%;height:auto}</style></head><body>${source}</body></html>`;
  function restart() { setRevision(value => value + 1); setRunning(true); }
  return <figure className="chat-canvas"><div className="chat-canvas-controls"><button onClick={() => setRunning(value => !value)}>{running ? "Stop" : "Start"}</button><button onClick={restart}>Restart</button></div>{running ? <iframe key={revision} title="Animated canvas response" sandbox="allow-scripts" srcDoc={document} /> : <div className="chat-canvas-stopped">Animation stopped</div>}</figure>;
}

function QuestionForm({questions, answeredIds, disabled, onAnswer}: {questions: ChatQuestion[]; answeredIds: Set<string>; disabled?: boolean; onAnswer: (answer: string) => void}) {
  const unanswered = questions.filter(question => !answeredIds.has(question.id));
  const [selected, setSelected] = useState<Record<string, string[]>>({});
  const [qualifications, setQualifications] = useState<Record<string, string>>({});
  const [validation, setValidation] = useState("");
  function choose(question: ChatQuestion, value: string, checked: boolean) {
    setSelected(current => ({...current, [question.id]: question.multiple ? (checked ? [...(current[question.id] || []), value] : (current[question.id] || []).filter(item => item !== value)) : [value]}));
  }
  function submitAnswers() {
    const incomplete = unanswered.find(question =>
      (selected[question.id] || []).length === 0 && (qualifications[question.id] || "").trim().length === 0);
    if (incomplete) {
      setValidation(`Answer “${incomplete.prompt}” by selecting a choice or entering qualifying text.`);
      return;
    }
    setValidation("");
    const answer = unanswered.map(question => {
      const values = selected[question.id] || [];
      const labels = values.map(value => question.options.find(option => option.value === value)?.label || value);
      const selectedAnswer = labels.length > 0 ? labels.map((label, index) => `${label} [${values[index]}]`).join(", ") : "No predefined option selected.";
      const qualification = (qualifications[question.id] || "").trim();
      return `Question ID: ${question.id}\n${question.prompt}\nAnswer: ${selectedAnswer}` + (qualification ? `\nQualification: ${qualification}` : "");
    }).join("\n\n");
    onAnswer(answer);
  }
  if (unanswered.length === 0) return <div className="answered-question-note">Already answered; this question is closed.</div>;
  return <section className="chat-questions" aria-label="Questions requiring answers">{unanswered.map(question => <fieldset key={question.id}><legend>{question.prompt}</legend>{question.options.map(option => <label key={option.value} className={(selected[question.id] || []).includes(option.value) ? "selected" : ""}><input type={question.multiple ? "checkbox" : "radio"} name={question.id} value={option.value} checked={(selected[question.id] || []).includes(option.value)} onChange={event => { setValidation(""); choose(question, option.value, event.target.checked); }} /> <span>{option.label}{option.recommended && <small>Recommended</small>}</span></label>)}<label className="question-qualification"><span>Qualify this decision or provide a better answer</span><textarea value={qualifications[question.id] || ""} onChange={event => { setValidation(""); setQualifications(current => ({...current, [question.id]: event.target.value})); }} maxLength={4000} rows={3} placeholder="Optional when a choice fits; use this alone when none does." /></label></fieldset>)}{validation && <p className="question-validation" role="alert">{validation}</p>}<button type="button" className="primary" disabled={disabled} onClick={submitAnswers}>Submit answers</button></section>;
}

function Auth({onReady, account, onCancel, onLogout, loggingOut}: {onReady: (sessionPreserved?: boolean) => void; account?: string; onCancel?: () => void; onLogout?: () => void; loggingOut?: boolean}) {
  const [register, setRegister] = useState(false), [error, setError] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [username, setUsername] = useState(() => account || window.localStorage.getItem("leanfm:last-username") || "");
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (submitting || loggingOut) return;
    setSubmitting(true); setError(register ? "Verifying your provider keys…" : "Unlocking your provider keys…");
    const data = Object.fromEntries(new FormData(event.currentTarget)) as Record<string, string>;
    try { const result = await api<{session_preserved?: boolean}>(register ? "/api/accounts" : account ? "/api/provider-keys" : "/api/login", formRequest(data)); window.localStorage.setItem("leanfm:last-username", data.username); onReady(result.session_preserved === true); }
    catch (e) { setError((e as Error).message); }
    finally { setSubmitting(false); }
  }
  return <section className="auth"><div className="auth-card"><h1>{account ? "API keys" : "LeanFM"}</h1><p>Sign in to unlock your encrypted provider API keys. One password unlocks OpenAI and Anthropic together; this is your LeanFM login, not a provider login.</p>
    {!account && <div className="auth-tabs" role="tablist" aria-label="Account access"><button type="button" role="tab" aria-selected={!register} className={!register ? "active" : ""} onClick={() => { setRegister(false); setError(""); }}>Log in</button><button type="button" role="tab" aria-selected={register} className={register ? "active" : ""} onClick={() => { setRegister(true); setError(""); }}>Create account</button></div>}
    <form onSubmit={submit}><label>Username<input name="username" autoComplete="username" value={username} readOnly={!!account} onChange={event => setUsername(event.target.value)} required /></label><label>Password<input name="password" type="password" autoComplete={register ? "new-password" : "current-password"} minLength={register ? 8 : undefined} required /></label>
      <details key={register ? "registration" : "login"} open={register || !!account || undefined}><summary>{register ? "Provider API keys" : "Add or replace API keys (optional)"}</summary><label>OpenAI API key<input name="openai_api_key" type="password" autoComplete="off" maxLength={4096} /></label><label>Anthropic API key<input name="anthropic_api_key" type="password" autoComplete="off" maxLength={4096} /></label></details>
      {!register && <p className="stored-key-note">Already have an account? Use your username and password. Your saved API keys unlock automatically after a server restart.</p>}
      <p>{register ? "Provide at least one key; you can provide both now." : "Optional: add or replace either key. Leave blank to keep the stored key. Blank fields do not mean your saved keys were lost; your password unlocks them again after a server restart."} Keys are encrypted with your password and never returned to the browser. Adding another provider keeps you signed in. Replacing an existing key signs out older sessions.</p>
      <button className="primary" disabled={submitting || loggingOut}>{register ? "Create account" : account ? "Save API keys" : "Log in"}</button>{onCancel && <button type="button" onClick={onCancel} disabled={submitting || loggingOut}>Cancel</button>}</form>{onLogout && <button type="button" onClick={onLogout} disabled={loggingOut || submitting}>Log out and sign in again</button>}<div className="error" role="alert">{error}</div></div></section>;
}

function ProviderKeysDialog({account, onDone, onClose, onLogout, loggingOut}: {account: string; onDone: (sessionPreserved?: boolean) => void; onClose: () => void; onLogout: () => void; loggingOut: boolean}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => { const dialog = ref.current!; dialog.showModal(); return () => dialog.close(); }, []);
  return <dialog ref={ref} className="key-dialog" aria-label="Unlock or update provider keys" onCancel={event => { event.preventDefault(); onClose(); }}><Auth key={account || "signed-out"} account={account} onReady={onDone} onCancel={onClose} onLogout={onLogout} loggingOut={loggingOut} /></dialog>;
}

function Mermaid({source, className = "large-diagram"}: {source: string; className?: string}) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    let current = true;
    if (!window.mermaid || !ref.current) return;
    window.mermaid.initialize({startOnLoad: false, theme: "dark", securityLevel: "strict"});
    window.mermaid.render(`leanfm-react-${Date.now()}-${Math.random().toString(16).slice(2)}`, source)
      .then(({svg}: {svg: string}) => { if (current && ref.current) ref.current.innerHTML = svg; })
      .catch((e: Error) => { reportClientError("Rendering a Mermaid diagram in the project workspace", e); if (current && ref.current) ref.current.textContent = `${e.message}\n\n${source}`; });
    return () => { current = false; };
  }, [source]);
  return <div ref={ref} className={className}><pre>{source}</pre></div>;
}

function MessageView({message, projectId, answeredIds, onDelete, onResend, onAnswer, disabled}: {message: Message; projectId: string; answeredIds: Set<string>; onDelete: () => void; onResend?: () => void; onAnswer?: (answer: string) => void; disabled?: boolean}) {
  const result = extractResult(message.text);
  const structured = extractQuestions(result.text);
  const canvasContent = extractCanvases(structured.text);
  const [answerText, activity] = canvasContent.text.split(/\n\nOperational trace:\n/, 2);
  const images = projectImagePaths(answerText, projectId);
  const videos = projectVideoPaths(answerText, projectId);
  const internetImages = remoteImages(answerText);
  const pieces = answerText.split(/```mermaid\s*\n?/i);
  const first = pieces.shift() || "";
  const sentAt = message.sent_at_ms === undefined ? undefined : new Date(message.sent_at_ms);
  const validSentAt = sentAt && !Number.isNaN(sentAt.getTime());
  const timestamp = validSentAt ? sentAt.toLocaleString([], {dateStyle: "medium", timeStyle: "medium"}) : "Time unavailable (legacy message)";
  return <article className={`message ${message.role}`}><time className="message-timestamp" dateTime={validSentAt ? sentAt.toISOString() : undefined} title={validSentAt ? sentAt.toISOString() : timestamp}>{timestamp}{message.model ? ` · ${message.model}` : ""}</time>{result.status && <div className={`result-badge ${result.status}`}>{result.status.toUpperCase()}</div>}<div className="message-text"><LatexText text={first} />{pieces.map((part, i) => {
    const end = part.indexOf("```");
    return end < 0 ? <LatexText key={i} text={`\`\`\`mermaid\n${part}`} /> : <React.Fragment key={i}><Mermaid source={part.slice(0, end).trim()} className="chat-diagram" /><LatexText text={part.slice(end + 3)} /></React.Fragment>;
  })}</div>{structured.invalid && <div className="request-error"><div className="result-badge fail">FAIL</div><p>The model returned a malformed question form. Resend this message to retry.</p></div>}{canvasContent.canvases.map((source, index) => <CanvasAnimation source={source} key={index} />)}{images.map(path => <ProjectImage projectId={projectId} path={path} key={path} />)}{videos.map(path => <figure className="chat-inline-figure" key={path}><video controls preload="metadata" src={`/api/projects/${projectId}/files/${path.split("/").map(encodeURIComponent).join("/")}`}><a href={`/api/projects/${projectId}/files/${path.split("/").map(encodeURIComponent).join("/")}`}>Open {path}</a></video><figcaption>{path}</figcaption></figure>)}{internetImages.map(image => <figure className="chat-inline-figure" key={image.url}><img src={image.url} alt={image.alt} loading="lazy" referrerPolicy="no-referrer" /><figcaption><a href={image.source} target="_blank" rel="noreferrer noopener">Source: {image.source}</a><CopyImageReference reference={`![${image.alt}](${image.url})\nSource: ${image.source}`} /></figcaption></figure>)}{activity && <details className="operational-trace"><summary>Operational trace</summary><pre>{activity}</pre></details>}{structured.questions.length > 0 && onAnswer && <QuestionForm questions={structured.questions} answeredIds={answeredIds} disabled={disabled} onAnswer={onAnswer} />}{message.response_time_ms !== undefined && <div className="response-time">Response time: {(message.response_time_ms / 1000).toFixed(1)} s</div>}{message.usage && <div className="usage">{message.usage.input_tokens} input · {message.usage.cached_input_tokens} cached · {message.usage.output_tokens} output · {message.usage.total_tokens} total · billed to your API key</div>}
    <div className="message-actions">{onResend && <button onClick={onResend} disabled={disabled}>Resend</button>}<button onClick={onDelete}>Delete</button></div></article>;
}

function Chat({project, models, modelDetails, defaultModel, credentialIdentity, modelAvailability, modelError, onUnlockKeys, onRetryModels, onModelChange, onWorkspaceChange, onBusyChange}: {project: Project; models: string[]; modelDetails: ModelOption[]; defaultModel: string; credentialIdentity: string; modelAvailability: ModelAvailability; modelError: string; onUnlockKeys: () => void; onRetryModels: () => void; onModelChange: (model: string) => void; onWorkspaceChange: () => void; onBusyChange: (busy: boolean, model?: string) => void}) {
  const [attachments, setAttachments] = useState<ImageAttachment[]>([]), [uploading, setUploading] = useState(false), [attachmentError, setAttachmentError] = useState("");
  const attachmentInput = useRef<HTMLInputElement>(null);
  const [messages, setMessages] = useState<Message[]>([]), [prompt, setPrompt] = useState(""), [queue, setQueue] = useState<QueuedPrompt[]>([]), [busy, setBusy] = useState(false), [error, setError] = useState(""), [errorAction, setErrorAction] = useState(""), [errorTrace, setErrorTrace] = useState("");
  const [model, setModel] = useState(defaultModel);
  const [workProgress, setWorkProgress] = useState<WorkCheckpoint | null>(null);
  const [heldWork, setHeldWork] = useState<{item: QueuedPrompt; work: WorkCheckpoint | null} | null>(null);
  const credentialRef = useRef<Record<string, string>>({}), stopWork = useRef(false), busyRef = useRef(false);
  credentialRef.current = Object.fromEntries(modelDetails.map(option => [option.id, `${credentialIdentity}:${option.provider}:${option.key_fingerprint}`])); busyRef.current = busy;
  useEffect(() => {
    const cancel = (event: Event) => { if ((event as CustomEvent<string>).detail === project.project_id) stopWork.current = true; };
    window.addEventListener("leanfm:cancel-work", cancel);
    return () => window.removeEventListener("leanfm:cancel-work", cancel);
  }, [project.project_id]);
  useEffect(() => {
    if (!models.length || busyRef.current || project.read_only) return;
    void api<WorkStatus>(`/api/projects/${project.project_id}/chat/work/active`).then(status => {
      if (!busyRef.current && status.work && status.request && ["running", "checkpointed"].includes(status.work.state))
        setHeldWork({work: status.work, item: {id: status.request.id, text: status.request.prompt, model: status.request.model, credentialIdentity: credentialRef.current[status.request.model] || ""}});
    }).catch(() => {});
  }, [credentialIdentity, project.project_id]);

  const conversationEndRef = useRef<HTMLDivElement>(null);
  const answeredIds = new Set(messages.flatMap(message => [...message.text.matchAll(/Question ID:\s*([A-Za-z0-9._-]+)/g)].map(match => match[1])));
  const pendingQuestion = latestUnansweredQuestion(messages, answeredIds);
  useEffect(() => {
    window.requestAnimationFrame(() => conversationEndRef.current?.scrollIntoView({block: "end"}));
  }, [messages.length, error]);
  async function load(signal?: AbortSignal) { const data = await api<{messages: Message[]}>(`/api/projects/${project.project_id}/conversation`, {}, signal); setMessages(data.messages || []); }
  useEffect(() => { const controller = new AbortController(); if (!project.read_only) load(controller.signal).catch(e => { if (e.name !== "AbortError") setError(e.message); }); return () => controller.abort(); }, [project.project_id]);
  useEffect(() => { if (!models.includes(model)) setModel(defaultModel || models[0] || ""); }, [models, defaultModel, model]);
  useEffect(() => { onModelChange(model); }, [model, onModelChange]);
  function enqueue(text: string, clearComposer = false, pendingQuestion?: QueuedPrompt["pendingQuestion"]) {
    text = text.trim();
    if (!text) return;
    const id = globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    if (!models.includes(model)) return;
    setQueue(current => [...current, {id, text, model, credentialIdentity: credentialRef.current[model] || "", pendingQuestion}]);
    if (clearComposer) setPrompt("");
  }
  async function inspectHeldWork() {
    if (!heldWork) return;
    try {
      const status = await api<WorkStatus>(`/api/projects/${project.project_id}/chat/work/${heldWork.work?.id || heldWork.item.id}`);
      if (status.work && ["running", "checkpointed"].includes(status.work.state)) setHeldWork({...heldWork, work: status.work});
      else { setHeldWork(null); await load(); onWorkspaceChange(); }
    } catch (error) { setError((error as Error).message); }
  }
  async function run(item: QueuedPrompt, resume?: WorkCheckpoint, restart = false) {
    if (!resume) setMessages(v => [...v, {message_id: `pending-${item.id}`, role: "user", text: item.text, sent_at_ms: Date.now()}]);
    setBusy(true); busyRef.current = true; stopWork.current = false; onBusyChange(true, item.model);
    setHeldWork(null); setError(""); setErrorAction(""); setErrorTrace("");
    let work = resume || null;
    let values: Record<string, string> = resume ? {work_id: resume.id, checkpoint_id: resume.checkpoint, model: item.model, explicit_resume: "true", restart: String(restart)}
      : {prompt: item.text, model: item.model, work_request_id: item.id, ...(item.pendingQuestion ? {composer_question_id: item.pendingQuestion.id, composer_question_prompt_length: String(item.pendingQuestion.promptLength), composer_text_length: String(item.pendingQuestion.composerTextLength)} : {})};
    try {
      for (;;) {
        if ((credentialRef.current[item.model] || "") !== item.credentialIdentity) { setHeldWork({item, work}); setError("The credential changed. Explicitly resume this task after signing in."); break; }
        let result: {work?: WorkCheckpoint};
        try { result = await api(`/api/projects/${project.project_id}/chat`, formRequest(values)); }
        catch (failure) {
          // A status read can prove that a batch finished. Never blindly replay
          // a request whose provider outcome is uncertain.
          const status = await api<WorkStatus>(`/api/projects/${project.project_id}/chat/work/${work?.id || item.id}`).catch(() => null);
          if (status?.work && status.work.state === "checkpointed" && !status.work.requires_resume && !stopWork.current && (credentialRef.current[item.model] || "") === item.credentialIdentity) result = {work: status.work};
          else {
            if (status?.work ? ["running", "checkpointed"].includes(status.work.state) : !!work || !(failure instanceof ApiError) || failure.status === 0 || failure.status >= 500) setHeldWork({item, work: status?.work || work});
            throw failure;
          }
        }
        work = result.work || null; setWorkProgress(work);
        await load(); onWorkspaceChange();
        if (!work?.continue) break;
        if (stopWork.current) { await load(); break; }
        if ((credentialRef.current[item.model] || "") !== item.credentialIdentity || work.requires_resume) { setHeldWork({item, work}); break; }
        values = {work_id: work.id, checkpoint_id: work.checkpoint, model: item.model};
        await new Promise(resolve => window.setTimeout(resolve, 0));
      }
    } catch (error) {
      setMessages(v => v.filter(message => message.message_id !== `pending-${item.id}`));
      setError((error as Error).message);
      if (error instanceof ApiError) { setErrorAction(error.action); setErrorTrace("LeanFM error report (safe to paste to Codex)\n" + JSON.stringify({...error.trace, project_id: project.project_id, model: item.model}, null, 2)); }
      await load().catch(() => {}); onWorkspaceChange();
    } finally { setBusy(false); busyRef.current = false; onBusyChange(false); }
  }

  useEffect(() => {
    if (busy || heldWork || queue.length === 0) return;
    const [next, ...remaining] = queue;
    if (next.credentialIdentity !== (credentialRef.current[next.model] || "") || !models.includes(next.model)) {
      setError("Queued prompt held because the unlocked credential changed. Remove it and resubmit under the current key.");
      return;
    }
    setQueue(remaining);
    void run(next);
  }, [busy, heldWork, queue, credentialIdentity, models]);
  function send(event: FormEvent) {
    event.preventDefault();
    const text = prompt.trim() || (attachments.length ? "Please examine the attached image." : "");
    if (!text || uploading || !models.includes(model)) return;
    const answer = pendingQuestion
      ? `Question ID: ${pendingQuestion.id}\n${pendingQuestion.prompt}\nAnswer: No predefined option selected.\nQualification: ${text}`
      : text;
    const withImages = answer + attachments.map(image => `\n\n![Attached image](${image.path})`).join("");
    enqueue(withImages, true, pendingQuestion ? {id: pendingQuestion.id, promptLength: pendingQuestion.prompt.length, composerTextLength: text.length} : undefined);
    setAttachments([]); setAttachmentError("");
  }
  async function attach(files: FileList | null) {
    if (!files?.length || uploading) return;
    if (attachments.length + files.length > 4) { setAttachmentError("Attach at most four images per message."); return; }
    setUploading(true); setAttachmentError("");
    try {
      for (const file of Array.from(files)) {
        if (!file.size || file.size > 2 * 1024 * 1024) throw new Error("Each image must be nonempty and at most 2 MiB.");
        const mediaType = file.type || (file.name.toLowerCase().endsWith(".svg") ? "image/svg+xml" : "");
        if (!["image/png", "image/jpeg", "image/gif", "image/svg+xml"].includes(mediaType)) throw new Error("Choose a PNG, JPEG, GIF, or static SVG image.");
        const content = await new Promise<string>((resolve, reject) => {
          const reader = new FileReader(); reader.onerror = () => reject(new Error("Could not read this image."));
          reader.onload = () => resolve(String(reader.result).split(",", 2)[1]); reader.readAsDataURL(file);
        });
        const image = await api<ImageAttachment>(`/api/projects/${project.project_id}/markerboard/media`, {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({media_type: mediaType, content, filename: file.name})});
        setAttachments(current => [...current, image]);
      }
    } catch (error) { setAttachmentError((error as Error).message); }
    finally { setUploading(false); if (attachmentInput.current) attachmentInput.current.value = ""; }
  }
  async function remove(id: string) { if (!confirm("Delete this message from the project conversation?")) return; await api(`/api/projects/${project.project_id}/conversation/messages/${encodeURIComponent(id)}`, {method: "DELETE"}); await load(); }
  // Requirement refs: keyless_server_has_no_provider_spend,
  // one_password_unlocks_all_provider_keys, selected_model_determines_provider_credential.
  const modelPlaceholder = modelAvailability === "loading" ? "Loading models…" : modelAvailability === "locked" ? "Sign in to load models" : "Models unavailable";
  const modelAccess = models.length === 0 && <div className="model-access" role={modelAvailability === "error" ? "alert" : "status"}>
    <p>{modelAvailability === "loading" ? "Loading models for your unlocked API keys…"
      : modelAvailability === "locked" ? "Your API keys are locked. Sign in with your LeanFM username and password to load models and chat. Saved keys do not need to be entered again."
      : modelAvailability === "error" ? `Could not load your models. ${modelError}`
      : "No models are available for your unlocked API keys. Retry loading models or review your provider keys."}</p>
    {modelAvailability !== "loading" && <div>
      {modelAvailability !== "locked" && <button type="button" onClick={onRetryModels}>Retry loading models</button>}
      <button type="button" onClick={onUnlockKeys}>{modelAvailability === "locked" ? "Sign in" : "Review API keys"}</button>
    </div>}
  </div>;
  if (project.read_only) return <div className="empty"><div><h2>Read-only workspace</h2><p>Select an editable project to chat.</p></div></div>;
  return <section className="pane chat-pane">
    <div className="messages">{messages.length ? messages.map(m => <MessageView key={m.message_id} message={m} projectId={project.project_id} answeredIds={answeredIds} onDelete={() => remove(m.message_id)} onResend={m.role === "user" ? () => enqueue(m.text) : undefined} onAnswer={m.role === "assistant" ? enqueue : undefined} disabled={false} />) : <div className="empty"><div><h2>What problem are you trying to solve?</h2><p>Resume from the durable project files. Your book and specifications live in Project memory, not in chat history. Continue here; LeanFM will use those durable files.</p></div></div>}{error && <div className="request-error"><div className="result-badge fail">FAIL</div><p className="error">{error}</p><p className="error-action"><strong>What to do:</strong> {errorAction}</p>{errorTrace && <details open><summary>Diagnostic for Codex</summary><button onClick={() => navigator.clipboard.writeText(errorTrace)}>Copy diagnostic</button><pre>{errorTrace}</pre></details>}</div>}<div ref={conversationEndRef} aria-hidden="true" /></div>
    <div className="composer-wrap">{modelAccess}{busy && workProgress && <p role="status">Batch {workProgress.batch} saved · continuing the same task</p>}{heldWork && <div className="model-access" role="status"><p>Task paused: {heldWork.work?.progress || "Confirm the last batch before continuing."}</p><div><button type="button" onClick={() => void inspectHeldWork()}>Check progress</button>{heldWork.work?.state === "checkpointed" && <><button type="button" disabled={!models.includes(heldWork.item.model)} onClick={() => void run({...heldWork.item, credentialIdentity: credentialRef.current[heldWork.item.model] || ""}, heldWork.work!)}>Resume task</button><button type="button" disabled={!models.includes(heldWork.item.model)} onClick={() => void run({...heldWork.item, credentialIdentity: credentialRef.current[heldWork.item.model] || ""}, heldWork.work!, true)}>Restart from current files</button></>}<button type="button" onClick={() => void api(`/api/projects/${project.project_id}/chat/cancel`, {method: "POST"}).then(() => inspectHeldWork()).catch(error => setError(error.message))}>Cancel task</button></div></div>}{pendingQuestion && <p className="pending-question-hint">Your next message will answer: “{pendingQuestion.prompt}”</p>}{queue.length > 0 && <div className="prompt-queue" aria-label="Queued prompts"><strong>{queue.length} queued</strong>{queue.map((item, index) => <div key={item.id}><span>{index + 1}. [{item.model}] {item.text}</span><button onClick={() => setQueue(current => current.filter(queued => queued.id !== item.id))} aria-label={`Remove queued prompt ${index + 1}`}>Remove</button></div>)}</div>}<div className="attachment-controls"><input ref={attachmentInput} type="file" accept="image/png,image/jpeg,image/gif,image/svg+xml" multiple hidden aria-label="Choose image attachments" onChange={event => void attach(event.target.files)} /><button type="button" disabled={uploading || attachments.length >= 4} onClick={() => attachmentInput.current?.click()}>Attach image</button><span role="status">{uploading ? "Uploading image…" : "PNG, JPEG, GIF, SVG · 2 MiB each · up to 4"}</span></div>{attachmentError && <p className="error" role="alert">{attachmentError}</p>}{attachments.length > 0 && <div className="attachment-previews" aria-label="Attached images">{attachments.map(image => <div className="attachment-preview" key={image.artifact_id}><img src={"/api/projects/" + project.project_id + "/files/" + image.path} alt={"Attachment: " + image.name} /><span>{image.name}{image.frame === "first" ? " · first frame sent to model" : ""}</span><CopyImageReference reference={image.path} /><button type="button" aria-label={"Remove attachment " + image.name} onClick={() => setAttachments(current => current.filter(item => item.artifact_id !== image.artifact_id))}>Remove</button></div>)}</div>}<form className="composer" onSubmit={send}><textarea value={prompt} onChange={e => setPrompt(e.target.value)} placeholder={busy ? "Stack another prompt…" : "What are you trying to build?"} /><button disabled={(!prompt.trim() && attachments.length === 0) || !models.includes(model) || uploading}>Send</button><label className="model-picker">Model<select value={model} disabled={models.length === 0} onChange={event => setModel(event.target.value)} aria-label="Model for new prompts">{models.length === 0 && <option value="">{modelPlaceholder}</option>}{models.map(option => { const info = modelDetails.find(item => item.id === option); return <option key={option} value={option}>{info ? `${info.provider === "anthropic" ? "Anthropic" : "OpenAI"} · ${info.label}` : option}</option>; })}</select></label></form></div></section>;
}

function Book({project, workspaceRevision}: {project: Project; workspaceRevision: number}) {
  const [source, setSource] = useState(""), [status, setStatus] = useState("Loading book…"), [revision, setRevision] = useState(0), [dark, setDark] = useState(true);
  const [sourceRevision, setSourceRevision] = useState("");
  const [editorPercent, setEditorPercent] = useState(42), [previewOnly, setPreviewOnly] = useState(false);
  const workbenchRef = useRef<HTMLDivElement>(null), draggingRef = useRef(false);
  const resize = useCallback((event: PointerEvent) => {
    if (!draggingRef.current || !workbenchRef.current) return;
    const bounds = workbenchRef.current.getBoundingClientRect();
    setEditorPercent(Math.min(80, Math.max(15, ((event.clientX - bounds.left) / bounds.width) * 100)));
  }, []);
  const stopResize = useCallback(() => { draggingRef.current = false; document.body.classList.remove("resizing-book"); }, []);
  useEffect(() => {
    window.addEventListener("pointermove", resize);
    window.addEventListener("pointerup", stopResize);
    return () => { window.removeEventListener("pointermove", resize); window.removeEventListener("pointerup", stopResize); document.body.classList.remove("resizing-book"); };
  }, [resize, stopResize]);
  useEffect(() => { const controller = new AbortController(); api<{source: string; source_revision: string}>(`/api/projects/${project.project_id}/book`, {}, controller.signal).then(d => { setSource(d.source); setSourceRevision(d.source_revision); setStatus(project.read_only ? "Read-only book" : "book/main.tex · saved"); setRevision(Date.now()); }).catch(e => { if (e.name !== "AbortError") setStatus(e.message); }); return () => controller.abort(); }, [project.project_id, workspaceRevision]);
  async function save() { setStatus("Saving…"); const saved = await api<{source_revision: string}>(`/api/projects/${project.project_id}/book`, formRequest({source, source_revision: sourceRevision})); setSourceRevision(saved.source_revision); setStatus("Saved; PDF build required"); }
  async function build() { setStatus("Building PDFs…"); const saved = await api<{source_revision: string}>(`/api/projects/${project.project_id}/book`, formRequest({source, source_revision: sourceRevision})); setSourceRevision(saved.source_revision); await api(`/api/projects/${project.project_id}/book/build`, {method: "POST"}); setStatus("Book built successfully"); setRevision(Date.now()); }
  return <section className="pane book-pane"><header className="book-toolbar"><div><h1>Project book</h1><p>{status}</p></div><div>{!project.read_only && <><button onClick={save}>Save source</button><button className="primary" onClick={build}>Build &amp; preview</button></>}<button className={!dark ? "active" : ""} onClick={() => setDark(false)}>Light PDF</button><button className={dark ? "active" : ""} onClick={() => setDark(true)}>Dark PDF</button><button className={previewOnly ? "active" : ""} onClick={() => setPreviewOnly(value => !value)}>{previewOnly ? "Restore split" : "Maximize PDF"}</button></div></header>
    <div ref={workbenchRef} className={`book-workbench ${previewOnly ? "preview-only" : ""}`} style={!previewOnly ? {gridTemplateColumns: `minmax(240px, ${editorPercent}%) 8px minmax(320px, 1fr)`} : undefined}><textarea id="bookSource" value={source} onChange={e => setSource(e.target.value)} readOnly={project.read_only} spellCheck={false} /><div className="book-divider" role="separator" aria-label="Resize book source and PDF preview" aria-orientation="vertical" onPointerDown={event => { event.preventDefault(); draggingRef.current = true; document.body.classList.add("resizing-book"); }} /><iframe id="bookPreview" title="Project book PDF" src={`/api/projects/${project.project_id}/book/${dark ? "main-dark.pdf" : "main.pdf"}?revision=${revision}`} /></div></section>;
}

function GrammarNode({expr}: {expr: GrammarExpr}) {
  if (expr.kind === "event") return <div className="grammar-terminal message-node"><strong>{expr.message}</strong><span className="actors">{expr.src} → {expr.dst}</span></div>;
  if (expr.kind === "empty") return <div className="grammar-terminal">ε</div>;
  if (expr.kind === "ref") return <div className="grammar-terminal grammar-reference">↪ {expr.task}</div>;
  return <details className={`grammar-ast-node grammar-${expr.kind}`} open><summary>{expr.kind}{expr.predicate ? ` · ${expr.predicate}` : ""}</summary><div className="grammar-ast-children">{(expr.children || []).map((child, i) => <GrammarNode key={i} expr={child} />)}</div></details>;
}

function Specification({project, view, workspaceRevision}: {project: Project; view: "grammar" | "tasks"; workspaceRevision: number}) {
  const [tasks, setTasks] = useState<Task[]>([]), [selected, setSelected] = useState<string>(""), [kind, setKind] = useState("interaction"), [error, setError] = useState("");
  useEffect(() => { const controller = new AbortController(); api<{tasks: Task[]}>(`/api/projects/${project.project_id}/tasks`, {}, controller.signal).then(d => { setTasks(d.tasks || []); setSelected(current => d.tasks?.some(task => task.id === current) ? current : (d.tasks?.[0]?.id || "")); setError(""); }).catch(e => { if (e.name !== "AbortError") setError(e.message); }); return () => controller.abort(); }, [project.project_id, workspaceRevision]);
  const task = tasks.find(t => t.id === selected);
  if (error) return <div className="empty"><p className="error">{error}</p></div>;
  if (!tasks.length) return <div className="empty"><div><h2>No accepted project {view === "grammar" ? "grammar" : "tasks"} yet</h2><p>Use guided Chat to develop this project's book and requirements.</p></div></div>;
  if (view === "grammar") return <section className="pane grammar-pane"><header className="grammar-header"><h1>{project.display_name} grammar</h1></header><div className="grammar-workbench"><nav className="grammar-task-list">{tasks.map(t => <details key={t.id} open><summary onClick={() => setSelected(t.id)}>{t.id} ::=</summary>{t.grammar && <GrammarNode expr={t.grammar} />}</details>)}</nav><aside className="grammar-inspector"><h2>{task?.title}</h2><p>{task?.id}</p></aside></div></section>;
  return <section className="pane diagrams-pane"><header className="diagrams-header"><h1>Tasks</h1><div className="diagram-kind">{[["interaction","Productions · interaction"],["state","States · state machine"],["properties","Properties · CTL"],["constraints","where_ · CTL guards"]].map(([id,label]) => <button key={id} className={kind === id ? "active" : ""} onClick={() => setKind(id)}>{label}</button>)}</div></header><div className="diagrams-workbench"><nav className="diagram-task-list vertical-tabs">{tasks.map(t => <button key={t.id} className={`diagram-task ${selected === t.id ? "active" : ""}`} onClick={() => setSelected(t.id)}><strong>{t.title}</strong><span>{t.transitions.length} productions · {t.states.length} states</span></button>)}</nav><main className="diagram-stage"><h2>{task?.title}</h2>{task && (kind === "interaction" || kind === "state") && <Mermaid source={kind === "interaction" ? task.interaction_mermaid : task.state_mermaid} />}{task && kind === "properties" && task.properties.map(p => <article className="task-clause" key={p.name}><strong>{p.name}</strong><pre>{p.formula}</pre><small>{p.origin} · declared mode: {p.mode}</small></article>)}{task && kind === "constraints" && task.constraints.map(c => <article className="task-clause" key={c.id}><strong>where_ {c.id}</strong><pre>{c.formula}</pre><small>{c.origin}</small></article>)}</main></div></section>;
}

function Source({project, workspaceRevision, agentBusy}: {project: Project; workspaceRevision: number; agentBusy: boolean}) {
  const [files, setFiles] = useState<string[]>([]), [selected, setSelected] = useState(""), [source, setSource] = useState(""), [error, setError] = useState("");
  useEffect(() => {
    const controller = new AbortController();
    const refresh = () => api<{files: string[]}>(`/api/projects/${project.project_id}/source`, {}, controller.signal).then(result => {
      const next = result.files || [];
      setFiles(next); setSelected(current => current && next.includes(current) ? current : (next[0] || "")); setError("");
    }).catch(e => { if (e.name !== "AbortError") setFiles(current => { if (!current.length) setError(e.message); return current; }); });
    void refresh();
    const timer = agentBusy ? window.setInterval(refresh, 2000) : undefined;
    return () => { controller.abort(); if (timer !== undefined) window.clearInterval(timer); };
  }, [project.project_id, workspaceRevision, agentBusy]);
  useEffect(() => {
    if (!selected) return;
    const controller = new AbortController();
    const path = selected.split("/").map(encodeURIComponent).join("/");
    api<{source: string}>(`/api/projects/${project.project_id}/source/${path}`, {}, controller.signal).then(result => { setSource(result.source); setError(""); }).catch(e => { if (e.name !== "AbortError") { setSource(""); setError(e.message); } });
    return () => controller.abort();
  }, [project.project_id, selected]);
  if (error && !files.length) return <div className="empty"><p className="error">{error}</p></div>;
  if (!files.length) return <div className="empty"><div><h1>Source</h1><p>No implementation source exists yet. Ask for implementation after accepting both the requirements and implementation specification; LeanFM will ask focused blocking questions if those inputs are incomplete.</p></div></div>;
  return <section className="pane source-pane"><nav className="source-files vertical-tabs">{files.map(file => <button key={file} className={selected === file ? "active" : ""} onClick={() => setSelected(file)}>{file}</button>)}</nav><main className="source-view"><header><strong>{selected}</strong></header>{error ? <p className="error">{error}</p> : <pre><code>{source}</code></pre>}</main></section>;
}

function SpecificationAcceptance({project, workspaceRevision, agentBusy, compact = false, onAccepted}: {project: Project; workspaceRevision: number; agentBusy: boolean; compact?: boolean; onAccepted?: () => void}) {
  const [state, setState] = useState<SpecificationState | null>(null), [error, setError] = useState("");
  useEffect(() => {
    if (project.read_only) return;
    const controller = new AbortController();
    const refresh = () => api<SpecificationState>(`/api/projects/${project.project_id}/specification`, {}, controller.signal).then(value => { setState(value); setError(""); }).catch(error => { if (error.name !== "AbortError") setError(error.message); });
    void refresh();
    const timer = agentBusy ? window.setInterval(refresh, 2000) : undefined;
    return () => { controller.abort(); if (timer) window.clearInterval(timer); };
  }, [project.project_id, project.read_only, workspaceRevision, agentBusy]);
  async function accept(gate: "requirements" | "implementation") {
    if (!state) return;
    try { setError(""); setState(await api<SpecificationState>(`/api/projects/${project.project_id}/specification/${gate}/${state[gate].revision}/accept`, {method: "POST"})); onAccepted?.(); }
    catch (error) { setError((error as Error).message); }
  }
  if (project.read_only) return null;
  if (compact) {
    const gate = state?.requirements.checked && !state.requirements.accepted ? "requirements"
      : state?.requirements.accepted && state.implementation.checked && !state.implementation.accepted ? "implementation" : null;
    if (!gate && !error) return null;
    return <section className="specification-review" aria-label="Approval required">{gate && <article><strong>{gate === "requirements" ? "Requirements ready for approval" : "Implementation ready for approval"}</strong><span>The assistant handles reversible technical choices. Approve the current design when you are ready.</span><button type="button" disabled={agentBusy} onClick={() => void accept(gate)}>{gate === "requirements" ? "Approve requirements" : "Approve implementation"}</button></article>}{error && <p className="error" role="alert">{error}</p>}</section>;
  }
  return <section className="specification-review" aria-label="Specification acceptance">{(["requirements", "implementation"] as const).map(gate => <article key={gate}><strong>{gate === "requirements" ? "Requirements" : "Implementation specification"}</strong><span>{state?.[gate].accepted ? "Accepted current revision" : state?.[gate].checked ? "Checked · ready for your review" : "Needs a current canonical check"}</span><button type="button" disabled={!state?.[gate].checked || state[gate].accepted || agentBusy || (gate === "implementation" && !state.requirements.accepted)} onClick={() => void accept(gate)}>{gate === "requirements" ? "Accept requirements" : "Accept implementation specification"}</button></article>)}{error && <p className="error" role="alert">{error}</p>}</section>;
}

function ProjectMemoryView({project, workspaceRevision, agentBusy}: {project: Project; workspaceRevision: number; agentBusy: boolean}) {
  const [memory, setMemory] = useState<ProjectMemory | null>(null), [selected, setSelected] = useState("book"), [source, setSource] = useState(""), [error, setError] = useState("");
  useEffect(() => {
    const controller = new AbortController();
    const refresh = () => api<ProjectMemory>(`/api/projects/${project.project_id}/memory`, {}, controller.signal).then(result => { setMemory(result); setError(""); }).catch(e => { if (e.name !== "AbortError") setMemory(current => { if (!current) setError(e.message); return current; }); });
    void refresh();
    const timer = agentBusy ? window.setInterval(refresh, 2000) : undefined;
    return () => { controller.abort(); if (timer !== undefined) window.clearInterval(timer); };
  }, [project.project_id, workspaceRevision, agentBusy]);
  useEffect(() => {
    if (selected === "source-summary") { setSource(""); setError(""); return; }
    const controller = new AbortController();
    api<{source: string}>(`/api/projects/${project.project_id}/memory/${selected}`, {}, controller.signal).then(result => { setSource(result.source); setError(""); }).catch(e => { if (e.name !== "AbortError") { setSource(""); setError(e.message); } });
    return () => controller.abort();
  }, [project.project_id, selected, workspaceRevision]);
  const complete = (memory?.files.filter(file => file.status === "current").length || 0) + ((memory?.source_files || 0) > 0 ? 1 : 0);
  return <section className="pane memory-pane"><header className="memory-header"><div><h1>Project memory</h1><p>Durable state used to resume without conversation history.</p></div><strong>{complete} / 5 substantive layers</strong></header><SpecificationAcceptance project={project} workspaceRevision={workspaceRevision} agentBusy={agentBusy} /><div className="memory-workbench"><nav className="memory-files vertical-tabs">{memory?.files.map(file => <button key={file.id} className={selected === file.id ? "active" : ""} onClick={() => setSelected(file.id)}><span><strong>{file.label}</strong><small>{file.path}</small></span><em className={`memory-status ${file.status}`}>{file.status}</em></button>)}<button className="memory-source-summary" onClick={() => setSelected("source-summary")}><span><strong>Implementation source</strong><small>source/ · {memory?.source_files || 0} files · {memory?.source_bytes || 0} bytes</small></span><em className={`memory-status ${(memory?.source_files || 0) > 0 ? "current" : "missing"}`}>{(memory?.source_files || 0) > 0 ? "current" : "missing"}</em></button></nav><main className="source-view"><header><strong>{selected === "source-summary" ? "source/" : memory?.files.find(file => file.id === selected)?.path}</strong><span>Refreshes after every chat turn</span></header>{error ? <p className="error">{error}</p> : selected === "source-summary" ? <div className="memory-source-help"><h2>{memory?.source_files || 0} implementation files</h2><p>Open the Source phase to inspect generated implementation files. Source appears only after both acceptance gates and the security critique.</p></div> : <pre><code>{source}</code></pre>}</main></div></section>;
}

function ProjectWorkspace({project, authenticationRevision, session, onUnlockKeys, onLogout, loggingOut, logoutError, onRetryModels}: {project: Project; authenticationRevision: number; session: AccountSession; onUnlockKeys: () => void; onLogout: () => void; loggingOut: boolean; logoutError: string; onRetryModels: () => void}) {
  const [phase, setPhase] = useState<Phase>("chat");
  const {billing, availability: modelAvailability, error: modelError} = session;
  const [selectedModel, setSelectedModel] = useState("");
  const [workspaceRevision, setWorkspaceRevision] = useState(0);
  const [agentBusy, setAgentBusy] = useState(false);
  const [agentModel, setAgentModel] = useState(""), [agentSeconds, setAgentSeconds] = useState(0), [cancelRequested, setCancelRequested] = useState(false);
  const [agentStatus, setAgentStatus] = useState<{stage: string; detail: string; attempt: number} | null>(null);
  const [liveTrace, setLiveTrace] = useState<string[]>([]);
  useEffect(() => {
    if (!agentBusy) { setAgentSeconds(0); return; }
    const started = Date.now();
    const timer = window.setInterval(() => setAgentSeconds(Math.floor((Date.now() - started) / 1000)), 1000);
    return () => window.clearInterval(timer);
  }, [agentBusy]);
  useEffect(() => {
    if (!agentBusy) return;
    let current = true;
    const refresh = () => {
      api<{stage: string; detail: string; attempt: number}>(`/api/projects/${project.project_id}/chat/status`)
        .then(status => { if (current) setAgentStatus(status); }).catch(() => {});
      api<{entries: string[]}>(`/api/projects/${project.project_id}/chat/trace`)
        .then(trace => { if (current) setLiveTrace(trace.entries || []); }).catch(() => {});
    };
    void refresh();
    const timer = window.setInterval(refresh, 2000);
    return () => { current = false; window.clearInterval(timer); };
  }, [project.project_id, agentBusy]);
  const percentRemaining = billing?.token_budget ? Math.round(100 * billing.tokens_remaining / billing.token_budget) : 0;
  const selectedBilling = billing?.model_details?.find(info => info.id === (agentBusy ? agentModel : selectedModel));
  const agentElapsed = `${String(Math.floor(agentSeconds / 60)).padStart(2, "0")}:${String(agentSeconds % 60).padStart(2, "0")}`;
  const agentProgress = cancelRequested ? "Cancellation requested; waiting for the current safe boundary" : agentStatus?.detail || (agentSeconds >= 120 ? "Long-running model or tool work is still active" : agentSeconds >= 30 ? "Model or workspace tools are still working" : "Contacting the model");
  function agentState(busy: boolean, model?: string) { setAgentBusy(busy); if (busy) { setAgentModel(model || ""); setCancelRequested(false); setAgentStatus(null); setLiveTrace([]); } }
  async function cancelAgent() { window.dispatchEvent(new CustomEvent("leanfm:cancel-work", {detail: project.project_id})); setCancelRequested(true); try { await api(`/api/projects/${project.project_id}/chat/cancel`, {method: "POST"}); } catch { setCancelRequested(false); } }
  return <main className="main"><header className="topbar"><strong>{project.display_name}</strong><nav className="phase-tabs"><div className="phase-group"><span>Durable</span><button className={phase === "memory" ? "tab active" : "tab"} onClick={() => setPhase("memory")}>Project memory</button></div><div className="phase-group"><span>Discover</span><div><button className={phase === "chat" ? "tab active" : "tab"} onClick={() => setPhase("chat")}>Chat</button><button className={phase === "book" ? "tab active" : "tab"} onClick={() => setPhase("book")}>Book</button></div></div><div className="phase-group"><span>Specify</span><div><button className={phase === "grammar" ? "tab active" : "tab"} onClick={() => setPhase("grammar")}>Grammar</button><button className={phase === "tasks" ? "tab active" : "tab"} onClick={() => setPhase("tasks")}>Tasks</button></div></div><div className="phase-group"><span>Build</span><button className={phase === "source" ? "tab active" : "tab"} onClick={() => setPhase("source")}>Source</button></div></nav>{billing && <div className={`billing-meter ${percentRemaining <= 10 ? "danger" : percentRemaining <= 25 ? "warn" : ""}`} title="This is a local token safety budget across providers, not a provider dollar balance. Provider spend limits remain authoritative."><strong>{selectedBilling?.provider || billing.provider} · key {selectedBilling?.key_fingerprint || billing.key_fingerprint}</strong><span>{selectedBilling?.label || billing.model}</span><span>{billing.tokens_used.toLocaleString()} used · {billing.tokens_remaining.toLocaleString()} remaining</span><small>Local session limit; enforce provider spend caps</small></div>}<div className="session-controls" aria-label="Account session"><span>{session.username || "Signed out"}</span><button type="button" onClick={onUnlockKeys}>{session.username ? "API keys" : "Sign in"}</button><button type="button" onClick={onLogout} disabled={loggingOut}>{loggingOut ? "Logging out…" : "Log out"}</button></div></header>
    {logoutError && <p className="error" role="alert">{logoutError}</p>}
    {billing?.model_warnings?.map(warning => <p className="error" role="status" key={warning}>{warning}</p>)}
    {agentBusy && <div className="workspace-agent-progress"><div className="workspace-agent-running" role="status"><span className="agent-running-dot" /><span><strong>Agent running · {agentModel}</strong><small>{agentProgress}. You can inspect any project or phase while it runs.</small></span><time>{agentElapsed}</time><button type="button" onClick={cancelAgent} disabled={cancelRequested}>{cancelRequested ? "Cancel requested…" : "Cancel"}</button></div>{liveTrace.length > 0 && <details className={`live-operational-trace ${liveTrace.some(entry => entry.includes("rejected:") || entry.startsWith("Failed check:")) ? "has-error" : ""}`}><summary>Operational trace · {liveTrace.length} event{liveTrace.length === 1 ? "" : "s"} · latest: {liveTrace[liveTrace.length - 1]}</summary><pre>{liveTrace.map(entry => `- ${entry}`).join("\n")}</pre></details>}</div>}
    {phase === "chat" && <SpecificationAcceptance project={project} workspaceRevision={workspaceRevision} agentBusy={agentBusy} compact onAccepted={() => setWorkspaceRevision(value => value + 1)} />}
    <div className="phase-panel" hidden={phase !== "chat"}><Chat project={project} modelAvailability={modelAvailability} modelError={modelError} onUnlockKeys={onUnlockKeys} onRetryModels={onRetryModels} credentialIdentity={`${authenticationRevision}:${session.username || "locked"}`} models={billing?.models || []} modelDetails={billing?.model_details || []} defaultModel={billing?.model || ""} onModelChange={setSelectedModel} onWorkspaceChange={() => setWorkspaceRevision(value => value + 1)} onBusyChange={agentState} /></div>
    <div className="phase-panel" hidden={phase !== "memory"}><ProjectMemoryView project={project} workspaceRevision={workspaceRevision} agentBusy={agentBusy} /></div>
    <div className="phase-panel" hidden={phase !== "book"}><Book project={project} workspaceRevision={workspaceRevision} /></div>
    <div className="phase-panel" hidden={phase !== "grammar"}><Specification project={project} view="grammar" workspaceRevision={workspaceRevision} /></div>
    <div className="phase-panel" hidden={phase !== "tasks"}><Specification project={project} view="tasks" workspaceRevision={workspaceRevision} /></div>
    <div className="phase-panel" hidden={phase !== "source"}><Source project={project} workspaceRevision={workspaceRevision} agentBusy={agentBusy} /></div>
  </main>;
}

function App() {
  const [session, setSession] = useState<AccountSession>({...lockedSession, availability: "loading"});
  const [checkingSession, setCheckingSession] = useState(true), [projects, setProjects] = useState<Project[]>([]), [selected, setSelected] = useState<string | null>(null), [authVersion, setAuthVersion] = useState(0), [newName, setNewName] = useState("");
  const [showKeys, setShowKeys] = useState(false), [loggingOut, setLoggingOut] = useState(false), [logoutError, setLogoutError] = useState("");
  const [pollSession, setPollSession] = useState(true), [modelRefreshRevision, setModelRefreshRevision] = useState(0);
  const sessionGeneration = useRef(0);
  const logoutInFlight = useRef(false);
  const user = session.username;
  const [fontScale, setFontScale] = useState(() => {
    const stored = Number(window.localStorage.getItem("leanfm:font-scale") || "1");
    return Number.isFinite(stored) ? Math.max(.8, stored) : 1;
  });
  useEffect(() => {
    document.documentElement.style.setProperty("--font-scale", String(fontScale));
    window.localStorage.setItem("leanfm:font-scale", String(fontScale));
  }, [fontScale]);
  useEffect(() => { setClientDiagnosticProject(selected); }, [selected]);
  async function load() {
    const data = await api<{projects: Project[]}>("/api/projects");
    setProjects(data.projects || []);
    setSelected(current => data.projects.some(p => p.project_id === current) ? current : data.projects.find(p => !p.read_only)?.project_id || null);
  }
  useEffect(() => { load().catch(() => {}).finally(() => setCheckingSession(false)); }, []);
  // One session snapshot drives the account controls and every project's model
  // picker. Old requests cannot restore keys after an explicit local lock.
  // Requirement refs: one_password_unlocks_all_provider_keys,
  // model_key_is_request_scoped, keyless_server_has_no_provider_spend.
  useEffect(() => {
    if (!pollSession) return;
    let current = true, refreshing = false;
    const generation = sessionGeneration.current, controller = new AbortController();
    async function refresh() {
      if (refreshing) return;
      refreshing = true;
      try {
        const result = await api<{username: string; billing: Billing | null}>("/api/me", {}, controller.signal);
        if (current && generation === sessionGeneration.current) setSession(result.billing
          ? {availability: "ready", username: result.username, billing: result.billing, error: ""}
          : lockedSession);
      } catch (error) {
        if (current && generation === sessionGeneration.current && !controller.signal.aborted) setSession(
          error instanceof ApiError && error.status === 401 ? lockedSession
          : {...lockedSession, availability: "error", error: (error as Error).message});
      } finally { refreshing = false; }
    }
    void refresh();
    const timer = window.setInterval(refresh, 3000);
    return () => { current = false; controller.abort(); window.clearInterval(timer); };
  }, [authVersion, modelRefreshRevision, pollSession]);
  const lockLocalSession = useCallback(() => {
    sessionGeneration.current += 1;
    setSession(lockedSession); setPollSession(false); setAuthVersion(value => value + 1);
  }, []);
  useEffect(() => {
    window.addEventListener("leanfm:authentication-required", lockLocalSession);
    return () => window.removeEventListener("leanfm:authentication-required", lockLocalSession);
  }, [lockLocalSession]);
  function signedIn(sessionPreserved = false) {
    if (sessionPreserved) {
      setShowKeys(false); setLogoutError(""); setPollSession(true);
      setModelRefreshRevision(value => value + 1);
      return;
    }
    sessionGeneration.current += 1;
    setSession({...lockedSession, availability: "loading"}); setLogoutError("");
    setShowKeys(false); setPollSession(true); setAuthVersion(value => value + 1);
  }
  function retryModels() {
    sessionGeneration.current += 1;
    setSession({...lockedSession, availability: "loading"}); setPollSession(true);
    setModelRefreshRevision(value => value + 1);
  }
  async function logOut() {
    if (logoutInFlight.current) return;
    logoutInFlight.current = true;
    setLoggingOut(true); setLogoutError(""); lockLocalSession();
    try {
      try { await api("/api/logout", {method: "POST"}); }
      catch (error) {
        if (!(error instanceof ApiError && error.status === 401)) throw error;
        // An expired or missing session is already locked on the server.
      }
      setShowKeys(true);
    } catch (error) {
      setLogoutError(`Could not confirm server logout. Retry Log out. ${(error as Error).message}`);
    } finally { logoutInFlight.current = false; setLoggingOut(false); }
  }
  if (checkingSession) return <main className="auth"><div className="auth-card"><h1>LeanFM</h1><p>Loading workspace…</p></div></main>;
  const project = projects.find(p => p.project_id === selected);
  async function create(event: FormEvent) { event.preventDefault(); const result = await api<{project_id: string}>("/api/projects", formRequest({display_name: newName})); setNewName(""); await load(); setSelected(result.project_id); }
  async function remove(item: Project) { const confirmation = prompt(`Type ${item.display_name} to permanently delete it:`); if (confirmation === null) return; await api(`/api/projects/${item.project_id}`, {method: "DELETE", headers: {"Content-Type":"application/x-www-form-urlencoded"}, body: new URLSearchParams({confirmation}).toString()}); if (selected === item.project_id) setSelected(null); await load(); }
  return <div className="app"><aside className="sidebar">
    <div className="brand">LeanFM</div>
    <form onSubmit={create}><input value={newName} onChange={e => setNewName(e.target.value)} placeholder="New project name" required /><button className="new-project">＋ Add project</button></form>
    <div className="tab-set-label">Projects</div>
    <div className="projects vertical-tabs">{projects.map(item => <div className="project-row" key={item.project_id}><button className={`project ${selected === item.project_id ? "active" : ""}`} onClick={() => setSelected(item.project_id)}>{item.display_name}{item.read_only && <span className="project-kind">read-only</span>}</button>{!item.read_only && <button className="project-delete" onClick={() => remove(item)}>Delete</button>}</div>)}</div>
    <div className="sidebar-footer">
      <button type="button" onClick={() => setShowKeys(true)}>{user ? "API keys" : "Sign in"}</button>
      <button type="button" onClick={() => void logOut()} disabled={loggingOut}>{loggingOut ? "Logging out…" : "Log out"}</button>
      {logoutError && <p className="error" role="alert">{logoutError}</p>}
      <div className="font-controls" aria-label="Font zoom"><button type="button" aria-label="Decrease font size" disabled={fontScale <= .8} onClick={() => setFontScale(value => Math.max(.8, Number((value - .1).toFixed(1))))}>−</button><output aria-live="polite">{Math.round(fontScale * 100)}%</output><button type="button" aria-label="Increase font size" onClick={() => setFontScale(value => Number((value + .1).toFixed(1)))}>＋</button></div>
      <span>{user || "Keys locked"}</span>
    </div>
  </aside>
    {projects.map(item => <div className="project-panel" hidden={selected !== item.project_id} key={item.project_id}><ProjectWorkspace project={item} authenticationRevision={authVersion} session={session} onUnlockKeys={() => setShowKeys(true)} onLogout={() => void logOut()} loggingOut={loggingOut} logoutError={logoutError} onRetryModels={retryModels} /></div>)}
    {!project && <main className="main"><div className="session-controls"><button type="button" onClick={() => setShowKeys(true)}>Sign in</button><button type="button" onClick={() => void logOut()} disabled={loggingOut}>Log out</button></div><div className="empty"><h2>Create or select a project</h2></div></main>}
    {showKeys && <ProviderKeysDialog account={user || ""} onClose={() => setShowKeys(false)} onDone={signedIn} onLogout={() => void logOut()} loggingOut={loggingOut} />}
  </div>;
}

createRoot(document.getElementById("root")!).render(<ClientFaultBarrier><App /></ClientFaultBarrier>);
