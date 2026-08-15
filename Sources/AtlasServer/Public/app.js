/* Atlas — client.
 *
 * The server owns every rule; this file only renders state and posts intents.
 * The one thing it computes locally is the countdown, which is interpolated
 * from the last snapshot so the ring animates smoothly between pushes.
 */
'use strict';

const $ = (id) => document.getElementById(id);

const store = {
  get name() { return localStorage.getItem('atlas.name') || ''; },
  set name(v) { localStorage.setItem('atlas.name', v); },
  get session() {
    try { return JSON.parse(localStorage.getItem('atlas.session') || 'null'); }
    catch { return null; }
  },
  set session(v) {
    if (v) localStorage.setItem('atlas.session', JSON.stringify(v));
    else localStorage.removeItem('atlas.session');
  },
};

const app = {
  room: null,
  playerID: null,
  isHost: false,
  state: null,
  stream: null,
  clock: { left: 0, at: 0, paused: true, total: 30 },
  lastLogSeq: 0,
  challengeText: null,
  sending: false,
  /* Every push carries only the tail of the chain, so the client keeps its own
     copy and grows it.  Without this, scrolling back would stop at whatever the
     server last sent rather than at the start of the game. */
  chain: [],
  chainOffset: 0,
  mode: 'cards',
  /* Pictures and facts, keyed by the name as played.  A place is asked about
     once per session: the answer is either a record or the knowledge that the
     server has nothing yet, and neither is worth asking twice on every push. */
  media: new Map(),
  mediaAsked: new Set(),
};

/* ───────────────────────────── plumbing ───────────────────────────── */

async function api(path, body) {
  const options = body
    ? { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body) }
    : { method: 'GET' };
  const response = await fetch(path, options);
  let data = {};
  try { data = await response.json(); } catch { /* empty body is fine */ }
  if (!response.ok && !('ok' in data)) {
    throw new Error(data.error || `request failed (${response.status})`);
  }
  return data;
}

let toastTimer = null;
function toast(message, ms = 2600) {
  const el = $('toast');
  el.textContent = message;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, ms);
}

function show(screen) {
  for (const id of ['home', 'lobby', 'game', 'over']) {
    $('screen-' + id).hidden = (id !== screen);
  }
}

/* ───────────────────────────── session ────────────────────────────── */

function saveSession() {
  store.session = app.room
    ? { room: app.room, playerID: app.playerID, isHost: app.isHost }
    : null;
}

function enterRoom(result) {
  app.room = result.room;
  app.playerID = result.playerID;
  app.isHost = !!result.isHost;
  app.lastLogSeq = 0;
  saveSession();
  const url = new URL(location.href);
  url.searchParams.set('room', app.room);
  history.replaceState(null, '', url);
  connect();
}

function leaveRoom(silent) {
  if (app.stream) { app.stream.close(); app.stream = null; }
  if (!silent && app.room && app.playerID) {
    // Best effort; the server also reaps players whose stream has died.
    navigator.sendBeacon?.(
      `/api/room/${app.room}/leave`,
      new Blob([JSON.stringify({ playerID: app.playerID })], { type: 'application/json' }));
  }
  app.room = app.playerID = app.state = null;
  app.isHost = false;
  app.chain = [];
  app.chainOffset = 0;
  saveSession();
  const url = new URL(location.href);
  url.searchParams.delete('room');
  history.replaceState(null, '', url);
  show('home');
}

function connect() {
  if (app.stream) app.stream.close();
  const stream = new EventSource(
    `/api/room/${app.room}/events?playerID=${encodeURIComponent(app.playerID)}`);
  app.stream = stream;

  stream.addEventListener('state', (event) => {
    try { onState(JSON.parse(event.data)); }
    catch (error) { console.error('bad state payload', error); }
  });

  stream.onerror = () => {
    // EventSource retries on its own; make sure the room still exists.
    fetch(`/api/room/${app.room}/state`).then((r) => {
      if (r.status === 404) { toast('That table has expired.'); leaveRoom(true); }
    }).catch(() => {});
  };
}

/* ───────────────────────────── rendering ──────────────────────────── */

