# Wire a CI failure alert (the "Fail loudly" gap)

Status: **not started.** Noted 2026-07-26.

## The gap

CLAUDE.md names the driving risk of this whole project:

> A silently broken pipeline means the fleet silently stops getting updates; that
> risk drives most of the design (`bootc container lint --fatal-warnings` as final
> layer, `fail-fast: false`, notify-on-failure).

Two of those three exist. **`notify-on-failure` does not.** Grepping
`.github/workflows/` for any alerting — notify, webhook, mail, ntfy — returns
nothing except the comment that promises it.

Worse, that comment is a **dangling reference**:

```
.github/workflows/build.yml:6
# updates — see the "Fail loudly" note in the README for wiring a failure alert.
```

There is no "Fail loudly" section in `README.md`. So the one pointer to how this
is supposed to work leads nowhere.

## Why it matters more than it looks

These are custom images pinned to a base by digest — they do **not** inherit
upstream updates. The weekly cron rebuild *is* the mechanism by which new kernels
and security fixes reach the fleet. If the workflow starts failing (an expired
token, a Flathub ref that 404s, a base digest Renovate bumped to something that
won't build), nothing tells anyone. The fleet keeps running happily on an
increasingly stale image, and the failure surfaces months later.

GitHub's default notification for a failed scheduled workflow is an email to the
repo owner, which is easy to filter into oblivion and does not survive the owner
changing.

## Options

- **GitHub's built-in scheduled-workflow failure email** — free, already on;
  document it as the mechanism and be explicit about who receives it. Weakest but
  zero work.
- **A `notify` job with `if: failure()`** posting to whatever the school actually
  reads — email, ntfy, a Tailscale-reachable endpoint on svk-server.
- **Dead-man's-switch** — the inverse, and stronger for this specific risk: CI
  pings a healthcheck endpoint on *success*, and the endpoint alerts when the
  weekly ping fails to arrive. This catches the case a failure alert cannot — the
  workflow never running at all (disabled by GitHub after repo inactivity,
  schedule silently dropped, org billing lapse).

The dead-man's switch is the one that matches the stated risk. GitHub disables
scheduled workflows on public repos after 60 days of inactivity, which is exactly
the "silently stops" scenario and which no `if: failure()` job can ever catch.

## Also do

- Add the missing **"Fail loudly"** section to `README.md`, or fix the pointer in
  `build.yml:6` to reference wherever this actually ends up documented.

## Relationship to svk-check

`20260726-1908-svk-check-health-service.md` covers the **machine** side — a
machine asserting that its own last successful `bootc upgrade` was recent. This
task is the **CI** side. They catch different failures and neither substitutes
for the other: CI alerting catches a broken build, svk-check catches a machine
that stopped applying good builds. Both are needed before a cosign key rotation
can be attempted safely (see the *Signing key* section in `README.md`).
