# secrets/ — provisioning secrets (never committed)

`server.bu` references the two server-install secrets by **file** (Butane
`contents.local`), not inline, so the actual secret bytes live here and are
injected only at compile time:

```bash
butane --pretty --strict --files-dir . server.bu > server.ign
```

`.gitignore` blocks everything in this directory except this README and the
`*.example` templates, and blocks `server.ign` too. Nothing secret reaches git.

## Files to create here

| File | What it is | How to make it |
|---|---|---|
| `secrets/tailscale-authkey` | Server's one-off, tagged, pre-auth key | Tailscale admin console → Settings → Keys → *Generate auth key* (reusable off, ephemeral optional, tag `tag:svk-server`). Paste the `tskey-…` string. |
| `secrets/id_ed25519` | Server's **outbound** SSH private key | `ssh-keygen -t ed25519 -C svk-server -N '' -f secrets/id_ed25519` — this also writes `secrets/id_ed25519.pub`. |

The **public** half of `secrets/id_ed25519` must match the `svk-server` line in
`files/base/etc/ssh/authorized_keys.d/admin`. If you generate a fresh keypair,
paste the new `secrets/id_ed25519.pub` over that line and rebuild the images.

After the server's first install, delete the Tailscale key from the console (it
is one-off) and keep `secrets/` out of any backup that lands in git.
