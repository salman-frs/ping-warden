#!/usr/bin/env python3
"""Prepare a separate Control Center test app. Never edits shipping sources.

Build and sign the resulting project using the normal local tools. This command
does not install, launch, register a helper, or change a network interface.
The fixture's helper still controls the real awdl0 interface when enabled.
"""
import argparse
from pathlib import Path
import shutil


OLD_ID = "com.salmanfrs.pingwarden"
NEW_ID = "com.salmanfrs.pingwarden92test"
NAME = "Ping Warden 92 Test"


def prepare(destination):
    repo = Path(__file__).resolve().parents[1]
    destination = destination.resolve()
    if destination == repo or repo in destination.parents:
        raise ValueError("Fixture must be outside the production checkout")
    destination.mkdir(parents=True, exist_ok=False)
    project = destination / "PingWarden"
    shutil.copytree(repo / "PingWarden", project, ignore=shutil.ignore_patterns(
        "build", "DerivedData", "xcuserdata", "*.dmg", "*.zip"))
    scripts = destination / "scripts"
    scripts.mkdir()
    shutil.copy2(repo / "scripts/release_validation.sh", scripts)

    # Include product-name storage paths, launchd filenames, signature
    # requirements, notifications, App Groups, and the helper's crash marker.
    for path in destination.rglob("*"):
        if path.is_file() and path.suffix in {
            ".swift", ".m", ".h", ".plist", ".entitlements", ".pbxproj", ".sh", ".xcscheme"
        }:
            text = path.read_text()
            path.write_text(text.replace(OLD_ID, NEW_ID).replace("Ping Warden", NAME)
                            .replace("PingWarden-Diagnostics-", "PingWarden92Test-Diagnostics-"))
    for path in list(destination.rglob(OLD_ID + "*.plist")):
        path.rename(path.with_name(path.name.replace(OLD_ID, NEW_ID)))

    # The public widget title must be distinguishable in the Control Gallery.
    widget = project / "PingWardenWidget/PingWardenWidget.swift"
    widget.write_text(widget.read_text().replace('"Ping Protection"', '"Ping Protection 92 Test"'))

    print(project / "PingWarden.xcodeproj")
    print(f"App: {NAME}; bundle: {NEW_ID}; group: PV3W52NDZ3.{NEW_ID}")
    print("Before first launch, confirm the fixture has no saved protection intent.")
    print("The real AWDL interface is NOT isolated. Only enable protection during an approved test.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, help="New scratch directory, outside this checkout")
    arguments = parser.parse_args()
    prepare(arguments.destination)
