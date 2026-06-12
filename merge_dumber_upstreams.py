#!/usr/bin/env python3

from __future__ import annotations

import argparse
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class RemoteDef:
    name: str
    fetch: str
    revision: str | None


@dataclass(frozen=True)
class Project:
    path: str
    name: str
    remote: str
    revision: str | None
    upstream: str | None
    dest_branch: str | None


@dataclass(frozen=True)
class UpstreamOverride:
    url: str
    fetch_ref: str | None = None
    manifest_remote: str | None = None


@dataclass(frozen=True)
class UpstreamSpec:
    url: str
    fetch_ref: str
    source: str


SPECIAL_UPSTREAMS = {
    "device/phh/treble": UpstreamOverride(
        url="https://github.com/TrebleDroid/device_phh_treble.git",
        fetch_ref="master",
    ),
    "external/selinux": UpstreamOverride(
        url="https://android.googlesource.com/platform/external/selinux",
        manifest_remote="aosp",
    ),
    "frameworks/opt/net/ims": UpstreamOverride(
        url="https://android.googlesource.com/platform/frameworks/opt/net/ims",
        manifest_remote="aosp",
    ),
    "packages/modules/DeviceLock": UpstreamOverride(
        url="https://android.googlesource.com/platform/packages/modules/DeviceLock",
        manifest_remote="aosp",
    ),
    "packages/modules/DnsResolver": UpstreamOverride(
        url="https://android.googlesource.com/platform/packages/modules/DnsResolver",
        manifest_remote="aosp",
    ),
    "system/libbase": UpstreamOverride(
        url="https://android.googlesource.com/platform/system/libbase",
        manifest_remote="aosp",
    ),
    "system/apex": UpstreamOverride(
        url="https://android.googlesource.com/platform/system/apex",
        manifest_remote="aosp",
    ),
    "system/nfc": UpstreamOverride(
        url="https://android.googlesource.com/platform/system/nfc",
        manifest_remote="aosp",
    ),
    "vendor/hardware_overlay": UpstreamOverride(
        url="https://github.com/TrebleDroid/vendor_hardware_overlay.git",
        fetch_ref="pie",
    ),
    "vendor/gapps": UpstreamOverride(
        url="https://gitlab.com/MindTheGapps/vendor_gapps.git",
        fetch_ref="upsilon",
    ),
}

IGNORED_LOCAL_UPSTREAM_REMOTES = {"github", "upstream", "m"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Merge every DumberOS project in the manifest with its upstream."
    )
    parser.add_argument(
        "--manifest",
        default=".repo/manifests/default.xml",
        help="Manifest used to discover DumberOS projects (default: %(default)s).",
    )
    parser.add_argument(
        "--project",
        action="append",
        default=[],
        metavar="PATH",
        help="Only process the given project path. Can be passed multiple times.",
    )
    parser.add_argument(
        "--remote-name",
        default="upstream",
        help="Git remote name used for upstream fetches (default: %(default)s).",
    )
    parser.add_argument(
        "--allow-dirty",
        action="store_true",
        help="Allow merges in repos with tracked local changes.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the git commands without executing them.",
    )
    parser.add_argument(
        "--fail-fast",
        action="store_true",
        help="Stop after the first repo failure instead of continuing.",
    )
    parser.add_argument(
        "--push",
        action="store_true",
        help="Push each successfully merged branch to the github remote.",
    )
    parser.add_argument(
        "--push-remote",
        default="github",
        help="Remote used for --push (default: %(default)s).",
    )
    return parser.parse_args()


def run(
    args: list[str],
    *,
    cwd: Path | None = None,
    dry_run: bool = False,
    capture_output: bool = False,
    check: bool = True,
) -> str:
    printable = " ".join(shell_quote(part) for part in args)
    location = f" [{cwd}]" if cwd else ""
    print(f"$ {printable}{location}")
    if dry_run:
        return ""
    completed = subprocess.run(
        args,
        cwd=cwd,
        check=check,
        text=True,
        capture_output=capture_output,
    )
    if capture_output:
        return completed.stdout.strip()
    return ""


def shell_quote(text: str) -> str:
    if not text or any(ch.isspace() for ch in text) or any(ch in "'\"$`" for ch in text):
        return "'" + text.replace("'", "'\"'\"'") + "'"
    return text


