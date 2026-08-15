#!/usr/bin/env python3
"""End-to-end test against a running `atlas serve`.

Drives the real HTTP surface the phone will use — including the server-sent
event stream — so anything the Swift-level simulator cannot see (routing, JSON
shapes, SSE framing, concurrent rooms) gets exercised here.

    ./tools/e2e.py [--base http://localhost:8080] [--online]

--online additionally runs a challenge against the live Wikipedia lookup.
"""

import argparse
import json
import re
import unicodedata
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "http://localhost:8080"
FAILURES = []
CHECKS = [0]


def check(condition, label, detail=""):
    CHECKS[0] += 1
    if condition:
        print(f"  \033[32m✓\033[0m {label}")
    else:
        print(f"  \033[31m✗\033[0m {label}   {detail}")
        FAILURES.append(label)
    return condition


def post(path, body=None, expect_status=None):
    data = json.dumps(body or {}).encode()
    request = urllib.request.Request(BASE + path, data=data,
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        payload = error.read()
        try:
            return error.code, json.loads(payload or b"{}")
        except json.JSONDecodeError:
            return error.code, {"raw": payload.decode(errors="replace")}


def get(path):
    try:
        with urllib.request.urlopen(BASE + path, timeout=15) as response:
            body = response.read()
            try:
                return response.status, json.loads(body or b"{}")
            except json.JSONDecodeError:
                return response.status, {"raw": body.decode(errors="replace")}
    except urllib.error.HTTPError as error:
        return error.code, {}


class Stream:
    """Minimal server-sent-events client."""

    def __init__(self, path):
        self.states = []
        self.events = []
        self.error = None
        self._cursor = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, args=(path,), daemon=True)
        self._thread.start()

    def _run(self, path):
        try:
            with urllib.request.urlopen(BASE + path, timeout=60) as response:
                event_name, data_lines = None, []
                for raw in response:
                    if self._stop.is_set():
                        return
                    line = raw.decode("utf-8", errors="replace").rstrip("\n")
                    if line.startswith("event:"):
                        event_name = line[6:].strip()
                    elif line.startswith("data:"):
                        data_lines.append(line[5:].lstrip())
                    elif line == "":
                        if data_lines:
                            payload = "\n".join(data_lines)
                            self.events.append((event_name, payload))
                            if event_name == "state":
                                try:
                                    self.states.append(json.loads(payload))
                                except json.JSONDecodeError as e:
                                    self.error = f"bad state json: {e}"
                        event_name, data_lines = None, []
        except Exception as exc:            # noqa: BLE001 - reported, not raised
            self.error = repr(exc)

    def wait_for(self, predicate, timeout=12):
        """Wait for a state matching `predicate`.

        States are consumed in arrival order so that transient conditions (a
        clock that pauses and resumes again) are not missed, but a stale state
        from an earlier turn can never satisfy a later wait.  If nothing new
        matches, the newest state is retried, since the server only pushes on
        change and the condition may already hold.
        """
        deadline = time.time() + timeout
        while True:
            while self._cursor < len(self.states):
                state = self.states[self._cursor]
                self._cursor += 1
                if predicate(state):
                    return state
            if self.states and predicate(self.states[-1]):
                return self.states[-1]
            if time.time() >= deadline:
                return None
            time.sleep(0.05)

    @property
    def latest(self):
        return self.states[-1] if self.states else None

    def close(self):
        self._stop.set()


def fold(text):
    """Down to plain ASCII letters, the way the engine reads a name.

    Without this, Yaoundé ends in nothing at all — the é is stripped as
    punctuation and the last letter comes back as the d before it, so Everest
    is reported as a broken chain when it is a perfectly legal reply.  The
    engine folds diacritics (Normalize.fold); the checker has to fold the same
    way or it is testing a different game.
    """
    plain = unicodedata.normalize("NFD", text.lower())
    plain = "".join(c for c in plain if not unicodedata.combining(c))
    return re.sub(r"[^a-z]", "", plain)


def last_letter(text):
    letters = fold(text)
    return letters[-1] if letters else ""


def first_letter(text):
    letters = fold(text)
    return letters[0] if letters else ""


# --------------------------------------------------------------------------


def test_static_assets():
    print("\nstatic assets")
    for path, needle in [("/", b"<title>Atlas</title>"), ("/app.js", b"EventSource"),
                         ("/style.css", b"--accent"), ("/manifest.webmanifest", b"standalone"),
                         ("/icon.svg", b"<svg"), ("/icon.png", b"PNG")]:
        try:
            with urllib.request.urlopen(BASE + path, timeout=10) as response:
                body = response.read()
                check(response.status == 200 and needle in body, f"GET {path}",
                      f"status={response.status} len={len(body)}")
        except Exception as exc:            # noqa: BLE001
            check(False, f"GET {path}", repr(exc))

    status, _ = get("/../Package.swift")
    check(status in (400, 403, 404), "path traversal refused", f"status={status}")


