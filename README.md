# Port Manager

A tiny macOS menu bar app for seeing listening ports and killing the process that owns one.

## Run from source

```sh
swift run PortManager
```

Check the scanner without opening the menu bar app:

```sh
swift run PortManager --list
```

## Build the app

```sh
chmod +x scripts/build-app.sh
scripts/build-app.sh
open "dist/Port Manager.app"
```

## Install locally

For daily use, install a signed local copy into `~/Applications`:

```sh
chmod +x scripts/*.sh
make publish-local
```

Use the same command whenever you make changes:

```sh
make update-local
```

That will:

- build a release app bundle
- ad-hoc sign the `.app`
- quit any running dev or installed copy
- replace `~/Applications/Port Manager.app`
- remove quarantine metadata if present
- verify the code signature
- launch the installed app

Once launched from `~/Applications`, `Open at Login` has the right bundle shape to work as a normal login item.

You can override the install location:

```sh
INSTALL_DIR="/Applications" make publish-local
```

You can also sign with a real Developer ID identity if you have one:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make publish-local
```

## What it does

- Shows the count of visible listening ports in the menu bar.
- Lets you pin useful projects, containers, or individual ports to the top.
- Lists ports as `3000 · Astro · my-project` when it can identify the project.
- Infers common dev stacks from project files, including Astro, Next.js, TanStack Start, Vite, React, SvelteKit, Nuxt, Rails, Django, and FastAPI.
- Shows the project path in each port submenu, with actions to copy it or reveal it in Finder.
- Keeps Docker Desktop forwarded ports under one `Docker Containers` submenu, identified by container, compose project/service, image, and working directory.
- Uses `Stop Container` for Docker ports instead of killing Docker Desktop itself.
- Collapses multi-port dev servers to their primary app port and moves helper/debug ports under `Other Listening Ports`.
- Refreshes port data in the background so opening the menu stays fast.
- Hides noisy system ports by default. Use `Show System Ports` to see everything.
- Groups repeated projects when the list is long, e.g. `Astro · my-project · 12 ports`.
- Adds `Kill All Processes` on grouped projects so you can clear every PID behind a noisy project at once.
- Opens `http://localhost:<port>` in the browser.
- Copies local and network URLs.
- Sends `SIGTERM` to kill the owning process.

Port detection uses:

```sh
/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -F pcLn
```