function onState(view) {
  const previous = app.state;
  app.state = view;
  mergeChain(view);
  app.clock = {
    left: view.timeLeft,
    at: performance.now(),
    paused: view.paused || view.phase !== 'playing',
    total: view.turnSeconds || 30,
  };

  announceLog(view);

  if (view.phase === 'lobby') { renderLobby(view); show('lobby'); }
  else if (view.phase === 'playing') {
    renderGame(view, previous);
    show('game');
  } else {
    renderOver(view);
    show('over');
  }
}

/* Folds the window of moves the server just sent into the copy we are keeping.
   `chainLength` is the true length, so the window always belongs at the end. */
function mergeChain(view) {
  const before = app.chainOffset + app.chain.length;
  const window = view.moves || [];
  const start = Math.max(0, (view.chainLength || window.length) - window.length);
  // A shorter chain than we hold means either a fresh game or a dead-letter
  // retraction; either way the tail we are holding is no longer true.
  app.chain = start <= app.chain.length
    ? app.chain.slice(0, start).concat(window)
    : window.slice();
  app.chainOffset = (view.chainLength || window.length) - app.chain.length;
  // A fresh game, or a retraction: either way the end has moved, so follow it.
  if ((view.chainLength || 0) < before) $('chain')._pinned = true;
}

/* Surfaces the interesting log lines as toasts, so a player who is looking at
   the chain still learns why something happened. */
function announceLog(view) {
  const interesting = {
    challenge_ok: 2800, challenge_failed: 4200, eliminated: 3000,
    timeout: 2200, leave: 2000, join: 1800,
    card_met: 2600, rescue: 4000, dead_letter: 4200,
    wager: 3000, wager_lost: 3400, wager_off: 3000,
  };
  for (const entry of view.log) {
    if (entry.seq <= app.lastLogSeq) continue;
    app.lastLogSeq = entry.seq;
    if (app.lastLogSeq && interesting[entry.kind]) toast(entry.text, interesting[entry.kind]);
  }
}

function me(view) { return view.players.find((p) => p.id === app.playerID); }
function isMyTurn(view) { return view.currentPlayerID === app.playerID; }

function renderLobby(view) {
  $('lobby-code').textContent = app.room;
  const list = $('lobby-roster');
  list.innerHTML = '';
  for (const player of view.players) {
    const li = document.createElement('li');
    const who = document.createElement('span');
    who.className = 'who';
    who.textContent = player.name + (player.id === app.playerID ? ' (you)' : '');
    li.appendChild(who);

    const tag = document.createElement('span');
    tag.className = 'tag';
    tag.textContent = player.isBot ? `bot · ${player.difficulty}` : 'human';
    li.appendChild(tag);

    if (app.isHost && player.id !== app.playerID) {
      const kick = document.createElement('button');
      kick.className = 'kick';
      kick.textContent = '×';
      kick.setAttribute('aria-label', `Remove ${player.name}`);
      kick.onclick = () => api(`/api/room/${app.room}/kick`,
                               { playerID: app.playerID, text: player.id }).catch(showError);
      li.appendChild(kick);
    }
    list.appendChild(li);
  }
  $('lobby-host-controls').hidden = !app.isHost;
  $('lobby-wait').hidden = app.isHost;
  $('btn-start').disabled = view.players.length < 1;
}

function renderGame(view, previous) {
  const mine = isMyTurn(view);
  const current = view.players.find((p) => p.id === view.currentPlayerID);

  $('turn-name').textContent = view.paused
    ? 'checking a challenge…'
    : (mine ? 'your turn' : `${current ? current.name : '—'} is thinking`);
  $('chain-count').textContent = view.chainLength;
  $('required-letter').textContent = view.requiredLetter.toUpperCase();

  renderPlayers(view);
  renderCard(view);
  renderChain($('chain'), $('chain-inner'));

  // The composer is never removed from the page during a game.  See the note
  // in style.css: unmounting it drops focus and the keyboard with it.
  const waiting = !mine || view.paused;
  $('composer').classList.toggle('waiting', waiting);

  const input = $('input-place');
  const letter = view.requiredLetter.toUpperCase();
  input.placeholder = view.paused
    ? 'looking that place up…'
    : (mine ? `a place starting with ${letter}`
            : `${current ? current.name : 'someone'} is playing…`);

  // The bet is only ever offered when the server would take it, so pressing it
  // cannot be refused for a reason the player could have seen coming.
  $('btn-wager').hidden = !(mine && !view.paused && view.canWager);
  $('btn-wager').disabled = false;

  // A new turn means whatever was typed for the previous one is stale.
  if (previous && previous.chainLength !== view.chainLength) {
    hideChallenge();
    setFeedback('');
    if (!mine) input.value = '';
  }
  if (mine && previous && !isMyTurn(previous)) {
    input.value = '';
    hideChallenge();
    setFeedback('');
    if (navigator.vibrate) navigator.vibrate(18);
    // The field never lost focus, so this only matters when the turn arrives
    // while the player is looking somewhere else on the page.
    input.focus({ preventScroll: true });
  }
}