def parse_manifest(manifest_path: Path) -> tuple[dict[str, RemoteDef], list[Project], str, str | None]:
    root = ET.parse(manifest_path).getroot()

    remotes: dict[str, RemoteDef] = {}
    for remote in root.findall("remote"):
        remotes[remote.attrib["name"]] = RemoteDef(
            name=remote.attrib["name"],
            fetch=remote.attrib["fetch"],
            revision=remote.get("revision"),
        )

    default = root.find("default")
    if default is None:
        raise SystemExit(f"{manifest_path} is missing <default>.")

    default_remote = default.attrib["remote"]
    default_revision = default.get("revision")

    projects: list[Project] = []
    for project in root.findall("project"):
        name = project.attrib["name"]
        if not name.startswith("DumberOS/"):
            continue
        projects.append(
            Project(
                path=project.attrib["path"],
                name=name,
                remote=project.get("remote", default_remote),
                revision=project.get("revision", default_revision),
                upstream=project.get("upstream"),
                dest_branch=project.get("dest-branch"),
            )
        )

    return remotes, projects, default_remote, default_revision


def normalize_branch_name(ref: str | None) -> str | None:
    if not ref:
        return None
    for prefix in ("refs/heads/", "refs/tags/", "refs/remotes/"):
        if ref.startswith(prefix):
            return ref[len(prefix) :]
    return ref


def default_target_branch(project: Project) -> str:
    branch = normalize_branch_name(project.dest_branch) or normalize_branch_name(project.upstream)
    if branch is None:
        raise ValueError(f"{project.path}: could not determine target branch from manifest.")
    return branch


def local_remote_urls(repo_path: Path) -> dict[str, str]:
    output = run(
        ["git", "remote", "-v"],
        cwd=repo_path,
        capture_output=True,
    )
    urls: dict[str, str] = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[2] == "(fetch)":
            urls[parts[0]] = parts[1]
    return urls


def resolve_upstream(project: Project, repo_path: Path, manifest_remotes: dict[str, RemoteDef]) -> UpstreamSpec:
    override = SPECIAL_UPSTREAMS.get(project.path)
    if override:
        if override.fetch_ref:
            fetch_ref = override.fetch_ref
        elif override.manifest_remote:
            fetch_ref = manifest_remotes[override.manifest_remote].revision
        else:
            raise ValueError(f"{project.path}: override is missing fetch_ref details.")
        if not fetch_ref:
            raise ValueError(f"{project.path}: override did not resolve a fetch ref.")
        return UpstreamSpec(override.url, fetch_ref, "override")

    remotes = local_remote_urls(repo_path)
    for remote_name, url in remotes.items():
        if remote_name in IGNORED_LOCAL_UPSTREAM_REMOTES:
            continue
        fetch_ref = manifest_remotes.get(remote_name, RemoteDef(remote_name, "", None)).revision
        if not fetch_ref:
            fetch_ref = project.upstream or project.revision
        if not fetch_ref:
            raise ValueError(f"{project.path}: local remote {remote_name} has no fetch ref.")
        return UpstreamSpec(url, fetch_ref, f"local remote {remote_name}")

    if "/" not in project.name:
        raise ValueError(f"{project.path}: malformed project name {project.name!r}.")
    _, repo_name = project.name.split("/", 1)
    url = f"https://github.com/LineageOS/{repo_name}.git"
    fetch_ref = project.upstream or project.revision
    if not fetch_ref:
        raise ValueError(f"{project.path}: no upstream ref available for Lineage fallback.")
    return UpstreamSpec(url, fetch_ref, "Lineage fallback")


def ensure_clean(repo_path: Path, allow_dirty: bool) -> None:
    if allow_dirty:
        return
    dirty = subprocess.run(
        ["git", "diff", "--quiet", "--ignore-submodules=all", "HEAD", "--"],
        cwd=repo_path,
    )
    staged = subprocess.run(
        ["git", "diff", "--cached", "--quiet", "--ignore-submodules=all", "--"],
        cwd=repo_path,
    )
    if dirty.returncode != 0 or staged.returncode != 0:
        raise RuntimeError(f"{repo_path}: tracked local changes present; use --allow-dirty to override.")


