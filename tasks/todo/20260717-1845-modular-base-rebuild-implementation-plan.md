# Implementation plan — rebuild svk on the modular finpilot pattern

Status: **planning only — no repo files touched yet.** This is the execution
plan for the spec in
[`20260717-1822-modular-base-rebuild.md`](20260717-1822-modular-base-rebuild.md).
Read that spec first for the *why*; this file is the *how*, in order, with the
concrete file moves and the decisions that must be made before each phase.

## What "done" looks like

- `svk-base` is assembled from a raw `quay.io/fedora-ostree-desktops/silverblue`
  base + cherry-picked pieces of `projectbluefin/common`, following finpilot's
  multi-stage `ctx` pattern — **not** `FROM ghcr.io/ublue-os/bluefin:stable`.
- `svk-student` / `svk-staff` still build `FROM ghcr.io/svkoulu/svk-base` and
  still produce a locked kiosk and a normal staff desktop respectively; only the
  base they inherit changed shape. Every svk customization currently in the repo
  is either re-homed, consciously dropped, or replaced by an upstream mechanism —
  nothing is silently lost.
- `svk-server` (uCore) is **unchanged**; verify only.
- CI still builds all four, ends each in `bootc container lint`, cosign-signs
  with the existing key, and the fleet's `policy.json` still verifies.
- The two desktop ISOs still build, and the Firefox / offline-app question from
  the spec has a concrete answer baked in.

## Ground truth gathered this session (verified against the clones)

- **finpilot's shape** (`~/bluefin-repos/projectbluefin-finpilot/`): `Containerfile`
  defines named stages `common` and `brew` (pinned by digest), a `scratch`-based
  `ctx` stage that gathers `build/`, `custom/`, `/oci/common`, `/oci/brew`, then a
  final stage `FROM silverblue:44@sha256:…`. Build logic runs via
  `RUN --mount=type=bind,from=ctx,...` calling numbered scripts
  (`build/00-image-info.sh`, `build/10-build.sh`), then `build/clean-stage.sh`,
  then `bootc container lint --fatal-warnings`.
- **Package installs use `dnf5`**, not `rpm-ostree install`
  (`dnf5 config-manager setopt keepcache=1 install_weak_deps=0`; `dnf5 install -y`),
  with `--mount=type=cache` for the dnf/rpm-ostree caches. This is a real change
  from svk's current `rpm-ostree install` loop and its idempotency guards.
- **Branding** is a self-contained script (`build/00-image-info.sh`) driven by
  `ARG IMAGE_NAME/IMAGE_VENDOR/UBLUE_IMAGE_TAG/BASE_IMAGE_NAME/FEDORA_MAJOR_VERSION`
  → writes `/usr/share/ublue-os/image-info.json` and appends identity to
  `/usr/lib/os-release`. Drop-in for svk with our own ARG values.
- **Flatpaks, upstream-native**: `common` ships `flatpak-preinstall.service`
  (`shared/usr/lib/systemd/system/`, `ExecStart=/usr/bin/flatpak preinstall -y`,
  `After=network-online.target`) and reads `*.preinstall` INI files from
  `/usr/share/flatpak/preinstall.d/` (+ `/etc/flatpak/preinstall.d/`). finpilot's
  `custom/flatpaks/*.preinstall` are copied there by `build/10-build.sh`. This is
  **functionally svk's `svk-flatpak-preinstall.service` + `flatpaks.list`**, done
  the upstream way. Decision point below.
- **`common` gnome extensions are git submodules** — the shallow clone only
  materialized the one committed dir
  (`system_files/bluefin/usr/share/gnome-shell/extensions/custom-command-list@storageb.github.com`);
  the "set of 9" from the spec are uninitialized submodules. If we want any, we
  fetch them individually from source, not from this clone.
- **`bazaar.preinstall`** exists in
  `common/system_files/bluefin/usr/share/flatpak/preinstall.d/bazaar.preinstall`
  (`io.github.kolunmi.Bazaar`) — the real app-store-UI mechanism, and the natural
  "staff install without admin" answer.
