# Agent instructions

## FlightDeck simulator coordination

Use `flightdeck` (installed at `~/.local/bin/flightdeck`) for coordinated releases and simulator ownership. `flightdeck start patchbridge --worktree "$PWD" --mode archive` runs the existing project checks with automatically leased simulators; use `--mode testflight` only when an upload is authorized. Pass the intended worktree root explicitly, including when invoking from a subdirectory. Omitting `--worktree` selects FlightDeck's configured checkout, not the current directory.

For other simulator work, acquire a lease with `flightdeck lease acquire --project patchbridge --worktree "$PWD" --device UUID --owner DESCRIPTIVE_AGENT_OR_TASK_ID`. Keep the returned token, use that exact UUID for all install, launch, test, capture, boot and shutdown commands, heartbeat periodically with `flightdeck lease heartbeat --device UUID --token TOKEN`, and release in cleanup with `flightdeck lease release --device UUID --token TOKEN`. Do not use `booted`, choose another agent's device, erase a retained simulator, or assume a stale heartbeat means a device is free. Disable parallel simulator testing when using a single leased destination. The lease is cooperative: direct Xcode/simctl operations can bypass it.

Release scripts emit structured progress when launched by FlightDeck. Keep `.flightdeck/release.sh` with the release script in commits and worktrees. Persistent data remains after releasing a lease. Project-specific distribution and device restrictions elsewhere in this file still apply.