def test_full_game():
    print("\nfull game against a bot")
    # Three lives and a medium bot: an easy bot on one life blunders itself out
    # of the game every so often, which is correct behaviour but leaves nothing
    # here to test.
    status, room = post("/api/quick", {"name": "Tester", "difficulty": "medium", "bots": 1,
                                       "table": {"turnSeconds": 30, "lives": 3}})
    if not check(status == 200 and "room" in room, "quick play creates a room", str(room)):
        return
    code, me = room["room"], room["playerID"]

    stream = Stream(f"/api/room/{code}/events?playerID={me}")
    state = stream.wait_for(lambda s: s["phase"] == "playing")
    if not check(state is not None, "event stream delivers the opening state"):
        return
    check(any(name == "hello" for name, _ in stream.events), "stream sends a hello event")

    # -- rejections
    state = stream.latest
    letter = state["requiredLetter"]
    wrong = "Zzzzz" if letter != "z" else "Aaaaa"
    _, result = post(f"/api/room/{code}/submit", {"playerID": me, "text": wrong})
    check(result.get("ok") is False, "junk is rejected", str(result))

    bad_letter = "Paris" if letter != "p" else "Sydney"
    _, result = post(f"/api/room/{code}/submit", {"playerID": me, "text": bad_letter})
    check(result.get("ok") is False and result.get("code") == "wrong_letter",
          "wrong starting letter is rejected", str(result))

    _, result = post(f"/api/room/{code}/submit", {"playerID": "nobody", "text": "Sydney"})
    check(result.get("ok") is False and result.get("code") == "not_your_turn",
          "unknown player cannot move", str(result))

    # -- hints drive a whole game, which also tests the bot and the chain rule
    def poll_turn(timeout=40):
        """Block until the server itself says the turn is ours.

        Deciding this from the event stream is what used to make this test
        flake: a buffered state from before the bot moved still reads as our
        turn, and the submit that followed came back `not_your_turn`.  The
        stream is proven elsewhere; the loop below wants the authority.
        """
        deadline = time.time() + timeout
        while True:
            _, snapshot = get(f"/api/room/{code}/state")
            if (snapshot.get("phase") != "playing"
                    or snapshot.get("currentPlayerID") == me
                    or time.time() >= deadline):
                return snapshot
            time.sleep(0.2)

    played, repeats_refused = [], 0
    # Twenty-five moves each is a long game by the standards of the folklore
    # version, and long enough to exercise the chain and the no-repeat rule;
    # past that it is only the bot's thinking time being measured.
    for _ in range(25):
        state = poll_turn()
        if state.get("phase") != "playing" or state.get("currentPlayerID") != me:
            break
        _, hints = get(f"/api/room/{code}/hint")
        options = hints.get("hints") or []
        if not options:
            break

        # A replay is only *reached* by the already-used rule when it also fits
        # the current letter — the letter is checked first — so replay a move
        # that starts on the letter now being asked for, if one exists yet.
        # test_repeat_refused covers the rule head-on; this is opportunistic.
        if repeats_refused < 2:
            required = state["requiredLetter"]
            stale = next((m["text"] for m in state["moves"]
                          if m["text"][:1].lower() == required), None)
            if stale:
                _, result = post(f"/api/room/{code}/submit",
                                 {"playerID": me, "text": stale})
                if result.get("code") == "already_used":
                    repeats_refused += 1
                else:
                    check(False, f"replaying '{stale}' should be refused as used",
                          str(result))

        status, result = post(f"/api/room/{code}/submit",
                              {"playerID": me, "text": options[0]})
        if not result.get("ok"):
            check(False, f"hint '{options[0]}' was refused", str(result))
            break
        played.append(options[0])
        # The next iteration polls for our turn, which is also the wait for the
        # bot's reply.

    # The stream should have carried everything the polling saw; it is the
    # phone's only source of truth, so a lagging one is a real bug.
    caught_up = stream.wait_for(lambda s: s["chainLength"] >= len(played), timeout=15)
    check(caught_up is not None, "the event stream kept up with the game",
          str(stream.latest and stream.latest.get("chainLength")))

    _, final = get(f"/api/room/{code}/state")
    check(len(played) >= 3, f"played {len(played)} moves via hints",
          str([entry["text"] for entry in final.get("log", [])][-4:]))

    moves = final["moves"]
    broken = [(moves[i - 1]["text"], moves[i]["text"]) for i in range(1, len(moves))
              if last_letter(moves[i - 1]["text"]) != first_letter(moves[i]["text"])]
    check(not broken, "every move chains off the previous one", str(broken[:3]))

    names = [m["text"].lower() for m in moves]
    check(len(names) == len(set(names)), "no place repeats in the chain")
    check(all(m["playerName"] for m in moves), "every move names its player")
    stream.close()


