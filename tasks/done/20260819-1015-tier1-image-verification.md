# Tier 1 — static verification of the built image in CI

Status: **done 2026-08-19** (822f780). `ci/verify-image.sh`, 60-odd checks, green
against a local build except the findings it was written to catch — and now wired
into the build so it gates every push, with a `just verify` recipe for the desk.

Ported from `../infra/ci/verify-image.sh`, which is the same idea for a fleet
with the same problem (a custom image, an unreachable machine, a failure that
only shows up after you leave).

## Why

Today the only thing standing between a broken build and the fleet is
`bootc container lint --fatal-warnings`, which checks that the image is a
well-formed bootc image — not that it is *our* image. Everything svk actually
depends on is unasserted: that the lockdown db compiled to something non-empty,
that the units parse, that the signing key baked in is the one in this repo, that
the scripts we ship can find the binaries they call.

`tasks/todo/…-hardware-validation.md` lists nine blockers "nothing here has ever
run on real metal". Roughly half of them are **static properties of the image**
and do not need metal at all — they need a check that runs on every push. That is
what this is. The rest genuinely need a boot, and that is tier 2
(`…-tier2-boot-smoke-test.md`).

## What it checks

Grouped as it prints:

- **unit enablement** — `/etc` symlink *and* preset line for all eleven units,
  plus a real `systemctl preset-all` simulation
  (`…-unit-enablement-preset.md`)
- **enable/preset lists agree** in both directions, against the source tree
- **units and scripts** — every shipped unit parses, every helper is executable,
  nothing we ship is group- or world-writable (a CI umask can do that where a
  local build never will)
- **dconf lockdown** — the kiosk db exists, is non-empty, and actually contains
  the lock keys from `00-svk-locks`; the fleet-wide `user` profile does **not**
  select the kiosk db (that would lock down admin and staff too)
- **update policy** — the drop-in resets `ExecStart`, no `--apply` survives on
  the desktop path, the timer is weekly with a randomized delay
- **signing** — the baked `svk-cosign.pub` is byte-identical to the repo's,
  `policy.json` is valid JSON, requires `sigstoreSigned` for `ghcr.io/svkoulu`
  and points at the baked key
- **identity** — os-release, `image-info.json` and `PRETTY_NAME` all carry the
  same version string
- **accounts** — admin pinned to uid 1000, `SystemAccount=true` present (the
  matched pair), an authorized key present, sshd password auth off
- **helper binaries** — including one check that greps the shipped scripts for
  the commands they invoke and asserts each is installed. That check found
  `powerprofilesctl` missing on its first run
  (`…-power-profile-tuned-ppd.md`)
- **removals** — RPM firefox, gnome-tour, malcontent-control all gone
- **per-account app lockdown** — expectation is parsed from `Containerfile.os`'s
  own `ARG SVK_LOCKDOWN` default, so the check asserts image-matches-source, and
  a bring-up build prints an unmissable warning instead of passing quietly

## Deliberate design choices

- **Preflight refuses rather than fails.** No podman, no image, image won't run →
  exit 127 with a message saying it is a tooling problem. A verifier that cannot
  tell "broken" from "couldn't look" produces a screen of confident FAILs that
  mean nothing.
- **Failures print their output indented.** A bare FAIL sends you reading the
  image by hand.
- **Checks run inside the image**, via `podman run --entrypoint ""`, so it works
  the same on a workstation and on a runner with no KVM.

## Outcomes

- [x] `ci/verify-image.sh` written, shellcheck-clean
- [x] Green against a local `just build-os` (bar the real findings)
- [x] `just verify image="localhost/svk-os:latest"` recipe
- [x] Called after the build, **before** the push — as the `Verify (tier 1)` step
      in `.github/actions/build-image/action.yml`, which is what
      `build-images.yml` runs. A failed verify aborts the job and nothing is
      pushed. It verifies the first of the computed tags, i.e. the exact image
      the push would publish.
- [x] The CI/Justfile question, decided: **neither side reimplements anything** —
      `just verify` and the CI step both exec `ci/verify-image.sh`, so there is
      one implementation and no YAML copy of it. That is what infra's
      `just-recipes-work-in-ci.md` was protecting against; routing CI through
      `just` as well would only add a tool to the runner. The rule to keep: the
      checks live in the script, never in the recipe or the workflow.
