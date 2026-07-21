# vim: set ft=make :
# svk-maintenance.just — fleet diagnostics, surveyed from projectbluefin/common's
# own ujust recipes and adapted for svk (headless admin SSH, no gum/pkexec, no
# external network calls). See tasks/todo/…-fleet-update-cadence.md.

# Show all messages from this boot.
[group('Maintenance')]
logs-this-boot:
    sudo journalctl --no-hostname -b 0

# Show all messages from the previous boot.
[group('Maintenance')]
logs-last-boot:
    sudo journalctl --no-hostname -b -1

# Excludes host-identity files that legitimately differ per machine
# (machine-id, ssh host keys, hostname, fstab, etc.). No output = no drift.
# Diff /usr/etc (shipped defaults) against /etc (live config) on this machine.
[group('Maintenance')]
check-drift:
    #!/usr/bin/bash
    set -euo pipefail
    sudo diff -qr \
        --exclude "passwd*" --exclude "group*" \
        --exclude "subgid*" --exclude "subuid*" \
        --exclude "shadow*" --exclude "gshadow*" \
        --exclude "machine-id" --exclude "adjtime" --exclude "fstab" \
        --exclude "ssh_host*" --exclude "crypttab" --exclude "hostname" \
        --exclude "localtime" --exclude "locale*" --exclude "vconsole*" \
        --exclude "*lock" --exclude "*LOCK" --exclude "grub*" \
        --exclude "00-keyboard.conf" \
        --exclude "luks-bootstrap" --exclude "svk-provision.yaml" \
        --exclude "tailscaled.state" \
        /usr/etc /etc 2>/dev/null | sed -e '/Binary files /d ; /Common subdirectories/d' \
    || true
    echo "(no lines above = no drift detected)"

# Reads /usr/share/svk-os/image-info.json.
# Show this machine's channel/version/commit.
[group('Maintenance')]
channel-status:
    #!/usr/bin/bash
    set -euo pipefail
    jq -r '"image:   \(.["image-name"])\nchannel: \(.channel)\nversion: \(.version)\ncommit:  \(.["git-commit"])"' \
        /usr/share/svk-os/image-info.json

# To pilot a change outside the normal per-flavor schedule, then switch back.
# Switch THIS machine's channel (stable<->testing).
[group('Maintenance')]
toggle-channel:
    #!/usr/bin/bash
    set -euo pipefail
    INFO=/usr/share/svk-os/image-info.json
    NAME="$(jq -r '.["image-name"]' "$INFO")"
    VENDOR="$(jq -r '.["image-vendor"]' "$INFO")"
    CHANNEL="$(jq -r '.channel' "$INFO")"
    case "$CHANNEL" in
        stable) NEW=testing ;;
        testing) NEW=stable ;;
        *)
            echo "Cannot auto-toggle from channel '${CHANNEL}'."
            echo "Switch manually: sudo bootc switch --enforce-container-sigpolicy <ref>"
            exit 1 ;;
    esac
    TARGET="ghcr.io/${VENDOR}/${NAME}:${NEW}"
    echo "This switches THIS machine from '${CHANNEL}' to '${NEW}' (${TARGET})."
    read -r -p "Proceed? [y/N] " ans
    case "${ans,,}" in
        y|yes) ;;
        *) echo "Cancelled."; exit 0 ;;
    esac
    sudo bootc switch --enforce-container-sigpolicy "${TARGET}"

# Read-only. Not a re-enrollment tool — /usr/libexec/svk/luks-tpm-enroll is a
# first-boot-only one-shot that no-ops once enrolled; re-enrolling after a
# hardware change needs different logic (recovery key + --wipe-slot), not built here.
# Report LUKS/TPM2 key-slot enrollment state.
[group('Maintenance')]
luks-status:
    #!/usr/bin/bash
    set -euo pipefail
    crypt_line="$(awk '!/^#/ && NF {print; exit}' /etc/crypttab 2>/dev/null || true)"
    if [ -z "$crypt_line" ]; then
        echo "No LUKS device in /etc/crypttab — this machine is not disk-encrypted."
        exit 0
    fi
    uuid="$(awk '{print $2}' <<<"$crypt_line" | sed 's/^UUID=//')"
    dev="/dev/disk/by-uuid/${uuid}"
    if [ ! -e "$dev" ]; then
        echo "crypttab references ${dev}, which doesn't exist."
        exit 1
    fi
    echo "== Enrolled key slots (${dev}) =="
    sudo systemd-cryptenroll --list "$dev"

# Local only — nothing leaves the machine, unlike upstream's pastebin version.
# Snapshot of bootc/flatpak/image state for diagnosing this machine over SSH.
[group('Maintenance')]
device-info:
    #!/usr/bin/bash
    set -euo pipefail
    echo "== bootc status =="
    sudo bootc status --verbose
    echo
    echo "== svk-os image info =="
    cat /usr/share/svk-os/image-info.json
    echo
    echo "== System flatpaks =="
    flatpak list --system --columns=application,version,options

# Cheap fleet inventory across mixed/hand-me-down hardware.
# Show baseboard manufacturer/product/BIOS version+date.
[group('Maintenance')]
bios-info:
    #!/usr/bin/bash
    set -euo pipefail
    echo "Manufacturer:  $(sudo dmidecode -s baseboard-manufacturer)"
    echo "Product name:  $(sudo dmidecode -s baseboard-product-name)"
    echo "BIOS version:  $(sudo dmidecode -s bios-version)"
    echo "BIOS date:     $(sudo dmidecode -s bios-release-date)"

# Remove unused (orphaned) system flatpak runtimes.
[group('Maintenance')]
clean-flatpaks:
    #!/usr/bin/bash
    set -euo pipefail
    read -r -p "Remove unused flatpak runtimes (system-scope)? [y/N] " ans
    case "${ans,,}" in
        y|yes) ;;
        *) echo "Cancelled."; exit 0 ;;
    esac
    sudo flatpak uninstall --system --unused -y

# Useful for wiping/repurposing a machine that's still bootable and
# SSH-reachable, without the Titanoboa USB reinstall flow. Gated behind typing
# the machine's own hostname back, not a simple y/N.
# Factory-reset this machine (EXPERIMENTAL, DESTRUCTIVE — erases all local data).
[group('Maintenance')]
powerwash:
    #!/usr/bin/bash
    set -euo pipefail
    host="$(hostname)"
    echo "!! THIS FACTORY-RESETS THIS MACHINE AND ERASES ALL LOCAL DATA !!"
    echo "Uses 'bootc install reset --experimental' — verify this is still the"
    echo "correct invocation for the currently pinned bootc version."
    read -r -p "Type this machine's hostname (${host}) to confirm: " typed
    if [ "$typed" != "$host" ]; then
        echo "Hostname did not match — cancelled."
        exit 1
    fi
    echo "Resetting in 5 seconds — Ctrl-C now to abort."
    sleep 5
    sudo bootc install reset --experimental