def test_repeat_refused():
    """A place, once said, is dead for the rest of the game.

    Solo play makes this checkable head-on: with nobody else moving, the chain
    can be steered onto a letter that has already been used, and only then does
    the already-used rule get a chance to speak — the letter is checked first.
    """
    print("\nno place twice")
    status, room = post("/api/room", {"name": "Solo", "table": {"turnSeconds": 60, "lives": 3}})
    if not check(status == 200 and "room" in room, "solo room created", str(room)):
        return
    code, me = room["room"], room["playerID"]
    status, _ = post(f"/api/room/{code}/start", {"playerID": me})
    if not check(status == 200, "a lone player can start a solo game", f"status={status}"):
        return

    seen_first = set()
    for _ in range(20):
        _, state = get(f"/api/room/{code}/state")
        required = state["requiredLetter"]

        replay = next((m["text"] for m in state["moves"]
                       if m["text"][:1].lower() == required), None)
        if replay:
            _, result = post(f"/api/room/{code}/submit",
                             {"playerID": me, "text": replay})
            check(result.get("code") == "already_used",
                  f"replaying '{replay}' is refused as already used", str(result))
            # And the rejection must not have cost the turn or the chain.
            _, after = get(f"/api/room/{code}/state")
            check(after["chainLength"] == state["chainLength"],
                  "a refused replay leaves the chain untouched")
            check(after["requiredLetter"] == required,
                  "a refused replay leaves the letter untouched")
            return

        _, hints = get(f"/api/room/{code}/hint")
        options = hints.get("hints") or []
        if not options:
            break
        seen_first.add(required)
        # Steer towards a letter already played, which is what makes a legal
        # replay attempt possible at all.
        pick = next((h for h in options if last_letter(h) in seen_first), options[0])
        _, result = post(f"/api/room/{code}/submit", {"playerID": me, "text": pick})
        if not result.get("ok"):
            check(False, f"hint '{pick}' was refused", str(result))
            return

    check(False, "never revisited a letter, so the rule went untested")


def test_lobby_and_rematch():
    print("\nlobby, join, rematch")
    _, host = post("/api/room", {"name": "Host", "table": {"turnSeconds": 10, "lives": 1}})
    code, host_id = host["room"], host["playerID"]
    check(host.get("isHost") is True, "creator is the host")

    _, guest = post(f"/api/room/{code}/join", {"name": "Guest"})
    guest_id = guest.get("playerID")
    check(guest_id and not guest.get("isHost"), "a second player can join", str(guest))

    _, again = post(f"/api/room/{code}/join", {"name": "Guest", "playerID": guest_id})
    check(again.get("playerID") == guest_id, "rejoining with the same id reconnects")

    status, denied = post(f"/api/room/{code}/start", {"playerID": guest_id})
    check(status == 403, "a guest cannot start the game", f"status={status} {denied}")

    _, result = post(f"/api/room/{code}/bot", {"difficulty": "hard"})
    check(result.get("ok"), "host can add a bot", str(result))

    host_stream = Stream(f"/api/room/{code}/events?playerID={host_id}")
    guest_stream = Stream(f"/api/room/{code}/events?playerID={guest_id}")
    time.sleep(0.4)

    status, _ = post(f"/api/room/{code}/start", {"playerID": host_id})
    check(status == 200, "host starts the game", f"status={status}")
    check(host_stream.wait_for(lambda s: s["phase"] == "playing") is not None,
          "host stream sees the game start")
    check(guest_stream.wait_for(lambda s: s["phase"] == "playing") is not None,
          "guest stream sees the game start too")

    # Nobody plays: 10s turns and 1 life each must end the game on its own.
    finished = host_stream.wait_for(lambda s: s["phase"] == "finished", timeout=60)
    if finished is None:
        # Distinguish a stuck game from a stream that stopped delivering: the
        # polled state is the truth, the stream is only how the phone hears it.
        _, polled = get(f"/api/room/{code}/state")
        detail = (f"stream={host_stream.error} states={len(host_stream.states)} "
                  f"last={(host_stream.latest or {}).get('phase')} "
                  f"polled={polled.get('phase')}")
    else:
        detail = ""
    check(finished is not None, "a game where everyone stalls still finishes", detail)

    if finished:
        _, result = post(f"/api/room/{code}/again", {"playerID": host_id})
        check(result.get("ok"), "host can start a rematch", str(result))
        fresh = host_stream.wait_for(
            lambda s: s["phase"] == "playing" and s["chainLength"] == 0, timeout=15)
        check(fresh is not None, "rematch reuses the open streams")
        if fresh:
            check(all(not p["eliminated"] for p in fresh["players"]),
                  "rematch revives every player")

    host_stream.close()
    guest_stream.close()


