# Agent Notes

portman is a macOS menu bar app that lists everything listening locally, identifies what it
is, and lets you act on it. Swift 6, SwiftUI hosted in an AppKit panel, SwiftPM only — there
is no Xcode project.

Read this before changing anything. The **Traps** section in particular: each entry is a bug
that was found the hard way, and undoing one reintroduces it.

## Product Direction

The category is crowded with apps that list ports and kill them. That part is a commodity.

portman's edge is **knowing what a server actually is** — the project, the framework and
version, the git branch, whether it's still answering, what page it's serving. Detection is
the moat. When choosing between two implementations, favour the one that identifies things
more precisely, even if it costs more work.

Second principle: **honesty over convenience**. A reading we can't take renders as `—`, never
`0`. A kill that failed says so rather than animating the row away. A tunnel that isn't
resolvable yet isn't handed over as if it were.

Third: **the panel is a glance, not a dashboard**. Anything not scannable in a second belongs
in the expanded row, not on it. Rows default to Simple density for this reason.

## Repo Map

```
Sources/Portman/
  Core/        scanning, project + framework detection, Docker, metrics, git, ancestry
  Services/    health probing, page previews, tunnels, terminal attach, app launching
  Store/       ServerStore (@Observable), filtering/sorting/grouping, preferences
  UI/          status item, panel, list, detail card, settings, hotkey, theme
  main.swift   CLI entry (--list, --login-status, --enable-login, --disable-login)

Tests/PortmanTests/     pure-logic tests only
Resources/AppIcon.icon  Icon Composer document, compiled by actool at build time
scripts/                build-app.sh, build-dmg.sh, install-local.sh, release.sh, icon/
```

`Core` never imports SwiftUI. The UI never shells out — everything that spawns a process
lives in `Core` or `Services`.

## Architecture

`PortScanner` runs `lsof -nP -iTCP -sTCP:LISTEN -F pcLn` and produces `ServerEntry` values.
Enrichers then fill in optional fields independently — metrics, git, health — so a row
renders before every enricher has finished.

`ServerStore` owns all state and rebuilds derived values (`sections`, `rows`,
`conflictPorts`) only when an input changes, via `inputsChanged()`. They were computed
properties once, and `conflictPorts` was read per row inside the list body, so the whole
folding pipeline ran n times per frame.

`ListShaper` is pure: search, sort, fold, group. Everything the list does is reproducible
from its inputs, which is why it's the part with tests.

## Traps

**The panel must not resize while open.** `NSWindow` origins are bottom-left, so a height
change moves the *top* edge and walks the panel away from the menu bar. `PanelController`
picks a size once in `sizeOnOpen` and leaves it; content scrolls. Never set
`NSHostingView.sizingOptions = .intrinsicContentSize` here.

**Anything that changes on refresh needs a reserved slot.** CPU and uptime are
monospaced-digit in fixed frames, and the row's second line is a single composed `Text`
rather than separate views, so nothing can shove anything else sideways. The sparkline uses
a floored y-axis and fixed x-slots — scaling it to its own window maximum made an idle
server redraw as a full-height cliff every two seconds.

**Only animate the list when it changes shape.** `commit()` compares row identities. A
refresh that merely moved a number must not animate, or the list shimmers while you read it.

**Health is checked once per port, not per scan.** Results live in `healthByPort` across
scans; re-probing every cycle rewrote the list continuously. Probing also runs off the scan
cycle — awaiting it made a scan outlast the poll interval whenever a few servers were wedged.

**No `confirmationDialog` from the panel.** It's a separate window, so presenting it takes
key focus and dismisses the panel underneath. Confirmations are an in-panel footer bar.
Relatedly, `windowDidResignKey` must not close the panel — menus opened from inside it
resign key too.

**Status item images must be templates, and never tinted.** Set `isTemplate = true` on the
image handed to the button, *after* any `withSymbolConfiguration` (which returns a copy with
the flag cleared). Setting `contentTintColor` at all opts the button out of automatic
menu-bar adaptation, so it stops following light/dark.

**Ports are identifiers, not quantities.** `Text("\(port)")` localises 4321 into "4,321".
Use `Text(verbatim:)`.

