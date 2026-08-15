#!/bin/zsh
#
# Everything, in one go.  Builds both configurations, runs the Swift suite, plays
# 1900 games on a virtual clock across seven different tables, hammers one game
# from sixteen threads, then starts a server and tests it the way a phone would —
# over HTTP, over the event stream, and in a real browser at an iPhone viewport.
#
#   zsh tools/sweep.sh            # about ten minutes, most of it the browser
#
# The online pass asks the live Wikipedia; if it is rate-limiting you the
# challenge test says so and moves on rather than failing.
set -u
cd "$(dirname "$0")/.."
PORT=${PORT:-8080}
BASE="http://localhost:$PORT"

echo "=== build ==="
pkill -f "atlas serve --port $PORT" 2>/dev/null
sleep 1
swift build 2>&1 | tail -2
# The atlas is embedded in the binary, so the release build carries its own copy
# and has to be rebuilt whenever atlas.json changes.
swift build -c release 2>&1 | tail -2

echo
echo "=== unit + integration tests ==="
./.build/debug/atlastests 2>&1 | tail -4

echo
echo "=== simulator: 400 games, mixed seats ==="
./.build/release/atlas sim --games 400 --seats mixed --seed 11 2>&1 | tail -15

echo
echo "=== simulator: 400 games, bots only ==="
./.build/release/atlas sim --games 400 --seats bots --seed 12 2>&1 | tail -15

echo
echo "=== simulator: 300 games, forced cards ==="
./.build/release/atlas sim --games 300 --seats mixed --seed 13 \
  --cards 1 --forced-cards 2>&1 | tail -15

echo
echo "=== simulator: 300 games, blitz clock and hard cards ==="
./.build/release/atlas sim --games 300 --seats mixed --seed 14 \
  --turn 12 --decay 0.5 --cards 0.8 --tiers hard 2>&1 | tail -15

echo
echo "=== simulator: 300 games, sudden death — one life, and bets for it ==="
./.build/release/atlas sim --games 300 --seats humans --seed 16 \
  --turn 25 --lives 1 --cards 0.45 2>&1 | tail -15

echo
echo "=== simulator: 200 games, dead-letter rescue off ==="
./.build/release/atlas sim --games 200 --seats mixed --seed 15 \
  --no-rescue 2>&1 | tail -15

echo
echo "=== soak: 60s, 16 threads ==="
./.build/release/atlas soak --seconds 60 --threads 16 2>&1 | tail -12

echo
echo "=== server ==="
# A scratch data directory, so a test run never touches the real ~/.atlas, and a
# handful of hand-written picture records, so the media tests depend neither on
# the network nor on how far the background harvester has got.  The harvester
# itself is off here: this server is for tests, and five thousand background
# lookups underneath them would only add noise.
export ATLAS_DATA_DIR=${ATLAS_DATA_DIR:-/tmp/atlas-sweep-data}
mkdir -p "$ATLAS_DATA_DIR"
cat > "$ATLAS_DATA_DIR/media.json" <<'JSON'
{
  "sydney": {"n": "Sydney", "q": "Its opera house is roofed with 1,056,006 tiles, in two shades of cream.",
             "i": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
             "w": 640, "h": 427, "s": "https://en.wikipedia.org/wiki/Sydney", "c": true},
  "aizawl": {"n": "Aizawl", "q": "The city keeps a Sunday silence: almost every shop closes and the streets empty for church.",
             "i": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
             "w": 512, "h": 341, "s": "https://en.wikipedia.org/wiki/Aizawl", "c": true},
  "nowherewithnopicture": {"n": "Nowhere With No Picture", "c": true}
}
JSON
nohup ./.build/release/atlas serve --port "$PORT" --no-harvest \
  > /tmp/atlas-server.log 2>&1 &
sleep 2
curl -s "$BASE/api/health"
echo

echo
echo "=== e2e x2 ==="
for run in 1 2; do
  echo "--- run $run"
  python3 tools/e2e.py --base "$BASE" 2>&1 | grep -aE "✗|checks passed|all good"
done

echo
echo "=== e2e online ==="
python3 tools/e2e.py --base "$BASE" --online 2>&1 \
  | grep -aE "✗|checks passed|all good|throttling"

echo
echo "=== browser (WebKit, iPhone viewport) ==="
node tools/ui_test.mjs --base "$BASE" 2>&1 | grep -aE "✗|checks passed|all good"

echo
echo "=== SWEEP COMPLETE ==="
echo "the server is still up on $BASE"
