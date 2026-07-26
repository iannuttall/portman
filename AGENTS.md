# Agent Notes

Portman is a macOS menu bar app that lists everything listening locally, identifies what it
is, and lets you act on it. Swift 6, SwiftUI hosted in an AppKit panel, SwiftPM only — there
is no Xcode project.

Read this before changing anything. The **Traps** section in particular: each entry is a bug
that was found the hard way, and undoing one reintroduces it.

## Product Direction

The category is crowded with apps that list ports and kill them. That part is a commodity.

Portman's edge is **knowing what a server actually is** — the project, the framework and
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

**The alert dot is the one exception, and it has to pay for the adaptation itself.** A template
image is tinted wholesale to the menu bar's colour, so a badged image can't be one — the dot
would come out black. `PanelController.badged` therefore draws the plug itself, in
`labelColor`, and the image must be built with `NSImage(size:flipped:drawingHandler:)` rather
than composited once: the handler runs inside the button's own appearance, so `labelColor`
resolves to white on a dark menu bar and black on a light one. Compositing eagerly bakes in
whichever appearance was current when that scan finished, and the icon then stays that colour
through a light/dark switch. Verified both ways by switching appearance with the app running.

**The count is set as an `attributedTitle` in both states, never as `title`.** The count often
doesn't change when an alert clears, and assigning an unchanged string can leave the previous
colour in place — the number stays orange after the problem is gone.

**A menu bar signal blinks once per problem, not once per scan.** `PanelController` remembers
which issue IDs it has already flagged, which is why `ServerIssue.id` is kind-plus-port and
carries no pid: a restarted server is the same problem, and an ID that changed under it would
blink again every 15 seconds. The dot holds the state; the blink only says "look now".

**Sparkle's windows open *behind* the panel.** The panel is at `.popUpMenu` level, so an
update dialog appears underneath it and can only be read after dismissing the panel by hand.
`UpdateController` closes the panel from `SPUStandardUserDriverDelegate` — both
`standardUserDriverWillHandleShowingUpdate` and `standardUserDriverWillShowModalAlert`, since
the first covers the update dialog and the second the "you're up to date" and error alerts.
Closing runs synchronously inside the callback: a modal alert spins its own run loop, which
doesn't service queued main-actor work, so a `Task` hop wouldn't land until the alert was
already dismissed.

**Sparkle doesn't re-announce an update it has already presented.** If a scheduled check puts
the dialog up while the panel is closed, opening the panel afterwards covers it, and a
subsequent user-initiated check only re-focuses the existing dialog — the delegate is not
called again, so nothing closes the panel. Sparkle logs a warning about this class of problem
for background apps ("does not implement gentle reminders"). Fixing it properly means a gentle
reminder, which the menu bar dot is now the natural home for. Not done yet.

**Verify the update flow with `PORTMAN_OPEN_ON_LAUNCH=update`.** The panel's overflow menu
can't be reached through accessibility, so there's no way to click "Check for Updates" from a
script. That value opens the panel, waits until it's unambiguously up, then asks for an update.
Test against an isolated bundle ID — `BUNDLE_ID=is.ian.portman.updatecheck VERSION=0.2.9
BUILD_NUMBER=3 ./scripts/build-app.sh` — so Sparkle's state doesn't land in the real domain,
and set `SUEnableAutomaticChecks -bool NO` in it or a scheduled check races the panel and
invalidates the test.

**Issues are folded per port, not per entry.** Both halves of a conflict are one conflict, and
a stale worktree holding a contested port is usually *why* it's contested — one kill fixes
both. Counting them separately makes the menu bar overstate how much is wrong.

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

The app's name and identity are build variables (`APP_NAME`, `EXECUTABLE_NAME`, `BUNDLE_ID`,
`SIGN_IDENTITY`), and `AppInfo` reads them from the bundle. Don't hardcode any of them in
source.

`APP_NAME` is the display name and `EXECUTABLE_NAME` the binary inside the bundle, and they
differ on purpose: `Portman.app` containing `MacOS/portman`. Capitalising a command is
unusual, and it would break anyone scripting `portman` on a case-sensitive volume. The DMG
takes the lowercase name too, because it ends up in a download URL that the appcast has
already published.

## Development Commands

```sh
swift build                  # build
swift run portman            # run from source (no bundle: previews and login items won't work)
swift run portman --list     # scan and print as TSV — fastest way to check detection
swift test                   # pure-logic tests
make build                   # build dist/Portman.app
make publish-local           # build, sign, install to ~/Applications, relaunch
make dmg                     # drag-install DMG
```

