# Port Manager

A macOS menu bar app for everything listening on your Mac — what it is, which project it belongs to,
how hard it's working, and whether it's actually alive.

Built for people running a lot of dev servers at once.

## What makes it different

**It knows what your servers are.** Not `node (pid 10791)` — `4321 · Astro · web`, with the project
path, the git branch, and the page title of whatever it's serving. Frameworks are inferred from
`package.json`, lockfiles, Vite's dep cache and the command line: Astro, Next.js, TanStack Start,
Vite, Remix, SvelteKit, Nuxt, Angular, Expo, Rails, Django, FastAPI and more.

**It catches wedged servers.** A dev server that's holding its port but no longer answering looks
identical to a healthy one in every other tool. Port Manager probes each port and flags it:
`not responding · alive but hung`.

**It shows you the page.** Expand a row and you get a live thumbnail of `localhost:<port>`, so you
can tell which of your six Astro servers is the one you wanted.

**It knows about your dead ones.** Servers whose project folder has been deleted, and dev servers
left behind by agent worktrees (Conductor, Claude, Codex), get grouped into collapsed sections with
a single `Kill all` — instead of burying the three projects you actually care about.

**It understands Docker.** Forwarded ports resolve back to the container, compose project, service
and working directory, and the action is `Stop container` rather than killing Docker Desktop.

**It makes port conflicts decidable.** When two things hold the same port, they get their own
heading — `Conflict on :3000` — with the rivals listed underneath and always ordered by port. The
comparison you actually have to make is the thing on screen.

**It tells you who can reach it.** Every row knows whether it's bound to loopback or to a real
interface, so you can see at a glance that your Docker Postgres is reachable by anyone on the
network you just joined.

## Using it

Press **⌥⌘P** from anywhere, or click the menu bar icon, and start typing. Search matches ports, project names, frameworks, paths,
git branches and page titles.

| | |
|---|---|
| `↑` `↓` | move through the list |
| `→` `←` | expand / collapse a row |
| `⏎` | open in your browser |
| `⌘⏎` | open the project in your editor |
| `⌘C` | copy the local URL |
| `⌘⌫` | kill the selected server |
| `esc` | collapse, then clear the search, then close |
| `⌥⌘P` | open the panel from any app |

Wrap a search in slashes to use a regular expression — `/astro.*43[0-9]{2}/` — then hit
**Kill all N** in the footer. That's "kill by regex" without a separate feature for it.

Sort by port, name, CPU, memory, uptime or most recently started. Group smartly (the default), flat,
by project, or by kind.

Every action lives on the expanded row: open, copy local or network URL, reveal in Finder, open in
your terminal or editor, restart the dev server with the right package manager, pin, ignore, kill.
Nothing is more than one click deep.

## Sharing a port publicly

Expand a row and hit **Share** to open a Cloudflare quick tunnel, and the public URL
lands in your clipboard. Needs `cloudflared`:

```sh
brew install cloudflared
```

No Cloudflare account and no DNS setup — quick tunnels are account-free.

Requests reach your dev server with `Host: localhost:<port>`, so Vite, Next and Astro
accept them instead of answering "This host is not allowed". You don't need to add
anything to `allowedHosts`. If your app needs to see the real public hostname, turn
that off in Settings → Apps.

**Shared links are deliberately temporary.** A tunnel closes when you stop it, quit, or
restart Port Manager, and you get a new address next time. Port Manager also kills any
tunnel left behind by a previous session at launch, so a public URL can never outlive
the app that opened it.

## Metrics

CPU, memory, uptime, thread count and an energy estimate come from `libproc`, sampled in the
background. No root, no helper tool, no polling `ps` in a loop.

Processes owned by another user or by root can't be read, and those show `—` rather than a
misleading `0`.

## Settings

Choose your terminal (Ghostty, iTerm, Terminal, WezTerm, Warp, Alacritty, kitty), editor (VS Code,
Cursor, Zed, Sublime, Xcode) and browser — only the ones you actually have installed are offered.
Set the refresh interval, pick what the menu bar shows, and manage ignore rules for noisy ports,
apps, projects and containers.

## Distribution

Direct download, signed and notarized with a Developer ID — not the Mac App Store.

That isn't a decision to revisit later; it's a constraint. A port manager needs to run `lsof`,
read other processes' metrics through `libproc`, send signals to processes it doesn't own, shell
out to `docker`, `git` and `cloudflared`, and read project directories it was never explicitly
granted. The App Sandbox forbids essentially all of it, and there's no entitlement that opens it
up. Every tool in this category ships outside the store for the same reason.

## Releasing

```sh
VERSION=0.3.0 BUILD_NUMBER=3 \
  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  NOTARY_PROFILE=portmanager \
  SPARKLE_FEED_URL=https://example.com/appcast.xml \
  SPARKLE_PUBLIC_KEY=your-ed-public-key \
  ./scripts/release.sh
```

Builds, signs, notarizes, staples, and prints the `<item>` block to paste into
`appcast.xml`. Store notary credentials once with
`xcrun notarytool store-credentials`.

Updates use [Sparkle](https://sparkle-project.org). Generate the signing key pair once
with Sparkle's `generate_keys` — the private key lives in your keychain and must never be
committed; only the public key goes into the build. A build without `SPARKLE_FEED_URL`
and `SPARKLE_PUBLIC_KEY` simply has no updater rather than a broken one, so local builds
need neither.

The app name, bundle identifier and signing identity are all build variables
(`APP_NAME`, `BUNDLE_ID`, `SIGN_IDENTITY`), so renaming the app or moving it to a
different developer account doesn't require touching the source.

## Install

```sh
make publish-local
```

Builds a release bundle, ad-hoc signs it, installs to `~/Applications`, and enables Open at Login.
Run the same command to update.

Override the destination or sign with a real identity:

```sh
INSTALL_DIR="/Applications" make publish-local
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make publish-local
ENABLE_LOGIN=0 make publish-local
```

Build a drag-install DMG:

```sh
make dmg
```

Requires macOS 15 or later.

## Development

```sh
swift run PortManager          # run from source
swift run PortManager --list   # scan and print as TSV, no UI
swift test                     # parsing, search, sorting, folding, classification
make build                     # build the .app bundle into dist/
```

`--list` is the fastest way to check detection without opening the panel.

Port discovery uses:

```sh
/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -F pcLn
```

### Layout

```
Core/       scanning, project and framework detection, Docker, metrics, git
Services/   health probing, page previews, terminal attach, app launching
Store/      observable state, filtering, sorting, grouping, preferences
UI/         status item, panel, list, detail card, settings
```

Core is pure and testable; the UI never shells out.

## Permissions

Focusing the terminal tab a server runs in uses AppleScript, so macOS asks for Automation access the
first time. Declining it is fine — the app falls back to opening a new terminal at the project root,
which is what happens anyway for servers that have outlived their shell.

## License

MIT.
