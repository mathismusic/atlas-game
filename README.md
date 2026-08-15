# Atlas

The playground game: someone says **Sydney**, the next person has to name a place
starting with **Y** — Yemen — then **N**, and so on. Say nothing in time and you
lose a life. No place twice. A place is worth a point, and every place tells you
one line about itself, so a game leaves you knowing where Lubumbashi is.

This is that game for a phone. A small Swift server runs on your Mac and holds
the game; everyone else joins from a browser on the same Wi-Fi.

```
swift run -c release atlas serve
```

```
  Atlas is running.  5052 places in the book.

    on this Mac      http://localhost:8080
    from your phone  http://192.168.1.24:8080
```

Open that second address on the phone. Tap **Share → Add to Home Screen** and it
gets an icon and runs full screen, no browser chrome.

## Playing

- **Quick play** deals you a bot straight away — pick easy, medium or hard.
- **New room** gives you a four-letter code. Anyone on the Wi-Fi types the code
  to join; the host picks the table and how many bots fill it. Bots and people
  mix freely, so one phone and three bots is a game and so is four phones.
- **Hint** shows a few places that would work, if you want the easy life.
- **Points** are one a place, more when you meet a card. The strip along the top
  keeps the score; the end screen ranks everyone by it.
- **Every place explains itself** in a line under the name — which country, which
  side of it, and what is spoken there: *Chiclayo is a city in north-west Peru,
  where Spanish is spoken.*
- **And shows itself.** A photograph of the place sits at the end of its row,
  with a quirky fact under the geography — *Its opera house is roofed with
  1,056,006 tiles, in two shades of cream.* Both arrive on their own a moment
  after the move; nothing waits for them, and a place with neither just looks
  like it always did.
- **Nobody is out on a dead letter.** When the clock runs out, Ada says what she
  would have played — *Ada would have said Qom* — and that costs you a life, as
  it always has. But if even she has nothing, the letter was the problem, not
  you: the place that led there is taken back, its points with it, and the
  player who said it plays again from the letter before. You only ever lose a
  life for missing a place that was there.
- **Challenge** is for when the atlas is wrong. Type a place it refuses, press
  *Challenge*, and the server asks Wikipedia: it wants a real article, with map
  coordinates, that reads like a geography article rather than a person or a
  band. A name with several meanings is followed through — *Tanga* is a list of
  meanings, so the port under *Tanga, Tanzania* is what answers. If the place
  checks out, the move stands **and the place is added
  permanently** — it is in the atlas for every game after this one. The clock is
  paused while the lookup runs, so a challenge never costs you the turn. If
  Wikipedia cannot be reached it says so rather than calling your place fake,
  and does not hold the failure against the name — challenge again. There is no
  ration on challenges: the atlas being wrong is not your fault, and charging
  you to fix it only teaches people to stop reporting it.
- **Bet a life** when you fancy your chances. Pressing 🎲 on your turn deals you
  a hard card there and then: meet it and you take five times the points *and*
  the life back, miss it and the life is gone. See below.

Learned places live in `~/.atlas/learned.json`. Delete that file to forget them.

## Cards

A card is one extra condition on top of the letter, dealt for a single turn:
*ends in a vowel*, *nine letters or more*, *somewhere in South America*, *has a
double letter*, *a place where Portuguese is spoken*, *avoid the letter E*. 83
of them, and the numeric ones fan out over their ranges, so you are not looking
at the same six cards by the third game.

Meeting one multiplies the move — ×2 easy, ×3 medium, ×5 hard — and a hard card
also hands you **an extra life**, banked for later. Ignoring one costs nothing:
the move still scores its point. That is the ordinary table. At a **forced**
table the card is the rule, and a place that does not meet it is refused.

Cards are checked against the letter in play *before* being dealt: a card is
only offered if enough unplayed places on this letter satisfy it, and only
counts as hard if hardly any do. So the banner's "14 fit" is a real count, and a
forced card can never be a sentence with no answer.

### Betting a life

A bet is not a new kind of scoring, only a card you asked for and are allowed to
fail. Press **🎲 Bet a life** on your turn and a hard card is dealt immediately;
it pays exactly what a hard card always pays — ×5 and a life — and if you miss
it the staked life is taken instead. The move itself still scores its point.

The details that matter at the table:

- The button only appears when the server would take the bet, so pressing it
  can never be refused for a reason you could not see. Both come from the same
  function, and a property test holds them together.
- **One bet a turn**, by the player whose turn it is, and never by a bot.
- A wagered card is **never a rule**, even at a forced table. Being free to miss
  it is the entire wager.
- Running out of time **voids** the bet rather than doubling the punishment: the
  clock takes its usual life and the stake goes back.