- **finpilot's ISO** (`iso/iso.toml`) is a plain `bootc-image-builder` Anaconda
  kickstart that just `bootc switch`es post-install — it does **not** bake
  flatpaks. The offline-flatpak bake lives only in `projectbluefin/iso`
  (Titanoboa). So finpilot alone does not solve svk's offline-app requirement;
  that's still a separate decision (Phase 5).

## Target repo layout (after rebuild)

```
archived/                       # everything from the current repo, verbatim, for reference
Containerfile.base              # multi-stage: common(+?) -> ctx -> silverblue -> svk-base
Containerfile.staff             # FROM ghcr.io/svkoulu/svk-base  (thin, ~unchanged shape)
Containerfile.student           # FROM ghcr.io/svkoulu/svk-base  (thin, ~unchanged shape)
Containerfile.server            # FROM ucore  (UNCHANGED)
build/                          # base's numbered scripts (finpilot style)
  00-image-info.sh              #   branding -> os-release + image-info.json
  10-packages.sh                #   dnf5 installs (tailscale repo, print stack, CLI, mDNS)
  20-services.sh                #   systemctl enable (sshd, avahi, tailscale, hostname, power, flatpak)
  30-users-admin.sh             #   admin account + sudoers + ssh hardening perms
  40-desktop.sh                 #   dconf update, app-restriction chmods, CA trust
  clean-stage.sh                #   from finpilot verbatim (or lightly trimmed)
custom/                         # base's cherry-pick / data inputs
  flatpaks/*.preinstall         #   fleet flatpak set (see Phase 5 decision)
  files/                        #   svk static tree (was files/base/), COPY'd in build
build.student.sh                # student's script (adapted: dnf5, no brew-strip needed)
build.staff.sh                  # staff's script (adapted: mostly empty)
build.server.sh                 # UNCHANGED
files/                          # student/, staff/, server/ static trees (base's moves under custom/files)
cosign.pub / cosign.key         # UNCHANGED
server.bu, secrets/             # UNCHANGED
.github/                        # build.yml + action adapted for the new base build
```

> Exact `build/` numbering and whether base's static tree lives under
> `custom/files/` vs staying at `files/base/` is a style call — settle it in
> Phase 1, keep it consistent, and reflect it in CLAUDE.md.

---

## Phase 0 — Preparation (mechanical, low-risk)

1. `git switch -c rebuild/modular-base` — do the whole rebuild on a branch; `main`
   keeps building the current fleet until the new base is proven.
2. `mkdir archived/` and `git mv` **every** current top-level build artifact into
   it (`Containerfile.*`, `build.*.sh`, `files/`, `server.bu`, the two workflow
   files, the composite action, `README.md`, `TODO.md`, `prompt.md`). Keep
   `cosign.pub/.key`, `secrets/`, `.gitignore`, `CLAUDE.md`, `tasks/` at root.
   Rationale: the spec explicitly authorizes "move all current files into an
   archived folder" — this gives a clean slate while keeping every current file
   one `git mv` away as the reference implementation.
3. Copy the finpilot skeleton in as the new scaffold:
   `cp -r ~/bluefin-repos/projectbluefin-finpilot/{Containerfile,build,custom,iso,Justfile,.dockerignore,.hadolint.yaml} .`
   then immediately strip finpilot's brew/gaming/example content we know we don't
   want (see cherry-pick matrix). Do **not** copy finpilot's `.github/` wholesale —
   svk's signing/mirror CI is bespoke and must be adapted deliberately (Phase 4),
   not replaced by finpilot's `projectbluefin/actions` reusable actions.
4. Commit this as one "scaffold" checkpoint so every later diff is reviewable
   against a known baseline.

> Note: the finpilot `custom/`, `build/`, `iso/` files are MIT-licensed template
> content meant to be edited — copying them in and rewriting is the intended use,
> not a fork we must track upstream.

## Phase 1 — Rebuild `svk-base` on the modular pattern

This is the heart of the work. Sub-steps:

### 1a. `Containerfile.base` (model on finpilot's `Containerfile`)
- Stages: `FROM ghcr.io/projectbluefin/common:latest@sha256:… AS common`. **Omit
  the `brew` stage entirely** — svk strips Homebrew from every image today, so
  never import it (this alone deletes the brew-strip code from student/staff).
- `FROM scratch AS ctx` → `COPY build /build`, `COPY custom /custom`,
  `COPY --from=common /system_files /oci/common`.
