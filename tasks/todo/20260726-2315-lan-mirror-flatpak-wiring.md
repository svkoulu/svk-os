# D7 — point `flatpak update` at the LAN mirror, then retire `archived/`

Status: **not started.** Extracted 2026-07-26 from
`20260717-1845-modular-base-rebuild-implementation-plan.md`, which is otherwise
complete and has been moved to `tasks/done/`. This is the last piece of code the
modular rebuild left open, plus the two cleanups that block on it.

Hardware/VM validation that the rebuild plan also left open was extracted
separately into `20260726-2315-hardware-validation.md`.

---

## What is actually wired today

Client-side, nothing points at the school mirror. The chain is:

1. `iso/installer/build.sh:364` curls `flathub.flatpakrepo` into the **installer
   image's** `/etc/flatpak/remotes.d/`, then installs the baked set from
   `flathub` (`:367`).
2. `:307` rsyncs that image's whole `/var/lib/flatpak` into the target. The repo
   config — and therefore the **`flathub` remote and its imported GPG key** —
   rides along.
3. On the installed machine, `files/base/usr/libexec/svk/svk-update-flatpak` runs
   `flatpak update -y --system` against whatever remotes exist. That is
   **`dl.flathub.org` over the internet.**

So updates work on a staff laptop and quietly do nothing useful on a lab machine
with no internet path — the exact case the mirror exists for. The server half is
done and shipping (`files/server/etc/systemd/system/svk-flathub-sync.{service,timer}`,
`files/server/usr/bin/svk-flathub-sync.py`).

`iso/README.md:211-217` documents this as "still TODO" and points at
`archived/files/base/usr/bin/svk-flatpak-preinstall.sh` for the logic to reuse.

## The design problem the old script has

The archived script (`svk-flatpak-preinstall.sh:36-50`) bootstrapped the mirror
remote **at first boot** by fetching `https://dl.flathub.org/repo/flathub.flatpakrepo`
over the internet and extracting `GPGKey=` from it. That was correct under the old
"install flatpaks at first boot" model. It is wrong now: **first boot is fully
offline** by design, so a first-boot internet fetch is precisely the dependency
the Titanoboa bake removed.

Options, in rough order of fit — pick one during implementation:

- **Reuse the key already on disk.** The rsync'd `/var/lib/flatpak/repo/config`
  already carries the `flathub` remote *with its GPG key imported*. Adding the
  mirror as a second `--prio=2` remote that trusts the same key needs no fetch at
  all. Cleanest, if flatpak will re-export the key from the existing remote.
- **Serve the key from the server.** `svk-flathub-sync.py:143` already extracts a
  keyfile for its own `--gpg-import`; publish it next to the repo and have the
  client pull it over the LAN. Needs the server, but the mirror needs the server
  anyway, so it adds no new dependency.
- **`flatpak remote-modify --url=`** on the existing `flathub` remote instead of a
  second remote. Simplest, but loses the fall-through to real Flathub that the old
  `--prio=2` arrangement gave staff laptops off-site.
- Bake the key at image build time — rejected by default: it is a build-time
  network dependency that isn't the registry, which CLAUDE.md's build strategy
  says to avoid.

Whichever is chosen, keep the old script's two properties: the mirror is
**non-exclusive** (unreachable mirror must fall through, never fail an update),
and trust is **Flathub's own published key**, never a blob committed to this repo.

## Where it belongs

Machine-scoped, not flavor-scoped — so `files/base/`, and per the single-image
collapse (`20260726-1957-single-image-collapse.md`) that is the only tree left
anyway. Mirror URL/hostname is per-site config; check whether it should ride the
provisioning USB (`20260719-0110-usb-provisioning-config.md`) rather than being
hardcoded to `svk-server.local:8080` the way the archived script had it.

## Then, and only then

- **Delete `archived/`.** It is currently load-bearing: `iso/README.md:216` and
  the rebuild plan both send the reader there for this logic. Once the logic is
  ported, the tree has no remaining referent. (The rebuild plan's other condition
  — "merge to `main`" — is moot; the work was done on `main` directly.)
- **Fix the `iso/` listing in `CLAUDE.md`.** It still says
  `iso/  # Titanoboa ISO pipeline (build-iso.sh, hook-anaconda.sh)`. There is no
  `hook-anaconda.sh`; the tree is `iso/build-iso.sh` + `iso/installer/{build.sh,Containerfile}`.
- Tick the "LAN-mirror `flatpak update` wiring (D7)" box in `iso/README.md:219`'s
  TODO list and rewrite the "How updates work after install" section to describe
  what shipped.

## Verify

- On an installed machine with the server reachable: `flatpak remotes --system`
  shows the mirror at the expected priority, and `ujust update-now` pulls from it
  (check the server's access log, not just a zero exit).
- With the server **down**: the same update falls through to real Flathub on a
  staff laptop, and fails cleanly (logged, non-zero, no fabricated log line) on a
  lab machine with no internet — not a hang.
- First boot with no network at all still completes without the unit erroring.
