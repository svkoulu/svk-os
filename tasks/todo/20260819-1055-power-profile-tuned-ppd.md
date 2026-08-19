# Power switching never worked: Fedora 44 has no `powerprofilesctl`

Status: **fixed 2026-08-19, unverified on hardware.** Found by the first run of
`ci/verify-image.sh` (`…-tier1-image-verification.md`) — specifically by the check
that greps the shipped scripts for the commands they invoke and asserts each one
is installed.

## What was wrong

`files/os/usr/bin/svk-power-profile.sh` set the profile with:

```sh
powerprofilesctl set "$profile" 2>/dev/null || exit 0
```

Fedora 44 Silverblue does **not** ship `power-profiles-daemon`. It ships
`tuned-ppd`, which implements the same `net.hadess.PowerProfiles` D-Bus interface
(mapping `power-saver` → the `powersave` tuned profile) but installs no
`powerprofilesctl` binary. So the command was never found, the error was
redirected to `/dev/null`, and the script exited 0 — reporting success while
doing nothing, on every machine, at every boot and every plug/unplug, for the
entire life of the Silverblue rebuild.

The unit was wrong in the same direction:

```
After=power-profiles-daemon.service
Wants=power-profiles-daemon.service
```

— a unit that does not exist in this base, so the ordering bought nothing.

Note this is only *mostly* invisible: `tuned-ppd` ships `battery_detection=true`,
so machines have been switching to tuned's `balanced-battery` on battery of their
own accord. The fleet's intended behaviour is `power-saver`, and the switching we
believed we were doing was somebody else's.

## The fix

- Set the profile over the D-Bus interface with `busctl`, which is systemd's own
  and therefore cannot go missing the way a CLI from a separate package can:
  `busctl set-property net.hadess.PowerProfiles /net/hadess/PowerProfiles
  net.hadess.PowerProfiles ActiveProfile s "$profile"`.
- Order the unit after `tuned-ppd.service`.
- **Stop swallowing the failure.** It now logs to the journal when the property
  cannot be set. Error suppression is what turned a missing binary into a silent
  no-op for a month.
- `ci/verify-image.sh` asserts every command the shipped scripts call exists, so
  the whole class of failure fails the build from now on.

## What is still owed

- [ ] Verify on a real laptop: `powerprofilesctl`-free check —
      `busctl get-property net.hadess.PowerProfiles /net/hadess/PowerProfiles
      net.hadess.PowerProfiles ActiveProfile` after plug and unplug, and the
      journal line from the unit.
- [ ] Decide whether `power-saver` on battery is still what we want now that
      tuned-ppd's own battery detection is doing something reasonable by default.
      Two mechanisms fighting over the same setting is worse than either.
- [ ] TODO.md's hardware checklist item ("`power-saver` on battery, `balanced` on
      AC") stands — it was going to fail, and would have been read as a hardware
      quirk rather than a missing binary.
