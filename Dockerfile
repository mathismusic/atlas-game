# Atlas, as a deployable container.
#
#   docker build -t atlas .
#   docker run -p 8080:8080 atlas
#
# Two stages: the Swift toolchain is 1.5 GB and none of it is needed to *run* a
# compiled binary, so the finished image carries only the runtime libraries.
#
# The atlas itself is compiled into the binary (`.embedInCode`), so there is no
# data file to mount.  The two things that do have to be handed over are the web
# client — SwiftPM would look for it in a bundle beside the binary, and the
# runtime image has no bundle — and the harvested pictures.

FROM swift:6.3.2-noble AS build
WORKDIR /src

# Manifest first: it changes far less often than the sources, so Docker can keep
# the dependency-resolution layer across edits.
COPY Package.swift ./
COPY Sources ./Sources
COPY Tests ./Tests

# Only the server product.  The test runner is an executable target too, and
# building it here would add minutes to every deploy for something no deployed
# container ever runs.  (`Tests/` is copied all the same: SwiftPM refuses to
# read a manifest whose target directories are missing, even unbuilt ones.)
#
# The binary is then put somewhere with a fixed name, because `.build/release`
# is a symlink to a directory named after the build triple, and copying through
# a symlink between stages is a thing that works until it does not.
RUN swift build -c release --product atlas \
    && cp "$(swift build -c release --product atlas --show-bin-path)/atlas" /atlas

FROM swift:6.3.2-noble-slim
WORKDIR /app

# `swift:*-slim` carries the Swift runtime but not curl's development files;
# FoundationNetworking dlopens libcurl at runtime for the challenge lookup and
# the picture harvest, and ca-certificates is what makes its HTTPS trust work.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libcurl4 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /atlas /app/atlas
COPY Sources/AtlasServer/Public /app/Public

# The pre-harvested pictures and facts (see `atlas media` in the README).
# Free-tier disks are wiped on every restart, so anything the container learns
# is lost; shipping the file inside the image is what keeps the pictures there
# after a redeploy.  `deploy/` always exists, so the build works even before the
# first harvest — the server simply starts with nothing and fills in as it runs.
COPY deploy /app/deploy
ENV ATLAS_MEDIA=/app/deploy/media.json

ENV ATLAS_PUBLIC_DIR=/app/Public \
    ATLAS_DATA_DIR=/data \
    PORT=8080
RUN mkdir -p /data

EXPOSE 8080

# No --port: the platform assigns one in $PORT, and the binary reads it.
# --host 0.0.0.0 is the default, and is required — a server bound to localhost
# inside a container is unreachable from outside it.
CMD ["/app/atlas", "serve"]
