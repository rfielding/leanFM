// Requirement refs: property:Browser navigation reflects server state;
// proof:Browser never fabricates destinations or crosses scopes.
// The session lives in sessionStorage (one per browser tab, like a separate person).

export const storage: {getItem(k: string): string | null; setItem(k: string, v: string): void} = (() => {
  try { const s = window.sessionStorage; void s.length; return s; }
  catch { const m = new Map<string, string>(); return {getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v)}; }
})();

export const auth = {
  session: storage.getItem('goserver:session') || '',
  identity: storage.getItem('goserver:identity') || '',
};

const messages: Record<string, string> = {
  unauthorized: 'Your session ended because the app restarted.', invalid_name: 'Use a name between 1 and 128 characters.',
  room_exists: 'That room already exists. Open it from the room list.', invalid_body: 'Write a message between 1 and 4,000 characters.',
  busy: 'The local demo has reached its room, challenge or session action limit.', forbidden: 'Enter the room or challenge before using it.',
  request_id_conflict: 'This action conflicts with a previous request. Refresh and try again.', not_open: 'That can only change before the game starts.',
  not_seated: 'Take a seat first.', seat_occupied: 'A person holds that seat; they must leave it first.', invalid_seat_plan: 'Choose a listed controller and team.',
  invalid_bot_settings: 'Choose listed bot settings.', invalid_team: 'Choose another existing team.', no_person_on_team: 'That team has no person to accept a merge.',
  duplicate_proposal: 'Those teams already have a pending proposal.', no_proposal: 'That proposal is no longer pending.', not_on_team: 'Only people on the two teams can answer.',
  deadline_passed: 'Your time ran out before the move arrived.', already_seated: 'You already have a seat in this game.', seat_unavailable: 'That seat is taken.',
  not_creator: 'Only the challenge creator can start the game.', not_playing: 'This game is not in progress.', not_your_turn: 'It is not your turn.',
  stale_move: 'The board changed; your move was not played. Look again.', occupied: 'That point is occupied.', ko: 'Ko: that recapture must wait a round.',
  superko: 'Superko: that move recreates an earlier position.', illegal_move: 'That move is not on the board.', invalid_board: 'Choose a listed board size.',
  invalid_seats: 'Choose 2 to 8 players.', invalid_deadline: 'Choose a listed deadline.', invalid_bot_time: 'Choose a listed bot deadline.', invalid_ko_rule: 'Choose a listed ko rule.',
};

let counter = Date.now() * 1000;
export const nextID = () => ++counter;

// The server keeps sessions in memory, so a restart forgets them. Drop the stale session,
// keep the name, and show the name form again (prefilled) instead of a dead page.
export function sessionLost() {
  storage.setItem('goserver:session', '');
  storage.setItem('goserver:lastName', auth.identity);
  storage.setItem('goserver:notice', 'The app restarted, so your session ended. Press Enter GoServer to continue.');
  auth.session = '';
  location.reload();
}

export async function api(action: string, payload: Record<string, unknown> = {}): Promise<any> {
  const response = await fetch('./api/' + action, {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({sessionId: auth.session, ...payload})});
  const result = await response.json();
  if (result.code === 'unauthorized' && auth.session) sessionLost();
  if (!response.ok || result.code || result.error) throw new Error(messages[result.code] || result.error || 'The action could not be completed.');
  return result;
}

export async function issueSession(identity: string) {
  const response = await fetch('./api/issue_session', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({identity})});
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || 'Could not start a session.');
  auth.session = result.session; auth.identity = identity;
  storage.setItem('goserver:session', auth.session); storage.setItem('goserver:identity', identity);
}

// A tiny shared notice line ("feedback") any component can write to.
type Listener = (m: {text: string; error: boolean}) => void;
const listeners = new Set<Listener>();
export function feedback(text = '', error = false) { listeners.forEach(l => l({text, error})); }
export function onFeedback(l: Listener) { listeners.add(l); return () => void listeners.delete(l); }
