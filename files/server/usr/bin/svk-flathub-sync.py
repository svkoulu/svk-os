#!/usr/bin/python3
"""svk-flathub-sync.py — refresh the curated Flathub mirror.

Runs daily (svk-flathub-sync.timer). What it does, in order:

  1. Resolve the storage location: a named Podman volume (flathub-mirror.volume
     quadlet -> Podman volume "systemd-flathub-mirror"), same lifecycle model as
     registry-cache, but read/written natively here rather than from inside a
     container — uCore already ships `ostree` (it IS an ostree-based OS), and we
     layer `flatpak` + `python3` in build.server.sh for the tooling this script
     needs. That avoids standing up a fifth, throwaway image just to run a sync
     job (this repo is deliberately four images — see CLAUDE.md).
  2. Bootstrap a local OSTree repo there, with a `flathub` remote pointing at
     the REAL Flathub, trusting Flathub's own signing key (extracted from their
     published .flatpakrepo — never hand-copied into this repo, so a future key
     rotation is picked up automatically instead of silently breaking mirroring).
  3. Pull just the appstream branch and curate: license, verified-developer,
     sandbox permissions, OARS content rating (see should_include() below), then
     apply the admin's allow/block-list overrides.
  4. `ostree pull --mirror` only the refs that survive curation — NOT the whole
     catalog (impractical size; staff self-serve still needs vetting anyway).
  5. `flatpak build-update-repo` so the result is a real, browsable flatpak
     remote (summary + scoped appstream branch), not just a raw OSTree dump.

Non-fatal by design: a network hiccup here just means tomorrow's run tries
again (like svk-flatpak-preinstall.sh's per-app tolerance) — never blocks the
registry cache or dispenser, which live on this same box.
"""
import configparser
import fcntl
import gzip
import os
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

ARCH = "x86_64"  # the whole fleet is x86_64; revisit if that ever changes.
VOLUME_NAME = "systemd-flathub-mirror"  # Quadlet's naming for flathub-mirror.volume
FLATHUB_URL = "https://dl.flathub.org/repo/"
FLATHUB_REPO_FILE_URL = "https://dl.flathub.org/repo/flathub.flatpakrepo"
APPSTREAM_REFS = (f"appstream2/{ARCH}", f"appstream/{ARCH}")  # try new, then old

STATE_DIR = "/var/lib/svk"
ALLOWLIST_PATH = f"{STATE_DIR}/flathub-allowlist"
BLOCKLIST_PATH = f"{STATE_DIR}/flathub-blocklist"
EXAMPLE_DIR = "/usr/share/svk"
LOCK_PATH = "/run/svk-flathub-sync.lock"


