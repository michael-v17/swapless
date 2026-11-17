<div align="center">

# Swapless

**The menu-bar app that keeps a 16 GB Mac out of swap.**

[![macOS](https://img.shields.io/badge/macOS-27%2B-000000?style=flat-square&logo=apple&logoColor=white)](#build-run-verify)
[![Swift](https://img.shields.io/badge/Swift-5-F05138?style=flat-square&logo=swift&logoColor=white)](Package.swift)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![Status](https://img.shields.io/badge/status-v1%20in%20development-orange?style=flat-square)](#roadmap)

It measures memory the way Activity Monitor does, names the **real** culprit — system processes, Safari tabs and booted simulators included — and fixes it **only** when you have set a rule for that app.

[What it does](#what-it-does) · [Install](#install) · [How it works](#how-it-works) · [Roadmap](#roadmap) · [Development](#development)

<!-- HERO-SCREENSHOT: clean menu-bar dropdown shot — replace the proof capture below when we take the polished one -->

![Swapless menu](docs/proof/v1-menu-today/menu-screenshot-today.png)

</div>

---

## Why

On a 16 GB Mac, swap is the slow bleed: the beach balls, the SSD wear, the "why is everything slow" after a full workday. macOS won't tell you *who* pushed it into swap — Activity Monitor shows you a wall of processes and leaves the detective work to you. Swapless does that work: it watches, it names the culprit, and it only acts on what you've explicitly ruled on.

## What it does

- **Measures every process the way Activity Monitor does** — real per-process footprint, not guesses.
- **Names the real culprit** — including the ones other tools miss: system processes, Safari tabs, booted iOS simulators.
- **Fixes only what you have ruled on.** An app you never configured is *never* touched — it gets named, not killed.
- **Known-leak guard** — quietly restarts macOS's own leaking wallpaper process (`WallpaperImageExtension`), the classic invisible memory hole.
- **Today in the menu bar** — footprint per app, a growth map of what's expanding, and an idle-CPU footer.

## How it works

```mermaid
flowchart LR
    A[Sampler\nper-process footprint\nlike Activity Monitor] --> B[Culprit detection\ngrowth flags + history]
    B --> C[Menu bar\nToday · top apps · idle CPU]
    B --> D{Your rule\nfor this app?}
    D -- "no rule" --> E[Named in the menu\nnever touched]
    D -- "known macOS leak" --> F[Quiet restart\nwallpaper guard]
    D -- "your rule" --> G[Watch / restart / quit\nper your threshold]
```

The safety rail is the design: **unknown apps are never touched.** Every automated action is either a macOS-known leak fix or a rule you wrote yourself.

## Roadmap

v1, built in public:

- [x] **Core** — sampler, culprits menu, growth flags, history, wallpaper guard
- [x] **Menu today** — Today row, 5 s menu refresh, idle-CPU footer
- [ ] **Quit on last window close** — opt-in, with per-app exceptions
- [ ] **Quiet, actionable alerts** — an alert names the cause and offers the fix
- [ ] **Per-app rules** — watch only, restart above a threshold, quit when idle, or quit on last window close

## Install

Requires macOS 27+ and a Swift toolchain.

```bash
git clone https://github.com/michael-v17/swapless.git
cd swapless
swift build && swift test
./scripts/make-cert.sh          # once per Mac (keychain prompt)
./scripts/make-app.sh release   # wrap, sign, install to /Applications, relaunch
```

## Development

This repo is built spec-first with an AI-driven workflow — every task ships with a contract in `specs/`, decisions and their reasoning live in `DECISIONS.md`, and `main` only ever receives PRs (`WORKFLOW.md`).

```bash
swift build && swift test                                  # compile + unit tests
./scripts/leak-rig.sh [--only N | --budget | --sim | ...]  # synthetic leak rig (exit 0 = pass)
SWAPLESS_STATE_DIR=$(mktemp -d) .build/debug/Swapless --headless   # JSON-lines contract
```

- `docs/research/` — prior art and API findings
- `docs/proof/` — verification captures per shipped slice

## License

[MIT](LICENSE) © 2026 michael-v17