- Final stage `FROM quay.io/fedora-ostree-desktops/silverblue:<N>@sha256:…`.
  **Decision D1 (base tag):** pin by digest + adopt Renovate (finpilot's model) so
  weekly rebuilds are reproducible and bumps are reviewable — *recommended* — vs a
  floating `:stable`-style tag matching svk's current mental model. Digest-pin is
  the current best practice and the whole reason for the rebuild.
- `ARG` block with svk identity: `IMAGE_NAME=svk-base`, `IMAGE_VENDOR=svkoulu`,
  `UBLUE_IMAGE_TAG=stable`, `BASE_IMAGE_NAME=silverblue`, `FEDORA_MAJOR_VERSION=<N>`.
- `RUN --mount=type=bind,from=ctx…` invoking each `build/NN-*.sh` in order, then
  `clean-stage.sh`, then `RUN rm -rf /opt && ln -s /var/opt /opt`, `CMD ["/sbin/init"]`,
  `RUN bootc container lint --fatal-warnings`.
- **Decision D2 (`--fatal-warnings`):** finpilot lints with `--fatal-warnings`;
  svk currently lints without. Adopt `--fatal-warnings` on a clean base (fewer
  inherited warnings to fight) — but expect the first build to surface warnings
  the fused Bluefin base was hiding; budget time to resolve them.

### 1b. Split `build.base.sh` into numbered `build/` scripts
Port the *logic* of the current `build.base.sh`, converting mechanism:
- **`rpm-ostree install` → `dnf5 install -y`.** On a raw silverblue base most of
  svk's current idempotency guards (`rpm -q … || to_install+=`) become
  unnecessary because the packages aren't already present — but keep guards where
  a package *might* already be in silverblue. Add the Tailscale repo before its
  install (`dnf5 config-manager` / drop the `.repo`), as today.
- **`rpm-ostree override remove` → `dnf5 remove`** where student strips packages —
  and note that gnome-tour / malcontent-control / input-remapper / Distrobox /
  Homebrew **are not on a raw silverblue base at all**, so most of student's and
  all of staff's "strip" code simply *deletes* (spec learning #4). Verify each
  against a real silverblue image list before assuming; `malcontent-control` in
  particular needs the Decision D5 spike (does `malcontent` the library survive).
- Preserve exactly, re-homed into the right numbered script: admin account +
  `/etc/sudoers.d` perms + sshd enable/hardening; avahi + `nss-mdns` nsswitch
  edit; power-profile service + udev; hostname-claim service; CA-trust rebuild;
  the app-restriction `chmod 700` + `.desktop` removal loop; `dconf update`.
- **`files/base/` static tree** moves under `custom/files/` (or stays `files/base/`
  — D-style) and is `COPY`'d/`rsync`'d into `/` inside an early build script or
  directly in the Containerfile. `cosign.pub` still lands at
  `/etc/pki/containers/svk-cosign.pub`.

### 1c. Firefox — **Decision D3: RESOLVED → Flatpak Firefox (Bluefin's model)**
Keep svk's existing Flatpak Firefox; do **not** ship RPM Firefox. Consequences on
the new raw-silverblue base:
- Silverblue ships Firefox as an **RPM by default**, so we must **exclude/remove
  it** the way Bluefin does (its `04-packages.sh` `EXCLUDED_PACKAGES`): `dnf5
  remove -y firefox firefox-langpacks` in a build script (verify exact package
  names against the chosen `silverblue:<N>`). Otherwise both an RPM and a Flatpak
  Firefox would ship.
- `org.mozilla.firefox` is **not** installed by the image at all — it goes into the
  Titanoboa ISO flatpak list (`flatpaks/common.list`, Phase 5), so it's baked into
  the ISO and present with zero first-boot network. The image's only Firefox action
  is *excluding the RPM*.
- svk's existing uBO managed-policy work carries over **unchanged**: the per-image
  full-override `policies.json` (`files/{base,staff,student}/etc/firefox/policies/`)
  + the `files/base/etc/flatpak/overrides/org.mozilla.firefox` that gives the
  Flatpak read access to that policy dir (README §uBlock Origin). This already
  targeted Flatpak Firefox, so no re-pointing needed.

### 1d. Branding (`build/00-image-info.sh`)
Copy finpilot's script, set svk `IMAGE_PRETTY_NAME` / URLs. Cosmetic beyond the
identity fields; background/logo optional and low priority (spec). The identity
fields DO matter — `bootc`/`fastfetch`/update tooling should report `svk-base`,
not `finpilot`/`bluefin`.

### 1e. Build & lint locally
`podman build -f Containerfile.base -t svk-base .` until it passes
`bootc container lint --fatal-warnings`. This is the gate for Phase 2.

## Phase 2 — Adapt `svk-student` / `svk-staff`

Both keep `FROM ghcr.io/svkoulu/svk-base:latest` and their `COPY files/<img>/` +
`build.<img>.sh` shape. Changes:
- **Delete the brew/Distrobox strip blocks** from both (never added by the new
  base). Delete student's gnome-tour/malcontent-control/input-remapper
  `override remove` block **unless** the D5 spike shows silverblue pulls one in as
  a dependency — re-verify, don't assume.
- Convert any remaining `rpm-ostree` calls to `dnf5`.
- Student's dconf lockdown, polkit rules, opilas account, skel reset, bluetooth-off,
  Wi-Fi lockdown, autologin: **all carry over unchanged** (they're svk-authored,
  not base-dependent).
- Re-confirm the `.desktop` files student removes (discourse/documentation/
  system-update) still exist on the new base — some came from `projectbluefin/common`
  which we now only *partially* cherry-pick, so they may already be absent
  (a strip that becomes a no-op, or a file we simply never add).
- **GNOME extensions (spec):** decide per-extension, and be *more* conservative on
  student (each is lockdown surface). Default: adopt none from `common` unless a
  specific need appears; `custom-command-list` is the only one actually present in
  the clone anyway.

## Phase 3 — `svk-server` (verify-only)

No changes. After the base rebuild, run `podman build -f Containerfile.server -t
svk-server .` once to confirm nothing about the repo restructure (paths, shared
files) broke it. It shares no build code with the desktop images and is uCore-based.

## Phase 4 — CI (`.github/`)

Adapt svk's bespoke pipeline to the new base build. The distinction that matters:
finpilot's `projectbluefin/actions` are **modular**, so treat the *signing/push*
half and the *build-optimization* half separately — they are not a package deal.

### 4a. Keep bespoke — the fleet's security/update model depends on it (firm)
- **Signing stays exactly as-is.** svk signs with a **key** (`COSIGN_PRIVATE_KEY`,
  cosign **v2.5.3** pinned) and every machine enforces that key via baked-in
  `cosign.pub` + `policy.json` + `registries.d` `use-sigstore-attachments` (the
  `sha256-<digest>.sig` scheme). finpilot's `sign-and-publish` action is
  **keyless OIDC/Fulcio** and `continue-on-error: true` (signing optional) — both
  incompatible with svk: a keyless signature is invisible to svk's key-based
  policy, so adopting it would make every machine reject updates (the #1 project
  risk). Do **not** touch the cosign path until `registries.d` support for the OCI
  1.1 referrer scheme is confirmed on real fleet hardware.
- **Keep the composite `build-image` action** (login → build → push two tags →
  cosign-sign by digest). It's image-agnostic and correct.
- **Keep the 4-image structure**: `build-base` → `build-derived` (student/staff)
  `needs: build-base`, independent `build-server`. finpilot is single-image; its
  workflow shape does not map onto svk's fan-out. Keep `fail-fast: false`, the
  weekly cron, and the notify-on-failure job (this is why the project exists).
- **ghcr pull-through mirror** (`registries.conf.d`/`registries.d`) is svk-specific;
  finpilot has no equivalent — nothing to adopt there.

### 4b. Build-half actions — an à-la-carte menu, adopt on their own merits (optional)
These touch **none** of the signing path and are independently cherry-pickable:
- `bootc-build/dnf-cache` (restore/save) — cross-run dnf cache persistence.
- `bootc-build/setup-runner` — btrfs storage backend + podman update.
- `bootc-build/chunka` (rechunking) — regroups layers for **smaller OTA deltas**,
  directly relevant to svk's weekly-rebuild → every-machine-pulls model.
- `bootc-build/generate-tags`, `detect-changes` — tag/skip helpers.

**Decision D4 (dnf cache) — revised.** Two viable answers, pick per appetite:
- (a) *Adopt `bootc-build/dnf-cache`* — the purpose-built answer to cache
  persistence, pinned + Renovate-tracked. Cleanest if we're comfortable taking a
  third-party action into the build path. **Recommended** now that the reason to
  avoid it (signing coupling) is shown not to apply.
- (b) *Keep `--mount=type=cache` only* — harmless no-op without a warm CI cache;
  defer persistence until build times justify it. Zero new dependencies.

Adopting any 4b action is a build-speed/OTA-quality decision, reversible, and
carries no fleet-security implication — the opposite of the 4a signing path.

- `build-base` job: point at the new `Containerfile.base`. The multi-stage build
  pulls `projectbluefin/common` by digest — public image, runner can fetch it.
  Pass `--secret id=GITHUB_TOKEN` only if a build script needs it (finpilot does
  for COPR; svk currently does not — likely omit).
- Reference only, do not import wholesale: finpilot's `.agents/skills/finpilot-ci.md`
  documents how these actions fit together, if we want their rationale.

## Phase 5 — ISOs via Titanoboa (offline flatpak bake)

### Decision D6 — RESOLVED: bake flatpaks at ISO time with **Titanoboa** (Route A)

Chosen by the user 2026-07-17: build the two desktop ISOs with **Anaconda +
Titanoboa** (the same pipeline `projectbluefin/iso` uses), which pre-bakes the
flatpak set into the ISO so first boot is **fully offline**, landing the apps in
`/var/lib/flatpak` (system scope → survive the student home-reset). This
**replaces svk's current plain-BIB `iso.yml`.**

**Consequences of this choice (all accepted):**
- **Flatpaks leave the image build entirely.** `svk-base`/`-student`/`-staff`
  images stay lean — **no** build-time flatpak install, so the B2 spike work is
  shelved (it informed the call; not carried forward). No +4–6 GB image, no
  read-only-`/usr` risk, no bwrap-in-build concern.
- **Provisioning is materially the same end-state as today.** Titanoboa still
  installs *our image* from the ISO (`ostreecontainer --transport=containers-storage`),
  then `bootc switch --mutate-in-place --enforce-container-sigpolicy --transport
  registry ghcr.io/svkoulu/svk-<img>:stable` **re-points the origin to the
  registry** so auto-updates track ghcr (via `bootc-fetch-apply-updates.timer`).
  The `--enforce-container-sigpolicy` aligns with svk's cosign policy — good.
- **Not `bootc switch`-portable:** flatpaks are now an *ISO-install* artifact, not
  an image artifact. A machine provisioned by bare `bootc switch` (the README's
  break-glass path) won't have them — acceptable, since all real provisioning is
  via the student/staff ISOs.

**Titanoboa adoption specifics:**
- **Source (N3):** track `ublue-os/titanoboa` upstream, **pinned** (digest/tag +
  Renovate), and adapt a slimmed `configure_iso_anaconda.sh` for svk — do **not**
  fork the whole `projectbluefin/iso` repo. Reference its flow:
  `flatpaks/*.list` → Justfile stages a flatpak repo by running the target image →
  Titanoboa embeds it → `install-flatpaks.ks` `%post --nochroot` rsyncs
  `/var/lib/flatpak` onto the target.
- **Secure Boot (N4): SKIP.** Drop the `secureboot-enroll-key.ks` `%post`. svk adds
  no custom kmods on the raw-silverblue base; the Fedora-signed kernel already
  works under firmware Secure Boot. Removes the `universalblue` enrollment password
  and the key-fetch entirely.
- **Two ISOs** (student, staff), each its own Titanoboa run with its own flatpak
  list (below).

### Flatpak app lists (N2) — RESOLVED: shared base + per-flavor extras

Layered like Bluefin's `system-flatpaks.list` (+ `-dx.list`):
- `flatpaks/common.list` — shared fleet set (Firefox, LibreOffice, VLC, GIMP, the
  video tools — svk's current `flatpaks.list`).
- `flatpaks/student.list` — student-only additions (educational apps; may be empty
  initially).
- `flatpaks/staff.list` — staff-only additions.
- The **student** ISO bakes `common.list + student.list`; the **staff** ISO bakes
  `common.list + staff.list` (concatenate at ISO-build time). Firefox lives in
  `common.list`, so the image no longer installs it any way (D3: image just
  *excludes* the RPM Firefox).

### Ongoing flatpak updates (D7/D8) — RESOLVED: via the **LAN mirror**

Baked flatpaks sit in mutable `/var/lib/flatpak` and update on **flatpak's own
timer**, not with the OS image. Chosen policy: **students update from the server's
curated Flathub mirror over the LAN** (no internet). This **keeps** the whole
`svk-flathub-sync.py` + nginx-serve subsystem — now justified by *ongoing updates*,
not first-boot speed. So **D8 = KEEP the mirror.**

- svk's old first-boot `svk-flatpak-preinstall.service` (the *install* path) is
  **deleted** — first boot is offline/baked now. But the piece of it that adds the
  **LAN mirror as a flatpak remote** (the fresh-GPG-key extraction, `--prio`) is
  **repurposed and kept**: it's what makes `flatpak update` pull from the mirror.
- **Impl item to design (not a blocker):** ISO-build-time bake pulls from *real*
  Flathub (CI can't reach `svk-server.local`), so baked apps carry origin
  `flathub`. To make on-machine *updates* come from the mirror, either (a) repoint
  the `flathub` remote URL to the mirror with real-Flathub fallback, or (b) prefer
  the mirror via remote priority. Settle during Phase 5.
- **Students:** enable a flatpak-update timer scoped to the LAN mirror. Reconcile
  with the kiosk dconf locks (students can't *install/uninstall* via Software, but
  the system-level update timer still runs) — verify the locks don't block the
  timer.

Two ISOs confirmed; the spec's "two precisely-scoped images" reasoning is unchanged.

## Cherry-pick matrix — `projectbluefin/common`

| Path in `common` | Take? | Notes |
|---|---|---|
| `shared/.../flatpak-preinstall.service` | **No** | first-boot pull mechanism — rejected by D6/D7 (set is baked at build) |
| `bluefin/.../preinstall.d/bazaar.preinstall` | **Maybe (staff only)** | app-store UI for staff self-serve; ties to the open server-mirror question (D6 consequence). Never on student |
| `bluefin/etc/dconf/db/distro.d/*` | **Diff first** | compare vs svk `00-svk-desktop`/`00-svk-lockdown` before adopting (spec) |
| gnome-shell extensions (submodules) | **Per-item, mostly no** | only `custom-command-list` present in clone; lockdown surface on student |
| brew Brewfiles / `brew-preinstall` | **No** | svk strips Homebrew |
| homebrew `preinstall.d/*.Brewfile` | **No** | same |
| Framework/ASUS/OEM hooks, gaming | **No** | irrelevant to fleet hardware (spec) |
| JetBrains/VSCode Bazaar warning hooks | **No** | spec: not wanted |

## Customization inventory — where each current svk piece lands

| Current svk file/behavior | New home | Change |
|---|---|---|
| `files/base/**` static tree | `custom/files/**` (or keep `files/base/`) | path move only |
| `build.base.sh` package installs | `build/10-packages.sh` | `rpm-ostree install`→`dnf5 install` |
| admin acct + sudoers + sshd | `build/30-users-admin.sh` | logic unchanged |
| avahi/nss-mdns, power, hostname, CA | `build/20-services.sh` / `40-desktop.sh` | unchanged logic |
| app-restriction chmod loop | `build/40-desktop.sh` | unchanged |
| `flatpaks.list` (app set) | Titanoboa `flatpaks/common.list` (+ `student.list`/`staff.list`) | D6/N2 — ISO bake input, per-flavor |
| `svk-flatpak-preinstall.service` (install path) | **deleted** (first boot is baked/offline) | D6/D7 |
| mirror-remote logic (GPG-key extraction, `--prio`) | **kept, repurposed** → makes `flatpak update` pull from LAN mirror | D7/D8 |
| `svk-flathub-sync.py` + nginx mirror (server) | **kept** — now justifies ongoing flatpak updates | D8 = keep |
| Firefox flatpak + override + policies | exclude RPM firefox (image); firefox baked via ISO list; override + policies **unchanged** | D3 |
| `iso.yml` (plain BIB) | **replaced** by Titanoboa pipeline (adapted `configure_iso_anaconda.sh`, no Secure Boot) | D6/N3/N4 |
| brew/Distrobox strip (base absent) | **deleted** | base never adds them |
| student kiosk (dconf/polkit/skel/autologin/bt/wifi) | `build.student.sh` + `files/student/` | unchanged |
| staff | `build.staff.sh` + `files/staff/` | near-empty after strip-block removal |
| `svk-server` everything | unchanged | verify-only |
| `build.yml` / `action.yml` | adapted (Phase 4) | base job + cosign kept |
| branding | `build/00-image-info.sh` | new, svk identity |

## Open decisions to confirm before / during execution

- **D1 — ACCEPTED (default):** silverblue base pinned by digest + Renovate.
- **D2 — ACCEPTED (default):** `bootc container lint --fatal-warnings`.
- **D3 — RESOLVED:** Flatpak Firefox (Bluefin's model); exclude the RPM Firefox
  silverblue ships; firefox baked via ISO list; uBO policy/override unchanged.
- **D4** CI dnf cache: adopt `bootc-build/dnf-cache` reusable action (rec) vs
  `--mount=type=cache` only, persistence deferred. (Build-half only — signing
  stays bespoke regardless; see Phase 4a/4b.)
- **D5** does `malcontent` (library) survive removing `malcontent-control` on the
  new base, and is it the allowlist mechanism for student app visibility? (spike
  during impl; touches student strip logic).
- **D6 — RESOLVED (2026-07-17):** bake flatpaks at ISO time via **Titanoboa**
  (Route A). Flatpaks leave the image build; B2 spike shelved. Provisioning
  end-state unchanged (install image from ISO → `bootc switch` origin to registry).
- **D7 — RESOLVED (folds into D6):** first-boot *install* service deleted; the
  mirror-remote client logic is **kept, repurposed** for `flatpak update`.
- **D8 — RESOLVED:** **KEEP** the server's curated Flathub mirror — now justified by
  ongoing student flatpak updates over the LAN.
- **N2 — RESOLVED:** flatpak lists = shared `common.list` + per-flavor
  `student.list`/`staff.list`, concatenated per ISO.
- **N3 — ACCEPTED (default):** track `ublue-os/titanoboa` upstream, pinned; adapt a
  slim `configure_iso_anaconda.sh`, don't fork `projectbluefin/iso`.
- **N4 — RESOLVED:** **SKIP** Secure Boot key enrollment (no custom kmods).
- **D-style** base static tree under `custom/files/` vs `files/base/`; `build/`
  numbering scheme. Pick and record in CLAUDE.md.
- **OPEN (impl, non-blocking):** how on-machine `flatpak update` is pointed at the
  LAN mirror (repoint `flathub` URL w/ fallback vs remote priority) — settle in
  Phase 5.

## Risks / watch-items

- **Silent update stoppage is the project's #1 risk** — do the entire rebuild on a
  branch, prove the new `svk-base` builds + lints + `bootc switch`es on one test
  machine before repointing the fleet or merging to `main`. Do not delete the old
  `FROM bluefin` path from `main` until the new base is proven on real hardware.
- `--fatal-warnings` on a fresh base may surface lints the old base masked
  (D2) — budget for it.
- Raw silverblue may **lack** things Bluefin quietly provided that svk assumed
  present (a codec, a font, a default GNOME app). Diff a booted svk-base against
  the current fleet image early; add back only what's actually needed.
- The cosign **v2 signature scheme pin** must survive the CI rewrite — the fleet's
  `policy.json` verifies the old `sha256-<digest>.sig` attachment scheme; keep the
  v2.5.3 installer pin and the digest-signing step exactly.
- `projectbluefin/common:latest` is pinned by digest in the Containerfile — Renovate
  (or a manual bump cadence) must keep it current or the base slowly staleness-drifts,
  reintroducing the very "silent no-updates" failure mode in a new spot.

## Suggested execution order (checklist)

1. Phase 0 branch + archive + scaffold, one commit.
2. ✅ **DONE 2026-07-17.** `Containerfile.base` (scratch `ctx` → silverblue:44
   pinned `sha256:b21b78d6…`) + `build/00-image-info,10-packages,20-services,
   30-users,40-desktop` + `clean-stage`; excludes RPM firefox; flatpaks NOT in the
   image (ISO-baked). Local build **green `--fatal-warnings` (13 checks)**, verified
   image. Two lint/verify fixes: admin → `sysusers.d/svk-admin.conf` (not
   `/etc/passwd`); branding script → upsert os-release fields (finpilot's guard
   no-ops on Silverblue). Note: nss-mdns wires mDNS via its own authselect
   integration, so the manual nsswitch sed is a harmless no-op. D-style: static tree
   stays `files/base/`; `archived/` kept as reference (copied out, not moved).
3. ✅ **DONE 2026-07-17.** student/staff adapted, both build `FROM localhost/svk-base`
   (via `ARG BASE_IMAGE`), **green `--fatal-warnings` (13 checks each)**, verified.
   - **D5 CONFIRMED on the image:** `dnf5 remove malcontent-control` pulls only
     itself; `malcontent` the library stays → available for student app-allowlisting.
   - opilas → `files/student/usr/lib/sysusers.d/svk-opilas.conf` (like admin);
     reset-opilas-home.service ordered `After=systemd-sysusers.service`.
   - Strip logic collapsed: input-remapper/distrobox/brew and the discourse/
     documentation/system-update `.desktop`s are **absent on Silverblue** → deleted;
     only `gnome-tour` + `malcontent-control` remain to remove.
   - build.staff.sh → no-op (nothing to strip on the clean base).
   - Fixes: Wi-Fi `[ -f ] && …` → `if` (latent `set -e` exit-1 as last line);
     build script COPY+rm not host-context bind (SELinux label denial); student
     gets ctx + clean-stage + `--mount=type=cache,dst=/var/cache/libdnf5` so the
     `dnf5 remove` doesn't trip var-tmpfiles / nonempty-run-tmp / var-log.
4. ✅ **DONE 2026-07-17 (files restored; build verify deferred — battery).** Server
   is fully self-contained (uCore base, own `build.server.sh`/`files/server/`,
   doesn't even COPY cosign.pub) so the restructure can't have touched it. Restored
   `Containerfile.server`/`build.server.sh`/`server.bu`/`files/server/` from
   `archived/`. A local build was started then stopped (uCore pull is power-hungry);
   CI will verify. Server lint stays plain `bootc container lint` (not
   `--fatal-warnings`) — a different base we don't control; leave unchanged.
5. ✅ **DONE 2026-07-17 (CI files adapted; verify via real run).** Restored
   `.github/` from `archived/`. `build.yml` needed **no structural change** — same
   Containerfile names, `NAMESPACE=svkoulu`, cosign **v2.5.3** pin, `fail-fast:false`,
   base→derived `needs` graph, independent server; student/staff build FROM the ghcr
   `BASE_IMAGE` default that `build-base` pushes. Removed the old BIB `iso.yml`
   (D6 → Titanoboa replaces it in Phase 5). Kept signing/push **bespoke** (4a);
   D4 dnf-cache reusable action **deferred** (first cut keeps `--mount=type=cache`
   only). Watch on first CI run: runner podman must support `RUN --mount=type=bind,
   from=stage` + `type=cache` (ubuntu-24.04 ships podman 4.9 — expected fine; add a
   podman-update step if not).
6. **Phase 5 Titanoboa**: adapt `configure_iso_anaconda.sh` (no Secure Boot),
   wire `flatpaks/common+<flavor>.list`, pin `ublue-os/titanoboa`; build both ISOs;
   design the LAN-mirror `flatpak update` wiring.
7. `bootc switch` / ISO-install ONE test laptop of each role; verify Firefox + the
   baked flatpaks are present **offline**, **survive a student home-reset**, and
   **update from the LAN mirror**, plus kiosk lockdown, mDNS, SSH, hostname claim,
   image auto-updates.
8. Update `README.md` + `CLAUDE.md` to the new structure (Titanoboa ISO, mirror-for-
   updates, no first-boot install); merge to `main`; delete `archived/` only after a
   full green fleet cycle (or keep it).
