#!/usr/bin/env python3
# Copyright (c) 2026 ROKCT INTELLIGENCE (PTY) LTD
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

"""Compose a per-product rcore app at image-build time.

This is the opt-in "compose at build" path (Dockerfile target
``tenant_composed``). It does NOT change the golden-build path: the existing
``builder`` stage keeps fetching rcore with ``bench get-app`` exactly as
before, which today ships the bare rcore shell (modules.txt = rcore, paas).

What this script does, in order:

1. Clones The-Rokct-Protocol at ``--protocol-ref`` (a build arg — pin it to a
   SHA for reproducible builds; the resolved SHA is logged either way).
2. Clones the rcore SHELL repo at ``--shell-ref`` (default main, matching the
   branch build_ecosystem.sh's ``bench get-app`` uses today).
3. Loads the product's compose template from the protocol checkout:
   ``core/utils/frappe/composer/<PRODUCT>.json`` (rcore.json, supacharge.json,
   deliveryplatform.json, ...).
4. Deals with the unpinned-ref reality honestly: the protocol's
   compose_backend.py refuses mutable refs (anything that is not a 40-char
   commit SHA) unless ROKCT_ALLOW_UNPINNED_SDKS=1 — and every template entry
   today says ``"ref": "main"``. Instead of using the escape hatch, this
   script resolves each source repo's current ref to a commit SHA via
   ``git ls-remote`` at build time, rewrites a WORKING COPY of the manifest
   with those SHAs, and logs the full module -> repo@sha table (stdout and
   ``composed_provenance.json`` inside the composed app). Deterministic per
   build; the protocol's pin enforcement then actively validates the refs.
   compose_backend.py itself is not patched.
5. Runs the protocol composer (compose_backend.py) from the shell root. The
   composer's local-sibling shortcut (it prefers ``../<repo>`` checkouts over
   cloning) is deliberately starved: the shell is cloned into an otherwise
   empty workspace directory, so every module is cloned at its pinned SHA.
6. Verifies every enabled module actually composed (directory exists under
   the app package and is registered in modules.txt) — the composer
   soft-skips modules whose manifest.json is missing, and a quietly
   incomplete app must fail the image build instead.
7. Byte-compiles the composed package (syntax gate), scrubs credentials and
   clone caches out of the tree, and moves the result to ``--output``.

The output location is chosen so build_ecosystem.sh needs NO changes: its
existing "Using LOCAL <app> from workspace" branch stages
``$GITHUB_WORKSPACE/rcore`` into apps/rcore instead of running
``bench get-app`` whenever that directory exists.

Auth mirrors platform/Dockerfile's existing mechanism exactly: plain build
args, MONOREPO_PAT preferred with GITHUB_TOKEN as fallback, injected as an
``x-access-token`` HTTPS URL (the same shape compose_backend.py's
authenticated_git_url() builds from MONOREPO_PAT).
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
GIT_TIMEOUT = 600  # same network-stall cap compose_backend.py uses


def log(msg):
    print(f"[compose_product] {msg}", flush=True)


def fail(msg, code=1):
    print(f"[compose_product] ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(code)


def effective_token():
    """MONOREPO_PAT preferred, GITHUB_TOKEN fallback — the exact resolution
    platform/Dockerfile already does (GIT_TOKEN="${MONOREPO_PAT:-${GITHUB_TOKEN}}").
    GitHub Actions masks secrets as ***; treat that as unset, like the
    Dockerfile's own '!= "***"' guard."""
    for var in ("MONOREPO_PAT", "GITHUB_TOKEN"):
        token = os.environ.get(var, "").strip()
        if token and token != "***":
            return token
    return None


def authenticated_url(url, token):
    if token and url.startswith("https://github.com/"):
        return url.replace(
            "https://github.com/", f"https://x-access-token:{token}@github.com/"
        )
    return url


def run(cmd, **kwargs):
    kwargs.setdefault("check", True)
    kwargs.setdefault("timeout", GIT_TIMEOUT)
    return subprocess.run(cmd, **kwargs)


def scrub_remote(repo_dir, plain_url):
    """Never leave a token-bearing remote URL inside a tree that ends up in
    the image."""
    try:
        run(["git", "-C", repo_dir, "remote", "set-url", "origin", plain_url])
    except Exception as exc:  # pragma: no cover - best effort
        log(f"warning: could not scrub remote url in {repo_dir}: {exc}")


