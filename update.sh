#!/usr/bin/env bash
# update.sh — personal screenpipe source-build updater. Run manually.
#
# Checks the rolling "cli-latest" GitHub release for a new CLI version,
# and ONLY on a new release: pins the matching source commit, rebuilds,
# and restarts the launchd agent.
#
# Why not compare git tags? The project's `cli-latest` tag is stale (the
# release workflow re-uploads assets without moving the tag), so the
# release TITLE ("CLI vX.Y.Z") is the only reliable version signal. We
# then locate the newest commit on origin/main whose root Cargo.toml
# version matches that release.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$REPO_DIR/target/release/screenpipe"
LABEL="com.bogdan.screenpipe"
API="https://api.github.com/repos/screenpipe/screenpipe/releases/tags/cli-latest"

cd "$REPO_DIR"
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"

current="$("$BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
[ -z "$current" ] && { echo "warning: no working binary at $BIN; treating as 0.0.0"; current="0.0.0"; }

latest="$(curl -fsSL "$API" | jq -r '.name' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ -z "$latest" ] && { echo "error: could not read latest CLI version from GitHub"; exit 1; }

echo "installed: v$current   latest release: v$latest"
newest="$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -1)"
if [ "$newest" = "$current" ]; then
    echo "up to date — nothing to do."
    exit 0
fi

echo "new release found — locating source commit for v$latest..."
GIT_LFS_SKIP_SMUDGE=1 git fetch origin main --quiet
sha=""
for c in $(git log origin/main -n 100 --format=%H -- Cargo.toml); do
    v="$(git show "$c:Cargo.toml" 2>/dev/null | sed -nE 's/^version *= *"([^"]+)".*/\1/p' | head -1)"
    if [ "$v" = "$latest" ]; then sha="$c"; break; fi
done
[ -z "$sha" ] && { echo "error: no commit on origin/main has Cargo.toml version $latest; aborting (tag/release scheme may have changed — inspect manually)"; exit 1; }

echo "building v$latest at $sha (this takes 30-60 min)..."
GIT_LFS_SKIP_SMUDGE=1 git checkout --quiet "$sha"

export PKG_CONFIG_PATH="/opt/homebrew/opt/ffmpeg/lib/pkgconfig"
export CFLAGS='-mcpu=apple-m1 -U__ARM_FEATURE_MATMUL_INT8'
export CXXFLAGS='-mcpu=apple-m1 -U__ARM_FEATURE_MATMUL_INT8'
# -j 4: this machine has 16 GB RAM; fat-LTO release builds at full
# parallelism have frozen it before. Do not raise.
nice -n 10 cargo build --release -j 4 -p screenpipe-engine --bin screenpipe --features metal,apple-intelligence

built="$("$BIN" --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
echo "built v$built"

# Re-sign with the stable personal identity so TCC grants survive the rebuild.
# Cargo's linker signs ad-hoc, which is hash-keyed in TCC: every rebuild
# silently revokes Screen Recording. A stable cert + identifier keeps it.
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