- A card is only offered if a hard one exists for the letter in play — worked
  out without touching the dealer's randomness, or merely drawing the button
  would change which cards the rest of the game gets.
- The table can switch bets off; **Classic** does, having no deck to bet on.

### Tables

The host picks one and the rest follows; anything you set by hand on top of it
wins.

| | |
|---|---|
| **Classic** | Just the letters. 30 seconds. |
| **Cards** | Cards appear. Meet one for bonus points. |
| **Forced cards** | 35 seconds, and every turn has a rule you must obey. |
| **Blitz** | 15 seconds, tightening by half a second a round, floor of 6. |
| **Marathon** | 45 seconds, three lives, cards half the time. |
| **Brutal** | 12 seconds, one life, forced cards, and the clock still tightens. |
| **Sudden death** | One life each, a 25-second clock, and a bet is the only way to win one back. |

## The atlas

5052 places, 5252 spellings — countries, capitals, big cities, and the rivers,
seas, deserts, islands and mountains people actually name. Deliberately not
exhaustive: a gazetteer of every hamlet on earth turns the game into a
lookup contest. Everything carries a **fame** score, which is what bot
difficulty is made of — an easy bot only reaches for household names, a hard one
uses the whole book.

The book is filled three ways at once, because population alone is a bad
measure of whether a player has heard of somewhere: the most famous places on
earth, then *every* seat of government down to the state and province level, then
a floor of several places for every country. That last rule is why Aizawl,
Imphal, Kohima and Gangtok are in here alongside Tokyo, and why no country is
represented by its capital alone.

Names people really say are aliases of one place, so *Bombay* and *Mumbai* are
the same place and cannot both be played — but the chain follows what you typed,
so saying Bombay hands the next player a **Y**. *Mount Everest* and *Everest*
likewise, on **M** and on **E**.

To rebuild it from the source data (GeoNames + a curated list):

```
python3 tools/build_atlas.py          # rewrites Sources/AtlasCore/Resources/atlas.json
```

## Testing

There is no Xcode on this machine, so there is no XCTest and `swift test` cannot
run. The suite is an ordinary executable instead:

```
swift run atlastests            # 193 tests: rules, clock, atlas, bots, cards,
                                #            bets, pictures, HTTP
swift run atlastests server     # or just one suite, by name
```

Beyond that:

```
swift run -c release atlas sim --games 500 --seats mixed   # virtual-clock games,
                                                           # invariants checked
                                                           # after every move
swift run -c release atlas soak --seconds 45 --threads 12  # one game, hammered
                                                           # from many threads
python3 tools/e2e.py                                       # against a live server
python3 tools/e2e.py --online                              # …including a real
                                                           # Wikipedia challenge
node tools/ui_test.mjs                                     # the real phone UI,
                                                           # in WebKit
zsh tools/linux_build.sh                                   # does it still
                                                           # compile for the
                                                           # server it deploys to
```

`zsh tools/sweep.sh` runs every one of those in order, from a clean build, over
seven different tables, and leaves the server up at the end. Allow it about
forty minutes — most of that is the 1900 simulated games, which got three times
slower when the atlas grew to five thousand places, because every card is
checked for feasibility against every unplayed place on the letter.

`sim` is the important one: the engine takes the time as an argument rather than
reading a clock, so a whole game can be played in microseconds and the same code
paths run in a real match. It takes the table apart with flags, so the awkward
corners get played thousands of times each:

```
atlas sim --games 300 --cards 1 --forced-cards   # every turn a rule
atlas sim --games 300 --turn 12 --decay 0.5 --tiers hard
atlas sim --games 300 --no-rescue                # the dead-letter rule off
atlas sim --games 300 --lives 1 --turn 25        # sudden death, bets and all
```

Every state it passes through is checked against the same list of invariants:
the chain follows its letters, no place twice, the clock only moves forward,
nobody plays out of turn, a forced card was actually obeyed, a bet was always
against a hard card, and the scoreboard is exactly the moves added up. That last one caught a real bug within a minute
of being written — a rematch revived the players but kept their old scores.

Running the whole challenge catalogue against the live encyclopedia is what
turned up the worst bugs in it, and they were all one bug wearing hats: the
description was searched for disqualifying words anywhere rather than as whole
words, so every Polish city was refused for being a **ship** — the word hides
inside *Voivodeship* — Songkhla was a **song**, Lubango was a **band** by way of
Sá da Bandeira, and every American township was a ship too. Under it were three
more: a rate-limited lookup announced that Oaxaca does not exist *and cached the
verdict*, a name with several meanings gave up at the disambiguation page
instead of reading on to the place, and provincial seats went into the atlas as
national capitals.