function renderPlayers(view) {
  const strip = $('game-players');
  strip.innerHTML = '';
  const scoring = view.players.some((p) => p.score > 0);
  for (const player of view.players) {
    const chip = document.createElement('div');
    chip.className = 'pchip'
      + (player.id === view.currentPlayerID ? ' active' : '')
      + (player.eliminated ? ' out' : '');

    const name = document.createElement('span');
    name.textContent = player.name + (player.id === app.playerID ? ' (you)' : '');
    chip.appendChild(name);

    if (scoring) {
      const points = document.createElement('span');
      points.className = 'pts';
      points.textContent = player.score;
      points.title = `${player.score} points from ${player.placesPlayed} places`;
      chip.appendChild(points);
    }
    if (!player.eliminated) {
      const lives = document.createElement('span');
      lives.className = 'lives';
      lives.textContent = '♥'.repeat(Math.max(0, player.lives));
      chip.appendChild(lives);
    }
    if (!player.isBot && !player.connected && !player.eliminated) {
      const away = document.createElement('span');
      away.className = 'away';
      away.textContent = '⚠';
      away.title = 'disconnected';
      chip.appendChild(away);
    }
    strip.appendChild(chip);
  }
  const active = strip.querySelector('.active');
  if (active) active.scrollIntoView({ block: 'nearest', inline: 'center', behavior: 'smooth' });
}

function renderCard(view) {
  const banner = $('cardbanner');
  const card = view.card;
  banner.hidden = !card;
  if (!card) return;
  banner.classList.toggle('rule', !!view.cardIsRule);
  banner.classList.toggle('bet', !!view.wagered);
  $('card-tier').textContent =
    view.wagered ? 'your bet' : (view.cardIsRule ? 'rule' : card.tier);
  $('card-tier').className = 'tier ' + (view.wagered ? 'hard' : card.tier);
  $('card-headline').textContent = card.headline;
  const fits = `${card.answers} place${card.answers === 1 ? '' : 's'} fit`;
  $('card-demand').textContent =
    (view.cardIsRule ? 'must ' : 'meet it: ') + card.demand + ' · ' + fits;
  // A bet says what it costs as well as what it pays, since the cost is the
  // half you agreed to and the half you are about to forget.
  $('card-reward').innerHTML = view.wagered
    ? `×${card.multiplier}<br><span class="demand">+1 life · miss −1</span>`
    : `×${card.multiplier}${card.grantsLife ? '<br><span class="demand">+1 life</span>' : ''}`;
}

/* Draws only what changed.  Rebuilding the whole list on every push threw away
   the scroll position, so scrolling back through a long game was impossible
   while anyone was still playing.

   Whether to follow the newest place is remembered on the scroller rather than
   measured here.  Measuring looked equivalent and was not: a card banner
   appearing shortens the scroller without moving the content, so the bottom
   silently leaves the viewport and a measurement taken afterwards reads as
   "the player has scrolled away" — leaving you to press *newest* every time a
   card turned up.  Only a real drag changes the intent now, and anything that
   changes the layout underneath a pinned chain re-pins it. */
/* ── pictures ──
   A place gets a photograph and a quirky fact once the server has looked it up,
   which for a place nobody has played before may be minutes away.  So this is
   asked for after the move is already on screen and drawn in when it lands:
   the game never waits for a picture, and a row without one is simply a row. */

function mediaKey(name) { return (name || '').trim().toLowerCase(); }

function mediaFor(move) { return app.media.get(mediaKey(move.text)) || null; }

