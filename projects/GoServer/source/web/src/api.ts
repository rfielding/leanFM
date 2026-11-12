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
  claimed: storage.getItem('goserver:claimed') === '1',
};

const messages: Record<string, string> = {
  unauthorized: 'Your session ended because the app restarted.', invalid_name: 'Use a name between 1 and 128 characters.',
  room_exists: 'That room already exists. Open it from the room list.', invalid_body: 'Write a message between 1 and 4,000 characters.',
  busy: 'The local demo has reached its room, challenge or session action limit.', forbidden: 'Enter the room or challenge before using it.',
  request_id_conflict: 'This action conflicts with a previous request. Refresh and try again.', not_open: 'That can only change before the game starts.',
  not_seated: 'Take a seat first.', seat_occupied: 'A person holds that seat; they must leave it first.', invalid_seat_plan: 'Choose a listed controller and team.',
  invalid_bot_settings: 'Choose listed bot settings.', invalid_team: 'Choose another existing team.', no_person_on_team: 'That team has no person to accept a merge.',
  duplicate_proposal: 'Those teams already have a pending proposal.', no_proposal: 'That proposal is no longer pending.', not_on_team: 'Only people on the two teams can answer.',
  deadline_passed: 'Your clock ran out before the move arrived.', already_seated: 'You already have a seat in this game.', seat_unavailable: 'That seat is taken.',
  not_creator: 'Only the challenge creator can start the game.', not_playing: 'This game is not in progress.', not_your_turn: 'It is not your turn.',
  stale_move: 'The board changed; your move was not played. Look again.', occupied: 'That point is occupied.', ko: 'Ko: that recapture must wait a round.',
  superko: 'Superko: that move recreates an earlier position.', illegal_move: 'That move is not on the board.', invalid_board: 'Choose a listed board size.',
  invalid_password: 'Use a password of 8 to 128 characters.', already_claimed: 'That name is already claimed.',
  name_in_use: 'Someone is signed in with that name as a guest. It can be claimed once they sign out.',
  wrong_password: 'Wrong password.', throttled: 'Too many wrong passwords for this name; try again later.',
  not_claimed: 'That name is not claimed.', too_soon: 'The password was changed less than a minute ago; wait a moment.',
  capacity: 'The server holds its maximum number of claimed names.', unavailable: 'The claim could not be saved. Try again later.',
  invalid_seats: 'Choose 2 to 8 players.', invalid_clock: 'Choose a listed main time, number of periods and period length.', invalid_ko_rule: 'Choose a listed ko rule.',
};

let counter = Date.now() * 1000;
export const nextID = () => ++counter;

// The server keeps sessions in memory, so a restart forgets them. Drop the stale session,
// keep the name, and show the name form again (prefilled) instead of a dead page.
export function sessionLost() {
  storage.setItem('goserver:session', '');
  storage.setItem('goserver:lastName', auth.identity);
  storage.setItem('goserver:notice', auth.claimed ? 'Your session ended (the app restarted, or you signed in elsewhere). Enter your password to continue.' : 'The app restarted, so your session ended. Press Enter GoServer to continue.');
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

// The password goes only to issue_session and is never stored; a claimed name's
// spelling comes back from the server (claims ignore letter case).
export async function issueSession(identity: string, password = '') {
  const body: Record<string, string> = {identity};
  if (password) body.password = password;
  const response = await fetch('./api/issue_session', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)});
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || 'Could not start a session.');
  signedIn(result.session, result.identity || identity, !!result.claimed);
}

function signedIn(session: string, identity: string, claimed: boolean) {
  auth.session = session; auth.identity = identity; auth.claimed = claimed;
  storage.setItem('goserver:session', session); storage.setItem('goserver:identity', identity);
  storage.setItem('goserver:claimed', claimed ? '1' : '');
}

// These run from the sign-in form, before there is a session; each password is sent once
// and never kept.
async function post(action: string, body: Record<string, unknown>) {
  const response = await fetch('./api/' + action, {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({...body, requestId: nextID()})});
  const result = await response.json();
  if (!response.ok || result.code || result.error) throw new Error(messages[result.code] || result.error || 'The action could not be completed.');
  return result;
}
export async function claimName(identity: string, password: string) {
  const r = await post('claim_name', {identity, password}); signedIn(r.session, r.identity, true);
}
export async function changePassword(identity: string, password: string, newPassword: string) {
  const r = await post('change_password', {identity, password, newPassword}); signedIn(r.session, r.identity, true);
}
export async function releaseName(identity: string, password: string) {
  await post('release_name', {identity, password});
}
export async function signOut() {
  try { await post('sign_out', {sessionId: auth.session}); } catch { /* the session may already be gone */ }
  storage.setItem('goserver:session', ''); storage.setItem('goserver:lastName', auth.identity);
  storage.setItem('goserver:notice', 'Signed out. Enter a name to continue.');
  auth.session = ''; location.reload();
}

// A tiny shared notice line ("feedback") any component can write to.
type Listener = (m: {text: string; error: boolean}) => void;
const listeners = new Set<Listener>();
export function feedback(text = '', error = false) { listeners.forEach(l => l({text, error})); }
export function onFeedback(l: Listener) { listeners.add(l); return () => void listeners.delete(l); }
