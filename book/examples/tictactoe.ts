// TicTacToe, implementing examples/sessions/TicTacToe.leanfm: X is the person, O plays at random
// (seeded, so a run can be replayed), and the Referee writes every protocol message as an event.
type Mark = "X" | "O" | null;
type Ev = { id: string; session: string; from: string; to: string; label: string; cause?: string };

const LINES = [[0,1,2],[3,4,5],[6,7,8],[0,3,6],[1,4,7],[2,5,8],[0,4,8],[2,4,6]];
let cells: Mark[] = [], events: Ev[] = [], n = 0, game = 0, over = false, seed = 7;

function random(): number { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; }

function winner(c: Mark[]): string | null {
  for (const [a, b, d] of LINES) if (c[a] && c[a] === c[b] && c[a] === c[d]) return c[a];
  return c.every((x) => x) ? "draw" : null;
}

function log(label: string, from: string, to: string, cause?: string, id?: string): string {
  const e: Ev = { id: id || "e" + (++n), session: "g" + game, from, to, label };
  if (cause) e.cause = cause;
  events.push(e);
  return e.id;
}

function result(cause: string, w: string): string {
  log("Result", "Referee", "X", cause); log("Result", "Referee", "O", cause); over = true;
  return w === "draw" ? "Draw" : w + " wins";
}

function start(): void {
  game++; cells = Array(9).fill(null); events = []; n = 0; over = false;
  log("Joined", "Referee", "O", log("NewGame", "X", "Referee", undefined, "g"));
}

function moveX(i: number): string {
  if (over || cells[i]) return "";
  cells[i] = "X"; const x = log("MoveX", "X", "Referee");
  const w = winner(cells); if (w) return result(x, w);
  log("OTurn", "Referee", "O", x);
  const free = cells.map((v, k) => (v ? -1 : k)).filter((k) => k >= 0);
  cells[free[Math.floor(random() * free.length)]] = "O";
  const o = log("MoveO", "O", "Referee");
  const w2 = winner(cells); if (w2) return result(o, w2);
  log("XTurn", "Referee", "X", o);
  return "Your move, X";
}