async function requestMedia(moves) {
  const wanted = [];
  for (const move of moves) {
    const key = mediaKey(move.text);
    if (!key || app.mediaAsked.has(key)) continue;
    app.mediaAsked.add(key);
    wanted.push(move.text);
  }
  if (!wanted.length) return;
  let reply;
  try {
    reply = await api(`/api/media?q=${encodeURIComponent(wanted.join('|'))}`);
  } catch {
    // A picture is not worth a toast.  Let the names be asked again later.
    for (const name of wanted) app.mediaAsked.delete(mediaKey(name));
    return;
  }
  let arrived = 0;
  for (const record of reply.places || []) {
    app.media.set(mediaKey(record.q), record);
    arrived++;
  }
  /* Places the server has not looked up yet are worth asking about again, but
     not on every push — once the chain has moved on a few turns. */
  if ((reply.places || []).length < wanted.length) {
    setTimeout(() => {
      for (const name of wanted) {
        if (!app.media.has(mediaKey(name))) app.mediaAsked.delete(mediaKey(name));
      }
    }, 20000);
  }
  if (arrived && app.state) {
    renderChain($('chain'), $('chain-inner'));
    if ($('over-chain')) renderChain($('over-chain'), $('over-chain-inner'));
  }
}

function renderChain(scroller, inner) {
  const moves = app.chain;
  /* The key carries the picture itself, so a row drawn bare is redrawn — and
     only that row — once its photograph turns up.  It has to be the URL and not
     merely a has-a-record flag: a country with no picture of its own borrows
     its capital's, which arrives as a *second* record for a place that already
     had one, and under a flag both records look identical and the row keeps
     the blank it was drawn with. */
  const keys = moves.map((m, i) => {
    const media = mediaFor(m) || {};
    return `${i + app.chainOffset}:${m.placeID}:${m.points}`
      + `:${media.image || ''}:${(media.fact || '').length}`;
  });
  const old = inner._keys || [];
  let common = 0;
  while (common < old.length && common < keys.length && old[common] === keys[common]) common++;
  while (inner.children.length > common) inner.removeChild(inner.lastChild);

  for (let i = common; i < moves.length; i++) {
    inner.appendChild(moveRow(moves[i]));
  }
  inner._keys = keys;
  if (isPinned(scroller)) scrollChainToEnd(scroller);
  updateJumpButton();
  // The newest first: those are the ones on screen.
  requestMedia(moves.slice(-24).reverse());
}

// A chain follows its end until its own reader scrolls away from it.
function isPinned(scroller) { return scroller._pinned !== false; }

function atChainEnd(scroller) {
  return scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 28;
}

function scrollChainToEnd(scroller) {
  scroller._pinned = true;
  scroller.scrollTop = scroller.scrollHeight;
}

function updateJumpButton() {
  const button = $('btn-jump');
  if (!button) return;
  button.hidden = isPinned($('chain'));
}

/* The player's own finger is the only thing that unpins the chain. */
function onChainScroll() {
  const scroller = $('chain');
  scroller._pinned = atChainEnd(scroller);
  updateJumpButton();
}

/* A card arriving, the keyboard opening, a picture loading late — all of these
   resize the chain without anyone scrolling.  Follow the end through them. */
function watchChainSize() {
  if (typeof ResizeObserver !== 'function') return;
  const scroller = $('chain');
  const observer = new ResizeObserver(() => {
    if (isPinned(scroller)) scroller.scrollTop = scroller.scrollHeight;
  });
  observer.observe(scroller);
  observer.observe($('chain-inner'));
}