`PORTMAN_OPEN_ON_LAUNCH=1|expand|settings|update` drives the panel on launch, for screenshots
and UI checks without a real click. `update` also asks Sparkle for an update once the panel is
up — see the Traps entry, which has the rest of the setup that check needs.

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

## Bundle Size

The release bundle is ~7.1 MB, ~4.1 MB compressed into the DMG.

**The app ships universal**, so it runs on every Mac that runs macOS 15 rather than only Apple
Silicon. That costs ~2.3 MB — the second slice of both the app binary and Sparkle. It's a
deliberate trade: nothing in the codebase is architecture-specific, so the alternative was
excluding Intel Macs purely as an artefact of `swift build` targeting the build machine.

`BUILD_DIR` is read from `swift build --show-bin-path` with the arch flags, never hardcoded. A
universal build lands in `.build/apple/Products/Release`, but `.build/release` is a symlink to
the single-arch directory that survives any earlier plain `swift build` — copying from it
ships one slice inside an app that claims two, and nothing about that fails loudly.

Two steps still trim what's genuinely dead, both before signing since `codesign` seals bytes:

`strip -x` on the main binary. A SwiftPM release build leaves the full symbol table behind —
over half the executable, and nothing reads it at runtime. `-x` drops local symbols only, so
public frames still symbolicate in a crash report. Universal: 4.7 MB → 2.3 MB.

Sparkle's `Headers`, `PrivateHeaders` and `Modules` are deleted. They're what you'd compile
against; a shipped app linked at build time and never opens them.

There's also a thinning step that reduces Sparkle to the app's architecture. It reads that arch
off the built binary and **no-ops while the app is universal** — it exists so that going back to
single-arch doesn't leave a megabyte of unreachable Sparkle behind. Don't hardcode `arm64` into
it; that's what makes it safe to leave in place.

The rest is the icon: `Assets.car` (1.45 MB, the layered icon macOS 26 renders itself) plus
`AppIcon.icns` (0.58 MB, for macOS 15–25). Both eras have to ship, so the icon is ~2 MB and
that's the floor unless the minimum target moves to macOS 26.

Verify a universal build with `lipo -archs` on the app binary *and* on Sparkle's five Mach-Os,
then run the Intel slice under Rosetta — `arch -x86_64 …/MacOS/portman --list`. Sparkle is a
load-time dependency, so the app surviving launch under `arch -x86_64` is what proves its Intel
slice resolves.

## Releasing

`scripts/release.sh` builds, signs, runs a pre-flight, produces a DMG, notarises, staples and
prints the appcast `<item>`.

The pre-flight deliberately does **not** run `spctl --assess`: an app that's signed but not
yet notarised always reports `rejected / source=Unnotarized Developer ID`, so gating on it
would abort every release before it could be notarised. It asserts the hardened-runtime flag
and launches the app instead. `spctl` runs after stapling, where it reflects what a
downloader actually gets.

`appcast.xml` in the repo root **is** the update feed — Sparkle reads it from
`raw.githubusercontent.com`, so committing a new `<item>` is what ships an update.

`raw.githubusercontent.com` sends `max-age=300`, so a freshly pushed `<item>` is invisible
for up to five minutes and the feed keeps serving the previous version meanwhile. Checking
for updates in that window returns "you're up to date", which reads exactly like a broken
release. Wait for the cache before concluding anything is wrong — `curl -I` the feed and
compare `source-age` against `max-age`. The feed
URL is baked into every build's Info.plist and cannot move afterwards without orphaning
everyone on an older version, so it defaults in `build-app.sh` rather than being passed per
release. (It also means the repo has to stay public.)

Update signing is an EdDSA key pair generated once by Sparkle's `generate_keys`. The **public**
half is pinned as the default `SPARKLE_PUBLIC_KEY` in `build-app.sh` — it ships in every copy's
Info.plist, so it isn't a secret, and like the feed URL it can't change without invalidating
every signature an installed copy will accept. The **private** half lives in the login keychain
and must never enter the repo; `sign_update` reads it from there.

`release.sh` parses the signature out of `sign_update` and interpolates it into the printed
`<item>` rather than leaving a `PASTE_SIGNATURE` placeholder. Hand-copying it is how you ship an
update that every installed copy then refuses, having verified it against the wrong bytes.

Losing the private key means no existing install can ever be updated again — they'd each have to
re-download by hand. It's worth knowing where your keychain backup is before the first release.
