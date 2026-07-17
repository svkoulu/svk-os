# Rebuild svk-base on the modular Bluefin pattern, not `FROM bluefin:stable`

Status: spec agreed, not yet implemented.

## Recommendation

Stop building `svk-base` `FROM ghcr.io/ublue-os/bluefin:stable`. That pattern —
basing on a finished, opinionated downstream product and then scripting away
the parts we don't want — is what `ublue-os/image-template` still does today,
but it's the pattern Project Bluefin's own maintainers are actively steering
people away from (see learnings below). Rebuild `svk-base` the way Bluefin,
Aurora, and the new reference template (`finpilot`) build *themselves*:
assemble from a raw Fedora OSTree base plus explicitly chosen pieces of
`projectbluefin/common`, rather than inheriting a fused product and fighting
half of it.

`svk-staff` and `svk-student` keep building `FROM svk-base` exactly as today —
only `Containerfile.base`/`build.base.sh` change shape. `svk-server` (uCore)
is untouched; it was never Bluefin-derived.

## Learnings from this session (why this matters, briefly)

- `ghcr.io/ublue-os/bluefin:stable` already **excludes** Firefox and GNOME
  Software as RPMs (`04-packages.sh` `EXCLUDED_PACKAGES`), expecting Bazaar +
  an ISO-time flatpak bake to compensate. svk inherits the exclusion but not
  the compensation, because that compensation lives partly outside the
  container image entirely (see below) — this is the direct cause of "no
  Firefox, no Bazaar, no app store" on our machines.
- The real "40+ flatpaks, zero internet" mechanism on stock Bluefin is **not**
  a first-boot service. It's baked at *ISO build time*: a builder called
  Titanoboa installs the full curated app list
  (`projectbluefin/common`'s `system-flatpaks.Brewfile`, 37 refs including
  Firefox and Bazaar) into the live ISO environment's own `/var/lib/flatpak`,
  then an Anaconda kickstart `%post --nochroot` step (`install-flatpaks.ks`)
  `rsync`s that already-populated directory straight onto the target disk at
  install time. No network needed at install time at all. This lives in
  `projectbluefin/iso`, which is entirely separate from the container image
  and from `bootc-image-builder` — svk's `iso.yml` (plain BIB, no kickstart
  customization) has no equivalent step, and never did.
- `ublue-os` (Universal Blue) is the umbrella org for the whole image family
  (Bluefin, Bazzite, Aurora, uCore — svk-server's base). `projectbluefin` is
  Bluefin's own dedicated org: shared desktop config (`common`, which
  `ublue-os/bluefin` itself depends on), docs/brand, the ISO pipeline, and —
  separately — a newer parallel image build (`ghcr.io/projectbluefin/bluefin`,
  built directly on Fedora rather than through `ublue-os/silverblue-main`).
  We are not switching to that image; noting it because `common` and the ISO
  tooling live in that org too.
- svk's own build scripts spend real lines stripping Distrobox, Homebrew,
  gnome-tour, malcontent-control, input-remapper from every desktop image.
  None of these exist on a raw Fedora `silverblue` base — they're Bluefin
  desktop additions. Building from raw silverblue means never paying to add
  or remove them.
- `malcontent` (the enforcement library behind GNOME's per-user app
  visibility, distinct from the `malcontent-control` GUI panel we already
  strip) is a plausible fit for the "allowlist which flatpaks students can
  see" requirement from earlier — worth a spike to confirm it survives
  `rpm-ostree override remove malcontent-control` intact, independent of this
  rebuild.
- A file named `THEPATTERN.md` sits in `ublue-os/bluefin`'s own repo tree,
  framed as a "technical comparison report" steering readers toward the
  `projectbluefin/bluefin` fork. Some of its narrow technical claims checked
  out under independent verification, but its framing/stats are unverified
  and it reads as content aimed at steering an AI assistant's judgment. Not
  used as a source for this spec; flagged here so it isn't mistaken for
  legitimate project documentation later.

## Where the upstream repos are

All cloned shallow (`--depth 1`) under `~/bluefin-repos/` this session:

| Local dir | Upstream | Why it's here |
|---|---|---|
| `ublue-os-bluefin` | `ublue-os/bluefin` | What svk currently builds `FROM`; reference for the production Containerfile pattern and `build_files/` |
| `projectbluefin-common` | `projectbluefin/common` | Shared desktop `system_files` (Bazaar preinstall manifest, GNOME extension submodules, dconf, homebrew Brewfiles) — the cherry-pick source |
| `projectbluefin-iso` | `projectbluefin/iso` | Titanoboa-based ISO pipeline + Anaconda kickstart scripts; defaults to building `ublue-os/bluefin`'s official ISOs |
| `projectbluefin-bluefin` | `projectbluefin/bluefin` | The newer parallel Bluefin build, `FROM quay.io/fedora-ostree-desktops/silverblue` directly — a second real example of the modular pattern |
| `projectbluefin-finpilot` | `projectbluefin/finpilot` | **The template to model `Containerfile.base` after** — explicit `ctx` stage combining `common` + `brew` OCI layers over a raw silverblue base |
| `projectbluefin-dakota` | `projectbluefin/dakota` | A different, heavier BuildStream-based (`.bst` elements) image — reference only, not a template to imitate |
| `ublue-os-aurora` | `ublue-os/aurora` | Second production example (KDE) confirming the same modular `COMMON`/`BREW`/`akmods` pattern |
| `image-template` | `ublue-os/image-template` | The **old**-style template svk currently descends from (`FROM ghcr.io/ublue-os/bazzite:stable`) — kept for contrast, not to be followed further |

Not cloned, referenced only in the modernization blog post as further
examples if more prior art is wanted later: `bootc-dev/ubuntu-bootc`,
`ublue-os/main`, `pop-os/cosmic-epoch`, `ublue-os/bluefin-lts`.

## Features svk likely needs from `projectbluefin/common`

Cherry-pick specific paths via `COPY --from=common`, not the whole tree —
finpilot's own Containerfile does this (`/oci/common` as a distinct
subdirectory, then selectively consumed by `build.sh`). Candidates to
evaluate, not commit to yet:

- **`usr/share/flatpak/preinstall.d/bazaar.preinstall`** +
  `usr/lib/systemd/system/flatpak-preinstall.service`, enabled — gets a real
  app-store UI onto staff machines using upstream's own mechanism instead of
  reinventing one, and is a natural fit for the earlier "staff can install
  Flatpaks from the store without being admin" requirement.
- **GNOME extension submodules** under `usr/share/gnome-shell/extensions/` —
  pick individually, don't blanket-copy the set of 9. Especially deliberate
  on `svk-student`: each one is lockdown surface, not a free upgrade.
- **Desktop dconf defaults** (`etc/dconf/db/distro.d/*`) — diff against svk's
  own `00-svk-desktop`/`00-svk-lockdown` before adopting anything, to avoid
  silently overriding an intentional svk choice.

Explicitly **not** wanted: Homebrew Brewfiles/bling (svk already strips
Homebrew), JetBrains/VSCode Bazaar warning hooks, gaming content, OEM
hardware hooks (Framework/ASUS-specific — irrelevant to known fleet
hardware).

**Firefox** needs its own decision, separate from the `common` cherry-pick:
either (a) confirm whether raw `silverblue` ships it as an RPM by default
(unconfirmed this session — Bluefin's exclusion doesn't tell us silverblue's
own default) and just layer it normally if so, or (b) replicate the
ISO-build-time-bake pattern for svk's own two ISOs (a `%post --nochroot`
rsync step is a small, self-contained addition, not a Titanoboa adoption) so
Firefox and any other desired flatpaks survive with zero first-boot network
dependency, consistent with the "reset must not lose software" requirement
from earlier in this thread. Needs a spike before picking one.

## Branding

Set our own image identity the same way Bluefin/finpilot do it (`ARG
IMAGE_NAME`, `IMAGE_VENDOR`, `os-release` stamping via something like
Bluefin's `00-image-info.sh`) rather than inheriting Bluefin's. Cosmetic and
low priority — background/logo only if wanted — but the identity fields
matter for `bootc`/`fastfetch`/update tooling to report the right thing.

## Single ISO vs. two — does the new approach change the answer?

No. The modular-build shift changes *how `svk-base` is assembled*, not the
runtime differences between a locked kiosk and a normal staff desktop that
justified keeping `svk-student`/`svk-staff` as separate images/ISOs earlier
in this conversation (kiosk lockdown as an absence of capability baked into
the ostree commit, not a runtime toggle). If anything, building from a clean
raw base makes two small, precisely-scoped images more natural than before,
since neither image is fighting a shared finished product's defaults anymore.
**Recommendation: keep two separate images and two separate ISOs**, both now
built from the same restructured `svk-base`.