function moveRow(move) {
  const row = document.createElement('div');
  row.className = 'play'
    + (move.playerID === app.playerID ? ' mine' : '')
    + (move.viaChallenge ? ' challenged' : '')
    + (move.metCard ? ' bonus' : '');

  const name = document.createElement('span');
  name.className = 'name';
  name.textContent = move.playerName;
  row.appendChild(name);

  const place = document.createElement('span');
  place.className = 'place';
  const letters = move.text.replace(/[^A-Za-z]/g, '');
  const tail = letters.slice(-1);
  const cut = move.text.lastIndexOf(tail);
  place.append(move.text.slice(0, cut));
  const strong = document.createElement('span');
  strong.className = 'tail';
  strong.textContent = move.text.slice(cut);
  place.appendChild(strong);
  row.appendChild(place);

  const meta = document.createElement('span');
  meta.className = 'meta';
  meta.textContent = (move.viaChallenge ? '🔎 ' : '') + (move.kind || '');
  row.appendChild(meta);

  // One line of geography, so the chain teaches something as it goes past.
  if (move.blurb) {
    const blurb = document.createElement('span');
    blurb.className = 'blurb';
    blurb.textContent = `${move.text} is ${move.blurb}.`;
    row.appendChild(blurb);
  }

  const media = mediaFor(move);
  if (media && media.fact) {
    const fact = document.createElement('span');
    fact.className = 'fact';
    fact.textContent = media.fact;
    row.appendChild(fact);
  }
  if (media && media.image) {
    const shot = document.createElement('img');
    shot.className = 'shot';
    shot.src = media.image;
    shot.alt = move.text;
    shot.loading = 'lazy';
    shot.decoding = 'async';
    // A dead link would otherwise leave a broken-image glyph in the chain.
    shot.addEventListener('error', () => { shot.remove(); row.classList.remove('pictured'); });
    row.classList.add('pictured');
    row.appendChild(shot);
  }
  if (move.metCard && move.card) {
    const scored = document.createElement('span');
    scored.className = 'scored';
    scored.textContent = (move.wagered ? '🎲 bet won — ' : '✦ ') + move.card.headline
      + ` — ${move.points} points` + (move.card.grantsLife ? ' and a life' : '');
    row.appendChild(scored);
  } else if (move.wagered && move.card) {
    const lost = document.createElement('span');
    lost.className = 'scored lost';
    lost.textContent = `🎲 bet lost — it had to ${move.card.demand} — a life gone`;
    row.appendChild(lost);
  }
  return row;
}

function renderOver(view) {
  const winner = view.players.find((p) => p.id === view.winnerID);
  const iWon = winner && winner.id === app.playerID;
  $('over-emoji').textContent = winner ? (iWon ? '🏆' : '🌍') : '🏁';
  $('over-title').textContent = winner
    ? (iWon ? 'You win' : `${winner.name} wins`)
    : 'Game over';
  $('over-sub').textContent = `${view.chainLength} places without a repeat.`;
  renderScores(view);
  renderChain($('over-chain'), $('over-chain-inner'));
  $('btn-again').hidden = !app.isHost;
}

function renderScores(view) {
  const list = $('over-scores');
  list.innerHTML = '';
  const ranked = view.players.slice().sort((a, b) =>
    b.score - a.score || b.placesPlayed - a.placesPlayed);
  ranked.forEach((player, index) => {
    const li = document.createElement('li');
    if (player.id === app.playerID) li.className = 'you';

    const rank = document.createElement('span');
    rank.className = 'rank';
    rank.textContent = index + 1;
    li.appendChild(rank);

    const who = document.createElement('span');
    who.className = 'who';
    who.textContent = player.name + (player.id === app.playerID ? ' (you)' : '');
    li.appendChild(who);

    const detail = document.createElement('span');
    detail.className = 'detail';
    detail.textContent = `${player.placesPlayed} places`
      + (player.cardsMet ? ` · ${player.cardsMet} cards` : '');
    li.appendChild(detail);

    const points = document.createElement('span');
    points.className = 'pts';
    points.textContent = player.score;
    li.appendChild(points);
    list.appendChild(li);
  });
}

/* ───────────────────────────── countdown ──────────────────────────── */

const CIRCUMFERENCE = 2 * Math.PI * 52;

function animate() {
  requestAnimationFrame(animate);
  const view = app.state;
  if (!view || view.phase !== 'playing') return;

  const elapsed = (performance.now() - app.clock.at) / 1000;
  const left = app.clock.paused
    ? app.clock.left
    : Math.max(0, app.clock.left - elapsed);
  const fraction = Math.max(0, Math.min(1, left / app.clock.total));

  const ring = $('clock-fill');
  ring.style.strokeDashoffset = String(CIRCUMFERENCE * (1 - fraction));
  ring.className.baseVal = 'clock-fill'
    + (app.clock.paused ? ' paused' : left <= 5 ? ' critical' : left <= 10 ? ' low' : '');
  $('seconds-left').textContent = app.clock.paused ? '⏸' : Math.ceil(left);
}

/* ───────────────────────────── actions ────────────────────────────── */

function setFeedback(text, kind) {
  const el = $('feedback');
  el.textContent = text;
  el.className = 'feedback' + (kind ? ' ' + kind : '');
}

function showChallenge(text) {
  app.challengeText = text;
  $('btn-challenge').hidden = false;
}