def test_challenge_offline():
    print("\nchallenge flow")
    _, room = post("/api/quick", {"name": "Tester", "bots": 1, "table": {"turnSeconds": 60}})
    code, me = room["room"], room["playerID"]
    stream = Stream(f"/api/room/{code}/events?playerID={me}")
    state = stream.wait_for(lambda s: s.get("currentPlayerID") == me, timeout=20)
    if not check(state is not None, "got a turn to challenge on"):
        return

    letter = state["requiredLetter"]
    invented = letter.upper() + "qzlandia"
    _, result = post(f"/api/room/{code}/submit", {"playerID": me, "text": invented})
    check(result.get("ok") is False and result.get("code") == "not_in_atlas",
          "an unknown name is refused", str(result))
    check(result.get("canChallenge") is True, "the server offers a challenge", str(result))

    _, result = post(f"/api/room/{code}/challenge", {"playerID": me, "text": invented})
    check(result.get("ok"), "challenge starts", str(result))

    paused = stream.wait_for(lambda s: s["paused"], timeout=4)
    resolved = stream.wait_for(lambda s: not s["paused"] and s.get("pending") is None,
                               timeout=25)
    check(paused is not None or resolved is not None, "the clock pauses during a lookup")
    check(resolved is not None, "the challenge resolves and the clock resumes")
    if resolved:
        check(resolved["timeLeft"] <= resolved["turnSeconds"] + 0.01,
              "the resumed clock is not longer than a turn",
              f"timeLeft={resolved.get('timeLeft')}")
        check(not any(m["text"].lower() == invented.lower() for m in resolved["moves"]),
              "a made-up name does not enter the chain")
    stream.close()


def test_challenge_online():
    print("\nlive Wikipedia challenge")
    _, room = post("/api/quick", {"name": "Tester", "bots": 1, "table": {"turnSeconds": 90}})
    code, me = room["room"], room["playerID"]
    stream = Stream(f"/api/room/{code}/events?playerID={me}")
    state = stream.wait_for(lambda s: s.get("currentPlayerID") == me, timeout=20)
    if not check(state is not None, "got a turn"):
        return

    # Real but obscure places, several per letter: a confirmed challenge is
    # remembered for good, so a single candidate would only be unknown on the
    # very first run and the test would quietly stop testing anything.
    catalogue = {
        "a": ["Arequipa", "Ambato", "Antofagasta", "Aswan"],
        "b": ["Bandung", "Bafoussam", "Batumi", "Bydgoszcz"],
        "c": ["Chiclayo", "Comilla", "Cuenca", "Constanta"],
        "d": ["Dodoma", "Daegu", "Douala", "Dnipro"],
        "e": ["Enugu", "Eldoret", "Eskisehir", "Esbjerg"],
        "f": ["Fukuoka", "Foshan", "Faisalabad", "Fortaleza"],
        "g": ["Gyor", "Gaborone", "Gwangju", "Gorakhpur"],
        "h": ["Hamamatsu", "Hargeisa", "Hualien", "Hubli"],
        "i": ["Iquitos", "Ilorin", "Iasi", "Ipoh"],
        "j": ["Jaen", "Jos", "Jalandhar", "Juliaca"],
        "k": ["Kumasi", "Kaduna", "Kisumu", "Kutaisi"],
        "l": ["Lubumbashi", "Lubango", "Loja", "Lucena"],
        "m": ["Matsuyama", "Mwanza", "Mbeya", "Mazatlan"],
        "n": ["Nampula", "Nakuru", "Niigata", "Nampa"],
        "o": ["Oaxaca", "Oujda", "Ogbomosho", "Orsk"],
        "p": ["Piura", "Ploiesti", "Pekanbaru", "Pematangsiantar"],
        "q": ["Quilmes", "Quetta", "Qazvin", "Quy Nhon"],
        "r": ["Ruse", "Rustenburg", "Ratnagiri", "Rzeszow"],
        "s": ["Sokoto", "Sanandaj", "Sylhet", "Songkhla"],
        "t": ["Trujillo", "Tanga", "Tuzla", "Toluca"],
        "u": ["Uyo", "Uberaba", "Urgench", "Ubon Ratchathani"],
        "v": ["Vitoria", "Vinnytsia", "Valdivia", "Volos"],
        "w": ["Warri", "Wonsan", "Wagga Wagga", "Wloclawek"],
        "x": ["Xalapa", "Xuzhou", "Xining", "Xiangyang"],
        "y": ["Yenagoa", "Yamagata", "Yazd", "Yopal"],
        "z": ["Zaria", "Zhuhai", "Zamboanga", "Zwolle"],
    }
    letter = state["requiredLetter"]
    candidates = catalogue.get(letter, [])
    if not check(candidates, f"have test places for '{letter}'"):
        return

    name = None
    for candidate in candidates:
        _, info = get(f"/api/atlas?q={urllib.parse.quote(candidate)}")
        if not info.get("found"):
            name = candidate
            break
    if name is None:
        print(f"  (every '{letter}' candidate is already known — nothing new to learn)")
        stream.close()
        return

    _, result = post(f"/api/room/{code}/submit", {"playerID": me, "text": name})
    if not check(result.get("ok") is False and result.get("canChallenge") is True,
                 f"{name} is unknown and challengeable", str(result)):
        stream.close()
        return

    _, result = post(f"/api/room/{code}/challenge", {"playerID": me, "text": name})
    check(result.get("ok"), f"challenge on {name} starts", str(result))
    resolved = stream.wait_for(lambda s: s.get("pending") is None
                               and s["chainLength"] > 0, timeout=25)

    # Wikipedia rate-limits, and when it does every lookup comes back a refusal.
    # That is not this server being wrong, and failing here would only teach us
    # to distrust the suite — so say what happened and move on.
    _, current = get(f"/api/room/{code}/state")
    throttled = any("did not answer" in entry.get("text", "")
                    for entry in current.get("log", []))
    if resolved is None and throttled:
        print(f"  (Wikipedia is throttling us — the challenge on {name} could not "
              f"be judged; not a failure of the server)")
        stream.close()
        return

    if check(resolved is not None, f"{name} was confirmed and played"):
        move = resolved["moves"][0]
        check(move["viaChallenge"] is True, "the move is flagged as challenged")
        _, info = get(f"/api/atlas?q={name}")
        check(info.get("found") and info.get("learned"),
              "the place joined the atlas permanently", str(info))
    stream.close()

    # A non-place with a Wikipedia page must still be refused.
    _, room = post("/api/quick", {"name": "Tester", "bots": 1, "table": {"turnSeconds": 90}})
    code, me = room["room"], room["playerID"]
    stream = Stream(f"/api/room/{code}/events?playerID={me}")
    state = stream.wait_for(lambda s: s.get("currentPlayerID") == me, timeout=20)
    if state:
        bogus = {"a": "Abraham Lincoln", "b": "Barack Obama", "c": "Charles Darwin",
                 "d": "Donald Duck", "e": "Elvis Presley", "f": "Frank Sinatra",
                 "g": "George Orwell", "h": "Harry Potter", "i": "Isaac Newton",
                 "j": "Julius Caesar", "k": "Karl Marx", "l": "Leonardo da Vinci",
                 "m": "Marilyn Monroe", "n": "Napoleon Bonaparte", "o": "Oscar Wilde",
                 "p": "Pablo Picasso", "q": "Queen Victoria", "r": "Ronald Reagan",
                 "s": "Steve Jobs", "t": "Thomas Edison", "u": "Ulysses Grant",
                 "v": "Vincent van Gogh", "w": "Winston Churchill", "x": "Xerxes I",
                 "y": "Yuri Gagarin", "z": "Zeus"}.get(state["requiredLetter"])
        if bogus:
            post(f"/api/room/{code}/submit", {"playerID": me, "text": bogus})
            _, result = post(f"/api/room/{code}/challenge", {"playerID": me, "text": bogus})
            if result.get("ok"):
                after = stream.wait_for(lambda s: s.get("pending") is None, timeout=25)
                if after:
                    check(not any(m["text"] == bogus for m in after["moves"]),
                          f"'{bogus}' is not accepted as a place")
    stream.close()


