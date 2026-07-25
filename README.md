<div align="center">

# Portman

**Every port on your Mac, and what's actually using it.**

A menu bar app that names your dev servers by project and framework, spots the ones that have
quietly died, and kills them in one click.

[Download for macOS](https://github.com/iannuttall/portman/releases/latest) ·
[ian.is/portman](https://ian.is/portman) · MIT licensed

</div>

---

## Who this is for

People who run a lot of local servers at once — several projects, a few Docker containers, an
agent or two spawning worktrees in the background. The kind of machine where `lsof -i :3000`
is muscle memory and something is always still running that shouldn't be.

If you run one dev server at a time, you don't need this.

## Quick start

[Download the DMG](https://github.com/iannuttall/portman/releases/latest) and drag it to
Applications. Requires **macOS 15 or later**, on Apple Silicon or Intel.

Press **⌥⌘P** from anywhere, or click the plug in the menu bar, and start typing.

## What makes it different

Most tools in this category list ports and kill them. That part is easy. These are the parts
that aren't:

**It knows what your servers are.** Not `node (pid 10791)` — `web :4321`, with the project
path, the git branch and its uncommitted count, and the page title of whatever it's serving.
Frameworks are inferred from `package.json`, lockfiles, Vite's dep cache and the command line:
Astro, Next.js, TanStack Start, Vite, Remix, SvelteKit, Nuxt, Angular, Expo, Rails, Django,
FastAPI and more.

**It catches wedged servers.** A dev server that's holding its port but no longer answering
looks identical to a healthy one everywhere else. Portman probes each port and flags it —
`alive, but not responding`. That distinction is the difference between "why is 3000 taken"
and "oh, that one's hung".

**It shows you the page.** Expand a row for a live thumbnail of `localhost:<port>`, so you can
tell which of your six Astro servers is the one you wanted.

**It makes port conflicts decidable.** When two things hold the same port they get their own
heading — `Conflict on :3000` — with the rivals listed underneath and always ordered by port.
The comparison you actually have to make is the thing on screen.

**It knows about your dead ones.** Servers whose project folder has been deleted, and dev
servers left behind by agent worktrees (Conductor, Claude, Codex), fold into collapsed
sections with a single `Kill all` — instead of burying the three projects you care about.

**It understands Docker.** Forwarded ports resolve back to the container, compose project,
service and working directory, and the action is `Stop container` rather than killing Docker
Desktop itself.

**It tells you who can reach it.** Every row knows whether it's bound to loopback or to a real
interface, so you can see at a glance that a database is reachable by anyone on the network
you just joined.

## Everyday use

Type to search. It matches ports, project names, frameworks, paths, git branches and page
titles.

| | |
|---|---|
| `⌥⌘P` | open the panel from any app |
| `↑` `↓` | move through the list |
| `→` `←` | expand / collapse a row |
| `⏎` | open in your browser |
| `⌘⏎` | open the project in your editor |
| `⌘C` | copy the local URL |
| `⌘⌫` | kill the selected server |
| `esc` | collapse, then clear the search, then close |

Wrap a search in slashes for a regular expression — `/astro.*43[0-9]{2}/` — then hit
**Kill all N** in the footer. That's "kill by regex", without a separate feature for it.

Sort by port, name, CPU, memory, uptime or most recently started. Group smartly (the default),
flat, by project, or by kind.

Every action lives on the expanded row: open, copy local or network URL, reveal in Finder,
open in your terminal or editor, restart the dev server with the right package manager, pin,
ignore, kill. Nothing is more than one click deep.

## Sharing a port publicly

Expand a row and hit **Share** to open a Cloudflare quick tunnel; the public URL lands in your
clipboard. Needs `cloudflared`:

```sh
brew install cloudflared
```

No Cloudflare account and no DNS setup — quick tunnels are account-free.

Requests reach your dev server with `Host: localhost:<port>`, so Vite, Next and Astro accept
them instead of answering "This host is not allowed". You don't need to touch `allowedHosts`.

**Shared links are deliberately temporary.** A tunnel closes when you stop it, quit, or
restart Portman, and you get a new address next time. Portman also kills any tunnel left
behind by a previous session at launch, so a public URL can never outlive the app that opened
it.

## Metrics

CPU, memory, uptime, thread count and an energy estimate come from `libproc`, sampled in the
background. No root, no helper tool, no polling `ps` in a loop.

Processes owned by another user or by root can't be read, and those show `—` rather than a
misleading `0`.

## Settings

Choose your terminal (Ghostty, iTerm, Terminal, WezTerm, Warp, Alacritty, kitty), editor (VS
Code, Cursor, Zed, Sublime, Xcode) and browser — only the ones you actually have installed are
offered.

Rows default to **Simple**: name, port, framework and anything that needs attention. Switch to
**Detailed** for CPU, a CPU history graph and page titles. Each element toggles individually,
and there's a Reduce motion switch that stops the list animating at all.

## Verify the download

This app reads your processes, so you should be suspicious of it. Everything below is
checkable.

**Nothing leaves your Mac.** No analytics, no telemetry, no accounts. The only network
requests are to your own localhost ports, and to Cloudflare if you explicitly share one.

**Signed and notarised**, so macOS can verify it hasn't been tampered with since it was built:

```sh
codesign --verify --deep --strict --verbose=2 /Applications/Portman.app
spctl --assess --type execute /Applications/Portman.app
```

**Checksums.** Every release publishes a SHA-256. Compare it against what you downloaded:

```sh
shasum -a 256 ~/Downloads/portman-*.dmg
```

**Or build it yourself** — see below. The build scripts are in this repo too.

## Permissions

Focusing the terminal tab a server runs in uses AppleScript, so macOS asks for Automation
access the first time. Declining is fine — Portman falls back to opening a new terminal at the
project root, which is what happens anyway for servers that have outlived their shell.

Nothing else requires a permission prompt. There is no privileged helper.

## Develop locally

```sh
swift build                  # build
swift run portman            # run from source
swift run portman --list     # scan and print as TSV, no UI
swift test                   # pure-logic tests
make build                   # build dist/Portman.app
make publish-local           # build, sign, install to ~/Applications
make dmg                     # drag-install DMG
```

`--list` is the fastest way to check detection without opening the panel.

Port discovery uses:

```sh
/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -F pcLn
```

### Layout

```
Core/       scanning, project and framework detection, Docker, metrics, git
Services/   health probing, page previews, tunnels, terminal attach, app launching
Store/      observable state, filtering, sorting, grouping, preferences
UI/         status item, panel, list, detail card, settings
```

Core is pure and testable; the UI never shells out.

If you're working on this — or pointing an agent at it — read [AGENTS.md](AGENTS.md) first. It
documents the traps, and several are subtle enough to reintroduce by accident.

## Common questions

### Does it need root?

No, and it doesn't ask for it. It reads what your own user can see. Processes owned by root or
another user appear in the list, but their metrics show `—`, and killing one fails with a
message saying so rather than pretending it worked.

### Does it run on Intel Macs?

Yes. The release is a universal binary, so it runs natively on Apple Silicon and Intel — no
Rosetta. If your Mac runs macOS 15, it runs Portman.

### Why isn't it on the Mac App Store?

It can't be. A port manager needs to run `lsof`, read other processes' metrics through
`libproc`, signal processes it doesn't own, and shell out to `docker`, `git` and `cloudflared`.
The App Sandbox forbids essentially all of that, and there's no entitlement that opens it up.
Every tool in this category ships outside the store for the same reason.

### What happens to my pins and ignore rules on update?

They're kept. The preference keys haven't changed since the first release.

### Does it slow my machine down?

It scans every 15 seconds while the panel is closed and every 2 seconds while it's open, and
the scan runs off the main thread. Health checks happen once per port rather than on every
scan. Page previews render only for a row you expand, on demand.

## License

MIT. See [LICENSE](LICENSE).
