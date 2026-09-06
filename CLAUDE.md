# CLAUDE.md — fork notes

This is a fork of [Midrags/SFF](https://github.com/Midrags/SFF) (SteaMidra) at
[aidankinzett/SFF](https://github.com/aidankinzett/SFF), carrying local fixes for
bugs that break downloads on Linux. GitHub Actions is disabled on the fork (it
was **not** disabled by default on creation — it had to be turned off explicitly)
so pushing a `v*` tag can't kick off a release build.

## Layout

| | |
|---|---|
| `main` | clean mirror of `upstream/main`, never committed to directly |
| `local-fixes` | all local work; **build AppImages from this branch** |
| `origin` | `https://github.com/aidankinzett/SFF.git` |
| `upstream` | `https://github.com/Midrags/SFF.git` |

Commits are kept small and single-purpose so any one can be dropped if upstream
fixes it independently.

## Why the fork exists

Four commits, each fixing a distinct bug found by tracing a failing download:

**1. Skip the native downloader by default** (new `SKIP_NATIVE_DOWNLOADER` setting,
default on, in Settings → Downloads).

`native_downloader.py` calls `cdn.get_auth_token(...)`, **which does not exist** in
`steam==1.4.4` (the pinned and latest release — verified against `dir(CDNClient)`),
nor in upstream master, where `get_auth_token` and `cdn_auth_token` appear zero
times. Older tags weren't checked. The call has always raised `AttributeError`
inside a bare `except`, so every chunk URL is built with an empty token. Steam's
`cache*.steamcontent.com` hosts answer those with HTTP 403, so every depot falls
through to DepotDownloaderMod anyway — just after a long CDN timeout first.

This is not fixable in the current design: minting a CDN auth token needs a Steam
session with a **license for the depot**, which an anonymous login doesn't have for
paid games. The chunk request is a plain unauthenticated GET, so the CDN can't know
who you are — the 403 is a blanket "no token supplied". The native downloader can
therefore only ever work against hosts that serve chunks token-free.

> **Note on upstream PR #145.** Its diagnosis is wrong. It claims the code "minted a
> single token and appended it to every host", but no token was ever minted — the
> method doesn't exist. Its real effect is to replace the single permissive
> `steampipe.akamaized.net` fallback with the full `cache*.steamcontent.com` list,
> which enforces auth strictly, so it turns partial downloads into total 403s. It
> does correctly fix a real bug (`CDNClient.servers` is a `deque`, so the old
> `isinstance(raw, list)` check was always False) — but that fix is what breaks it.

**2. Drop the unused Steam `CDNClient` from the manifest paths** — this was the
`CDN Client timed out. Retrying (n/5)` stall, ~125s per download.

`CDNClient.__init__` calls `load_licenses()` → `steam.get_product_info()`, which
drives the SteamClient's gevent hub. **gevent binds a hub to the thread that first
drove it**, and the app deliberately pins all Steam CM traffic to a dedicated
`steamcm` thread (`_CM_EXECUTOR` in `sff/network/steam_client.py`). `get_cdn_client()`
ran on a download worker instead, so the greenlet was never scheduled and every
attempt burned gevent's full 25s timeout, 5 retries deep. Measured, same client:

```
same thread (steamcm) : OK in 1.30s (20 servers)
different thread      : gevent.Timeout after 25.03s
```

Nothing needed the client — `download_single_manifest` ignores its `cdn_client`
argument entirely and fetches over plain HTTP — so both construction sites were
removed rather than marshalled onto the CM thread. **If you ever reintroduce a
caller, wrap it in `_run_on_cm_thread`.**

Not environment-specific: it reproduces on any machine, AppImage or source.

**3. `get_request_raw`: reject non-2xx** instead of returning the error page.

It returned `response.content` regardless of status. Every caller feeds that
straight into a `.manifest` file, and Steam's CDN answers 504/403 with an HTML
error page, so a 280-byte Akamai "504 Gateway Time-out" page was treated as a
downloaded manifest and written into `depotcache` — where later runs would find it
on disk and reuse it.

**4. `git` + `binutils` in the AppImage build prerequisite check**, plus
`build_linux_appimage_docker.sh`. Both tools are needed by the build and neither was
checked for; they're preinstalled on GitHub runners so CI never surfaced them.
Commit 4 is upstream-PR-safe on its own — it has no bearing on 1–3.

## Pulling in upstream updates

```bash
git fetch upstream
git checkout main && git merge --ff-only upstream/main
git checkout local-fixes && git rebase main
```

Then re-check each fix against the new upstream — if any was fixed upstream, drop
that commit during the rebase rather than resolving conflicts against it.

## Building the AppImage

`build_linux_appimage.sh` is Debian/Ubuntu-only (probes `dpkg` and `python3.12`), so
on Arch-family distros it runs in a container:

```bash
git worktree add --detach ../SFF-build local-fixes   # first time only
git -C ../SFF-build checkout --detach local-fixes    # subsequently, to move it
bash build_linux_appimage_docker.sh ../SFF-build
```

Build in a **separate worktree**, never in place — the build creates a Python 3.12
`.venv` and would clobber the one you run from source with. Pass `--fresh` only when
`requirements-linux.txt` changes; otherwise the container reuses its venv and skips
straight to PyInstaller (~3 min instead of ~15).

`ubuntu:24.04` matches upstream CI (`release.yml`: `runs-on: ubuntu-24.04`), and its
older glibc (2.39) keeps the AppImage portable — a binary linked against 2.39 runs
on newer systems, not the reverse.

## Installing

Both target machines run CachyOS with `fuse2` installed, so the AppImage mounts
natively (no `--appimage-extract-and-run` needed). Each has an existing launcher at
`~/.local/share/applications/steamidra.desktop` pointing at the path below, so
replacing the file in place is all that's required.

```bash
cd ~/.local/share/SteaMidra
cp -a SteaMidra.AppImage SteaMidra.AppImage.upstream-<version>.bak
cp /path/to/SteaMidra-<version>-x86_64.AppImage SteaMidra.AppImage.new
chmod +x SteaMidra.AppImage.new && mv -f SteaMidra.AppImage.new SteaMidra.AppImage
```

Copy to a temp name and `mv` into place so a partial copy can't clobber a working
install. Never touch the sibling files in that directory — `settings.bin`,
`saved_lua/`, `recent_files.json`, `api_cache.json`, `manifests/`, `provider_cache/`,
`SLSsteam/` are live app data.

The remote machine is `deck@192.168.86.113` (key-based SSH; despite the username it
is **CachyOS, not SteamOS**, glibc 2.44).

## Running from source

```bash
QTWEBENGINE_DISABLE_SANDBOX=1 .venv/bin/python Main_gui.py
```

- Quit any running AppImage first — `sff.single_instance` uses a QLocalServer, so a
  second launch just forwards a SHOW request to the running one and exits silently.
- Output goes to `debug.log`, **not stdout** (`Main_gui.py` sets a FileHandler).
- From source, `root_folder()` resolves to the repo, so the repo directory becomes
  the data dir with its own settings — separate from the AppImage's.
- Running in the repo writes `all_games.txt`, `manifests/`, `debug.log`, and modifies
  the tracked `sff/lua/contributor_state.json`. These are in `.git/info/exclude`
  (local only); don't commit them.
- Deps install fine on Python 3.14 despite the build script assuming 3.12.

## Environment notes

- `steampipe.akamaized.net` returns **504 for everything** from this network,
  including nonexistent depots. The GMRC mirrors hand out valid request codes, but
  the CDN they point at is unreachable, so that cascade always fails here — which is
  why manifest fetching runs ManifestHub + GitHub first.
- A nonexistent chunk returns 404 from `cache*.steamcontent.com` while real chunks
  return 403 — that difference is how the 403 was confirmed as an auth refusal
  rather than a missing chunk.
