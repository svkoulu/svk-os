# Spec — USB provisioning config for install-time user accounts

Status: **planning only — no repo files touched yet.** This is the design; the
implementation is a later, separate task. **Reviewed for staleness 2026-07-26** —
the core design survives, but four things shifted under it and the fallback table
was outright wrong; see the update notes below before implementing.

## Context — why

The installer today hardcodes locale/keyboard/timezone and handles login accounts
two different ways: **student** bakes the passwordless `opilas` kiosk account into
the image; **staff** creates its login account interactively on Anaconda's Create
Account page (the one manual step). There is no way to provision a staff login
account without either typing it by hand at each install, or baking a password
into the repo/image — which we explicitly refuse to do.

We want a **provisioning config file on the SVK-PROV USB** that any install reads
when present and uses to create the real login account(s) for that site — chiefly
the staff account(s) — plus optional locale/keyboard/timezone overrides. The
operator seeds a `.example` into a real config manually; it never lives in git or
the image. One ISO becomes reusable across sites/accounts without a rebuild.

## Resolved decisions

- **`admin` is untouched.** Stays the SSH-key-only, NOPASSWD-sudo, greeter-hidden
  system account (`files/base/usr/lib/sysusers.d/svk-admin.conf`), created
  automatically at first boot on both flavors. **Not** in the config. No GNOME
  desktop-admin account is introduced.
- **`opilas` is untouched.** Student kiosk stays passwordless autologin, baked via
  sysusers. Not in the config.
- **The config only *adds* login accounts** (uid ≥ 1000), primarily the staff
  login. It is **flavor-agnostic**: the same `%pre` reads it on any install and
  creates the listed users when the file is present.
- **Format:** YAML, placed **directly on the SVK-PROV USB** as `svk-provision.yaml`
  and parsed in Anaconda's `%pre` (`python3-pyyaml` is installed into the installer/
  live image so the parser is dependency-safe).
- **Passwords are plaintext** in the YAML. No hashing helper. The USB is physically
  controlled and wiped after provisioning — same trust model as `tailscale-authkey`,
  which already rides the SVK-PROV USB.
- **Installer seeds a `.example`.** Canonical `iso/svk-provision.yaml.example` lives
  in the repo; `build-iso.sh` drops a copy next to the built ISO. The operator
  copies it to the USB as `svk-provision.yaml`, fills it in, and plugs the USB in
  for the install (leaving it in through first boot, since the same USB also carries
  `tailscale-authkey`).
- **Config also carries locale/keyboard/timezone** (optional; defaults
  `fi_FI.UTF-8` / `fi` / `Europe/Helsinki`).
- **No-USB fallback:** student = `opilas` only + defaults (unchanged, still
  zero-click); staff = the baked placeholder `staff` login + defaults. No secret is
  in the repo/image beyond that well-known placeholder, which must be changed.

> **Update (2026-07-19) — staff automation landed ahead of this suite.** As the
> validation step the operator asked for, staff no longer stops at the WebUI Create
> Account page: it now installs via a **complete `inst.ks=` kickstart** (like
> student) with a baked placeholder `staff` account (`iso/installer/build.sh`, staff
> case). This **resolves the R4/"validation caveat" below** — there is no WebUI
> accounts-page ambiguity to worry about, because the account is fully preset in the
> kickstart. When this USB suite is implemented, the `%pre`-generated `user` line
> supersedes the baked placeholder; **decide then** whether the no-USB staff
> fallback keeps that placeholder or reverts to an interactive account page.

> **Update (2026-07-20) — per-install LUKS passphrase landed; this suite owns the
> no-TPM fallback.** The disk-encryption passphrase is now minted per-install in the
> kickstart's `%pre` (`iso/installer/build.sh`, `common_ks`) — no shared secret in the
> ISO (`build-iso.sh` no longer generates/prints one). For a machine with a TPM this
> is fully transparent (auto-unlock + first-boot recovery key). The **open gap** is a
> no-TPM machine: first boot prompts for a passphrase nobody has; the interim is an
> attended operator reading `/tmp/svk-luks-bootstrap` from the installer console
> before reboot (documented in `iso/README.md`). **This USB suite is the proper fix:**
> when `%pre` reads `svk-provision.yaml`, also have it **write that machine's
> per-install passphrase (or recovery key) to the SVK-PROV USB**, so a no-TPM machine
> has a retrievable fallback without any secret ever touching the ISO or the repo.

