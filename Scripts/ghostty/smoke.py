#!/usr/bin/env python3
"""Compile and run an isolated native terminal; requires a logged-in macOS desktop."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--background", action="store_true", help="Do not activate the test window; skip native keyboard-focus checks")
options = parser.parse_args()
subprocess.run([ROOT / "Scripts/build-ghostty.sh"], check=True)
framework = ROOT / ".build/ghostty/GhosttyKit.xcframework"
entry = plistlib.loads((framework / "Info.plist").read_bytes())["AvailableLibraries"][0]
library = framework / entry["LibraryIdentifier"]
executable = ROOT / ".build/ghostty/OctoGhosttySmoke"
subprocess.run(["swiftc", "-swift-version", "5", "-I", str(library / entry["HeadersPath"]),
                *map(str, sorted((ROOT / "Sources/OctoGhostty").glob("*.swift"))),
                str(ROOT / "Scripts/ghostty/SmokeMain.swift"), str(library / entry["LibraryPath"]),
                "-framework", "AppKit", "-framework", "Carbon", "-framework", "Metal",
                "-framework", "QuartzCore", "-framework", "IOSurface", "-framework", "CoreText",
                "-lc++", "-o", str(executable)], check=True)
with tempfile.TemporaryDirectory(prefix="octo-ghostty-smoke-") as folder:
    result = Path(folder) / "result.json"
    env = dict(os.environ, OCTO_GHOSTTY_RESOURCES=str(ROOT / "Sources/OctoGhostty/Resources/Runtime"),
               OCTO_GHOSTTY_EXPECTED_VERSION=json.loads((ROOT / "Vendor/Ghostty.lock.json").read_text())["source"]["version"],
               OCTO_GHOSTTY_SMOKE_BACKGROUND="1" if options.background else "0",
               OCTO_GHOSTTY_SMOKE_RESULT=str(result))
    subprocess.run([executable], env=env, timeout=90, check=True)
    outcome = json.loads(result.read_text())
    evidence = ROOT / ".build/ghostty/native-smoke.json"
    evidence.write_text(json.dumps(outcome, indent=2) + "\n")
    if not outcome["success"]:
        raise SystemExit(outcome["error"])
    print("Native smoke passed; " + str(evidence))
