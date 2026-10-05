#!/usr/bin/env python3
"""Build Octo's Ghostty framework from pinned official source, never a binary release.

The lock is reviewed source input. The manifest is evidence of this local build,
not a claim that two different machines produce byte-identical output.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / ".build/ghostty"
LOCK = ROOT / "Vendor/Ghostty.lock.json"
FRAMEWORK = CACHE / "GhosttyKit.xcframework"
RESOURCES = ROOT / "Sources/OctoGhostty/Resources/Runtime"
MANIFEST = CACHE / "build-manifest.json"


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def run(args, cwd=None, env=None, capture=False):
    # Arguments stay arrays, including every path. No shell evaluation.
    result = subprocess.run([str(arg) for arg in args], cwd=cwd, env=env,
                            check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def inventory(directory):
    return {str(p.relative_to(directory)): digest(p)
            for p in sorted(directory.rglob("*")) if p.is_file()}


def verify_tree(directory, expected):
    if not directory.is_dir() or not expected or inventory(directory) != expected:
        raise RuntimeError(f"Missing or modified Ghostty output: {directory}. Run Scripts/build-ghostty.sh.")


def verify_manifest(lock, target=None):
    if not MANIFEST.is_file():
        raise RuntimeError("Ghostty has not been built. Run Scripts/build-ghostty.sh first.")
    manifest = json.loads(MANIFEST.read_text())
    if manifest.get("lockSHA256") != digest(LOCK):
        raise RuntimeError("Ghostty lock changed. Rebuild with Scripts/build-ghostty.sh.")
    if manifest.get("scriptSHA256") != digest(__file__):
        raise RuntimeError("Ghostty build recipe changed. Rebuild with Scripts/build-ghostty.sh.")
    if manifest.get("sourceRevision") != lock["source"]["revision"]:
        raise RuntimeError("Ghostty source revision does not match the lock.")
    if target and manifest.get("target") != target:
        raise RuntimeError("Ghostty architecture selection changed; rebuild it.")
    verify_tree(FRAMEWORK, manifest.get("frameworkFiles", {}))
    verify_tree(RESOURCES, manifest.get("resourceFiles", {}))
    return manifest


def download(url, destination, expected):
    if destination.is_file() and digest(destination) == expected:
        return
    temporary = destination.with_suffix(destination.suffix + ".download")
    run(["curl", "--fail", "--location", "--retry", "3", "--output", temporary, url])
    if digest(temporary) != expected:
        temporary.unlink()
        raise RuntimeError("Downloaded compiler failed SHA-256 verification.")
    temporary.replace(destination)


def toolchain(lock):
    architecture = platform.machine()
    if platform.system() != "Darwin" or architecture not in lock["zig"]["archives"]:
        raise RuntimeError("Ghostty builds require an arm64 or x86_64 Mac.")
    xcode = run(["xcodebuild", "-version"], capture=True)
    version = re.search(r"Xcode (\d+)", xcode)
    if not version or int(version.group(1)) < 26:
        raise RuntimeError("The pinned Ghostty source requires Xcode 26 or newer and the macOS 26 SDK.")
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-build-version"], capture=True)
    # --find can locate the stub even when the optional compiler is absent.
    try:
        run(["xcrun", "--sdk", "macosx", "metal", "--version"], capture=True)
    except subprocess.CalledProcessError:
        raise RuntimeError("Install Apple's Metal compiler: xcodebuild -downloadComponent MetalToolchain")
    return architecture, xcode, sdk


def prepare_source(lock):
    source = CACHE / "source"
    pin = lock["source"]
    if not (source / ".git").is_dir():
        source.mkdir(parents=True, exist_ok=True)
        run(["git", "init", source])
        run(["git", "remote", "add", "origin", pin["repository"]], cwd=source)
    if run(["git", "remote", "get-url", "origin"], cwd=source, capture=True) != pin["repository"]:
        raise RuntimeError("Ghostty checkout has an unexpected origin; preserve it and inspect manually.")
    if run(["git", "status", "--porcelain", "--untracked-files=all"], cwd=source, capture=True):
        raise RuntimeError("Ghostty checkout has edits; preserve them and inspect before rebuilding.")
    try:
        revision = run(["git", "rev-parse", "HEAD"], cwd=source, capture=True)
    except subprocess.CalledProcessError:
        revision = None
    if revision != pin["revision"]:
        run(["git", "fetch", "--depth", "1", "origin", pin["revision"]], cwd=source)
        run(["git", "checkout", "--detach", pin["revision"]], cwd=source)
    if run(["git", "rev-parse", "HEAD"], cwd=source, capture=True) != pin["revision"]:
        raise RuntimeError("Official source checkout does not match the pin.")
    for name, key in [("ghostty.h", "headerSHA256"), ("module.modulemap", "moduleMapSHA256")]:
        if digest(source / "include" / name) != pin[key]:
            raise RuntimeError(f"Pinned {name} checksum mismatch.")
    if lock["patches"]:
        raise RuntimeError("This build recipe supports unchanged upstream source only.")
    metadata = (source / "build.zig.zon").read_text()
    for field, expected in [("version", pin["version"]), ("minimum_zig_version", lock["zig"]["version"])]:
        match = re.search(r"\." + field + r'\s*=\s*"([^"]+)"', metadata)
        if not match or match.group(1) != expected:
            raise RuntimeError(f"Pinned source {field} does not match the lock.")
    return source


def validate_framework(framework, source, architectures):
    info = plistlib.loads((framework / "Info.plist").read_bytes())
    slices = info["AvailableLibraries"]
    if len(slices) != 1 or slices[0]["SupportedPlatform"] != "macos":
        raise RuntimeError("Expected exactly one macOS framework slice.")
    entry = slices[0]
    if set(entry["SupportedArchitectures"]) != set(architectures):
        raise RuntimeError("Built framework architecture metadata differs from the requested target.")
    directory = framework / entry["LibraryIdentifier"]
    actual = run(["lipo", "-archs", directory / entry["LibraryPath"]], capture=True).split()
    if set(actual) != set(architectures):
        raise RuntimeError("Static archive architecture differs from its metadata.")
    for name in ["ghostty.h", "module.modulemap"]:
        if digest(directory / entry["HeadersPath"] / name) != digest(source / "include" / name):
            raise RuntimeError("Framework headers differ from the compiled source.")


def stage_notices(source, directory):
    notices = directory / "Notices"
    notices.mkdir()
    shutil.copy2(source / "LICENSE", notices / "Ghostty-MIT.txt")
    # Preserve component notices alongside embedded fonts, scripts and libraries.
    # This inventory is build evidence, not a distribution-license certification.
    roots = [("ghostty", source / "vendor"), ("packages", source / "zig-pkg"),
             ("legacy-package-cache", CACHE / "zig-global-cache/p")]
    index = []
    for label, root in roots:
        if not root.exists():
            continue
        for path in sorted(root.rglob("*")):
            if path.is_file() and path.name.lower().startswith(("license", "copying", "notice")):
                relative = Path(label) / path.relative_to(root)
                destination = notices / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, destination)
                index.append({"path": str(relative), "sha256": digest(path)})
    (notices / "inventory.json").write_text(json.dumps(index, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    # 1.3.1's universal target includes iOS, outside this macOS-only recipe.
    parser.add_argument("--target", choices=["native"], default="native")
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--force", action="store_true", help="Run the source build even if staged outputs verify")
    options = parser.parse_args()
    lock = json.loads(LOCK.read_text())
    if lock["schemaVersion"] != 1:
        raise RuntimeError("Unsupported Ghostty lock schema.")
    if options.verify_only:
        manifest = verify_manifest(lock)
        if platform.machine() not in manifest["architectures"]:
            raise RuntimeError("Ghostty artifact does not contain this Mac's architecture.")
        print("Verified Octo-built Ghostty " + manifest["sourceRevision"])
        return
    architecture, xcode, sdk = toolchain(lock)
    architectures = [architecture] if options.target == "native" else ["arm64", "x86_64"]
    if not options.force:
        try:
            manifest = verify_manifest(lock, options.target)
            if manifest["xcode"] == xcode and manifest["sdkBuild"] == sdk and manifest["architectures"] == architectures:
                print("Verified cached Octo-built Ghostty.")
                return
        except (RuntimeError, KeyError, ValueError):
            pass
    CACHE.mkdir(parents=True, exist_ok=True)
    archive = lock["zig"]["archives"][architecture]
    archive_path = CACHE / archive["url"].rsplit("/", 1)[1]
    download(archive["url"], archive_path, archive["sha256"])
    compiler_dir = CACHE / archive_path.name.removesuffix(".tar.xz")
    # Extract the checksum-verified compiler for each actual rebuild, not an
    # arbitrary zig found on PATH or a previously modified compiler executable.
    run(["tar", "-xf", archive_path, "-C", CACHE])
    compiler = compiler_dir / "zig"
    if run([compiler, "version"], capture=True) != lock["zig"]["version"]:
        raise RuntimeError("Compiler version mismatch.")
    source = prepare_source(lock)
    environment = os.environ.copy()
    environment["ZIG_GLOBAL_CACHE_DIR"] = str(CACHE / "zig-global-cache")
    args = [compiler, "build", *lock["buildFlags"], "-Dxcframework-target=" + options.target]
    print("Building pinned official Ghostty (first build downloads hash-pinned source dependencies).", flush=True)
    run(args, cwd=source, env=environment)
    built_framework = source / "macos/GhosttyKit.xcframework"
    validate_framework(built_framework, source, architectures)
    with tempfile.TemporaryDirectory(prefix="stage-", dir=CACHE) as temporary:
        stage = Path(temporary)
        shutil.copytree(built_framework, stage / "GhosttyKit.xcframework")
        runtime = stage / "Runtime"
        runtime.mkdir()
        for name in ["ghostty", "terminfo"]:
            shutil.copytree(source / "zig-out/share" / name, runtime / name)
        stage_notices(source, runtime)
        manifest = {"schemaVersion": 1, "sourceRevision": lock["source"]["revision"],
                    "sourceVersion": lock["source"]["version"],
                    "lockSHA256": digest(LOCK), "scriptSHA256": digest(__file__),
                    "zigVersion": lock["zig"]["version"], "zigArchiveSHA256": archive["sha256"],
                    "xcode": xcode, "sdkBuild": sdk, "target": options.target,
                    "architectures": architectures, "flags": lock["buildFlags"], "patches": [],
                    "frameworkFiles": inventory(stage / "GhosttyKit.xcframework"),
                    "resourceFiles": inventory(runtime)}
        # Remove the stamp before replacement: interrupted staging must not be
        # mistaken for a complete build. Only our generated outputs are replaced.
        MANIFEST.unlink(missing_ok=True)
        for destination, staged in [(FRAMEWORK, stage / "GhosttyKit.xcframework"), (RESOURCES, runtime)]:
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                shutil.rmtree(destination)
            shutil.move(str(staged), str(destination))
        MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n")
    verify_manifest(lock, options.target)
    print("Built and verified " + str(FRAMEWORK))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        print("Ghostty build: " + str(error), file=sys.stderr)
        sys.exit(1)