def log(msg):
    print(f"svk-flathub-sync: {msg}", flush=True)


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def acquire_lock():
    # A slow sync (big first run) shouldn't overlap with tomorrow's timer fire.
    fh = open(LOCK_PATH, "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("previous run still in progress; skipping this fire")
        sys.exit(0)
    return fh  # keep a reference so the lock isn't released by GC


def seed_list(path, example_name):
    # Same seed-then-edit-in-place pattern as hostname-pool.example: the real,
    # admin-editable file lives on the data volume and survives image rebuilds;
    # the image only ships a starting point.
    if os.path.exists(path):
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    example = f"{EXAMPLE_DIR}/{example_name}"
    with open(example, "r") as src, open(path, "w") as dst:
        dst.write(src.read())
    log(f"seeded {path} from {example}")


def read_list(path):
    ids = set()
    if not os.path.exists(path):
        return ids
    with open(path) as f:
        for line in f:
            app = line.split("#", 1)[0].strip()
            if app:
                ids.add(app)
    return ids


def resolve_repo_path():
    run(["podman", "volume", "create", "--ignore", VOLUME_NAME], stdout=subprocess.DEVNULL)
    out = subprocess.run(
        ["podman", "volume", "inspect", VOLUME_NAME, "--format", "{{.Mountpoint}}"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    return out


def fetch_flathub_gpg_key(tmpdir):
    # The .flatpakrepo file is Flathub's own canonical statement of "this is our
    # current signing key" — same trick the client-side preinstall script uses,
    # so a key rotation upstream is picked up here too instead of drifting.
    with urllib.request.urlopen(FLATHUB_REPO_FILE_URL, timeout=30) as resp:
        text = resp.read().decode()
    # GPGKey= is the first line of the key; the rest of the block is the
    # continuation of the same base64 blob with no further "key=" prefix.
    lines = text.splitlines()
    collecting = False
    parts = []
    for line in lines:
        if line.startswith("GPGKey="):
            parts.append(line[len("GPGKey="):])
            collecting = True
            continue
        if collecting:
            if "=" in line and line.split("=", 1)[0].isalpha() and line[0].isupper():
                break  # next Key=Value field in the .flatpakrepo file
            parts.append(line.strip())
    key_path = os.path.join(tmpdir, "flathub.gpg")
    import base64
    with open(key_path, "wb") as f:
        f.write(base64.b64decode("".join(parts)))
    return key_path


def ensure_repo(repo_path, tmpdir):
    if not os.path.exists(os.path.join(repo_path, "config")):
        run(["ostree", "init", f"--repo={repo_path}", "--mode=archive"])
    remotes = subprocess.run(
        ["ostree", f"--repo={repo_path}", "remote", "list"],
        check=True, capture_output=True, text=True,
    ).stdout.split()
    if "flathub" not in remotes:
        keyfile = fetch_flathub_gpg_key(tmpdir)
        run([
            "ostree", f"--repo={repo_path}", "remote", "add",
            f"--gpg-import={keyfile}", "flathub", FLATHUB_URL,
        ])
        log("added flathub upstream remote (trusting Flathub's published signing key)")


def pull_appstream(repo_path):
    for ref in APPSTREAM_REFS:
        try:
            run(["ostree", f"--repo={repo_path}", "pull", "flathub", ref])
            return ref
        except subprocess.CalledProcessError:
            continue
    raise RuntimeError("could not pull either appstream2 or appstream branch from flathub")


def load_components(repo_path, appstream_ref, tmpdir):
    checkout = os.path.join(tmpdir, "appstream-checkout")
    run(["ostree", f"--repo={repo_path}", "checkout", "-U", appstream_ref, checkout])
    xml_gz = os.path.join(checkout, "appstream.xml.gz")
    xml_plain = os.path.join(checkout, "appstream.xml")
    src = xml_gz if os.path.exists(xml_gz) else xml_plain
    opener = gzip.open if src.endswith(".gz") else open
    with opener(src, "rb") as f:
        tree = ET.parse(f)
    return tree.getroot()


def bundle_ref(component):
    for bundle in component.findall("bundle"):
        if bundle.get("type") == "flatpak":
            return bundle.text
    return None


def is_verified(component):
    for value in component.findall("./custom/value"):
        if value.get("key") == "flathub::verification::verified":
            return (value.text or "").strip().lower() == "true"
    return False


def oars_clean(component):
    rating = component.find("content_rating")
    if rating is None:
        return True  # no rating data at all -> nothing to flag, don't punish it
    for attr in rating.findall("content_attribute"):
        cid = attr.get("id", "")
        value = (attr.text or "none").strip().lower()
        if (cid.startswith("violence-") or cid.startswith("sex-")) and value != "none":
            return False
    return True


def curated_candidates(root):
    """First pass: filters answerable purely from appstream (cheap, local)."""
    candidates = {}  # app_id -> ref
    for component in root.findall("component"):
        if component.get("type") == "runtime":
            continue
        ref = bundle_ref(component)
        if not ref:
            continue
        parts = ref.split("/")  # app/<id>/<arch>/<branch>
        if len(parts) != 4 or parts[0] != "app" or parts[2] != ARCH:
            continue
        app_id = parts[1]
        license_ = component.findtext("project_license", default="")
        if license_ == "LicenseRef-proprietary":
            continue
        if not is_verified(component):
            continue
        if not oars_clean(component):
            continue
        candidates[app_id] = ref
    return candidates


def sandbox_clean(repo_path, ref, tmpdir):
    """Second pass: pull just /metadata (ostree supports partial-subpath pulls)
    and check the [Context] section — no need to fetch full build manifests."""
    run(["ostree", f"--repo={repo_path}", "pull", "--subpath=/metadata", "flathub", ref])
    checkout = tempfile.mkdtemp(dir=tmpdir)
    run(["ostree", f"--repo={repo_path}", "checkout", "--subpath=/metadata", "-U", ref, checkout])
    meta_path = os.path.join(checkout, "metadata")
    if not os.path.exists(meta_path):
        return True  # nothing to sandbox-check; not our call to make up a reason to block
    cp = configparser.ConfigParser(delimiters=("=",), strict=False, interpolation=None)
    cp.read(meta_path)
    if not cp.has_section("Context"):
        return True
    filesystems = cp.get("Context", "filesystems", fallback="").split(";")
    sockets = cp.get("Context", "sockets", fallback="").split(";")
    devices = cp.get("Context", "devices", fallback="").split(";")
    if any(fs in ("host", "host-os", "host-etc") for fs in filesystems):
        return False
    if any(s in ("session-bus", "system-bus") for s in sockets):
        return False
    if any(d == "all" for d in devices):
        return False
    return True


def main():
    lock = acquire_lock()  # noqa: F841 (kept alive for the process lifetime)
    seed_list(ALLOWLIST_PATH, "flathub-allowlist.example")
    seed_list(BLOCKLIST_PATH, "flathub-blocklist.example")
    allowlist = read_list(ALLOWLIST_PATH)
    blocklist = read_list(BLOCKLIST_PATH)
    conflicts = allowlist & blocklist
    if conflicts:
        log(f"WARNING: on both allowlist and blocklist, blocklist wins: {sorted(conflicts)}")

    repo_path = resolve_repo_path()
    log(f"repo path: {repo_path}")

    with tempfile.TemporaryDirectory() as tmpdir:
        ensure_repo(repo_path, tmpdir)
        appstream_ref = pull_appstream(repo_path)
        root = load_components(repo_path, appstream_ref, tmpdir)
        candidates = curated_candidates(root)
        log(f"{len(candidates)} apps pass the license/verification/OARS filters")

        final_refs = {}
        skipped_sandbox = 0
        for app_id, ref in candidates.items():
            if app_id in blocklist:
                continue
            if app_id not in allowlist and not sandbox_clean(repo_path, ref, tmpdir):
                skipped_sandbox += 1
                continue
            final_refs[app_id] = ref
        # Allow-listed apps skip curation filters entirely, including sandbox.
        for app_id in allowlist - blocklist:
            if app_id not in final_refs:
                # We don't know the ref for an allow-listed app that failed an
                # earlier appstream filter (e.g. unverified) unless it was also
                # in `candidates`; look it up directly if appstream has it.
                ref = candidates.get(app_id) or next(
                    (bundle_ref(c) for c in root.findall("component")
                     if c.findtext("id") == app_id and bundle_ref(c)),
                    None,
                )
                if ref:
                    final_refs[app_id] = ref

        log(f"skipped {skipped_sandbox} apps for broad sandbox permissions")
        log(f"{len(final_refs)} apps in the final curated set")

        for app_id, ref in sorted(final_refs.items()):
            run(["ostree", f"--repo={repo_path}", "pull", "--mirror", "flathub", ref])

    run(["flatpak", "build-update-repo", f"--arch={ARCH}", repo_path])
    log("done")


if __name__ == "__main__":
    main()
