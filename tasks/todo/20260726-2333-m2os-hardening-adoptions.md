# Hardening items borrowed from m2Giles/m2os

Status: **not started.** Noted 2026-07-26.

Source: <https://github.com/m2Giles/m2os> (cloned to `../bluefin-repos/m2giles-m2os`).
A personal ublue derivative — 10 image variants published as tags of one repo —
structurally close to svk: keyed cosign signing, `policy.json` + `registries.d`
enforcement, Titanoboa ISOs, digest-pinned bases, Renovate, a fat Justfile. Close
enough that its solutions transfer; different enough (one `Containerfile.in`
driven by the C preprocessor, CI as a thin wrapper over the Justfile) that not
all of them should.

Five items below, ordered by value-per-effort. Each is independent — do them in
any order, or only some. Line references are into the m2os clone.

---

## 1. Ship a backup public key *now*, not at rotation time

`Containerfile.in:131-132` bakes **two** public keys; `build_files/signing.sh`
writes both into the policy:

```yaml
keyPaths:
  - /etc/pki/containers/m2os.pub
  - /etc/pki/containers/m2os-backup.pub
```

svk's `files/base/etc/containers/policy.json` has singular `keyPath`.

`README.md` § *Signing key → Rotation* already describes the both-keys trick as
**step 2 of 5** in the rotation sequence, and correctly notes that step 3 —
waiting until every machine has taken that image — is not skippable and blocks on
`20260726-1908-svk-check-health-service.md`.

The insight from m2os is to do steps 1–3 **preemptively**, while nothing is
wrong. Generate a second keypair, keep it offline (never in CI — it is not a
second signing key, it is a second *trust anchor*), and ship `keyPaths` with both
from the next build onward. `keyPaths` is OR semantics, so the backup key changes
no behaviour until it is needed. When rotation does become necessary, the
multi-week fleet-wide propagation wait is already behind you and the sequence
collapses to "start signing with the new key."

Also covers the case the README's rotation section does not: the *primary* key
being lost outright rather than deliberately rotated. Today that means every
in-field machine rejects all future updates with no remote recovery path.

**Caveat:** only protects machines provisioned or updated *after* this ships, so
the value strictly decreases with delay. Cheapest item here and the one with the
worst failure mode if skipped.

Touches: `files/base/etc/containers/policy.json`, `Containerfile.base` (COPY the
second `.pub`), `README.md` § Signing key.

---

## 2. Same-day rebuilds silently overwrite the "immutable" dated tags

`Justfile:182-193` computes `VERSION=<image>-<fedora>.<date>`, then checks the
registry before using it:

```bash
skopeo list-tags docker://$FQ_IMAGE_NAME > repotags.json
if [[ $(jq "any(.Tags[]; contains(\"$VERSION\"))" < repotags.json) == "true" ]]; then
    POINT=1
    while jq -e "any(.Tags[]; contains(\"$VERSION.$POINT\"))" < repotags.json; do ((POINT++)); done
    VERSION="$VERSION.$POINT"
fi
```

svk sells `testing-<DATE>` and `stable-<N>-<DATE>` as immutable pins (CLAUDE.md,
*Versioning / channels*). They are not. Two builds on one day — a push to main
plus the weekly cron, a re-run after a flake, any `workflow_dispatch` — reuse the
same tag, and the second push moves it. A machine pinned to that tag gets
different bytes than it got yesterday, which is the one thing a pin exists to
prevent. Nothing currently detects this.

Fix: one `skopeo list-tags` in `.github/actions/build-image/action.yml` before
the tag list is assembled (the "Compute version + tags" step, `action.yml:61`),
appending `.1`, `.2`, … on collision. The version string flows into os-release,
the `org.opencontainers.image.version` label, `image-info.json` and the ISO
filename, so the suffix needs to be computed **once in `setup`** and passed down
— same as `channel`/`major`/`date` — or base and derived images will disagree.