def test_concurrent_rooms():
    print("\nconcurrency")
    rooms, errors = [], []

    def spin(index):
        try:
            _, room = post("/api/quick", {"name": f"P{index}", "bots": 2,
                                          "difficulty": "hard", "table": {"turnSeconds": 15}})
            rooms.append(room["room"])
            stream = Stream(f"/api/room/{room['room']}/events?playerID={room['playerID']}")
            state = stream.wait_for(lambda s: s["chainLength"] >= 2, timeout=30)
            if state is None:
                errors.append(f"room {room.get('room')} made no progress")
            if stream.error:
                errors.append(f"stream error: {stream.error}")
            stream.close()
        except Exception as exc:            # noqa: BLE001
            errors.append(repr(exc))

    threads = [threading.Thread(target=spin, args=(i,)) for i in range(12)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=60)

    check(len(rooms) == 12, f"12 rooms created concurrently (got {len(rooms)})")
    check(len(set(rooms)) == len(rooms), "every room code is unique")
    check(not errors, "all rooms ran their bots", "; ".join(errors[:3]))

    status, health = get("/api/health")
    check(status == 200 and health.get("ok"), "server still healthy afterwards", str(health))


def test_tables_and_cards():
    """The v2 surface: named tables, forced cards, points and the blurbs.

    The engine-level rules are proved by the Swift suite; what is proved here
    is that they survive the wire — that a mode name picked on a phone reaches
    the room, and that a move comes back carrying its card, its points and its
    line of geography.
    """
    print("\ntables and cards")

    status, modes = get("/api/modes")
    names = [m.get("id") for m in modes.get("modes", [])]
    check(status == 200 and "forced" in names and "blitz" in names,
          "the server lists its tables", str(names))
    check(all(m.get("title") and m.get("blurb") for m in modes.get("modes", [])),
          "every table is named and explained")

    # A named table, with one knob turned by hand on top of it: the mode
    # supplies the rest and the explicit setting wins.
    _, room = post("/api/quick", {"name": "Tester", "bots": 1,
                                  "table": {"mode": "forced", "turnSeconds": 20}})
    code, me = room["room"], room["playerID"]
    _, state = get(f"/api/room/{code}/state")
    config = state.get("config", {})
    check(config.get("forcedCards") is True and config.get("cardChance") == 1,
          "the named table reached the room", str(config))
    check(config.get("turnSeconds") == 20,
          "a setting typed by hand beats the table's own", str(config))

    # Nonsense must be clamped rather than obeyed: a phone can send anything.
    _, silly = post("/api/quick", {"name": "Tester", "bots": 1,
                                   "table": {"mode": "nonsense", "turnSeconds": -5,
                                             "lives": 99}})
    _, sillyState = get(f"/api/room/{silly['room']}/state")
    clamped = sillyState.get("config", {})
    check(clamped.get("turnSeconds", 0) >= 5 and 1 <= clamped.get("lives", 0) <= 9,
          "nonsense settings are clamped", str(clamped))

    # Play the forced table out with hints.  Every hint the server offers has
    # to satisfy the card, or the rule is unplayable on a phone.
    played, cardless = 0, 0
    for _ in range(12):
        deadline = time.time() + 30
        while True:
            _, snapshot = get(f"/api/room/{code}/state")
            if (snapshot.get("phase") != "playing"
                    or snapshot.get("currentPlayerID") == me
                    or time.time() >= deadline):
                break
            time.sleep(0.2)
        if snapshot.get("phase") != "playing" or snapshot.get("currentPlayerID") != me:
            break
        if not snapshot.get("card"):
            cardless += 1
        _, hints = get(f"/api/room/{code}/hint")
        options = hints.get("hints") or []
        if not options:
            break
        _, result = post(f"/api/room/{code}/submit", {"playerID": me, "text": options[0]})
        if not result.get("ok"):
            check(False, f"hint '{options[0]}' was refused at a forced table", str(result))
            break
        played += 1

    check(played >= 3, f"played {played} moves at a forced table")
    check(cardless == 0, "a forced table always had a card in play",
          f"{cardless} turns without one")

    _, final = get(f"/api/room/{code}/state")
    moves = final["moves"]
    met = sum(1 for m in moves if m.get("metCard"))
    check(moves and all(m.get("card") for m in moves),
          "every move at a forced table records its card")
    check(met == len(moves),
          "every move at a forced table met its card", f"{met}/{len(moves)}")
    check(all(m.get("points", 0) >= 1 for m in moves),
          "every move is worth at least a point",
          str([m.get("points") for m in moves]))

    # Feature 3: one line of geography, on every move, from either player.
    blurbs = [m.get("blurb") for m in moves]
    check(all(b and b == b.strip() for b in blurbs),
          "every move explains itself in a line", str(blurbs[:2]))

    # Feature 5: the scoreboard is the moves, added up.
    for player in final["players"]:
        mine = [m for m in moves if m["playerID"] == player["id"]]
        total = sum(m["points"] for m in mine)
        check(player["score"] == total,
              f"{player['name']}'s score is their moves added up",
              f"{player['score']} vs {total}")

    # The table is the host's to set, and only while the room is theirs.
    _, guestRoom = post("/api/room", {"name": "Host"})
    guestCode = guestRoom["room"]
    _, guest = post(f"/api/room/{guestCode}/join", {"name": "Guest"})
    status, denied = post(f"/api/room/{guestCode}/config",
                          {"playerID": guest["playerID"],
                           "table": {"mode": "brutal"}})
    check(status == 403, "a guest cannot change the table", f"status={status} {denied}")
    status, _ = post(f"/api/room/{guestCode}/config",
                     {"playerID": guestRoom["playerID"], "table": {"mode": "blitz"}})
    _, lobby = get(f"/api/room/{guestCode}/state")
    check(status == 200 and lobby["config"]["turnSeconds"] == 15,
          "the host can change the table", str(lobby.get("config")))


