# custom/ujust — svk's fleet-maintenance commands

`.just` files here are consolidated at build time (`build/10-packages.sh`) into
`/usr/share/svk/svk.just`, reachable on every desktop image via a thin
`/usr/bin/ujust` wrapper (`exec just --justfile /usr/share/svk/svk.just "$@"`).

This is **not** ublue-os/bling's `ujust` binary — that's a COPR package with
`gum` as a runtime dependency, and pulling it in just for the command name would
add a trust root svk doesn't otherwise need (same reasoning that ruled out
`uupd`; see `tasks/todo/…-fleet-update-cadence.md`). It's Fedora's own `just`
plus a repo-owned justfile — same command name, no new dependency.

Recipes run over the **admin SSH session** (no GUI, no polkit agent) — use
`sudo`, not `pkexec`, for anything privileged.

## Files

- **`svk-update.just`** — `update-now` / `update-apply-now` / `update-status`:
  manually trigger or check the scheduled bootc-image/flatpak update units.
- **`svk-maintenance.just`** — fleet diagnostics: boot logs, config-drift check,
  channel switch, LUKS/TPM2 status, device/BIOS info, flatpak cleanup, and the
  (destructive, confirmation-gated) factory-reset `powerwash`.

## Adding a recipe

Any `.just` file dropped here is picked up automatically — no wiring needed
beyond adding the file. Keep recipes non-interactive-menu (no `gum`) and use
`sudo` for privileged steps. `[group('Name')]` above a recipe controls how it's
grouped in `ujust`'s default listing.