Note the ordering constraint: `svk-base` pushes before `svk-student`/`svk-staff`
build, so a naive per-job check would see base's own tag and give the derived
images a different suffix. Compute in `setup`, pass down.

---

## 3. An aggregate `check` job to hang alerting on

Every m2os workflow ends with (`build-image.yml:124-138`, and identically in
`gen-sbom.yml`):

```yaml
check:
  name: Check Build Images Successful
  if: ${{ !cancelled() }}
  needs: [build-image]
  runs-on: ubuntu-latest
  steps:
    - if: ${{ contains(fromJson('["failure", "skipped"]'), needs.build-image.result) }}
      run: exit 1
    - run: exit 0
```

svk uses `fail-fast: false` deliberately, so one image's failure does not mask
the others'. The gap is `skipped`: a matrix leg that never runs does not fail the
run. For svk that is concretely the case where `build-base` fails and
`build-student`/`build-staff` are skipped by `needs:` — the derived images
silently do not get rebuilt.

Two payoffs: a single required status to branch-protect, and a single place for
`20260726-2014-ci-failure-alerting.md` to attach `if: failure()` instead of
alerting per-image across three fan-out jobs and two channels.

Sequence with that task: land the `check` job first, wire the alert to it second.

Touches: `.github/workflows/build-images.yml`.

---

## 4. Renovate config — accepted in the plan, never written

`grep -rn renovate` finds no config anywhere in the repo, only prose. But
`tasks/done/20260717-1845-modular-base-rebuild-implementation-plan.md:406` records:

> **D1 — ACCEPTED (default):** silverblue base pinned by digest + Renovate.

So the base digest is currently frozen by hand. That quietly undermines the
weekly-rebuild security story: the cron faithfully rebuilds the *same* pinned
base every week, and new kernels only arrive when someone remembers to bump the
digest manually.

Two things to fix, both small:

- **Add `.github/renovate.json`.** m2os's is a good starting point: extends
  `config:best-practices`; automerge restricted to `pin`/`digest`/`pinDigest` for
  base images; `major`/`minor`/`patch` **disabled** for upstream image packages
  (svk wants digest freshness within a pinned Fedora major, not surprise version
  jumps); GitHub Actions pinned by SHA with digest bumps automerged. svk's inline
  `FROM …:44@sha256:…` is handled by Renovate's native Dockerfile manager — the
  regex `customManagers` in m2os's config exist only because its refs live in
  `image-versions.yml` and the Justfile, and are not needed here.
- **Pin the ucore base.** `Containerfile.server:12` is
  `FROM ghcr.io/ublue-os/ucore:stable` — a floating tag, unlike the Silverblue
  base. `svk-server` therefore has neither reproducibility nor Renovate
  visibility, and can change under CI without any commit. Pin it by digest.

Interaction with item 5: automerged digest bumps mean unattended changes to what
gets built, which is the argument for verifying the upstream signature too.

---

## 5. Verify the upstream base's signature before building

`Justfile:565-575` defines a `verify-container()` shell function injected into
recipes; every base image is `cosign verify`'d against the ublue public key
before the build starts, and the build aborts on failure.

A digest pin guarantees *immutability* but not *provenance* — it is only as good
as the moment it was recorded, and item 4 proposes letting Renovate bump it
unattended. Verification is the check that the thing being pinned was legitimate
in the first place.

Applies to **`svk-server` only**: `ghcr.io/ublue-os/ucore` is cosign-signed with
the ublue key, but `quay.io/fedora-ostree-desktops/silverblue` is not signed at
all, so `svk-base` has nothing to verify against. Worth knowing and worth writing
down — it means the desktop images' provenance rests entirely on the digest pin,
and that is not a gap that can be closed on svk's side.

---

## Smaller items, take or leave

- **Push-twice digest comparison** (`Justfile:433-449`): push each tag twice with
  `--digestfile` and `diff` the results, failing if they differ. m2os added it
  working around annotations being dropped on first push. Cheap integrity check
  on the one operation whose silent failure the fleet cannot detect.
