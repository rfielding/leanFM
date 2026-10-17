export type Project = {project_id: string; display_name: string; read_only: boolean; kind?: string};
export type Usage = {input_tokens: number; cached_input_tokens: number; output_tokens: number; total_tokens: number; context_window_tokens: number};
export type Message = {message_id: string; role: "user" | "assistant"; text: string; response_time_ms?: number; usage?: Usage};
export type GrammarExpr = {kind: string; message?: string; task?: string; src?: string; dst?: string; predicate?: string; required?: number; children?: GrammarExpr[]};
export type Task = {
  id: string; title: string; entry: string; terminals: string[]; actors: string[];
  states: Array<{name: string; description: string}>;
  transitions: Array<{message: string; source: string; target: string; source_actor: string; destination_actor: string}>;
  properties: Array<{mode: string; name: string; expression: string}>;
  constraints: string[]; grammar: GrammarExpr | null; interaction_mermaid: string; state_mermaid: string;
};