> **Update (2026-07-26) — staleness review against the current tree, and the
> single-image collapse.** Re-read alongside `iso/installer/build.sh` as it stands
> at 9ecc78c. The design holds; four things have moved under it.
>
> 1. **The `%pre` block already exists.** Implementation step 4 says to *add* a
>    `%pre` to `common_ks()`. There is now one at `iso/installer/build.sh:201`
>    (`%pre --erroronfail`), minting the per-install LUKS passphrase. **Extend it**
>    — a second `%pre` is legal but pointless, and the passphrase-to-USB write from
>    the 2026-07-20 note above belongs in the same block anyway.
> 2. **Locale lives in two places, not one.** Step 4 says to move
>    `lang`/`keyboard`/`timezone` out of `common_ks()` (`:181-183`). They are
>    **also** hardcoded at `:271-273` on the live-desktop install path, which has
>    no `%pre` and therefore cannot consume the `%include`. Decide explicitly:
>    either leave that path on the baked defaults (fine — it is the attended
>    fallback route) or give it its own handling. Do not silently fix one and leave
>    the other.
> 3. **This task and the single-image collapse
>    (`20260726-1957-single-image-collapse.md`) now overlap on the staff password.**
>    The collapse lists "replace the `stafff` placeholder (`:244`)" as in-scope for
>    itself, on the grounds that with the boundary moving from machine-scoped to
>    account-scoped, a real staff password becomes load-bearing rather than
>    cosmetic. **This suite is the real fix** — it removes the baked password
>    entirely rather than replacing one hardcoded string with another. Whichever
>    lands first should note it; if the collapse ships first, treat its replacement
>    password as an interim, not a resolution.
> 4. **Under the collapse, `FLAVOR` selects a kickstart, not an image.** One ISO
>    offers two automated GRUB entries (`svk-lab.ks` / `svk-staff.ks`) and the
>    kickstart is what decides which accounts exist — which is exactly this task's
>    mechanism. Consequences: the `%pre` in `common_ks()` stays shared and still
>    applies to both entries (good, unchanged); the emitted `user` line must gain
>    **`--groups=staff`** for the collapse's new `staff` group, which gates
>    `gnome-software` and the system-scope-flatpak polkit grant; and the
>    Verification section's "build both ISOs" becomes one ISO, two entries.
>
> Also note the collapse plans a per-user `environment.d` file for `DCONF_PROFILE`
> and `XDG_DATA_DIRS`. That is per-machine, install-time, account-scoped state —
> the same shape as everything here. If it is not written by the kickstart, it is
> a second install-time config mechanism; consider folding it in.

## Config schema (`iso/svk-provision.yaml.example`)

```yaml
# svk-provision.yaml — read by the SVK installer from the SVK-PROV USB.
# Copy this file to the USB as `svk-provision.yaml`, fill it in, plug it in
# for the install. PLAINTEXT passwords: keep the USB physically safe and wipe
# it after the fleet is provisioned.

# Optional — locale overrides (defaults shown; omit the block to keep them).
locale:
  lang: fi_FI.UTF-8
  keyboard: fi              # used for BOTH console vckeymap and X layout
  timezone: Europe/Helsinki

# Login accounts to create at install, IN ADDITION to the image built-ins
# (the SSH-only `admin`, and on students the passwordless `opilas` kiosk).
users:
  - name: opettaja          # unix username (^[a-z_][a-z0-9_-]*$)
    fullname: "Opettaja"     # optional GECOS
    password: "changeme"      # plaintext; omit => passwordless (then NOT admin)
    administrator: false      # true => wheel/sudo. default false
```

**Parser guards** (enforced in `%pre`; a failure skips the offending user with a
logged warning rather than aborting the install):

- username must match `^[a-z_][a-z0-9_-]*$` and not be one of `admin`, `opilas`,
  `root`;
- `administrator: true` requires a non-empty `password` (no passwordless sudo);
- passwords are written to the kickstart line safely quoted.

## Implementation outline

1. **`iso/svk-provision.yaml.example`** (new) — the schema above.
2. **`iso/installer/parse-provision.py`** (new) — small Python: read the YAML,
   apply guards, emit an Anaconda kickstart fragment to a given path:
   `lang …`, `keyboard --vckeymap=<k> --xlayouts=<k>`, `timezone <tz> --utc`, and
   one `user --name=… [--gecos=…] [--password=… --plaintext] [--groups=wheel]`
   per valid user. On any error / missing file it emits **only** the locale
   defaults (no user lines) so the install still proceeds.