- **`--inherit-labels=false`** plus an explicit label set (`Justfile:204-214`) —
  stops opaque upstream labels leaking into svk's images. Check what
  `build-image/action.yml` currently inherits.
- **Lint workflow gating builds** (`lint.yml`, `Justfile:355-413`): shellcheck +
  `yamllint -s` + `just --fmt --check` + `lint-recipes`, the last being
  `just -n <recipe> | shellcheck` — it lints the *rendered* recipe body, catching
  quoting bugs in interpolated shell that plain shellcheck cannot see. svk's
  `just lint` (`Justfile:146`) is shellcheck-only and is not wired into CI.
- **`common.sh` sourced by every build script** — `::group::` log folding plus a
  `ghcurl()` reading `/run/secrets/GITHUB_TOKEN` (mounted via `--secret`) to
  dodge API rate limits. svk's `build/` scripts have no shared preamble.
- **SBOM pipeline** (`gen-sbom.yml`): syft → grype → SARIF into the Security tab
  → `cosign sign-blob` → `oras attach` to the image digest → sign the attachment.
  Medium effort. For a fleet whose entire update rationale is "pull in security
  fixes," it makes *"did this rebuild actually fix anything"* visible rather than
  assumed. Requires the build job to upload OCI archives as artifacts.
- **ISO flow** (`iso_files/configure_iso.sh:158-185`): same
  `ostreecontainer --no-signature-verification` → `bootc switch --mutate-in-place
  --enforce-container-sigpolicy` handoff svk uses, plus an rsync of
  `/var/lib/flatpak` into the deployment as a `--nochroot` post-script. Worth
  diffing against `iso/hook-anaconda.sh`. **That file has a bug** — four `tee`
  calls all target `disable-fedora-flatpak.ks`, so the flatpak-rsync and
  secureboot scripts clobber each other. Read it for the technique, not the
  structure.

---

## Deliberately not adopted

- **`Containerfile.in` + C preprocessor.** Exists because m2os has 10 variants
  sharing one build graph. svk has 4 images and its derived manifests are already
  ~4 lines each. Would trade that clarity for `#ifdef` soup, and `Containerfile.in`
  has to be excluded from Renovate entirely (last `packageRules` block) because
  the macro syntax defeats the Dockerfile manager. CLAUDE.md's "base logic in
  numbered `build/` scripts, derived logic in `build.X.sh`" is the better
  factoring at this size.
- **`image-versions.yml`** (central digest registry read by `yq`). Buys a lot at
  20+ digests shared across variants; svk has two external bases. Revisit only if
  the image matrix grows.
- **Rechunking via `quay.io/jlebon/chunkah`** (`Justfile:239-271`). Genuinely
  reduces per-update bandwidth, which matters on a school LAN — but svk-server's
  pull-through cache already absorbs most of that, and the recipe is real
  complexity including a `podman system reset --force` in CI. Parked, not
  rejected.
- **CI-runs-the-Justfile.** m2os's `build-image.yml:96` is `just build $image`;
  local and CI builds are the same code path. svk's CLAUDE.md states "CI does NOT
  use it", which costs two implementations of build+push+sign that can drift, and
  no way to reproduce a CI failure locally. m2os is arguably right here — but
  unwinding it is a larger job than everything above combined, and it is a
  deliberate documented decision. **Raised as a question, not a recommendation.**

---

## Relationship to other tasks

- `20260726-2014-ci-failure-alerting.md` — item 3 gives it a single job to attach
  to. Land the `check` job first.
- `20260726-1908-svk-check-health-service.md` — item 1's "wait until every
  machine has it" step needs the per-machine last-successful-upgrade state that
  task provides. Preemptive backup-key staging is *more* valuable while
  svk-check does not exist yet, because it moves the wait to a time when nothing
  is on fire.
- `20260726-1957-single-image-collapse.md` — if the image count drops, item 4's
  Renovate surface shrinks and the "not adopted" verdict on `image-versions.yml`
  gets stronger still.
