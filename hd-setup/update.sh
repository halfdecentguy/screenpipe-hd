#!/usr/bin/env bash
# update.sh — personal screenpipe source-build updater. Run manually.
#
# Builds the personal FORK's main branch (halfdecentguy/screenpipe-hd),
# which carries fork-only features (incognito audio suppression) on top
# of upstream. This script never looks at upstream: pulling a new
# upstream release INTO fork main is a deliberate manual step —
#
#   cd ~/projects/Personal/screenpipe
#   GIT_LFS_SKIP_SMUDGE=1 git fetch https://github.com/screenpipe/screenpipe.git main
#   git merge FETCH_HEAD        # resolve conflicts if any
#   git push origin main
#
# — after which running this script deploys it. (Finding the commit for a
# CLI release: the `cli-latest` tag is stale by design; match the release
# TITLE version against Cargo.toml on upstream main. See the git history
# of this script for the automated version of that dance.)
set -euo pipefail

# Fixed path: this script lives in the setup repo, not the checkout.
REPO_DIR="$HOME/projects/Personal/screenpipe"
BIN="$REPO_DIR/target/release/screenpipe"
LABEL="com.bogdan.screenpipe"

cd "$REPO_DIR"
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"

echo "fetching fork main..."
GIT_LFS_SKIP_SMUDGE=1 git fetch origin main --quiet

if [ "$(git rev-parse HEAD)" = "$(git rev-parse FETCH_HEAD)" ] \
    && [ -x "$BIN" ] \
    && [ "$(stat -f %m "$BIN")" -ge "$(git log -1 --format=%ct HEAD)" ]; then
    echo "binary already built from fork main $(git rev-parse --short HEAD) — nothing to do."
    exit 0
fi

# --ff-only: never rewrite local history (other agents work in this repo).
# If this fails, local main has unpushed commits — reconcile manually.
git checkout --quiet main
git merge --ff-only FETCH_HEAD

echo "building fork main $(git rev-parse --short HEAD) (incremental: ~10 min; clean: 30-60 min)..."

export PKG_CONFIG_PATH="/opt/homebrew/opt/ffmpeg/lib/pkgconfig"
export CFLAGS='-mcpu=apple-m1 -U__ARM_FEATURE_MATMUL_INT8'
export CXXFLAGS='-mcpu=apple-m1 -U__ARM_FEATURE_MATMUL_INT8'
# Apple clang 21 rejects whisper.cpp's -mcpu=native; SOURCE_DATE_EPOCH
# makes ggml default GGML_NATIVE off. If a configure already failed once,
# also: rm -rf target/release/build/whisper-rs-sys-*  (cmake caches it).
export SOURCE_DATE_EPOCH=0
export CMAKE_BUILD_PARALLEL_LEVEL=4
# thin LTO: memwatch SIGKILLs the fat-LTO link (~7.8 GB > its 6144 MB
# line). Do NOT remove this or pause memwatch to build.
export CARGO_PROFILE_RELEASE_LTO=thin
# macOS 27: release `strip = true` also strips proc-macro dylibs, and the
# new /usr/bin/strip leaves them unloadable ("mis-aligned LINKEDIT string
# pool" dlopen error on sqlx_macros → bogus sqlx E0432). Don't strip
# build-time artifacts; the final binary is still stripped.
export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=false
# -j 4: this machine has 16 GB RAM; fat-LTO release builds at full
# parallelism have frozen it before. Do not raise.
nice -n 10 cargo build --release -j 4 -p screenpipe-engine --bin screenpipe --features metal,apple-intelligence

built="$("$BIN" --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
echo "built v$built at $(git rev-parse --short HEAD)"

# Re-sign with the stable personal identity so TCC grants survive the rebuild.
# Cargo's linker signs ad-hoc, which is hash-keyed in TCC: every rebuild
# silently revokes Screen Recording. A stable cert + identifier keeps it.
# NOTE: codesign may block on a keychain dialog for the key unless
# "Always Allow" was clicked once — if this hangs, look at the screen.
if security find-identity -v -p codesigning | grep -q "screenpipe-personal"; then
    codesign --force --sign screenpipe-personal --identifier com.bogdan.screenpipe "$BIN"
    echo "re-signed binary with stable identity 'screenpipe-personal'"
else
    cat <<'EOR'

############################################################################
# WARNING: signing identity 'screenpipe-personal' not found in keychain,   #
# so the binary stays ad-hoc signed and the rebuild changed its code hash, #
# which SILENTLY invalidates its Screen Recording grant. Screen capture    #
# will return 0 monitors until you re-toggle it:                           #
#   System Settings > Privacy & Security > Screen & System Audio          #
#   Recording > toggle "screenpipe" OFF and back ON                        #
# Then: launchctl kickstart -k gui/$(id -u)/com.bogdan.screenpipe          #
# Verify: tail ~/Library/Logs/screenpipe.out.log — expect                  #
#   "VisionManager started with 1/1 monitor(s)"                            #
############################################################################
EOR
fi

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "restarting launchd agent $LABEL..."
    launchctl kickstart -k "gui/$(id -u)/$LABEL"
    sleep 3
    curl -fsS http://localhost:3030/health >/dev/null && echo "agent restarted, API healthy." || echo "warning: agent restarted but API not responding yet — check ~/Library/Logs/screenpipe.err.log"
    # Confirm the TCC grant actually survived: give vision time to push a frame.
    sleep 20
    fs="$(curl -fsS http://localhost:3030/health | jq -r .frame_status 2>/dev/null || echo unknown)"
    if [ "$fs" = "ok" ]; then
        echo "screen capture healthy (frame_status=ok) — TCC grant survived the rebuild."
    else
        echo "frame_status=$fs — if it stays not-ok, re-toggle Screen Recording (System Settings > Privacy & Security) and kickstart again."
    fi
else
    echo "launchd agent not loaded; binary updated in place."
fi