def clone_at_ref(url, ref, dest, token):
    """Clone url at ref (branch, tag, or commit SHA) into dest.

    Mirrors compose_backend.py's clone_ref(): shallow branch/tag clone first,
    full clone + checkout as the SHA-compatible fallback."""
    auth = authenticated_url(url, token)
    try:
        run(["git", "clone", "-b", ref, "--depth", "1", auth, dest])
    except subprocess.CalledProcessError:
        log(f"`git clone -b {ref}` failed (commit SHA ref?); retrying as full clone + checkout...")
        if os.path.exists(dest):
            shutil.rmtree(dest)
        run(["git", "clone", auth, dest])
        run(["git", "-C", dest, "checkout", ref])
    scrub_remote(dest, url)
    head = subprocess.run(
        ["git", "-C", dest, "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    return head


def resolve_remote_sha(url, ref, token, cache):
    """Resolve a mutable ref (branch or tag name) to the commit SHA it points
    at right now, via git ls-remote. Deterministic for the rest of this build."""
    key = (url, ref)
    if key in cache:
        return cache[key]
    auth = authenticated_url(url, token)
    out = subprocess.run(
        ["git", "ls-remote", auth, f"refs/heads/{ref}", f"refs/tags/{ref}"],
        check=True,
        capture_output=True,
        text=True,
        timeout=GIT_TIMEOUT,
    ).stdout
    sha = None
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 2 and parts[1] in (f"refs/heads/{ref}", f"refs/tags/{ref}"):
            sha = parts[0]
            break
    if not sha or not SHA_RE.match(sha):
        fail(f"could not resolve ref '{ref}' on {url} to a commit SHA (ls-remote output: {out!r})")
    cache[key] = sha
    return sha


def pin_manifest(manifest, token):
    """Rewrite every git-sourced module entry's mutable ref to the SHA it
    resolves to right now. Entries already pinned to a 40-char SHA are left
    untouched. Disabled entries are pinned too — compose_backend.py's
    resolve_module_sources() walks ALL git entries, so an unpinned disabled
    module would still fail its ref check."""
    cache = {}
    pins = []
    for module in manifest.get("modules", []):
        if module.get("source") != "git" or not module.get("git"):
            continue
        url = module["git"]
        ref = module.get("ref") or "main"
        if SHA_RE.match(ref.lower()):
            pins.append(
                {
                    "name": module.get("name"),
                    "repo": url,
                    "requested_ref": ref,
                    "pinned_sha": ref.lower(),
                    "already_pinned": True,
                }
            )
            continue
        sha = resolve_remote_sha(url, ref, token, cache)
        module["ref"] = sha
        pins.append(
            {
                "name": module.get("name"),
                "repo": url,
                "requested_ref": ref,
                "pinned_sha": sha,
                "already_pinned": False,
            }
        )
    if pins:
        log("build-time ref pinning (git ls-remote):")
        for p in pins:
            marker = "kept" if p["already_pinned"] else "pinned"
            log(f"  {p['name']:<16} {p['repo']} {p['requested_ref']} -> {p['pinned_sha']} ({marker})")
    return pins


def git_commit_all(repo_dir, message):
    env = dict(
        os.environ,
        GIT_AUTHOR_NAME="compose_product",
        GIT_AUTHOR_EMAIL="compose_product@rokct.ai",
        GIT_COMMITTER_NAME="compose_product",
        GIT_COMMITTER_EMAIL="compose_product@rokct.ai",
    )
    run(["git", "-C", repo_dir, "add", "-A"], env=env)
    run(["git", "-C", repo_dir, "commit", "-m", message, "--no-verify"], env=env)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--product",
        default="rcore",
        help="Compose template name under core/utils/frappe/composer/ (default: rcore, "
        "the full 26-module manifest — parity with what the shell's own composer.json declares)",
    )
    parser.add_argument(
        "--protocol-ref",
        default="main",
        help="The-Rokct-Protocol ref to fetch the composer + templates from "
        "(pass a commit SHA for reproducible builds)",
    )
    parser.add_argument(
        "--shell-ref",
        default="main",
        help="rcore shell repo ref (default main — the same branch the golden "
        "build's `bench get-app rcore` tracks today)",
    )
    parser.add_argument(
        "--shell-repo",
        default="https://github.com/RokctAI/rcore",
        help="rcore shell repository URL",
    )
    parser.add_argument(
        "--protocol-repo",
        default="https://github.com/RokctAI/The-Rokct-Protocol",
        help="protocol repository URL",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Where to leave the composed app repo (e.g. $GITHUB_WORKSPACE/rcore, "
        "which build_ecosystem.sh's LOCAL-staging branch then copies into apps/rcore)",
    )
    parser.add_argument(
        "--workdir",
        default=None,
        help="Scratch directory (default: <output>.compose-work); must not already exist",
    )
    parser.add_argument(
        "--keep-workdir",
        action="store_true",
        help="Keep the scratch directory for debugging",
    )
    args = parser.parse_args()

    token = effective_token()
    log(f"git token: {'present' if token else 'ABSENT (public clones only)'}")

    output = os.path.abspath(args.output)
    if os.path.exists(output):
        fail(f"--output {output} already exists; refusing to overwrite")

    workdir = os.path.abspath(args.workdir or f"{output}.compose-work")
    if os.path.exists(workdir):
        fail(f"--workdir {workdir} already exists; pass a fresh directory")
    protocol_dir = os.path.join(workdir, "protocol")
    # The compose workspace holds ONLY the shell clone: compose_backend.py
    # prefers a sibling ../<repo> checkout over cloning at the pinned ref, so
    # an empty parent directory is what guarantees the pins are honored.
    compose_ws = os.path.join(workdir, "ws")
    shell_dir = os.path.join(compose_ws, "rcore")
    os.makedirs(compose_ws)

    try:
        log(f"cloning protocol {args.protocol_repo} @ {args.protocol_ref}...")
        protocol_sha = clone_at_ref(args.protocol_repo, args.protocol_ref, protocol_dir, token)
        log(f"protocol resolved to {protocol_sha}")

        composer_py = os.path.join(protocol_dir, "core", "utils", "frappe", "compose_backend.py")
        if not os.path.isfile(composer_py):
            fail(f"composer not found at {composer_py} (protocol ref {args.protocol_ref})")

        template_dir = os.path.join(protocol_dir, "core", "utils", "frappe", "composer")
        template_path = os.path.join(template_dir, f"{args.product}.json")
        if not os.path.isfile(template_path):
            available = sorted(
                f[:-5] for f in os.listdir(template_dir) if f.endswith(".json")
            ) if os.path.isdir(template_dir) else []
            fail(
                f"no compose template for product '{args.product}' at {template_path}. "
                f"Available: {', '.join(available) or 'none'}",
                code=2,
            )

        log(f"cloning rcore shell {args.shell_repo} @ {args.shell_ref}...")
        shell_sha = clone_at_ref(args.shell_repo, args.shell_ref, shell_dir, token)
        log(f"rcore shell resolved to {shell_sha}")

        with open(template_path, "r", encoding="utf-8") as fh:
            manifest = json.load(fh)
        modules = manifest.get("modules", [])
        enabled = [m["name"] for m in modules if m.get("enabled")]
        log(
            f"product '{args.product}': {len(modules)} module entries, "
            f"{len(enabled)} enabled: {', '.join(enabled)}"
        )

        pins = pin_manifest(manifest, token)

        # The manifest must be COMMITTED into the shell clone: the composer's
        # main() starts with `git restore . && git clean -fd`, which would
        # wipe an uncommitted working-copy manifest.
        with open(os.path.join(shell_dir, "composer.json"), "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=2)
            fh.write("\n")
        git_commit_all(
            shell_dir,
            f"compose_product: pin '{args.product}' template refs for image build",
        )

        env = dict(os.environ)
        if token:
            # compose_backend.py's authenticated_git_url() reads MONOREPO_PAT.
            env["MONOREPO_PAT"] = token
        log(f"running protocol composer for product '{args.product}'...")
        started = time.time()
        result = subprocess.run([sys.executable, composer_py], cwd=shell_dir, env=env)
        if result.returncode != 0:
            fail(f"compose_backend.py exited {result.returncode}")
        log(f"composer finished in {time.time() - started:.1f}s")

        # Hard verification: the composer soft-skips modules whose
        # manifest.json is missing; an incomplete app must fail the build.
        app_pkg = os.path.join(shell_dir, "rcore")
        modules_txt_path = os.path.join(app_pkg, "modules.txt")
        registered = []
        if os.path.isfile(modules_txt_path):
            with open(modules_txt_path, "r", encoding="utf-8") as fh:
                registered = [line.strip() for line in fh if line.strip()]
        missing = [
            name
            for name in enabled
            if not os.path.isdir(os.path.join(app_pkg, name)) or name not in registered
        ]
        if missing:
            fail(
                f"composed app is incomplete — module(s) not composed/registered: "
                f"{', '.join(missing)} (modules.txt: {registered})"
            )
        log(f"verified {len(enabled)} composed modules; modules.txt now: {', '.join(registered)}")

        # Syntax gate over the composed package.
        log("byte-compiling composed package (python -m compileall)...")
        result = subprocess.run([sys.executable, "-m", "compileall", "-q", app_pkg])
        if result.returncode != 0:
            fail("compileall failed on the composed package")
        for root, dirs, _files in os.walk(shell_dir):
            for d in list(dirs):
                if d == "__pycache__":
                    shutil.rmtree(os.path.join(root, d))
                    dirs.remove(d)

        # The composer clones module repos into .rokct/cache inside the shell
        # with token-bearing remote URLs. Never ship that.
        cache_dir = os.path.join(shell_dir, ".rokct", "cache")
        if os.path.isdir(cache_dir):
            shutil.rmtree(cache_dir)

        provenance = {
            "product": args.product,
            "protocol_repo": args.protocol_repo,
            "protocol_ref_requested": args.protocol_ref,
            "protocol_sha": protocol_sha,
            "shell_repo": args.shell_repo,
            "shell_ref_requested": args.shell_ref,
            "shell_sha": shell_sha,
            "modules": pins,
            "composed_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        with open(os.path.join(shell_dir, "composed_provenance.json"), "w", encoding="utf-8") as fh:
            json.dump(provenance, fh, indent=2)
            fh.write("\n")

        os.makedirs(os.path.dirname(output), exist_ok=True)
        shutil.move(shell_dir, output)
        log(f"composed '{args.product}' app left at {output}")
    finally:
        if args.keep_workdir:
            log(f"keeping workdir {workdir}")
        else:
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
