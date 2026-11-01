// Requirement refs: property:Browser navigation reflects server state;
// proof:Browser never fabricates destinations or crosses scopes;
// grammar:take_seat, grammar:start_game, grammar:play_move, grammar:game_state.
'use strict';
const $ = id => document.getElementById(id);
const storage = (() => { try { const store = window.sessionStorage; store.length; return store; } catch { const values = new Map(); return {getItem:key=>values.get(key)||null, setItem:(key,value)=>values.set(key,value)}; } })();
let session = storage.getItem('goserver:session') || '';
let identity = storage.getItem('goserver:identity') || '';
let roomID = '', gameID = '', roomReady = false, gameReady = false;
let roomEpoch = 0, gameEpoch = 0, sessionEpoch = 0, requestCounter = Date.now() * 1000;
let roomItems = '[]', gameItems = '[]';
const messages = {unauthorized:'Your session ended because the app restarted.', invalid_name:'Use a name between 1 and 128 characters.', room_exists:'That room already exists. Select it from the room list.', invalid_body:'Write a message between 1 and 4,000 characters.', busy:'The local demo has reached its room, challenge or session action limit.', forbidden:'Enter the selected room or challenge before using it.', request_id_conflict:'This action conflicts with a previous request. Refresh and try again.', not_open:'That can only change before the game starts.', not_seated:'Take a seat first.', seat_occupied:'A person holds that seat; they must leave it first.', invalid_seat_plan:'Choose a listed controller and team.', invalid_bot_settings:'Choose listed bot settings.', invalid_team:'Choose another existing team.', no_person_on_team:'That team has no person to accept a merge.', duplicate_proposal:'Those teams already have a pending proposal.', no_proposal:'That proposal is no longer pending.', not_on_team:'Only people on the two teams can answer.', deadline_passed:'Your time ran out before the move arrived.', already_seated:'You already have a seat in this game.', seat_unavailable:'That seat is taken.', not_creator:'Only the challenge creator can start the game.', not_playing:'This game is not in progress.', not_your_turn:'It is not your turn.', stale_move:'The board changed; your move was not played. Look again.', occupied:'That point is occupied.', ko:'Ko: that recapture must wait a round.', superko:'Superko: that move recreates an earlier position.', illegal_move:'That move is not on the board.', invalid_board:'Choose a listed board size.', invalid_seats:'Choose 2 to 8 players.', invalid_deadline:'Choose a listed deadline.', invalid_bot_time:'Choose a listed bot deadline.', invalid_ko_rule:'Choose a listed ko rule.'};
function feedback(message = '', error = false) { $('feedback').textContent = message; $('feedback').className = error ? 'error' : ''; }
function empty(node, message) { node.replaceChildren(); const p = document.createElement(node.tagName === 'OL' ? 'li' : 'p'); p.className = 'empty'; p.textContent = message; node.append(p); }
async function api(action, payload = {}) {
  const response = await fetch('./api/' + action, {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({sessionId:session, ...payload})});
  const result = await response.json();
  if (result.code === 'unauthorized' && session) sessionLost();
  if (!response.ok || result.code || result.error) throw new Error(messages[result.code] || result.error || 'The action could not be completed.');
  return result;
}
const nextID = () => ++requestCounter;
// The server keeps sessions in memory, so a restart forgets them. Drop the stale session,
// keep the name, and show the name form again (prefilled) instead of a dead page.
function sessionLost() {
  storage.setItem('goserver:session', ''); storage.setItem('goserver:lastName', identity);
  storage.setItem('goserver:notice', 'The app restarted, so your session ended. Press Enter GoServer to continue.');
  session = ''; location.reload();
}
function signedIn() { $('welcome').hidden = !!session; $('identity-label').textContent = session ? identity : 'Choose a local name to join'; $('room-fields').disabled = !session; $('refresh-rooms').disabled = !session; }
function selectStyles() { document.querySelectorAll('.room-button').forEach(button => { const selected = button.dataset.room === roomID; button.classList.toggle('active', selected); button.setAttribute('aria-current', selected ? 'true' : 'false'); }); }
async function loadRooms() {
  const stamp = sessionEpoch;
  const result = await api('list_rooms', {requestId:nextID()});
  if (stamp !== sessionEpoch) return;
  const list = $('room-list'); list.replaceChildren();
  for (const id of result.roomIds || []) { const button = document.createElement('button'); button.type = 'button'; button.className = 'room-button'; button.dataset.room = id; button.textContent = id; button.addEventListener('click', () => void openRoom(id)); list.append(button); }
  if (!list.children.length) empty(list, 'No rooms yet. Create the first room.');
  selectStyles();
}
function closeGame() { ++gameEpoch; if (typeof GameView !== 'undefined') GameView.close(); gameID = ''; gameReady = false; gameItems = '[]'; $('game-panel').hidden = true; $('game-chat-fields').disabled = true; $('game-chat').replaceChildren(); $('game-heading').textContent = ''; $('participants').textContent = ''; document.querySelectorAll('.challenge-card').forEach(card => card.classList.remove('active')); }
async function openRoom(id) {
  const epoch = ++roomEpoch; closeGame(); roomID = id; roomReady = false; roomItems = '[]';
  $('room-heading').textContent = id; $('room-state').textContent = 'Entering…'; $('room-chat-fields').disabled = true; $('challenge-fields').disabled = true; $('challenge-count').textContent = '0';
  empty($('room-chat'), 'Loading this room’s conversation…'); empty($('challenge-list'), 'Loading challenges…'); selectStyles(); feedback();
  try { await api('enter_room', {roomId:id, requestId:nextID()}); if (epoch !== roomEpoch) return; roomReady = true; $('room-state').textContent = 'Joined'; $('room-chat-fields').disabled = false; $('challenge-fields').disabled = false; await Promise.all([refreshRoom(epoch), refreshChallenges(epoch)]); }
  catch (error) { if (epoch === roomEpoch) { $('room-state').textContent = 'Could not enter'; feedback(error.message, true); } }
}
function renderChat(node, items, placeholder) {
  const pinned = node.scrollHeight - node.scrollTop - node.clientHeight < 70;
  node.replaceChildren();
  if (!items.length) { empty(node, placeholder); return; }
  for (const item of items) { const li = document.createElement('li'); li.className = 'chat-item'; const meta = document.createElement('div'); meta.className = 'chat-meta'; const who = document.createElement('strong'); who.textContent = item.sender; const when = document.createElement('time'); when.dateTime = new Date(item.timeMs).toISOString(); when.textContent = new Date(item.timeMs).toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'}); const body = document.createElement('p'); body.textContent = item.body; meta.append(who, when); li.append(meta, body); node.append(li); }
  if (pinned) node.scrollTop = node.scrollHeight;
}
async function refreshRoom(epoch = roomEpoch) { if (!roomReady) return; const id = roomID; const result = await api('room_history', {roomId:id}); if (epoch !== roomEpoch || result.roomId !== roomID) return; const serialized = JSON.stringify(result.items); if (serialized !== roomItems || !$('room-chat').querySelector('.chat-item')) { roomItems = serialized; renderChat($('room-chat'), result.items || [], 'Start the conversation in this room.'); } }
async function refreshChallenges(epoch = roomEpoch) {
  if (!roomReady) return; const id = roomID; const result = await api('list_games', {roomId:id, requestId:nextID()}); if (epoch !== roomEpoch || result.roomId !== roomID) return;
  const list = $('challenge-list'); list.replaceChildren(); $('challenge-count').textContent = String(result.games.length);
  for (const game of result.games) { const card = document.createElement('article'); card.className = 'challenge-card'; card.classList.toggle('active', game.gameId === gameID); card.dataset.game = game.gameId; const title = document.createElement('h3'); title.textContent = game.gameName; const detail = document.createElement('p'); detail.textContent = game.boardSize + '×' + game.boardSize + ' · ' + game.seatsFilled + '/' + game.seats + ' seated · by ' + game.creator + ' · ' + game.status; const button = document.createElement('button'); button.type = 'button'; button.textContent = 'Open challenge'; button.addEventListener('click', () => { if (roomID === id && roomReady) void openGame(game); }); card.append(title, detail, button); list.append(card); }
  if (!result.games.length) empty(list, 'No challenges in this room yet. Create one below.');
}
async function openGame(game) {
  const epoch = ++gameEpoch, parent = roomEpoch; gameID = game.gameId; gameReady = false; gameItems = '[]'; $('game-panel').hidden = false; $('game-heading').textContent = game.gameName; $('participants').textContent = 'Joining…'; $('game-chat-fields').disabled = true; empty($('game-chat'), 'Loading this challenge’s conversation…');
  document.querySelectorAll('.challenge-card').forEach(card => card.classList.toggle('active', card.dataset.game === gameID));
  try { await api('join_game', {gameId:gameID, requestId:nextID()}); if (epoch !== gameEpoch || parent !== roomEpoch) return; gameReady = true; $('game-chat-fields').disabled = false; await refreshGame(epoch); GameView.open(gameID); }
  catch (error) { if (epoch === gameEpoch && parent === roomEpoch) feedback(error.message, true); }
}
async function refreshGame(epoch = gameEpoch) { if (!gameReady) return; const id = gameID, parent = roomEpoch; const result = await api('game_history', {gameId:id}); if (epoch !== gameEpoch || parent !== roomEpoch || result.gameId !== gameID) return; $('participants').textContent = 'In this challenge: ' + result.participants.join(', '); const serialized = JSON.stringify(result.items); if (serialized !== gameItems || !$('game-chat').querySelector('.chat-item')) { gameItems = serialized; renderChat($('game-chat'), result.items || [], 'This conversation is separate from the room.'); } }
function submit(id, work) { $(id).addEventListener('submit', async event => { event.preventDefault(); const button = $(id).querySelector('button[type="submit"]'); if (button.disabled) return; button.disabled = true; try { await work(); } catch (error) { feedback(error.message, true); } finally { button.disabled = false; } }); }
submit('session-form', async () => { const response = await fetch('./api/issue_session', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({identity:$('identity').value.trim()})}); const result = await response.json(); if (!response.ok) throw new Error(result.error); identity = $('identity').value.trim(); session = result.session; ++sessionEpoch; storage.setItem('goserver:session', session); storage.setItem('goserver:identity', identity); signedIn(); await loadRooms(); if (!roomID) await openRoom('lobby'); feedback('Welcome, ' + identity + '. Choose a room or create your own.'); });
submit('room-form', async () => { const epoch = roomEpoch; const created = await api('create_room', {roomName:$('room-name').value, requestId:nextID()}); $('room-name').value = ''; await loadRooms(); if (epoch === roomEpoch) { await openRoom(created.roomId); feedback('Room created. Invite someone to join the conversation.'); } });
submit('challenge-form', async () => { if (!roomReady) return; const epoch = roomEpoch, id = roomID;
  const num = key => parseInt($(key).value, 10);
  const created = await api('create_game', {roomId:id, gameName:$('challenge-name').value.trim(), boardSize:num('board-size'), seats:num('seats'), turnDeadlineMs:num('turn-deadline'), botMs:num('bot-time'), koRule:num('ko-rule'), exploreMilli:num('explore'), rewardMode:$('reward-mode').value, softness:num('softness'), requestId:nextID()});
  if (epoch !== roomEpoch) return; $('challenge-name').value = ''; await refreshChallenges(epoch);
  if (epoch === roomEpoch) { await openGame(created); if ($('sit-down').checked && gameID === created.gameId) { try { await api('take_seat', {gameId:created.gameId, seat:0, requestId:nextID()}); } catch (error) { feedback(error.message, true); } } feedback('Challenge created in ' + id + '. Plan seats as Person or Bot and set teams below; others in the room can open it and sit; press Start when ready.'); } });
