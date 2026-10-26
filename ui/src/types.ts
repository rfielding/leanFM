export type Project = {project_id: string; display_name: string; read_only: boolean; kind?: string};
export type Usage = {input_tokens: number; cached_input_tokens: number; output_tokens: number; total_tokens: number; context_window_tokens: number};
export type Message = {message_id: string; role: "user" | "assistant"; text: string; model?: string; sent_at_ms?: number; response_time_ms?: number; usage?: Usage};
export type ModelOption = {id: string; model: string; label: string; provider: string; credential_ref: string; key_fingerprint: string; context_window_tokens: number};
export type Billing = {provider: string; credential_ref: string; key_fingerprint: string; model: string; models: string[]; model_details: ModelOption[]; model_warnings: string[]; tokens_used: number; token_budget: number; tokens_remaining: number};
export type ProjectMemoryFile = {id: string; path: string; label: string; stage: string; bytes: number; status: "missing" | "bootstrap" | "current"};
export type ProjectMemory = {files: ProjectMemoryFile[]; source_files: number; source_bytes: number};
export type SpecificationState = {requirements: {revision: string; checked: boolean; committed: boolean | null}; implementation: {revision: string; checked: boolean; committed: boolean | null}; ready: boolean; blocker: string; git?: {repository: boolean; uncommitted: string[]}};
export type GrammarExpr = {kind: string; message?: string; task?: string; src?: string; dst?: string; predicate?: string; required?: number; children?: GrammarExpr[]};
export type Task = {
  id: string; title: string; entry: string; terminals: string[]; actors: string[];
  states: Array<{name: string; description: string}>;
  transitions: Array<{message: string; source: string; target: string; source_actor: string; destination_actor: string}>;
  properties: Array<{mode: string; name: string; expression: string; formula: string; origin: string}>;
  constraints: Array<{id: string; predicate: string; formula: string; origin: string}>; grammar: GrammarExpr | null; interaction_mermaid: string; state_mermaid: string;
};