**`cloudflared --http-host-header` needs the `=` form.** Passed as a separate argument it
prints its help and never starts. Without the flag, dev servers reject the request — Vite
answers "This host is not allowed".

**Tunnel URLs aren't resolvable when cloudflared prints them.** Measured: URL at 5.4s, DNS at
8.6s. Opening one inside that window gets NXDOMAIN, which macOS caches, so the link keeps
failing long after the tunnel is healthy. `waitUntilResolvable` checks via `dig @1.1.1.1`
deliberately — asking the system resolver would cache the very negative answer we're
avoiding.

**Keep draining cloudflared's output** for the tunnel's whole life. Stop reading and the pipe
fills, which blocks cloudflared and takes the tunnel down.

**Missing metrics render as `—`, never `0`.** Root- and other-user-owned processes reject
`proc_pidinfo`. A zero reads as "idle", which is a lie. They sort last, not as zero.

**Kill reports failure.** `kill(2)` returns EPERM for processes you don't own. Animating the
row away regardless is a lie — the server is still there and returns on the next scan.

**Don't hand-draw an `.icns`.** macOS 26 puts a legacy icon in its own rounded container but
doesn't mask it, so a self-drawn squircle renders as a squircle inside a squircle, and a
full-bleed square renders as a square. `actool` compiles `Resources/AppIcon.icon` into both
`Assets.car` (macOS 26) and a generated `.icns` (macOS 15 and earlier) from one source.

**`lockFocus()` renders at the display's backing scale.** On Retina, asking for 1024 gives
2048, and `iconutil` silently drops a rendition whose pixel size is wrong. Draw into an
`NSBitmapImageRep` with explicit pixel dimensions.

## Code Style

4-space indent. No force unwraps. `guard` for early exit.

Comments explain *why*, not what. Most comments in this codebase mark a trap — don't remove
them as noise.

Design tokens live in `UI/Theme.swift`. If a spacing, radius or colour value is used twice,
it belongs there.

`UserDefaults` keys are shared with the pre-rewrite release (`pinnedKeys`, `ignoredPorts`,
`ignoredCommands`, `ignoredTargets`, `showAllProcesses`). Don't rename them or people lose
their configuration.

The app's name and identity are build variables (`APP_NAME`, `BUNDLE_ID`, `SIGN_IDENTITY`),
and `AppInfo` reads them from the bundle. Don't hardcode either in source.

## Development Commands

```sh
swift build                  # build
swift run portman            # run from source (no bundle: previews and login items won't work)
swift run portman --list     # scan and print as TSV — fastest way to check detection
swift test                   # pure-logic tests
make build                   # build dist/portman.app
make publish-local           # build, sign, install to ~/Applications, relaunch
make dmg                     # drag-install DMG
```

`PORTMAN_OPEN_ON_LAUNCH=1|expand|settings` drives the panel on launch, for screenshots and UI
checks without a real click.

## Verification

Tests cover the pure logic only: lsof parsing, Docker port mapping, search and regex,
nil-safe metric sorting, sibling-port folding, conflict detection, classification, exposure,
ancestry trust, tunnel URL extraction. The UI is untested.

For anything touching live processes, verify against real state rather than reasoning about
it. `swift run portman --list` before and after a detection change is the quickest useful
diff.

Several bugs here were only visible when the built app was actually launched — a dynamic-link
failure and a hardened-runtime failure both passed every build check and appeared only at
runtime. Don't claim something works because it compiles.

## Releasing

`scripts/release.sh` builds, signs, runs a pre-flight, produces a DMG, notarises, staples and
prints the appcast `<item>`.

The pre-flight deliberately does **not** run `spctl --assess`: an app that's signed but not
yet notarised always reports `rejected / source=Unnotarized Developer ID`, so gating on it
would abort every release before it could be notarised. It asserts the hardened-runtime flag
and launches the app instead. `spctl` runs after stapling, where it reflects what a
downloader actually gets.

Sparkle stays dormant unless the build supplies `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_KEY`.
The private signing key lives in the keychain and must never enter the repo.
