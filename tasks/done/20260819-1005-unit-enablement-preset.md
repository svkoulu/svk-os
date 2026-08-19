# Unit enablement must be stated twice — preset file + `systemctl enable`

Status: **implemented 2026-08-19** (`files/os/usr/lib/systemd/system-preset/50-svk.preset`,
the cross-check in `ci/verify-image.sh`). Open half: **confirm on a real install**
that a freshly-installed machine comes up with all eleven units enabled — the VM
install run is what closes this. Borrowed from `../infra` (ADR 0024,
`tasks/done/enable-units-by-preset.md`), where it was found by watching an image
boot for the first time.

## The bug this prevents

`build/20-services.sh` says "these units are on" by calling `systemctl enable`,
which writes symlinks under `/etc/systemd/system/*.wants/`. In a bootc image
those become `/usr/etc`, and a new deployment's `/etc` is populated from them —
so far so good.

Then systemd boots that deployment for the **first time**. With a fresh `/etc`
it applies **preset policy** over it, and preset policy is the base image's
opinion, not ours. Silverblue's is:

```
81-desktop.preset:  disable sshd.service      # explicitly
99-default-disable.preset:  disable *          # everything else
```

Reproduced offline against a built `svk-os` on 2026-08-19 — `systemctl
preset-all` inside the image turns **10 of our 11 units off**:

```
tailscaled.service                     disabled
svk-tailscale-enroll.service           disabled
sshd.service                           disabled
svk-power-profile.service              disabled
svk-claim-hostname.service             disabled
svk-luks-tpm-enroll.service            disabled
bootc-fetch-apply-updates.timer        disabled
svk-flatpak-update.timer               disabled
reset-opilas-home.service              disabled
svk-bluetooth-default-off.service      disabled
avahi-daemon.service                   enabled     <- the only survivor
```

That is: no admin SSH, no Tailscale, no automatic image or flatpak updates, no
TPM enrollment, no home reset, no Bluetooth blocking — on a machine that
installed cleanly and shows a login prompt. Nothing reports it. It is precisely
the "silently stops getting updates" failure CLAUDE.md names as the driving risk,
arriving through a door nobody was watching.

**UPDATE 2026-08-19, after the first end-to-end VM install: it does NOT fire on
this install path.** `ConditionFirstBoot` was not met on the first boot of a fresh
install — `/etc/machine-id` is already populated by the time systemd evaluates it —
so preset policy never runs and the eleven `/etc` symlinks survive untouched
(verified on the installed disk before and after that boot,
`…-first-end-to-end-vm-install.md`). The preset file stays as insurance for the day
the install path changes (`bootc install to-disk`, a bootc-image-builder disk, an
image-mode reinstall), where the symlinks stop being the mechanism. It costs one CI
assertion. The urgency below is retracted; the reasoning is kept because it is why
the file exists.

The original framing follows.

**Whether our Anaconda install actually triggers it is the one thing not yet
proven.** infra observed the deletion on `bootc-image-builder` disks and does not
see it on its own install path, because stock FCOS boots first and populates
`/etc` before the rebase — an update onto an established `/etc`, where preset
policy never runs. Our kickstart lays down a deployment and boots it directly,
which is the fresh-`/etc` case. So the mechanism is confirmed, the trigger is
assumed, and one VM install settles it.

## What was done

- `files/os/usr/lib/systemd/system-preset/50-svk.preset` — an `enable` line for
  each of the eleven units. Numbered **50** deliberately: preset files are
  evaluated in lexicographic order, first match wins, so it must sort ahead of
  `81-desktop.preset`'s explicit `disable sshd.service`.
- `build/20-services.sh` carries a header pointing at it.
- `ci/verify-image.sh` asserts, for every unit: the `/etc` symlink exists, a
  preset line exists, **and** the unit still reports `enabled` after a real
  `systemctl preset-all` inside a throwaway container. That last one is the
  regression test — it catches a numbering mistake, which a per-line grep cannot.
- It also asserts the two lists agree in both directions, so adding a unit to one
  file and forgetting the other fails the build rather than a machine.

## Do not "clean this up"

Deleting the `systemctl enable` calls in favour of the preset alone is a
**fleet-wide outage**, not a simplification. ostree 3-way-merges `/etc` on
update: a symlink present in the old commit and absent in the new one is
*removed from the live machine*. Shipping that deletion would turn sshd, both
update timers and the kiosk units off on every installed machine in one update,
and the preset would not save them — preset policy does not run again on an
established `/etc`. The duplication is permanent. Its cost is one CI assertion,
which already exists.

## Outcomes

- [x] `50-svk.preset` ships every enabled unit
- [x] `ci/verify-image.sh` cross-checks both lists and simulates preset policy
- [x] A VM install boots with all eleven units `enabled` — confirmed 2026-08-19,
      and confirmed for the reason above rather than the one expected
- [x] The EliteBook worry is retired: preset policy does not run on this install
      path, so that machine's units were never disabled by it
