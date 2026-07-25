# portman — working notes

A macOS menu bar app that lists everything listening locally, identifies what it is,
and lets you act on it. Swift 6, SwiftUI in an AppKit panel, SPM only — no Xcode project.

## Commands

```sh
swift build                     # build
swift run portman           # run from source (no bundle: previews and login items won't work)
swift run portman --list    # scan and print as TSV — fastest way to check detection
swift test                      # 45 tests over the pure logic
make build                      # build dist/portman.app
make publish-local              # build, sign, install to ~/Applications, relaunch
make dmg                        # drag-install DMG
```

`--list` before and after a detection change is the quickest useful diff.

## Layout

```
Core/       scanning, project/framework detection, Docker, metrics, git — pure, testable
Services/   health probing, previews, tunnels, terminal attach, app launching
Store/      ServerStore (@Observable), filtering/sorting/grouping, preferences
UI/         status item, panel, list, detail card, settings, hotkey
```

Core never imports SwiftUI. The UI never shells out — everything that spawns a process
lives in Core or Services.

## Shape of the thing

`PortScanner` runs `lsof -nP -iTCP -sTCP:LISTEN -F pcLn` and produces `ServerEntry`
values. Enrichers then fill in optional fields independently — metrics, git, health —
so a row renders before every enricher has finished.

`ServerStore` owns all state and rebuilds derived values (`sections`, `rows`,
`conflictPorts`) only when an input changes. They used to be computed properties, and
`conflictPorts` was read once per row inside the list body, which ran the whole folding
pipeline n times per frame.

`ListShaper` is pure: search, sort, fold, group. Everything the list does is
reproducible from its inputs, which is why it's the part with tests.

## Things that will bite you

These were all found the hard way. Changing any of them reintroduces a real bug.

**The panel must not resize while open.** `NSWindow` origins are bottom-left, so a
height change moves the *top* edge and walks the panel away from the menu bar. The
controller picks a size once in `sizeOnOpen` and leaves it; content scrolls. Do not set
`NSHostingView.sizingOptions = .intrinsicContentSize` here.

**Anything that changes on refresh needs a reserved slot.** CPU and uptime are
monospaced-digit in fixed frames; the row's second line is a single composed `Text`
rather than separate views, so nothing can push anything else sideways. The sparkline
uses a floored y-axis and fixed x-slots — scaling it to its own window maximum made an
idle server redraw as a full-height cliff every two seconds.

**Only animate the list when it changes shape.** `commit()` compares row identities. A
refresh that just moved a number must not animate, or the whole list shimmers while
you're reading it.

**Health is checked once per port, not per scan.** Results are kept in `healthByPort`
across scans. Re-probing every cycle rewrote the list continuously. Probing also runs
off the scan cycle — awaiting it meant a scan outlasted the poll interval whenever a few
servers were wedged.

**No `confirmationDialog` from the panel.** It's a separate window, so presenting it
takes key from the panel and dismisses it. Confirmations are an in-panel footer bar.
Relatedly, `windowDidResignKey` must not close the panel — menus opened from inside it
resign key too.

**Status item images must be templates, and never tinted.** Set `isTemplate = true` on
the image you actually hand to the button, after any `withSymbolConfiguration`. Setting
`contentTintColor` at all opts the button out of automatic menu-bar adaptation, so it
stops following light/dark.

**Ports are identifiers, not quantities.** `Text("\(port)")` localises 4321 into
"4,321". Use `Text(verbatim:)`.

**`cloudflared --http-host-header` needs the `=` form.** Passed as a separate argument it
prints help and never starts. Without the flag, dev servers reject the request — Vite
answers "This host is not allowed".

**Tunnel URLs aren't resolvable when cloudflared prints them.** Measured: URL at 5.4s,
DNS at 8.6s. Opening one in that window gets NXDOMAIN, which macOS caches — the link
then keeps failing long after the tunnel is healthy. `waitUntilResolvable` checks via
`dig @1.1.1.1` deliberately, because asking the system resolver would cache the very
negative answer we're avoiding.

**Keep draining cloudflared's output** for the tunnel's whole life. Stop reading and the
pipe fills, which blocks cloudflared and takes the tunnel down.

**Missing metrics render as `—`, never `0`.** Root- and other-user-owned processes reject
`proc_pidinfo`. A zero would read as "idle", which is a lie. They also sort last, not as
zero.

**Kill reports failure.** `kill(2)` returns EPERM for processes you don't own. Animating
the row away regardless is a lie — the server is still there and returns on the next scan.

## Icon

`Resources/AppIcon.icon` is an Icon Composer document — `icon.json` plus the SVG
layers. `build-app.sh` compiles it with `actool`, which emits both halves from that
one source: `Assets.car` carries the layered icon that macOS 26 masks and lights
itself, and a generated `AppIcon.icns` covers macOS 15 and earlier, which do
neither. `CFBundleIconName` points at the first, `CFBundleIconFile` at the second.

Don't hand-draw an `.icns`. An earlier version did, and it was wrong twice over:
macOS 26 puts legacy icons in its own container without masking them, so a
self-drawn squircle showed as a squircle inside a squircle with a grey ring, while
a full-bleed square showed as a square. Both symptoms disappear once the system is
given layers to work with.

## Conventions

4-space indent. No force unwraps. `guard` for early exit. Comments explain *why*, not
what — most of the comments in this codebase mark a trap, so don't delete them as noise.

Design tokens live in `UI/Theme.swift`. If a spacing or colour value is used twice, it
belongs there.

`UserDefaults` keys are shared with the pre-rewrite release (`pinnedKeys`,
`ignoredPorts`, `ignoredCommands`, `ignoredTargets`, `showAllProcesses`) — don't rename
them or people lose their config.

## Testing

Tests cover the pure logic only: lsof parsing, Docker port mapping, search and regex,
nil-safe metric sorting, sibling-port folding, conflict detection, classification,
exposure, ancestry trust, tunnel URL extraction. UI is untested.

For anything involving live processes, verify against real state rather than assuming.
`PORTMAN_OPEN_ON_LAUNCH=1|expand|settings` drives the panel on launch for
screenshots and UI checks.
