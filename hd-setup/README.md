# screenpipe-hd

Personal build-and-run setup (lives in `hd-setup/` of the fork `halfdecentguy/screenpipe-hd`; formerly the separate `screenpipe-hd-setup` repo) for [screenpipe](https://github.com/screenpipe/screenpipe) on this Mac (16 GB Apple Silicon), plus a hub report snapshot of the upstream monorepo.

## What's here

| file | purpose |
|---|---|
| `com.bogdan.screenpipe.plist` | launchd agent running the source-built CLI: telemetry off, 14-day media retention, pause on DRM content, `whisper-large-v3-turbo-quantized` with EN/RU/UK, password-manager windows ignored. |
| `update.sh` | Manual updater. Reads the rolling `cli-latest` GitHub **release title** (the tag itself is stale — the release workflow re-uploads assets without moving it), finds the matching commit on upstream main by `Cargo.toml` version (fetched ad hoc by URL — the checkout's `origin` is the personal fork `halfdecentguy/screenpipe`), rebuilds with `metal,apple-intelligence` at `-j 4` (full-parallelism fat-LTO builds have frozen this machine), re-signs with the stable `screenpipe-personal` codesigning identity so the TCC Screen Recording grant survives the rebuild, then kickstarts the agent and verifies `/health` `frame_status`. |
| `screenpipe-hd.html` | Hub report of the upstream monorepo — architecture, subsystems, activity, and risk register. Snapshot 2026-06-11 at `1a99c64aa` (app v2.5.31 / crates v0.4.17). |

## Install

```sh
cp com.bogdan.screenpipe.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.bogdan.screenpipe.plist
```

The plist runs `~/.local/bin/screenpipe`. `hd-setup/update.sh` builds into `target/release/` and installs the signed binary there, so `target/` is a disposable build cache.

## Why the stable signing identity matters

Cargo's linker signs ad-hoc, which TCC keys by code hash: every rebuild silently revokes Screen Recording (capture returns 0 monitors with no error). Signing with a persistent self-signed `screenpipe-personal` identity and a fixed identifier keeps the grant across rebuilds. If the identity is missing, `update.sh` prints recovery steps (re-toggle Screen Recording, then `launchctl kickstart`).

Logs: `~/Library/Logs/screenpipe.{out,err}.log` · Health: `curl localhost:3030/health`
