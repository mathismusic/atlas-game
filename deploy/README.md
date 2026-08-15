# deploy/

This directory is copied into the container image as `/app/deploy`.

`media.json` — the harvested pictures and quirky facts, one entry per place.
It is not checked in by default because it is large and it is *derived*: rebuild
it whenever you like with

    ./.build/release/atlas media --limit 5000 --interval 0.4
    cp ~/.atlas/media.json deploy/media.json

The server reads it through `$ATLAS_MEDIA` at boot and treats it as read-only,
writing anything it learns afterwards to `$ATLAS_DATA_DIR/media.json` instead.
That split is deliberate: a free-tier disk is wiped on every restart, so the
shipped file is the part that survives a redeploy.

If the file is missing the server still starts — it just begins with no pictures
and fills them in from Wikipedia in the background, about one place a second.