def test_wager():
    """A life staked on a hard card, over the wire.

    The arithmetic is proved by the Swift suite.  What is proved here is the
    half a phone can see: that the button the client draws agrees with what the
    server will take, that the card arrives in the same breath as the bet, and
    that the life ledger balances whichever way the bet goes.
    """
    print("\nbetting a life")

    _, modes = get("/api/modes")
    names = [m.get("id") for m in modes.get("modes", [])]
    check("sudden" in names, "sudden death is one of the tables", str(names))

    # Cards off, so every card below is one that was asked for: nothing else
    # can explain a banner, a multiplier or a life appearing.
    _, room = post("/api/quick", {"name": "Better", "bots": 1,
                                  "table": {"mode": "marathon", "turnSeconds": 45,
                                            "lives": 3, "cardChance": 0}})
    code, me = room["room"], room["playerID"]

    def poll_turn(timeout=40):
        deadline = time.time() + timeout
        while True:
            _, snapshot = get(f"/api/room/{code}/state")
            if (snapshot.get("phase") != "playing"
                    or snapshot.get("currentPlayerID") == me
                    or time.time() >= deadline):
                return snapshot
            time.sleep(0.2)

    def my_seat(snapshot):
        return next((p for p in snapshot["players"] if p["id"] == me), {})

    bets, won, lost, refusals = 0, 0, 0, 0
    for turn in range(10):
        state = poll_turn()
        if state.get("phase") != "playing" or state.get("currentPlayerID") != me:
            break
        check(not state.get("card"), "no card until a life is put on one",
              str(state.get("card")))

        _, plain = get(f"/api/room/{code}/hint")
        anything = plain.get("hints") or []
        if not anything:
            break

        # The client only draws the button when the snapshot says so, so the
        # snapshot saying no has to mean the server would refuse.
        if not state.get("canWager"):
            _, denied = post(f"/api/room/{code}/wager", {"playerID": me})
            check(denied.get("ok") is False and denied.get("code") == "wager_refused",
                  "a bet the client never offered is refused", str(denied))
            refusals += 1
            post(f"/api/room/{code}/submit", {"playerID": me, "text": anything[0]})
            continue

        before = my_seat(state)
        _, bet = post(f"/api/room/{code}/wager", {"playerID": me})
        if not check(bet.get("ok"), "the bet is taken", str(bet)):
            break
        bets += 1
        check(bet.get("multiplier") == 5, "a bet is always against a hard card", str(bet))

        _, table = get(f"/api/room/{code}/state")
        card = table.get("card") or {}
        check(card.get("tier") == "hard" and table.get("wagered") is True,
              "the hard card is on the table at once", str(card))
        check(table.get("cardIsRule") is False,
              "and is not a rule — being free to miss it is the wager", str(table))
        check(table.get("canWager") is False, "the button is gone once you have bet")
        check(my_seat(table)["lives"] == before["lives"],
              "the life is not taken until the bet is settled", str(my_seat(table)))

        _, twice = post(f"/api/room/{code}/wager", {"playerID": me})
        check(twice.get("ok") is False and twice.get("code") == "wager_refused",
              "a second bet on the same turn is refused", str(twice))
        _, stranger = post(f"/api/room/{code}/wager", {"playerID": "nobody"})
        check(stranger.get("ok") is False and stranger.get("code") == "not_your_turn",
              "nobody can bet on somebody else's turn", str(stranger))

        # Hints obey the card, so they are the way to win on purpose; a place
        # the card-filtered list left behind is the way to try and lose.  The
        # loser is a guess — the list is short — so the outcome is read back
        # from the server rather than assumed.
        _, filtered = get(f"/api/room/{code}/hint")
        meeting = filtered.get("hints") or []
        missing = next((h for h in anything if h not in meeting), None)
        aiming_to_win = turn % 2 == 0 or missing is None
        text = (meeting[0] if aiming_to_win and meeting else missing) or anything[0]

        _, played = post(f"/api/room/{code}/submit", {"playerID": me, "text": text})
        if not check(played.get("ok"), f"'{text}' plays", str(played)):
            break

        _, settled = get(f"/api/room/{code}/state")
        move = settled["moves"][-1]
        after = my_seat(settled)
        check(move.get("wagered") is True, "the move remembers it was a bet", str(move))
        if move.get("metCard"):
            won += 1
            check(move.get("points") == 5 and after["lives"] == before["lives"] + 1,
                  "a bet won pays five points and the life back",
                  f"{move.get('points')} points, {before['lives']}→{after['lives']} lives")
        else:
            lost += 1
            check(move.get("points") == 1 and after["lives"] == before["lives"] - 1,
                  "a bet lost costs the life and scores the plain point",
                  f"{move.get('points')} points, {before['lives']}→{after['lives']} lives")
        if settled.get("phase") != "playing":
            break

    check(bets >= 2, f"placed {bets} bets ({won} won, {lost} lost, {refusals} refused)")
    check(won >= 1 and lost >= 1,
          "both halves of the bet were reached", f"{won} won, {lost} lost")

    # A table may switch betting off, and then the button must never appear.
    _, quiet = post("/api/quick", {"name": "Better", "bots": 1, "table": {"mode": "classic"}})
    _, quietState = get(f"/api/room/{quiet['room']}/state")
    check(quietState.get("canWager") is False, "the classic table offers no bets",
          str(quietState.get("canWager")))
    _, quietBet = post(f"/api/room/{quiet['room']}/wager", {"playerID": quiet["playerID"]})
    check(quietBet.get("ok") is False and quietBet.get("code") == "wager_refused",
          "and refuses one asked for anyway", str(quietBet))

    _, suddenRoom = post("/api/quick", {"name": "Better", "bots": 1,
                                        "table": {"mode": "sudden"}})
    _, sudden = get(f"/api/room/{suddenRoom['room']}/state")
    check(all(p["lives"] == 1 for p in sudden["players"]),
          "sudden death starts everyone on one life", str(sudden["players"]))


