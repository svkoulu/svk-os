# Server strategy (build an image or not?) + PXE provisioning

Status: **open question + deferred work.** Noted 2026-07-26. Neither part is
scheduled; both block on the server actually being deployed (currently WIP).

---

## Part 1 — should we keep building `svk-server` at all?

**The question:** `svk-server` is a maintained, CI-built, cosign-signed bootc
image for exactly **one machine**. That is a poor ratio. The alternative is to
run stock Fedora CoreOS (or uCore, or openSUSE MicroOS) unmodified and do all
the configuration with IaC — which for this machine largely already exists.

**What the image actually adds** over the stock base (`build.server.sh`):

- Layered packages: `htop curl wget ncdu fd-find`, `flatpak python3` (Flathub
  mirror tooling), `tailscale`, `avahi nss-mdns`, `cockpit cockpit-podman`.
- `firewall-offline-cmd` rules (5353/udp mDNS, 5000/tcp registry cache,
  8765/tcp hostname dispenser).
- A handful of `systemctl enable` calls.

Everything in that list is reachable from Ignition/Butane at provision time, and
we **already provision this machine with Ignition** — `server.bu` is 164 lines
and does the genuinely machine-specific half (hostname, secrets, quadlets).

**Arguments for dropping the image:**

- Removes an image from the CI matrix, from Renovate, and from the signing path.
- One machine does not benefit from "byte-identical across the fleet", which is
  the entire justification for the image model on the desktops.
- The server is the one machine an admin can always reach physically and over
  SSH — the "must never break unattended" pressure that justifies bootc on the
  laptops is much weaker here.

**Arguments for keeping it:**

- Package layering at *provision* time (`rpm-ostree install` from Ignition) is
  slow and can fail on a bad network; the image bakes it, so first boot is
  deterministic.
- `bootc rollback` on the server is genuinely useful — it hosts the registry
  cache the whole fleet pulls through, so a bad server update has fleet-wide
  blast radius.
- The build already exists and is working. Removing it is work with no new
  capability.

**Not decided.** If it goes, the replacement is stock FCOS/MicroOS + an expanded
`server.bu` (+ possibly Ansible for ongoing config, which introduces a second
config-management model to the project — weigh that).

Note MicroOS supports Ignition/combustion natively, so `server.bu` would survive
a move to the SUSE side essentially intact. That is *not* an argument for moving
the desktops (see `../../../aeon-os/NOTES.md` — Fedora is settled).

---

## Part 2 — PXE provisioning (deferred until the server exists)

**Why:** installing the fleet from USB sticks is the slow, manual part of
provisioning. PXE would make re-imaging a lab machine a network boot, remove
per-flavor ISO builds from the common path, and take `iso.yml` off the critical
path. Expected to make fleet installs substantially faster.

**Mechanism:**

1. `dnsmasq` on svk-server in **proxy-DHCP mode** — answers PXE requests
   alongside the school's existing DHCP server, so no school network config has
   to change. This is the detail that makes the whole thing deployable.
2. TFTP serves `shim.efi` → `grubx64.efi` → a GRUB config carrying the same
   entries the ISO uses.
3. HTTP serves kernel/initrd and the kickstarts:
   `inst.ks=http://svk-server/ks/<name>.ks`.
4. Kickstart uses `ostreecontainer --transport=registry` against the
   pull-through cache the server already runs, instead of the ISO's
   `containers-storage`.

**The flatpak catch.** Today the flatpak set is baked into the installer image's
`/var/lib/flatpak` and rsync'd into the target in `%post` (`iso/installer/build.sh`).
With no ISO there is no baked store. Preferred replacement:

- Build the flatpak set once, publish `flatpaks.tar.zst` on svk-server, and have
  `%post` do `curl | tar -x` into `/var/lib/flatpak` followed by the same
  `chcon -R -t var_lib_t`. This preserves today's semantics exactly — pinned at
  build time, one download per machine, deterministic.
- Alternative: install from the server's LAN Flathub mirror. No extra artifact
  to build, but slower per machine and not pinned.

**Keep the ISO path.** PXE makes the server a hard provisioning dependency. The
ISO remains the fallback for a machine that can't reach the server, or for
re-provisioning the server itself.
