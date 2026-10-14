<p align="center">
  <img src="assets/mark.svg" width="112" alt="Skewed Glass Row mark: three translucent panes, cyan, blue, violet">
</p>

<h1 align="center">Space Manager</h1>

<p align="center">A macOS menu bar app that gives Spaces what they've always been missing:<br>
names, visibility, a fast switcher, and per-space automations.</p>

> **Note:** "Space Manager" is the working name — a final name may still land before
> the public v1. The bundle identifier will not change either way.

## What it does

- **Arrival HUD** — a transient bezel confirms every space switch the moment you land:
  space name, emoji, and accent color, positioned top center under the notch.
- **Space names** — persistent names, emoji, and accent colors keyed to each space's
  stable UUID, so they survive reordering. Unnamed spaces mirror the macOS defaults
  ("Desktop N", or the app name for full-screen spaces).
- **Hotkey switcher** — <kbd>⌃⌥⌘/</kbd> opens a tile switcher with live space previews:
  type to filter, <kbd>1</kbd>–<kbd>9</kbd> jumps immediately, <kbd>⏎</kbd> selects,
  <kbd>↓</kbd> opens a per-space menu (rename, quick-launch).
- **Quick-launch** — per-space app launching with optional Chrome profile targeting and
  window placement presets (left half, right half, maximized, centered), all via public
  Accessibility APIs.
- **Per-space actions** — launch apps or run shell commands on arrival or on demand,
  with settle delays and once-per-session options.
- **Menu bar indicator** — the current space number composited onto the menu bar icon.

## Requirements

- macOS 26+
- **Accessibility** permission (required — space switching synthesizes the native
  <kbd>⌃1</kbd>–<kbd>⌃9</kbd> shortcuts, which must be enabled in
  System Settings → Keyboard Shortcuts → Mission Control)
- **Screen Recording** permission (optional — enables live space previews in the
  switcher; previews are session-only, in-memory screenshots)
- **Access to Chrome's data** (optional — only for Chrome profile targeting).
  Space Manager reads Chrome's profile list once, when you click
  **Refresh from Chrome** in Preferences; it never reads Chrome's folder at
  any other time. On macOS 27 that read is protected app data, so macOS shows
  a **"data access blocked"** prompt on the first click — choose **Allow**.
  If you dismissed or denied it earlier, no prompt appears again and Refresh
  finds nothing. Clear the stored decision and click Refresh once more:

  ```
  tccutil reset SystemPolicyAppDataDetailed com.taylorbird.spacemanager
  ```

## Install

Download `SpaceManager-<version>.dmg` from the
[latest release](https://github.com/taylorbird/spacemanager/releases/latest), open it, and drag
Space Manager to Applications. It has to run from `/Applications`: on macOS 27 the menu bar only
handles items correctly for apps launched from there. Updates arrive in the app (menu bar item →
Check for Updates…).

## Development

Two builds live side by side, with separate bundle IDs, settings and permissions:

| | Live | Dev |
|---|---|---|
| App | `/Applications/Space Manager.app` | `/Applications/Space Manager Dev.app` |
| Bundle ID | `com.taylorbird.spacemanager` | `com.taylorbird.spacemanager.dev` |
| Comes from | release DMG, updated by Sparkle | `scripts/build-app.sh` |

Only one runs at a time, since both hook the same space switches, HUD and hotkey.

```sh
scripts/build-app.sh      # build dev, quit live, install + launch dev
scripts/use-live.sh       # quit dev, relaunch live
```

The dev build needs its own Accessibility and Screen Recording grants the first time. It starts
with empty settings; to copy the live ones over (with both quit):
`defaults export com.taylorbird.spacemanager - | defaults import com.taylorbird.spacemanager.dev -`

Signing with a stable Developer ID keeps the permission grants across rebuilds. The menu's
version line names the build, its commit, and when it was built.

## Releasing

```sh
scripts/release.sh 0.2.0
```

First rewrite `RELEASE_NOTES.md` with `## 0.2.0` as its first line. The script commits and tags,
builds the live app, packages a notarized DMG (`scripts/package-dmg.sh`), signs the update feed
with the Sparkle key in the login keychain, then pushes and publishes the GitHub release.
One-time setup on a new machine:

- `xcrun notarytool store-credentials notary --apple-id <apple-id> --team-id UFCDGSKCXB`
- import the Sparkle signing key: `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account spacemanager -f <backup-file>`

## Design constraints

- Native Swift, AppKit + SwiftUI. No configuration files — all state lives in
  `UserDefaults` and is edited in-app (Preferences: <kbd>⌘,</kbd>).
- Augments Spaces, never replaces them: no Mission Control rendering, no space
  creation/removal, no wallpaper management.
- Private API surface is quarantined to a single call:
  `SLSCopyManagedDisplaySpaces` (read-only, loaded via `dlopen`/`dlsym`).
  Everything else is public API.

## Brand

The mark is the **Skewed Glass Row**: three translucent panes — cyan `#22D3EE`,
blue `#3B82F6`, violet `#8B5CF6` — leaning into an 8° skew, the current space
taller. Assets: [`assets/mark.svg`](assets/mark.svg) (full color),
[`assets/mark-mono.svg`](assets/mark-mono.svg) (single-color `currentColor`
variant for menu bar/template contexts).