function hideChallenge() {
  app.challengeText = null;
  $('btn-challenge').hidden = true;
}

function showError(error) {
  setFeedback(error.message || String(error), 'bad');
}

async function send() {
  const input = $('input-place');
  const text = input.value.trim();
  if (!text || app.sending) return;
  // The composer stays on screen between turns so the keyboard does; that means
  // it can be tapped when there is nothing to send.
  if (app.state && app.state.phase === 'playing' && !isMyTurn(app.state)) {
    setFeedback('Not your turn yet — it is saved, hit ▶ when the letter is yours.');
    return;
  }
  app.sending = true;
  $('btn-send').disabled = true;
  try {
    const result = await api(`/api/room/${app.room}/submit`,
                             { playerID: app.playerID, text });
    if (result.ok) {
      input.value = '';
      hideChallenge();
      setFeedback('');
    } else {
      setFeedback(result.error, 'bad');
      if (result.canChallenge) showChallenge(text); else hideChallenge();
      if (navigator.vibrate) navigator.vibrate([12, 40, 12]);
    }
  } catch (error) {
    showError(error);
  } finally {
    app.sending = false;
    $('btn-send').disabled = false;
    // Keeping focus keeps the iOS keyboard up between turns.
    input.focus();
  }
}

async function challenge() {
  const text = app.challengeText;
  if (!text) return;
  setFeedback(`Looking up ${text}…`, 'busy');
  $('btn-challenge').disabled = true;
  try {
    const result = await api(`/api/room/${app.room}/challenge`,
                             { playerID: app.playerID, text });
    if (!result.ok) setFeedback(result.error, 'bad');
    else hideChallenge();
  } catch (error) {
    showError(error);
  } finally {
    $('btn-challenge').disabled = false;
  }
}

/* A life on a hard card.  The confirmation is deliberate: the button sits next
   to Hint, and a mis-tap that costs a life would be unforgivable. */
async function wager() {
  const view = app.state;
  const lives = view && me(view) ? me(view).lives : 0;
  const question = lives <= 1
    ? 'Bet your last life on a hard card?'
    : 'Bet a life on a hard card? Meet it and you win one back.';
  if (!confirm(question)) return;
  $('btn-wager').disabled = true;
  try {
    const result = await api(`/api/room/${app.room}/wager`, { playerID: app.playerID });
    if (!result.ok) setFeedback(result.error, 'bad');
    else setFeedback(`bet on: ${result.demand}`, 'busy');
  } catch (error) {
    showError(error);
  } finally {
    $('btn-wager').disabled = false;
    $('input-place').focus();
  }
}

async function hint() {
  try {
    const result = await api(`/api/room/${app.room}/hint`);
    setFeedback(result.hints && result.hints.length
      ? 'try: ' + result.hints.slice(0, 4).join(', ')
      : 'nothing left under that letter!', 'good');
  } catch (error) {
    showError(error);
  }
}

/* ───────────────────────────── wiring ─────────────────────────────── */

function currentName() {
  const value = $('input-name').value.trim();
  if (value) store.name = value;
  return value || 'Player';
}

/* The table the host picked, plus only those knobs they actually moved.  An
   option left on "as the table says" is left out of the request entirely, so
   the mode's own setting survives. */
function table() {
  const t = { mode: app.mode };
  const number = (id, key) => {
    const raw = $(id).value;
    if (raw !== '') t[key] = Number(raw);
  };
  number('opt-turn', 'turnSeconds');
  number('opt-lives', 'lives');
  number('opt-cards', 'cardChance');
  number('opt-decay', 'turnDecay');
  if ($('opt-forced').value !== '') t.forcedCards = $('opt-forced').value === '1';
  if ($('opt-tiers').value !== '') t.cardTiers = $('opt-tiers').value.split(',');
  return t;
}

function renderModes(modes) {
  const box = $('opt-modes');
  box.innerHTML = '';
  for (const mode of modes) {
    const button = document.createElement('button');
    button.type = 'button';
    button.setAttribute('role', 'radio');
    button.setAttribute('aria-checked', String(mode.id === app.mode));
    button.dataset.mode = mode.id;
    const title = document.createElement('span');
    title.className = 't';
    title.textContent = mode.title;
    const blurb = document.createElement('span');
    blurb.className = 'b';
    blurb.textContent = mode.blurb;
    button.append(title, blurb);
    button.onclick = () => {
      app.mode = mode.id;
      localStorage.setItem('atlas.mode', mode.id);
      for (const other of box.children) {
        other.setAttribute('aria-checked', String(other.dataset.mode === mode.id));
      }
    };
    box.appendChild(button);
  }
}

