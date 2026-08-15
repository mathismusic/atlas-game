#!/usr/bin/env node
// Browser-level test of the phone UI, driven through WebKit at an iPhone
// viewport — the same engine Safari uses, so what passes here is what the
// phone will do.  The Python end-to-end suite proves the HTTP surface; this
// proves the half that only exists in the browser: the event stream driving a
// live DOM, the composer, the clock, and the rest of the screens.
//
//     node tools/ui_test.mjs [--base http://localhost:8080] [--headed]
//
// Screenshots land in tools/shots/ so the layout can be eyeballed afterwards.

import { mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SHOTS = path.join(HERE, 'shots');

// Playwright is vendored in tools/browser so this runs with nothing installed
// globally, but a system copy is just as good if someone has one.
const { webkit, devices } = await (async () => {
  const vendored = pathToFileURL(
    path.join(HERE, 'browser/node_modules/playwright/index.mjs')).href;
  for (const source of [vendored, 'playwright']) {
    try { return await import(source); } catch { /* try the next one */ }
  }
  console.error('playwright is missing — run: npm i --prefix tools/browser playwright'
                + ' && npx playwright install webkit');
  process.exit(2);
})();

const args = process.argv.slice(2);
const BASE = valueOf('--base') ?? 'http://localhost:8080';
const HEADED = args.includes('--headed');

function valueOf(flag) {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : null;
}

const failures = [];
let checks = 0;

function check(condition, label, detail = '') {
  checks += 1;
  if (condition) {
    console.log(`  \x1b[32m✓\x1b[0m ${label}`);
  } else {
    console.log(`  \x1b[31m✗\x1b[0m ${label}   ${detail}`);
    failures.push(label);
  }
  return condition;
}

/// Polls `probe` until it returns something truthy.  Playwright's own waiters
/// only speak DOM; a lot of what matters here is application state that has to
/// be read out of the page.
async function until(probe, { timeout = 20000, label = 'condition' } = {}) {
  const deadline = Date.now() + timeout;
  for (;;) {
    const value = await probe();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`);
    await new Promise((r) => setTimeout(r, 120));
  }
}

const text = (page, selector) => page.locator(selector).innerText();
const visible = (page, selector) => page.locator(selector).isVisible();

/// The composer is on screen for the whole game — taking it away would drop
/// the keyboard — so "can I play right now" is read off its waiting class.
const myTurn = (page) => page.evaluate(() =>
  !document.getElementById('screen-game').hidden
  && !document.getElementById('composer').classList.contains('waiting'));

/// Presses Hint and reads a place back out of the feedback line, which is
/// where the app prints "try: Oslo, Odessa, …".
async function askHint(page) {
  await page.click('#btn-hint');
  const line = await until(async () => {
    const t = (await text(page, '#feedback')).trim();
    return t.startsWith('try:') || t.includes('nothing left') ? t : null;
  }, { label: 'a hint', timeout: 10000 }).catch(() => null);
  if (!line || !line.startsWith('try:')) return null;
  return line.slice(4).split(',')[0].trim() || null;
}

async function shoot(page, name) {
  await page.screenshot({ path: path.join(SHOTS, `${name}.png`) });
}

/// A fresh phone: its own browser context, so its own localStorage.  Sharing
/// one context between "two players" would have them resume the same saved
/// session, which is not what two phones do.
async function phone(browser) {
  const context = await browser.newContext({ ...devices['iPhone 13'], baseURL: BASE });
  const page = await context.newPage();
  return { context, page };
}

/// What the server thinks, for when the screen and the server disagree.
async function serverState(page, code) {
  return page.evaluate(async (room) => {
    const r = await fetch(`/api/room/${room}/state`);
    return r.ok ? r.json() : { missing: true };
  }, code);
}

// --------------------------------------------------------------------------

async function testSoloGame(browser) {
  console.log('\nsolo game against the computer');
  const { context, page } = await phone(browser);
  const consoleErrors = [];
  page.on('pageerror', (e) => consoleErrors.push(String(e)));
  page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text()); });

  await page.goto(BASE, { waitUntil: 'networkidle' });
  check(await visible(page, '#screen-home'), 'home screen renders');
  await shoot(page, '01-home');

  // A phone with a soft keyboard: the name field must actually take input.
  await page.fill('#input-name', 'Krishna');
  // The settings live behind a disclosure triangle, as they do for a player.
  await page.click('.options > summary');
  check(await visible(page, '#opt-difficulty'), 'the options panel opens');
  // Short turns so that the losing end of the game — three timeouts — happens
  // inside the life of this test rather than a minute and a half later.
  await page.selectOption('#opt-difficulty', 'medium');
  await page.selectOption('#opt-turn', '10');
  await page.selectOption('#opt-lives', '3');
  // Deal on every turn so the card banner is not left to chance.
  await page.selectOption('#opt-cards', '1');
  // …but no hard cards.  A hard card hands out an extra life, so with them in
  // the deck "stop answering until you die" has no length: the test played its
  // way up to a dozen lives and then timed out waiting to lose them again.
  await page.selectOption('#opt-tiers', 'easy,medium');
  check((await page.locator('#opt-modes button').count()) > 0,
        'the home screen offers the table modes');
  await page.click('#opt-modes button[data-mode="cards"]');
  await page.click('#btn-quick');

  await until(() => visible(page, '#screen-game'),
              { label: 'the game screen', timeout: 15000 });
  check(true, 'quick play lands straight on the game screen');
  const code = await page.evaluate(
    () => JSON.parse(localStorage.getItem('atlas.session') || '{}').room);

  const letter = (await text(page, '#required-letter')).trim();
  check(/^[A-Z]$/.test(letter), 'a required letter is shown', `got ${letter}`);

  // The countdown is animated in the page from an anchor the server pushes, so
  // a moving number means both halves are alive: a state arrived, and the
  // animation frame loop is running off it.
  const first = await text(page, '#seconds-left');
  const ticked = await until(async () => (await text(page, '#seconds-left')) !== first,
                             { label: 'the clock to tick', timeout: 12000 }).then(() => true,
                                                                                  () => false);
  check(ticked, 'the turn clock ticks down', `stuck at ${first}`);
  await shoot(page, '02-game');

  // Rejection feedback has to reach the player, or a wrong answer just looks
  // like a dead button.
  const wrong = letter === 'Z' ? 'Argentina' : 'Zzzzzz';
  await page.fill('#input-place', wrong);
  await page.click('#btn-send');
  const feedback = await until(async () => {
    const t = (await text(page, '#feedback')).trim();
    return t.length > 0 ? t : null;
  }, { label: 'rejection feedback', timeout: 8000 }).catch(() => '');
  check(feedback.length > 0, 'a bad guess is explained on screen', JSON.stringify(feedback));
  check(await page.inputValue('#input-place') !== '', 'the rejected text is left to edit');

  // Nothing in the composer may sit below the fold on a phone: the Hint and
  // Challenge buttons are useless if the thumb cannot reach them.
  const fits = await page.evaluate(() => {
    const worst = ['input-place', 'btn-send', 'btn-hint']
      .map((id) => document.getElementById(id).getBoundingClientRect().bottom)
      .reduce((a, b) => Math.max(a, b), 0);
    return { worst: Math.round(worst), viewport: innerHeight };
  });
  check(fits.worst <= fits.viewport, 'the whole composer is on screen', JSON.stringify(fits));

  // A toast lands on top of those same buttons.  It must not swallow the tap.
  const throughToast = await page.evaluate(() => {
    const toast = document.getElementById('toast');
    toast.textContent = 'someone joined the table and this message is a long one';
    toast.hidden = false;
    const box = document.getElementById('btn-hint').getBoundingClientRect();
    const toastBox = toast.getBoundingClientRect();
    const overlaps = toastBox.top < box.bottom && toastBox.bottom > box.top
                  && toastBox.left < box.right && toastBox.right > box.left;
    const hit = document.elementFromPoint(box.left + box.width / 2,
                                          box.top + box.height / 2);
    toast.hidden = true;
    return { overlaps, hit: hit ? hit.id || hit.className : null };
  });
  check(!throughToast.overlaps || throughToast.hit === 'btn-hint',
        'a toast does not swallow taps meant for the buttons',
        JSON.stringify(throughToast));

  // Play the game out with the hint button, which is also how a real player
  // stuck on X gets unstuck.
  let played = 0;
  for (let turn = 0; turn < 40; turn += 1) {
    const mine = await until(async () => {
      if (await visible(page, '#screen-over')) return 'over';
      return (await myTurn(page)) ? 'mine' : null;
    }, { label: 'our turn', timeout: 45000 }).catch(() => null);
    if (mine !== 'mine') break;

    const suggestion = await askHint(page);
    if (!suggestion) break;

    const before = Number((await text(page, '#chain-count')).trim());
    await page.fill('#input-place', suggestion);
    // Enter, not the button: that is what the phone keyboard sends.
    await page.press('#input-place', 'Enter');
    const accepted = await until(async () => {
      if (await visible(page, '#screen-over')) return true;
      return Number((await text(page, '#chain-count')).trim()) > before;
    }, { label: 'the move to land', timeout: 15000 }).catch(() => false);
    if (!accepted) {
      const truth = await serverState(page, code);
      check(false, `hint "${suggestion}" never landed`,
            `feedback=${JSON.stringify(await text(page, '#feedback').catch(() => ''))} `
            + `screen-says-my-turn=${await myTurn(page)} `
            + `server=${JSON.stringify({ phase: truth.phase, letter: truth.requiredLetter,
                                         turn: truth.currentPlayerID, chain: truth.chainLength })}`);
      await shoot(page, '99-refused');
      break;
    }
    played += 1;
    if (played === 2) await shoot(page, '03-mid-game');

    // The one thing a phone must not do between turns: drop the keyboard.
    // The input is focused by pressing Enter in it, and nothing that happens
    // while the computer thinks — including a full re-render — may blur it.
    if (played === 1) {
      const grew = await until(async () => {
        if (await visible(page, '#screen-over')) return true;
        return Number((await text(page, '#chain-count')).trim()) > before + 1;
      }, { label: 'the computer to reply', timeout: 30000 }).catch(() => false);
      if (grew) {
        check(await page.evaluate(() => document.activeElement?.id) === 'input-place',
              'the caret stays in the box while the computer plays',
              await page.evaluate(() => document.activeElement?.id ?? 'nothing'));
      }
    }
  }

  check(played >= 3, `played ${played} moves through the UI`);

  const chain = await page.locator('#chain .play').count();
  check(chain > 0, 'the chain lists the places played', `nodes=${chain}`);

  // Feature: one line of geography under each place.
  const blurbs = await page.locator('#chain .play .blurb').allInnerTexts();
  check(blurbs.length > 0, 'the chain explains the places played',
        JSON.stringify(blurbs.slice(0, 2)));
  check(blurbs.some((b) => /\bis (a|an|the)\b/.test(b)),
        'the explanation reads as a sentence', JSON.stringify(blurbs[0] ?? ''));

  // Feature: cards, and the points they are worth.
  const sawCard = await page.evaluate(() => {
    const banner = document.getElementById('cardbanner');
    return banner.hidden ? null : {
      headline: document.getElementById('card-headline').textContent,
      demand: document.getElementById('card-demand').textContent,
      reward: document.getElementById('card-reward').textContent,
    };
  });
  check(sawCard && sawCard.headline.length > 0 && /fit/.test(sawCard.demand),
        'a card is shown with its demand and how many places fit',
        JSON.stringify(sawCard));

  const points = await page.locator('#game-players .pchip .pts').allInnerTexts();
  check(points.length > 0 && points.some((p) => Number(p) > 0),
        'the players strip shows the score', JSON.stringify(points));

  // Feature: the chain scrolls on its own, and the header stays put while it
  // does.  Before this, a long game pushed the clock off the top of the phone.
  const scrolling = await page.evaluate(() => {
    const chain = document.getElementById('chain');
    const screen = document.getElementById('screen-game');
    const clockBefore = document.querySelector('.clockwrap').getBoundingClientRect().top;
    chain.scrollTop = 0;
    const scrolledUp = chain.scrollTop;
    chain.scrollTop = chain.scrollHeight;
    return {
      screenOverflow: screen.scrollHeight - screen.clientHeight,
      canScrollBack: chain.scrollHeight > chain.clientHeight ? scrolledUp === 0 : 'short',
      clockMoved: Math.abs(
        document.querySelector('.clockwrap').getBoundingClientRect().top - clockBefore),
      newestVisible: chain.scrollHeight - chain.scrollTop - chain.clientHeight < 2,
    };
  });
  check(scrolling.screenOverflow <= 1,
        'the game screen itself never scrolls', JSON.stringify(scrolling));
  check(scrolling.clockMoved < 1,
        'the clock stays put while the chain scrolls', JSON.stringify(scrolling));
  check(scrolling.newestVisible,
        'the newest place is the one you land on', JSON.stringify(scrolling));

  // Feature: a card turning up must not cost you your place in the chain.  The
  // banner shortens the scroller without moving its contents, so the newest
  // place quietly slid out of view and the app read that as "the player has
  // scrolled away" — you had to press *newest* every single time a card came.
  const throughCard = await page.evaluate(async () => {
    const chain = document.getElementById('chain');
    const banner = document.getElementById('cardbanner');
    const frame = () => new Promise((resolve) => requestAnimationFrame(() => resolve()));
    const was = banner.hidden;

    banner.hidden = true;                       // start from a turn with no card
    await frame(); await frame();
    chain.scrollTop = chain.scrollHeight;       // …reading the newest place
    chain.dispatchEvent(new Event('scroll'));

    const gapOf = () =>
      Math.round(chain.scrollHeight - chain.scrollTop - chain.clientHeight);

    banner.hidden = false;                      // a card arrives…
    await frame(); await frame();
    const onArrival = gapOf();
    // …and the push that carried it redraws the chain.  app.js is a plain
    // script, so its functions are globals and the real path can be driven.
    renderChain(chain, document.getElementById('chain-inner'));
    await frame(); await frame();
    const result = {
      overflowing: chain.scrollHeight > chain.clientHeight + 4,
      onArrival,
      gap: gapOf(),
      jumpHidden: document.getElementById('btn-jump').hidden,
    };
    banner.hidden = was;
    await frame();
    return result;
  });
  check(throughCard.onArrival < 2 && throughCard.gap < 2,
        'a card arriving leaves the chain on the newest place',
        JSON.stringify(throughCard));
  check(throughCard.jumpHidden, 'and does not send you back to the *newest* button',
        JSON.stringify(throughCard));

  // Let the game finish so the end screen gets exercised too: stop answering
  // and the clock runs out.  Three lives at ten seconds, and no hard cards to
  // top them up, so this is a bounded wait rather than a hopeful one.
  const finished = await until(() => visible(page, '#screen-over'),
                               { label: 'the game to end', timeout: 90000 })
    .then(() => true, () => false);
  const truth = finished ? null : await serverState(page, code);
  check(finished, 'the game reaches an end screen',
        truth ? JSON.stringify({ phase: truth.phase, letter: truth.requiredLetter,
                                 paused: truth.paused, timeLeft: truth.timeLeft,
                                 lives: (truth.players || []).map((p) => p.lives) }) : '');
  if (finished) {
    await shoot(page, '04-game-over');
    const title = (await text(page, '#over-title')).trim();
    check(title.length > 0, 'the end screen names an outcome', title);
    const scores = await page.locator('#over-scores li').allInnerTexts();
    check(scores.length >= 2, 'the end screen ranks everyone by points',
          JSON.stringify(scores));
    check(await visible(page, '#btn-again') || await visible(page, '#btn-home'),
          'the end screen offers a way onward');
    await page.click('#btn-home');
    await until(() => visible(page, '#screen-home'), { label: 'the home screen' });
    check(true, 'back to start works');
  }

  check(consoleErrors.length === 0, 'no javascript errors on the page',
        consoleErrors.slice(0, 3).join(' | '));
  await context.close();
}

/// Betting a life, through the thumb rather than the wire.
///
/// The HTTP suite proves the rule; what only exists in the browser is the
/// button — whether it is offered on the right turns, whether the card it
/// summons is unmistakably a bet on screen, and whether the chain says which
/// way it went afterwards.
async function testWager(browser) {
  console.log('\nbetting a life');
  const { context, page } = await phone(browser);
  const consoleErrors = [];
  page.on('pageerror', (e) => consoleErrors.push(String(e)));
  // The bet asks before it is placed, which is a native dialog: without a
  // handler Playwright dismisses it and the button would look broken.
  let asked = '';
  page.on('dialog', (dialog) => { asked = dialog.message(); dialog.accept(); });

  await page.goto(BASE, { waitUntil: 'networkidle' });
  await page.fill('#input-name', 'Krishna');
  await page.click('.options > summary');
  // A long clock and lives to spare: this test is about the button, and a
  // player thinking about a bet is exactly who runs out of time.
  await page.selectOption('#opt-turn', '60');
  await page.selectOption('#opt-lives', '3');
  await page.selectOption('#opt-cards', '0');   // the only card is the bet's own
  await page.click('#opt-modes button[data-mode="cards"]');
  await page.click('#btn-quick');
  await until(() => visible(page, '#screen-game'),
              { label: 'the game screen', timeout: 15000 });
  const code = await page.evaluate(
    () => JSON.parse(localStorage.getItem('atlas.session') || '{}').room);

  await until(() => myTurn(page), { label: 'our turn', timeout: 30000 });
  check(await visible(page, '#btn-wager'), 'the bet is offered on our turn');
  check(await page.evaluate(() => document.getElementById('cardbanner').hidden),
        'and no card is on the table until it is taken');

  // Read lives from the server rather than the strip: the strip is what is
  // being tested elsewhere, and a stale push here would blame the wrong code.
  const livesOf = () => page.evaluate(async (room) => {
    const view = await (await fetch(`/api/room/${room}/state`)).json();
    return (view.players.find((p) => p.id === app.playerID) || {}).lives ?? null;
  }, code).catch(() => null);
  const livesBefore = await livesOf();

  await page.click('#btn-wager');
  const banner = await until(async () => {
    const shown = await page.evaluate(() => {
      const box = document.getElementById('cardbanner');
      if (box.hidden) return null;
      return {
        bet: box.classList.contains('bet'),
        tier: document.getElementById('card-tier').textContent,
        demand: document.getElementById('card-demand').textContent,
        reward: document.getElementById('card-reward').textContent,
      };
    });
    return shown;
  }, { label: 'the card the bet summons', timeout: 10000 }).catch(() => null);

  check(/bet/i.test(asked), 'pressing it asks before spending a life', asked);
  check(banner !== null, 'the card appears the moment the bet is placed');
  if (banner) {
    check(banner.bet && /bet/i.test(banner.tier),
          'the banner says it is a bet, not an ordinary card', JSON.stringify(banner));
    check(/×5/.test(banner.reward) && /life/i.test(banner.reward),
          'and what it pays: five times, and a life', JSON.stringify(banner));
  }
  check(await page.evaluate(() => document.getElementById('btn-wager').hidden),
        'the button goes away once the bet is on');
  await shoot(page, '06-wager');

  // Hints obey the card, so the first one wins the bet — which is the branch
  // that has to pay out on screen.
  const suggestion = await askHint(page);
  check(suggestion !== null, 'a hint is offered that meets the card', String(suggestion));
  if (suggestion) {
    await page.fill('#input-place', suggestion);
    await page.press('#input-place', 'Enter');
    const settled = await until(async () => {
      const rows = await page.locator('#chain .play .scored').allInnerTexts();
      const said = rows.find((r) => /bet/i.test(r));
      return said || null;
    }, { label: 'the bet to settle in the chain', timeout: 15000 }).catch(() => null);
    check(settled !== null && /bet won/i.test(settled),
          'the chain says the bet came home', String(settled));

    const livesAfter = await livesOf();
    check(livesBefore !== null && livesAfter === livesBefore + 1,
          'and the life is on the scoreboard', `${livesBefore} → ${livesAfter}`);
  }

  check(consoleErrors.length === 0, 'no javascript errors on the page',
        consoleErrors.slice(0, 3).join(' | '));
  await context.close();
}

/// A picture beside the place and a quirky fact under it.
///
/// The wire is tested elsewhere; what only exists here is the layout.  A
/// photograph arrives seconds after the row it belongs to is already drawn and
/// read, so the two things that can go wrong are both about that moment: the
/// row must gain a picture without losing the name beside it, and the chain
/// must not slide away from the newest place while it grows.
async function testPictures(browser) {
  console.log('\npictures and facts');
  const { context, page } = await phone(browser);
  const consoleErrors = [];
  page.on('pageerror', (e) => consoleErrors.push(String(e)));

  await page.goto(BASE, { waitUntil: 'networkidle' });
  await page.fill('#input-name', 'Krishna');
  await page.click('.options > summary');
  await page.selectOption('#opt-turn', '60');
  await page.selectOption('#opt-lives', '3');
  await page.click('#btn-quick');
  await until(() => visible(page, '#screen-game'),
              { label: 'the game screen', timeout: 15000 });

  // The client asks the server, over the real route, for a place the sweep has
  // seeded.  Everything after this is about drawing what came back.
  const fetched = await page.evaluate(async () => {
    await requestMedia([{ text: 'Sydney' }]);
    return app.media.get('sydney') || null;
  });
  check(fetched !== null, 'the page fetches a picture from the server',
        JSON.stringify(fetched));
  if (fetched) {
    // Against the seeded fixture the wording is known and pinned; against a
    // server holding a real harvest, Sydney's fact is something else entirely
    // and what matters is that a whole sentence arrived.  A data: URL for the
    // picture is what tells the two apart.
    const fact = String(fetched.fact || '');
    const seeded = String(fetched.image || '').startsWith('data:');
    check(seeded ? /1,056,006/.test(fact) : /^.{30,}[.!?]$/.test(fact.trim()),
          'and gets the quirky fact with it', fact.slice(0, 80));
  }

  // Put it on a real row, through the real render path: play a place, then let
  // its picture turn up late, exactly as it does in a game.
  await until(() => myTurn(page), { label: 'our turn', timeout: 40000 });
  const suggestion = await askHint(page);
  if (suggestion) {
    await page.fill('#input-place', suggestion);
    await page.press('#input-place', 'Enter');
  }
  await until(async () => (await page.locator('#chain .play').count()) > 0,
              { label: 'a place in the chain', timeout: 20000 });

  const late = await page.evaluate(async () => {
    const chain = document.getElementById('chain');
    const inner = document.getElementById('chain-inner');
    const frame = () => new Promise((r) => requestAnimationFrame(() => r()));
    const newest = app.chain[app.chain.length - 1];

    chain.scrollTop = chain.scrollHeight;         // reading the newest place…
    chain.dispatchEvent(new Event('scroll'));
    await frame();

    // Start the row bare, whatever the server happens to know.  Against the
    // seeded fixture the newest place has no record and this changes nothing;
    // against a server holding a real harvest it already has a photograph, and
    // a test that assumed otherwise was measuring the picture it began with.
    // The key goes into `mediaAsked` so the render does not simply fetch it
    // back before the count is taken.
    const key = newest.text.trim().toLowerCase();
    app.media.delete(key);
    app.mediaAsked.add(key);
    renderChain(chain, inner);
    await frame();
    // Counted on that row alone: on a server with a real library every other
    // row in the chain has a photograph of its own.
    const before = inner.lastElementChild.querySelectorAll('img.shot').length;

    // …and its photograph arrives a few seconds after it was played.
    app.media.set(newest.text.trim().toLowerCase(), {
      q: newest.text,
      name: newest.text,
      fact: 'It is known for a thing nobody expects.',
      image: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAA'
           + 'AfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      width: 640, height: 427,
    });
    renderChain(chain, inner);
    await frame(); await frame();

    const row = inner.lastElementChild;
    const shot = row.querySelector('img.shot');
    const place = row.querySelector('.place');
    const box = shot ? shot.getBoundingClientRect() : null;
    return {
      before,
      after: row.querySelectorAll('img.shot').length,
      pictured: row.classList.contains('pictured'),
      fact: (row.querySelector('.fact') || {}).textContent || '',
      // The picture sits beside the name, not on top of it.
      overlaps: box ? box.left < place.getBoundingClientRect().right : null,
      square: box ? Math.round(box.width) === Math.round(box.height) : null,
      width: box ? Math.round(box.width) : 0,
      // Every line of text belongs to the left of the picture — the picture
      // earns its size by having the whole height of the row to itself.
      factBeside: (box && row.querySelector('.fact'))
        ? row.querySelector('.fact').getBoundingClientRect().right <= box.left + 1
        : null,
      inside: box ? box.right <= row.getBoundingClientRect().right + 1 : null,
      nameVisible: place.getBoundingClientRect().width > 8,
      gap: Math.round(chain.scrollHeight - chain.scrollTop - chain.clientHeight),
      jumpHidden: document.getElementById('btn-jump').hidden,
    };
  });

  check(late.before === 0 && late.after === 1,
        'a picture arriving late is drawn into the row it belongs to',
        JSON.stringify(late));
  check(late.pictured && late.square && late.width >= 90,
        'it is a square picture, big enough to see', JSON.stringify(late));
  check(late.factBeside, 'with the fact beside it rather than under it',
        JSON.stringify(late));
  check(late.overlaps === false && late.nameVisible,
        'the place name still has its own room', JSON.stringify(late));
  check(late.inside, 'and the picture stays inside the row', JSON.stringify(late));
  check(/nobody expects/.test(late.fact), 'the quirky fact is under the geography',
        late.fact);
  check(late.gap < 2 && late.jumpHidden,
        'and the chain stays on the newest place while it grows',
        JSON.stringify(late));
  await shoot(page, '07-pictures');

  // A picture whose link has rotted must leave no trace: a broken-image glyph
  // in the middle of the chain looks like the game is broken.
  const rotted = await page.evaluate(async () => {
    const inner = document.getElementById('chain-inner');
    const newest = app.chain[app.chain.length - 1];
    app.media.set(newest.text.trim().toLowerCase(), {
      q: newest.text, name: newest.text, fact: '',
      image: '/api/photo/definitely-not-here.png', width: 10, height: 10,
    });
    renderChain(document.getElementById('chain'), inner);
    await new Promise((r) => setTimeout(r, 1200));
    const row = inner.lastElementChild;
    return { shots: row.querySelectorAll('img.shot').length,
             pictured: row.classList.contains('pictured') };
  });
  check(rotted.shots === 0 && !rotted.pictured,
        'a picture that will not load removes itself', JSON.stringify(rotted));

  check(consoleErrors.length === 0, 'no javascript errors on the page',
        consoleErrors.slice(0, 3).join(' | '));
  await context.close();
}

async function testTwoPhones(browser) {
  console.log('\ntwo phones at one table');
  const hostPhone = await phone(browser);
  const guestPhone = await phone(browser);
  const { page: host } = hostPhone;
  const { page: guest } = guestPhone;

  await host.goto(BASE, { waitUntil: 'networkidle' });
  await host.fill('#input-name', 'Host');
  await host.click('#btn-create');
  await until(() => visible(host, '#screen-lobby'), { label: 'the lobby' });
  const code = (await text(host, '#lobby-code')).trim();
  check(/^[A-Z0-9]{4,6}$/.test(code), 'the lobby shows a table code', code);
  await shoot(host, '05-lobby');

  await guest.goto(BASE, { waitUntil: 'networkidle' });
  await guest.fill('#input-name', 'Guest');
  await guest.fill('#input-code', code);
  await guest.click('#btn-join');
  await until(() => visible(guest, '#screen-lobby'), { label: "the guest's lobby" });

  // The host's roster is only updated by a push, so this is the two-device
  // path end to end: guest joins → server broadcasts → host's DOM changes.
  const rosterGrew = await until(async () => {
    const names = await host.locator('#lobby-roster li').allInnerTexts();
    return names.some((n) => n.includes('Guest')) ? names : null;
  }, { label: 'the host to see the guest', timeout: 15000 }).catch(() => null);
  check(!!rosterGrew, 'the host sees the guest arrive', JSON.stringify(rosterGrew));

  check(!(await visible(guest, '#btn-start')), 'only the host is offered Start');

  await host.click('#btn-start');
  await until(() => visible(host, '#screen-game'), { label: "the host's game" });
  const guestStarted = await until(() => visible(guest, '#screen-game'),
                                   { label: "the guest's game", timeout: 15000 })
    .then(() => true, () => false);
  check(guestStarted, 'starting the game moves both phones to the board');

  // Exactly one of the two may type at any moment.
  const composers = await Promise.all([host, guest].map(myTurn));
  check(composers.filter(Boolean).length === 1,
        'exactly one phone has the turn', JSON.stringify(composers));

  const active = composers[0] ? host : guest;
  const idle = composers[0] ? guest : host;

  // The phone without the turn keeps its input — removing it would drop the
  // keyboard — but is dimmed and told who it is waiting for.
  check(await visible(idle, '#composer'),
        'the waiting phone keeps its composer on screen');
  const idlePlaceholder = await idle.getAttribute('#input-place', 'placeholder');
  check(/is playing/i.test(idlePlaceholder ?? ''),
        'the placeholder names who it is waiting for', String(idlePlaceholder));
  check(/is thinking/i.test((await text(idle, '#turn-name')).trim()),
        'the banner names who is thinking', (await text(idle, '#turn-name')).trim());

  // The server still has to refuse an out-of-turn move, in case a stale phone
  // posts one anyway.
  const refusal = await idle.evaluate(async ([room, player]) => {
    const response = await fetch(`/api/room/${room}/submit`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ playerID: player, text: 'Sydney' }),
    });
    return response.json();
  }, [code, await idle.evaluate(
      () => JSON.parse(localStorage.getItem('atlas.session') || '{}').playerID)]);
  check(refusal.ok === false, 'the server refuses an out-of-turn move', JSON.stringify(refusal));

  // A real move on one phone must show up in the other's chain.
  const suggestion = await askHint(active);
  if (check(!!suggestion, 'the hint button suggests a place')) {
    await active.fill('#input-place', suggestion);
    await active.press('#input-place', 'Enter');
    const echoed = await until(async () => {
      const body = await idle.locator('#chain').innerText();
      return body.toLowerCase().includes(suggestion.toLowerCase());
    }, { label: 'the move to reach the other phone', timeout: 15000 })
      .then(() => true, () => false);
    check(echoed, `"${suggestion}" appears on the other phone`);
  }
  await shoot(guest, '06-two-players');

  // Safari discards a backgrounded tab and reloads it when you come back.  The
  // phone must find its way into the same seat at the same table, chain and
  // all, without the player doing anything.
  const chainBefore = await guest.locator('#chain .play').count();
  await guest.reload({ waitUntil: 'networkidle' });
  const resumed = await until(() => visible(guest, '#screen-game'),
                              { label: 'the reloaded phone to rejoin', timeout: 20000 })
    .then(() => true, () => false);
  check(resumed, 'a reloaded phone rejoins its game by itself');
  if (resumed) {
    const chainAfter = await guest.locator('#chain .play').count();
    check(chainAfter >= chainBefore, 'the chain survives the reload',
          `${chainBefore} before, ${chainAfter} after`);
    const stillTwo = await host.locator('#game-players .pchip').count();
    check(stillTwo === 2, 'the other phone still sees both players', `chips=${stillTwo}`);
  }

  await hostPhone.context.close();
  await guestPhone.context.close();
}

async function testInstallable(browser) {
  console.log('\nadd to home screen');
  const { context, page } = await phone(browser);
  await page.goto(BASE, { waitUntil: 'networkidle' });

  const manifestHref = await page.getAttribute('link[rel="manifest"]', 'href');
  check(!!manifestHref, 'the page links a web app manifest');
  const manifest = await page.evaluate(async (href) => {
    const r = await fetch(href);
    return r.ok ? r.json() : null;
  }, manifestHref);
  check(manifest?.display === 'standalone',
        'the manifest asks for a standalone window', JSON.stringify(manifest?.display));
  check((manifest?.icons ?? []).length > 0, 'the manifest ships an icon');

  const meta = await page.getAttribute('meta[name="viewport"]', 'content');
  check(/width=device-width/.test(meta ?? ''), 'the viewport is set for a phone', meta ?? '');

  // Nothing may spill sideways on the narrowest phone in circulation.
  await page.setViewportSize({ width: 320, height: 568 });
  await page.waitForTimeout(300);
  const overflow = await page.evaluate(() =>
    document.documentElement.scrollWidth - document.documentElement.clientWidth);
  check(overflow <= 1, 'the layout does not scroll sideways at 320px', `overflow=${overflow}px`);
  await shoot(page, '07-narrow');
  await context.close();
}

// --------------------------------------------------------------------------

async function main() {
  await rm(SHOTS, { recursive: true, force: true });
  await mkdir(SHOTS, { recursive: true });

  const health = await fetch(`${BASE}/api/health`).then((r) => r.json()).catch(() => null);
  if (!health?.ok) {
    console.error(`no atlas server at ${BASE} — start one with: swift run atlas serve`);
    process.exit(2);
  }
  console.log(`browser tests against ${BASE}  (${health.places} places)`);

  const browser = await webkit.launch({ headless: !HEADED });
  try {
    await testSoloGame(browser);
    await testWager(browser);
    await testPictures(browser);
    await testTwoPhones(browser);
    await testInstallable(browser);
  } catch (error) {
    check(false, 'the suite ran to the end', String(error));
  } finally {
    await browser.close();
  }

  console.log(`\n${checks - failures.length}/${checks} checks passed`);
  if (failures.length) {
    console.log(`\x1b[31mfailed:\x1b[0m ${failures.join(', ')}`);
    process.exit(1);
  }
  console.log('\x1b[32mall good\x1b[0m — screenshots in tools/shots/');
}

await main();
