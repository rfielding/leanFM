export type RequestTrace = {
  request_id: string;
  started_at: string;
  finished_at: string;
  elapsed_ms: number;
  method: string;
  path: string;
  status: number;
  browser_online: boolean;
  error: string;
  action: string;
  code: string;
  response_excerpt?: string;
};

export class ApiError extends Error {
  constructor(message: string, public readonly status: number, public readonly action: string, public readonly trace: RequestTrace) {
    super(message);
    this.name = "ApiError";
  }
}

let diagnosticProjectId = "";
let reportsThisMinute = 0;
let reportWindowStarted = Date.now();
let reportingDiagnostic = false;

export function setClientDiagnosticProject(projectId: string | null) {
  diagnosticProjectId = projectId || "";
}

function projectFromPath(path: string): string {
  return path.match(/^\/api\/projects\/([^/]+)/)?.[1] || diagnosticProjectId;
}

function safeStack(stack: string): string {
  return stack.replace(/(https?:\/\/[^\s?#]+)[?#][^\s)]+/g, "$1?[redacted]").slice(0, 12000);
}

export function reportClientError(description: string, cause: unknown, projectId = diagnosticProjectId): void {
  if (cause instanceof DOMException && cause.name === "AbortError") return;
  const now = Date.now();
  if (now - reportWindowStarted >= 60000) { reportWindowStarted = now; reportsThisMinute = 0; }
  if (reportingDiagnostic || reportsThisMinute >= 20) return;
  reportsThisMinute += 1;
  const error = cause instanceof Error ? cause : new Error(String(cause));
  const body = new URLSearchParams({
    project_id: projectId,
    description: description.slice(0, 1000),
    error_name: error.name.slice(0, 200),
    message: error.message.slice(0, 4000),
    stack: safeStack(error.stack || "Stack unavailable"),
    page: `${location.pathname}${location.hash}`.slice(0, 1000),
    occurred_at: new Date().toISOString()
  });
  reportingDiagnostic = true;
  fetch("/api/client-errors", {method: "POST", credentials: "same-origin", headers: {"Content-Type": "application/x-www-form-urlencoded"}, body})
    .catch(() => {})
    .finally(() => { reportingDiagnostic = false; });
}

window.addEventListener("error", event => {
  const location = event.filename ? ` at ${event.filename.split(/[?#]/)[0]}:${event.lineno}:${event.colno}` : "";
  reportClientError(`Unhandled JavaScript exception while rendering or handling a browser event${location}`, event.error || new Error(event.message));
});

window.addEventListener("unhandledrejection", event => {
  reportClientError("Unhandled promise rejection while running a browser operation", event.reason);
});

export async function api<T>(path: string, options: RequestInit = {}, signal?: AbortSignal): Promise<T> {
  const requestId = globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const startedAt = new Date(), started = performance.now(), method = options.method || "GET";
  let response: Response;
  try {
    response = await fetch(path, {credentials: "same-origin", ...options, signal, headers: {Accept: "application/json", "X-LeanFM-Request-ID": requestId, ...(options.headers || {})}});
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause);
    const action = navigator.onLine ? "Verify that the LeanFM server is running and reachable, then retry once. If it still fails, copy this diagnostic to Codex." : "Reconnect this device to the network, then retry.";
    const error = new ApiError(`Network request failed: ${message}`, 0, action, {request_id: requestId, started_at: startedAt.toISOString(), finished_at: new Date().toISOString(), elapsed_ms: Math.round(performance.now() - started), method, path, status: 0, browser_online: navigator.onLine, error: message, action, code: "leanfm_network_error"});
    reportClientError(`Calling LeanFM API: ${method} ${path}`, error, projectFromPath(path));
    throw error;
  }
  const text = await response.text();
  let body: any;
  try { body = JSON.parse(text); } catch { body = {error: text.trim() || `HTTP ${response.status}`}; }
  if (!response.ok) {
    if (response.status === 401 && path !== "/api/me") window.dispatchEvent(new Event("leanfm:authentication-required"));
    const message = body.error || `HTTP ${response.status}: ${response.statusText || "Request failed"}`;
    const action = body.action || (response.status >= 500 ? "Retry once. If it fails again, copy this diagnostic to Codex; also check or restart the LeanFM server." : "Correct the request if possible, then retry. If the failure is unclear, copy this diagnostic to Codex.");
    const code = body.code || `unexpected_http_${response.status}`;
    const error = new ApiError(message, response.status, action, {request_id: requestId, started_at: startedAt.toISOString(), finished_at: new Date().toISOString(), elapsed_ms: Math.round(performance.now() - started), method, path, status: response.status, browser_online: navigator.onLine, error: message, action, code, response_excerpt: text.slice(0, 4000)});
    reportClientError(`Calling LeanFM API: ${method} ${path}`, error, projectFromPath(path));
    throw error;
  }
  return body as T;
}

export const formRequest = (values: Record<string, string>): RequestInit => ({
  method: "POST",
  headers: {"Content-Type": "application/x-www-form-urlencoded"},
  body: new URLSearchParams(values).toString()
});