3. **`iso/installer/Containerfile`** — `COPY` the parser to
   `/usr/libexec/svk/parse-provision` in the installer image.
4. **`iso/installer/build.sh`**:
   - add `python3-pyyaml` to the live `dnf5 install`;
   - **move `lang`/`keyboard`/`timezone` out of the static `common_ks()`**
     (`:181-183`) into the `%pre`-generated include (so the config can override
     them without a duplicate-directive conflict). Decide separately what to do
     about the duplicate at `:271-273` on the live-desktop path — see the
     2026-07-26 note;
   - **extend the existing `%pre --erroronfail` block** (`:201`, which already
     mints the LUKS passphrase) to `findfs LABEL=SVK-PROV`, mount ro, run
     `/usr/libexec/svk/parse-provision <usb>/svk-provision.yaml
     /tmp/svk-provision.ks` (falling back to defaults when absent/unreadable), and
     write this machine's passphrase/recovery key back to the USB; add a matching
     `%include /tmp/svk-provision.ks`. Living in `common_ks()` makes it apply to
     **both** flavors / both kickstart entries.
5. **`iso/build-iso.sh`** — copy `iso/svk-provision.yaml.example` next to the output
   ISO and print a one-line hint (mirrors the existing luks-bootstrap hint).
6. **`.gitignore`** — ignore `iso/svk-provision.yaml` (a real filled config) as a
   safety net; the `.example` stays tracked.
7. **Docs** — `iso/README.md` gets a "Provisioning config (user accounts)" section
   + Pieces/Deps rows; `TODO.md` §1 notes the config-driven account path; brief
   mention in the top-level `README.md` deploy steps.

## Fallback behavior

Corrected 2026-07-26 to match the code. Both flavors are already fully automated
via `inst.kickstart=`; there is no interactive Create Account page on either path
any more.

| USB `svk-provision.yaml` | student / lab | staff |
|---|---|---|
| **present** | `opilas` (baked) + config users; locale from config | config users created, superseding the baked placeholder; locale from config |
| **absent / unreadable** | `opilas` only; `fi`/`fi`/Helsinki defaults | baked placeholder `staff` login (`build.sh:244`); defaults |

`admin` (SSH-only) is present on both, always.

**The no-USB staff case is the decision to make.** Options: keep the placeholder
(zero-click, but ships a well-known password to any machine installed without a
USB), or drop the baked `user` line so a no-USB staff install has no login account
and fails visibly. The second is safer once the boundary is account-scoped — see
the single-image collapse — but it makes the USB a hard dependency for staff
installs. Pick one when implementing; do not leave it implicit.

*(The former "Validation caveat" about Anaconda's WebUI Accounts screen is
**deleted** — it was resolved by the 2026-07-19 update above. Staff installs via a
complete `inst.ks=` kickstart, so there is no WebUI accounts page to be ambiguous
about.)*

## Verification (for the implementation task)

- **Parser unit-check** offline: run `parse-provision.py` against the `.example`
  and malformed inputs (bad username, admin-without-password, missing file) —
  confirm the emitted `.ks` is correct and guards fire.
- **Build the ISO(s)** — `just iso student local` / `just iso staff local` today;
  one ISO with two GRUB entries once the single-image collapse lands. Confirm the
  installer image builds with `python3-pyyaml` and the parser present.
- **VM install with a fake USB** via `just run-iso`: attach a second disk/volume
  labelled `SVK-PROV` holding a `svk-provision.yaml`; confirm the listed user is
  created with the right sudo/no-sudo, the right supplementary groups
  (`staff` post-collapse) and locale, and that `admin`/`opilas` are unchanged.
- **VM install with no USB**: confirm the lab path is still zero-click (opilas
  only) and that the staff path does whatever the no-USB decision above settled on
  — placeholder account, or a visible failure. Not "whatever happens."
- **Both `%pre` responsibilities coexist**: the LUKS passphrase is still minted and
  the provisioning config is still parsed in the same block, and a failure in
  either does not take out the other (`--erroronfail` is set — check that a
  malformed YAML degrades to defaults rather than aborting the install).

## Out of scope

Hostname (owned by the server's dispenser), Tailscale enrollment (already per-flavor
via `svk-tailscale-enroll`), and any change to `admin`/`opilas`.