def ref_exists(repo_path: Path, ref: str) -> bool:
    result = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", ref],
        cwd=repo_path,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def checkout_target_branch(repo_path: Path, branch: str, dry_run: bool) -> None:
    current = run(
        ["git", "symbolic-ref", "--short", "-q", "HEAD"],
        cwd=repo_path,
        dry_run=dry_run,
        capture_output=True,
        check=False,
    )
    if current == branch:
        return

    if ref_exists(repo_path, f"refs/heads/{branch}"):
        run(["git", "checkout", branch], cwd=repo_path, dry_run=dry_run)
        return

    if ref_exists(repo_path, f"refs/remotes/github/{branch}"):
        run(
            ["git", "checkout", "--track", "-b", branch, f"github/{branch}"],
            cwd=repo_path,
            dry_run=dry_run,
        )
        return

    # Detached repo sync checkouts are common; pin the branch to the current commit.
    run(["git", "checkout", "-B", branch], cwd=repo_path, dry_run=dry_run)


def configure_upstream_remote(
    repo_path: Path,
    remote_name: str,
    upstream: UpstreamSpec,
    dry_run: bool,
) -> None:
    existing = local_remote_urls(repo_path)
    current_url = existing.get(remote_name)
    if current_url == upstream.url:
        return
    if current_url:
        run(
            ["git", "remote", "set-url", remote_name, upstream.url],
            cwd=repo_path,
            dry_run=dry_run,
        )
        return
    run(
        ["git", "remote", "add", remote_name, upstream.url],
        cwd=repo_path,
        dry_run=dry_run,
    )


def merge_project(
    root: Path,
    project: Project,
    manifest_remotes: dict[str, RemoteDef],
    args: argparse.Namespace,
) -> tuple[bool, str]:
    repo_path = root / project.path
    if not repo_path.is_dir():
        return False, f"{project.path}: directory is missing."
    if not (repo_path / ".git").exists():
        return False, f"{project.path}: not a git checkout."

    ensure_clean(repo_path, args.allow_dirty)

    target_branch = default_target_branch(project)
    upstream = resolve_upstream(project, repo_path, manifest_remotes)

    print(f"\n==> {project.path}")
    print(f"    target branch: {target_branch}")
    print(f"    upstream: {upstream.url} ({upstream.fetch_ref}, {upstream.source})")

    checkout_target_branch(repo_path, target_branch, args.dry_run)
    configure_upstream_remote(repo_path, args.remote_name, upstream, args.dry_run)
    run(
        ["git", "fetch", args.remote_name, upstream.fetch_ref],
        cwd=repo_path,
        dry_run=args.dry_run,
    )
    run(
        ["git", "merge", "--no-edit", "FETCH_HEAD"],
        cwd=repo_path,
        dry_run=args.dry_run,
    )
    if args.push:
        run(
            ["git", "push", args.push_remote, f"HEAD:{target_branch}"],
            cwd=repo_path,
            dry_run=args.dry_run,
        )
    return True, f"{project.path}: merged {upstream.fetch_ref}"


def main() -> int:
    args = parse_args()

    manifest_path = Path(args.manifest).resolve()
    root = manifest_path.parent.parent.parent
    if not (root / ".repo").exists():
        raise SystemExit(f"{root} does not look like an Android repo root.")

    manifest_remotes, projects, _, _ = parse_manifest(manifest_path)

    selected = set(args.project)
    if selected:
        projects = [project for project in projects if project.path in selected]
        missing = selected.difference(project.path for project in projects)
        if missing:
            raise SystemExit(f"Unknown DumberOS project path(s): {', '.join(sorted(missing))}")

    successes: list[str] = []
    failures: list[str] = []

    for project in projects:
        try:
            ok, message = merge_project(root, project, manifest_remotes, args)
        except Exception as exc:  # noqa: BLE001
            ok, message = False, f"{project.path}: {exc}"
        if ok:
            successes.append(message)
        else:
            failures.append(message)
            print(f"ERROR: {message}", file=sys.stderr)
            if args.fail_fast:
                break

    print("\nSummary")
    print(f"  succeeded: {len(successes)}")
    print(f"  failed:    {len(failures)}")
    if failures:
        for failure in failures:
            print(f"  - {failure}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