$('btn-quick').onclick = async () => {
  try {
    enterRoom(await api('/api/quick', {
      name: currentName(),
      difficulty: $('opt-difficulty').value,
      bots: Number($('opt-bots').value),
      table: table(),
    }));
  } catch (error) { toast(error.message); }
};

$('btn-create').onclick = async () => {
  try {
    enterRoom(await api('/api/room', { name: currentName(), table: table() }));
  } catch (error) { toast(error.message); }
};

$('btn-join').onclick = async () => {
  const code = $('input-code').value.trim().toUpperCase();
  if (!code) return toast('Enter a table code.');
  try { enterRoom(await api(`/api/room/${code}/join`, { name: currentName() })); }
  catch (error) { toast(error.message); }
};

$('input-code').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') { e.preventDefault(); $('btn-join').click(); }
});

for (const button of document.querySelectorAll('[data-add-bot]')) {
  button.onclick = () => api(`/api/room/${app.room}/bot`,
                             { difficulty: button.dataset.addBot }).catch((e) => toast(e.message));
}

$('btn-start').onclick = () =>
  api(`/api/room/${app.room}/start`, { playerID: app.playerID })
    .catch((error) => toast(error.message));

$('btn-share').onclick = async () => {
  const url = `${location.origin}/?room=${app.room}`;
  if (navigator.share) {
    try { await navigator.share({ title: 'Atlas', text: `Join my table: ${app.room}`, url }); return; }
    catch { /* user cancelled */ }
  }
  try { await navigator.clipboard.writeText(url); toast('Link copied.'); }
  catch { toast(url); }
};

$('btn-lobby-back').onclick = () => leaveRoom(false);
$('btn-game-back').onclick = () => { if (confirm('Leave the game?')) leaveRoom(false); };
$('btn-home').onclick = () => leaveRoom(false);
$('btn-again').onclick = () =>
  api(`/api/room/${app.room}/again`, { playerID: app.playerID })
    .catch((error) => toast(error.message));

$('btn-send').onclick = send;
$('btn-challenge').onclick = challenge;
$('btn-hint').onclick = hint;
$('btn-wager').onclick = wager;
$('input-place').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') { e.preventDefault(); send(); }
});
$('input-place').addEventListener('input', () => {
  if (app.challengeText && $('input-place').value.trim() !== app.challengeText) hideChallenge();
});

$('chain').addEventListener('scroll', onChainScroll, { passive: true });
$('btn-jump').onclick = () => {
  scrollChainToEnd($('chain'));
  updateJumpButton();
};
watchChainSize();

/* ───────────────────────────── startup ────────────────────────────── */

async function boot() {
  $('input-name').value = store.name;
  app.mode = localStorage.getItem('atlas.mode') || 'cards';
  animate();

  try {
    const info = await api('/api/atlas');
    $('home-footnote').textContent =
      `${info.places} places in the book` + (info.learned ? ` · ${info.learned} learned` : '');
  } catch { /* the footnote is decoration */ }

  try {
    const { modes } = await api('/api/modes');
    if (modes && modes.length) {
      if (!modes.some((m) => m.id === app.mode)) app.mode = modes[0].id;
      renderModes(modes);
    }
  } catch { /* without the picker the server's default table still works */ }

  const fromLink = new URLSearchParams(location.search).get('room');
  const session = store.session;

  if (session && (!fromLink || fromLink === session.room)) {
    // Reconnect after a refresh or an app switch.
    try {
      const result = await api(`/api/room/${session.room}/join`,
                               { playerID: session.playerID, name: store.name });
      return enterRoom(result);
    } catch { store.session = null; }
  }
  if (fromLink) {
    $('input-code').value = fromLink;
    show('home');
    toast(`Table ${fromLink} — tap Join.`);
    return;
  }
  show('home');
}

// A phone that has been asleep comes back with a dead stream.
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && app.room && app.stream
      && app.stream.readyState === EventSource.CLOSED) {
    connect();
  }
});

boot();
