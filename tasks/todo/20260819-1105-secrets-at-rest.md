# Per-site secrets, encrypted at rest, off the command line

Status: **not started.** Written 2026-08-19. Borrowed from `../infra` (ADR 0012,
`tools/secretctl/`, `boxes/<box>/box.sec`). Prerequisite-adjacent to
`…-usb-provisioning-config.md`, which needs somewhere for its secrets to live.

## The problem this solves

Every secret this repo touches is currently handled a different way, and none of
them well:

| secret | today |
|---|---|
| staff account password | placeholder baked into the kickstart, expired at first login; overridable only via `STAFF_PASSWORD=` on the **command line** of the ISO build |
| lab Wi-Fi PSK | a gitignored `.nmconnection` a human fills in before building |
| Tailscale auth key | a file on a USB stick labelled `SVK-PROV` |
| cosign private key | `cosign.key`, gitignored, plus a GitHub secret that cannot be read back |

Two of those put a secret on a command line (visible in shell history and to
every process on the machine), one depends on remembering to fill in a file
before a build, and the whole set has no single answer to "what secrets does this
site need, and which are missing?"

## What infra does

`box.sec` sits next to the non-secret `box.env` in each box's directory,
encrypted at rest, with a small Go tool (`secretctl`) that:

- takes a value on **stdin**, never on argv (`just secret-set box-02 KEY`)
- decrypts only in memory at render time
- **refuses to render** if a key that belongs in `box.sec` appears in the
  plaintext `box.env` — so the failure mode of putting a password in the wrong
  file is a hard error, not a committed secret
- leaves no plaintext artifact behind (the rendered Ignition goes through tmpfs)

That last pair is the part worth copying regardless of the implementation: the
mistake is not "we lack encryption", it is "nothing stops the plaintext path".

## What we would do with it

The natural unit here is not a machine but a **site/role**: one encrypted file
carrying the staff password, the Wi-Fi PSK, and the Tailscale auth key, consumed
by the ISO build and by the USB provisioning config. That collapses three
different mechanisms into one and gives `just placeholders` a real answer instead
of a grep for `<<`.

## Decide before implementing

- **Port `secretctl` or use `age`/`sops` directly?** infra wrote a tool because it
  wanted a specific refusal behaviour and a specific stdin-only interface. We
  could get 80% with `age` and a Justfile recipe. Porting the Go tool means
  carrying a Go toolchain in this repo's CI, which it does not have today.
  Recommend: `age` + recipes first, and only port the tool if the refusal
  behaviour turns out to be the thing we keep wanting.
- **Where does the decryption key live?** infra's answer is a passphrase the
  operator types. For us the same applies at ISO-build time — the ISO build is
  already an at-the-desk operation with sudo prompts.
- The `SVK-PROV` USB stays as-is: it is a *delivery* mechanism to a machine with
  no other channel, not a storage question.

## Outcomes

- [ ] One encrypted per-site secrets file, format and tool chosen above
- [ ] `STAFF_PASSWORD` off argv
- [ ] The Wi-Fi PSK comes from it rather than from a hand-filled gitignored file
- [ ] A refusal path: building with a secret sitting in a plaintext file fails
- [ ] `TODO.md` §4 rewritten around it (it currently lists four separate manual
      steps that this replaces)