`ui_test.mjs` drives the app the way a thumb does — WebKit at an iPhone 13
viewport, two independent browser contexts for two phones — and is the only
layer that sees the browser itself. It has already caught three things nothing
else could: a CSS rule that defeated the `hidden` attribute, leaving the input
box on screen during the opponent's turn, a toast that swallowed taps aimed
at the Challenge button, and a card banner that silently unpinned the chain —
the banner shortens the scroller without moving its contents, so the newest
place slid out of view and the app read that as the player having scrolled
away, which is why you had to press *newest* every time a card turned up. It is also the only place that can prove the two things
a phone is judged on — that the caret stays in the box while the computer
answers, so you can type straight back, and that the list of places scrolls
inside itself while the clock stays nailed to the top. Playwright is vendored in `tools/browser/`, so it runs
with nothing installed globally; if the WebKit binary is ever missing, `npx
playwright install webkit` puts it back. Screenshots of every screen land in
`tools/shots/`.

## Pictures and facts

Five thousand places is far too many to write by hand, so the server collects
them itself: one Wikipedia lookup a second, in the background, famous places
first, while people play. Nothing in the game waits on it — a place with no
picture yet simply has no picture, and gets one for the next game.

```
atlas media --limit 5000 --interval 0.4   # fill the file in one go
atlas media status                        # how far it has got
atlas serve --no-harvest                  # serve, but collect nothing
```

Four things about it are less obvious than they look, and every one was found by
harvesting real places and reading the output — no unit test would have caught
any of them, though each is pinned by one now:

- **A flag is not a photograph.** Country articles lead with one, so taking the
  lead image gave two hundred flags and coats of arms. Drawings are now rejected
  by name, and a country with no photograph of its own borrows its **capital's**
  — the country's article, read further down, offers battle paintings and
  16th-century engravings, which are worse than nothing.
- **The summary endpoint is the wrong endpoint.** `/page/summary` is *defined* to
  return two or three sentences, and the first of them is the definition the game
  has just said out loud. One place in three had a fact. Asking the action API
  for the whole lead section instead — along with the picture, the URL and the
  disambiguation flag, in the same request — took that to nine in ten.
- **A superlative is not a fact.** "X is the capital and largest city" appears in
  almost every country article and is exactly what the game already tells you, so
  that phrasing is thrown out by name while genuine superlatives — *the world's
  flattest and driest inhabited continent* — survive. Economics goes with it: a
  GDP ranking is written with *largest* too, and is never the interesting bit.
- **A whole lead reaches the wars.** Two sentences never did. Three hundred real
  places came back with Goma occupied by the M23 rebels, the Anglo-Afghan wars,
  Juche, Gaza, and Niger being one of the poorest countries in the world — every
  one scored as quotable, because *the site of* and *one of the* are exactly the
  phrases that make a sentence worth repeating. Violence, rule, hardship and
  empire are refused outright now, and a place with nothing else to say keeps its
  picture and says nothing. Silence is the right answer: this is a party game.

- **An acronym is not a full stop.** Rhode Island's whole fact was once *Rhode
  Island is the smallest U.S.* — the stop after the S ended the sentence. It
  cannot simply be refused either, because a lead really does often end on one
  (*…the deepest lake in the U.S. The state is also…*), so the capital that
  follows decides, and the football clubs — *C.D. Guadalajara*, *Wigan Athletic
  F.C.* — are refused outright, being never the last thing said.

The filters are narrow on purpose, and the tests say why — *Warsaw is not a war*,
*a penguin colony is still a colony*, *a superlative outranks the statistic
beside it*, *but a sentence may still end on one*.

Across the whole atlas that comes to **4271 pictures and 2148 facts out of 5053
places** — 84% and 42%. The two numbers are far apart because they fail
differently: almost every place has *a* photograph, but only some have an article
that says anything beyond where they are and how many people live there. The
famous end does much better than the average — the first three hundred places, in
fame order, come back around 74% — so the places that actually come up in a game
are well covered, and the long tail shows a picture and its geography with no
fact under it. That is the intended outcome. A place with nothing to say says
nothing.

The file lives in `$ATLAS_DATA_DIR/media.json` (`~/.atlas` by default). A
read-only file baked into a deployment is loaded first from `$ATLAS_MEDIA`, and
anything learned afterwards goes to the writable one.

## Hosting it

Same server, in a container. Everything needed is here: a two-stage `Dockerfile`
and a Render blueprint.

```
docker build -t atlas . && docker run -p 8080:8080 atlas
```

Start to finish, on **Render** — this directory is not a git repository yet, so
step one is real:

`deploy/media.json` is already here and already full, so the first two lines are
only needed to refresh it:

```
./.build/release/atlas media                   # once, ~50 minutes
cp ~/.atlas/media.json deploy/media.json       # 1.3 MB, 5052 places

git init && git add -A && git commit -m "Atlas"
gh repo create atlas --private --source=. --push   # or push to a repo you made
```

Then on render.com: *New → Blueprint*, point it at the repository, *Apply*.
`render.yaml` does the rest — free plan, Docker runtime, health check on
`/api/health` — and the first build takes about ten minutes, nearly all of it
compiling Swift. You get an `https://…onrender.com` address that works from any
phone, anywhere, not just your Wi-Fi. Fly.io, Railway and Cloud Run take the
same `Dockerfile` if you would rather.

There is no Docker on this Mac, so the image itself has not been built here —
but the part that would actually fail has been checked: `zsh
tools/linux_build.sh` cross-compiles the server for Linux, x86-64 and arm64,
and it found four bugs that were invisible on a Mac. `Darwin.close` names a
module that does not exist elsewhere; `sa_family` is a byte on Darwin and a
short on Linux; `sa_len` is a BSD field glibc has never had; and `usleep` needs
a C library import that Foundation does not imply. The conditionals now test
for three C libraries rather than two, because the static Linux SDK is musl and
a `canImport(Glibc)`/`#else` pair silently picks *Darwin* under it.

What a free tier means in practice:

- The container **stops after about fifteen minutes** of no requests, and the
  next visitor waits half a minute for it to wake. The game itself does not
  survive that — an idle room is gone. Rooms are in memory by design; the state
  is small enough to persist later if it ever matters.
- The disk is **wiped on every restart**, so anything written to
  `$ATLAS_DATA_DIR` is scratch. This is why the atlas is compiled into the binary
  and the pictures are baked into the image: a cold start comes up complete. What
  *is* lost is `learned.json`, the places players added by challenge. A paid disk
  mounted at `/data` keeps them.
- Three environment variables are all the configuration there is: `PORT` (the
  platform sets it; the server reads it), `ATLAS_PUBLIC_DIR` (the web client,
  which lives in a SwiftPM bundle on a Mac and in a plain directory in the
  image), and `ATLAS_DATA_DIR`.

`deploy/media.json` ships with the image, so pictures are there from the first
game rather than trickling in over the first hour. Refresh it by running `atlas
media` and copying the result over. It matters more on a free tier than on a
laptop: the disk is ephemeral, so anything the container harvests for itself is
thrown away the next time it spins down.

### GitHub Pages, and the App Store

**GitHub Pages cannot host this.** Pages serves static files only, and Atlas is
a *server*: it holds the rooms, runs the clocks, deals the cards and asks
Wikipedia. A static host has nowhere to run any of that. (The web client alone
could sit on Pages while the server lives elsewhere, but there is no reason to
split them — the server serves it fine.)

**The App Store is a real option, but not from this machine.** `AtlasCore` was
kept deliberately portable for exactly this — no UI, no networking, no ambient
clock, every entry point taking `now:` — so a SwiftUI app can sit straight on
top of it and play offline against bots, with the server only needed for rooms.
What is missing is the toolchain: building for iOS needs Xcode and the iOS SDK,
neither of which is installed here, and there is no simulator, no code signing
and no way to submit. It also needs an Apple Developer account (\$99 a year) and
a review pass. The path is: install Xcode → add an iOS app target on top of
`AtlasCore` → point it at the deployed server for online rooms → TestFlight →
submit. Everything before "install Xcode" is already done.

## Other commands

```
atlas play  [--difficulty hard] [--mode blitz]   play in the terminal, no browser
                                              (`?` hints, `$` bets a life,
                                               `!name` challenges)
atlas verify <place>                          ask Wikipedia about one place
atlas stats                                   what is in the book
atlas media [status] [--limit N]              pictures and facts, from Wikipedia
atlas serve --offline                         no network; challenges are refused
atlas serve --no-harvest                      serve without collecting pictures
```

## How it fits together

```
Sources/AtlasCore     the game: rules, clock, bots, cards, tables, atlas,
                      Wikipedia lookups.  No UI, no networking, no ambient time —
                      every entry point takes `now:`.  A SwiftUI app could sit
                      straight on top.
Sources/AtlasServer   a dependency-free HTTP/1.1 server, rooms, and server-sent
                      events for pushing state to the phones.
Sources/AtlasServer/Public   the web client: three files, no build step, no
                      framework.
Sources/atlas         the command line.
Dockerfile, render.yaml, deploy/   the same server, hosted.
```

The client polls nothing: the server pushes the whole game state over an
`EventSource` whenever it changes, and the phone renders it. Turn timers are
drawn from a deadline the server sends, so a slow phone never disagrees with the
table about whose turn it is.

Requires Swift 6 (`swift --version`); the command-line tools are enough.
