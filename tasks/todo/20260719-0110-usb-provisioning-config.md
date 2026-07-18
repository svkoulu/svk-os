# Spec — USB provisioning config for install-time user accounts

Status: **planning only — no repo files touched yet.** This is the design; the
implementation is a later, separate task.

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
  zero-click); staff = the current interactive Create Account page + defaults
  (unchanged). No password is ever baked into the image.

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
   - **move `lang`/`keyboard`/`timezone` out of the static `common_ks()`** into the
     `%pre`-generated include (so the config can override them without a
     duplicate-directive conflict);
   - add to the shared `common_ks()` a `%pre` block that `findfs LABEL=SVK-PROV`,
     mounts ro, runs `/usr/libexec/svk/parse-provision <usb>/svk-provision.yaml
     /tmp/svk-provision.ks` (falling back to defaults when absent/unreadable), plus
     a matching `%include /tmp/svk-provision.ks`. Living in `common_ks()` makes it
     apply to **both** flavors.
5. **`iso/build-iso.sh`** — copy `iso/svk-provision.yaml.example` next to the output
   ISO and print a one-line hint (mirrors the existing luks-bootstrap hint).
6. **`.gitignore`** — ignore `iso/svk-provision.yaml` (a real filled config) as a
   safety net; the `.example` stays tracked.
7. **Docs** — `iso/README.md` gets a "Provisioning config (user accounts)" section
   + Pieces/Deps rows; `TODO.md` §1 notes the config-driven account path; brief
   mention in the top-level `README.md` deploy steps.

## Fallback behavior

| USB `svk-provision.yaml` | student | staff |
|---|---|---|
| **present** | `opilas` (baked) + config users; locale from config | config users created (satisfies the account step); locale from config |
| **absent / unreadable** | `opilas` only; `fi`/`fi`/Helsinki defaults | interactive Create Account page (current behavior); defaults |

`admin` (SSH-only) is present on both, always. No secret is ever baked in.

**Validation caveat:** on **staff-with-config**, whether Anaconda's WebUI fully
auto-satisfies the Accounts screen from a kickstart `user` (zero-click) vs. still
showing it pre-filled is version-dependent — confirm on the real ISO. If true
zero-click staff-with-config is required and the WebUI still stops, the follow-up
is to switch staff to a complete `inst.ks=` flow with `gnome-initial-setup` as the
no-config fallback (documented alternative, not done by default).

## Verification (for the implementation task)

- **Parser unit-check** offline: run `parse-provision.py` against the `.example`
  and malformed inputs (bad username, admin-without-password, missing file) —
  confirm the emitted `.ks` is correct and guards fire.
- **Build both ISOs** (`just iso student local`, `just iso staff local`) — confirm
  the installer image builds with `python3-pyyaml` and the parser present.
- **VM install with a fake USB** via `just run-iso`: attach a second disk/volume
  labelled `SVK-PROV` holding a `svk-provision.yaml`; confirm the listed user is
  created with the right sudo/no-sudo and locale, and that `admin`/`opilas` are
  unchanged.
- **VM install with no USB**: confirm student is still zero-click (opilas only) and
  staff still reaches the Create Account page.

## Out of scope

Hostname (owned by the server's dispenser), Tailscale enrollment (already per-flavor
via `svk-tailscale-enroll`), and any change to `admin`/`opilas`.