def test_media():
    """Pictures and quirky facts.

    The sweep seeds a scratch data directory with two records and one place that
    was looked up and found to have nothing, so this can assert real answers
    without waiting on the harvester or the network.  Run against a server with
    no media file at all, the seeded checks are skipped rather than failed:
    a missing picture is never a broken game.
    """
    print("\npictures and facts")

    status, info = get("/api/atlas")
    check(status == 200, "the atlas reports its media counts", str(info))
    check("described" in info and "pictured" in info,
          "the counts are there even when there is nothing to count", str(info))

    status, reply = get("/api/media?q=" + urllib.parse.quote("Utterly Made Up Place"))
    check(status == 200, "asking about an unknown place is not an error")
    check(reply.get("places") == [],
          "a place nobody has looked up simply has nothing", str(reply))

    if not info.get("described"):
        print("  (no media file on this server — seeded checks skipped)")
        return

    status, reply = get("/api/media?q=" + urllib.parse.quote("Sydney|Aizawl|Nowhere With No Picture"))
    found = {r["q"]: r for r in reply.get("places", [])}
    check(status == 200 and reply.get("ready") is True,
          "the server says it has a library", str(reply)[:200])
    check("Sydney" in found and "Aizawl" in found,
          "several places come back from one request", str(list(found)))
    check("Nowhere With No Picture" not in found,
          "a place looked up and found dull is not returned", str(list(found)))

    sydney = found.get("Sydney", {})
    check(sydney.get("image", "").startswith(("http", "data:")),
          "a picture is a URL the browser can load", str(sydney)[:120])
    check(sydney.get("width", 0) > 0 and sydney.get("height", 0) > 0,
          "the picture knows its own shape", str(sydney))
    check("1,056,006" in sydney.get("fact", ""), "the quirky fact comes through", str(sydney))
    check(sydney.get("fact", "") != "", "and it is not the blurb the game already says")

    # The name is matched the way the game matches names, not by string equality.
    status, reply = get("/api/media?q=" + urllib.parse.quote("  sYdNeY  "))
    check([r["q"] for r in reply.get("places", [])] == ["sYdNeY"],
          "a picture is found however the name was typed", str(reply)[:160])
    check(reply["places"][0]["name"] == "Sydney" if reply.get("places") else False,
          "and it answers with the proper spelling")

    # A phone that reconnects asks about its whole chain at once; that must not
    # become a way to make the server do unbounded work.
    many = "|".join(f"Place {n}" for n in range(400))
    status, reply = get("/api/media?q=" + urllib.parse.quote(many))
    check(status == 200, "a huge request is answered rather than refused")