submit('room-chat-form', async () => { if (!roomReady) return; const epoch = roomEpoch; await api('send_room_chat', {roomId:roomID, body:$('room-message').value, requestId:nextID()}); if (epoch !== roomEpoch) return; $('room-message').value = ''; await refreshRoom(epoch); });
submit('game-chat-form', async () => { if (!gameReady) return; const epoch = gameEpoch; await api('send_game_chat', {gameId:gameID, body:$('game-message').value, requestId:nextID()}); if (epoch !== gameEpoch) return; $('game-message').value = ''; await refreshGame(epoch); });
$('close-game').addEventListener('click', closeGame);
$('refresh-rooms').addEventListener('click', () => void loadRooms().catch(error => feedback(error.message, true)));

async function poll() { if (session && !document.hidden) { const epoch = roomEpoch; try { await Promise.all([loadRooms(), refreshRoom(epoch), refreshChallenges(epoch), refreshGame()]); } catch (error) { if (epoch === roomEpoch) feedback(error.message, true); } } setTimeout(poll, 2500); }
signedIn();
if (!session) { const last = storage.getItem('goserver:lastName'), note = storage.getItem('goserver:notice'); if (last) $('identity').value = last; if (note) { feedback(note); storage.setItem('goserver:notice', ''); $('identity').focus(); } }
if (session) loadRooms().then(() => { if (!roomID) return openRoom('lobby'); }).catch(error => feedback(error.message, true));
setTimeout(poll, 2500);