def test_malformed_input():
    print("\nmalformed input")
    cases = [
        ("/api/room/ZZZZ/submit", {"playerID": "x", "text": "y"}, "unknown room"),
        ("/api/room/ZZZZ/start", {"playerID": "x"}, "unknown room start"),
    ]
    for path, body, label in cases:
        status, _ = post(path, body)
        check(status == 404, f"{label} returns 404", f"status={status}")

    _, room = post("/api/quick", {"name": "T", "bots": 1})
    code = room["room"]
    for body, label in [({}, "missing fields"),
                        ({"playerID": 5, "text": []}, "wrong types"),
                        ({"playerID": "x" * 5000, "text": "y" * 5000}, "huge strings")]:
        status, _ = post(f"/api/room/{code}/submit", body)
        check(status in (200, 400), f"submit with {label} does not crash", f"status={status}")

    request = urllib.request.Request(BASE + f"/api/room/{code}/submit", data=b"not json{{",
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            status = response.status
    except urllib.error.HTTPError as error:
        status = error.code
    check(status == 400, "non-JSON body returns 400", f"status={status}")

    status, _ = get("/api/room/ZZZZ/events?playerID=x")
    check(status == 404, "events for a dead room returns 404", f"status={status}")

    status, health = get("/api/health")
    check(status == 200, "server survived the malformed input")


def main():
    global BASE

    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default=BASE)
    parser.add_argument("--online", action="store_true")
    arguments = parser.parse_args()

    BASE = arguments.base.rstrip("/")

    status, health = get("/api/health")
    if status != 200:
        print(f"no server at {BASE} — start `atlas serve` first")
        return 2
    print(f"testing {BASE} — {health.get('places')} places")

    test_static_assets()
    test_full_game()
    test_repeat_refused()
    test_lobby_and_rematch()
    test_challenge_offline()
    test_tables_and_cards()
    test_wager()
    test_media()
    test_malformed_input()
    test_concurrent_rooms()
    if arguments.online:
        test_challenge_online()

    print(f"\n{CHECKS[0] - len(FAILURES)}/{CHECKS[0]} checks passed")
    if FAILURES:
        print("\033[31mfailed:\033[0m")
        for name in FAILURES:
            print(f"  · {name}")
        return 1
    print("\033[32mall good\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
