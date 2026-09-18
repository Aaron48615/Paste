#!/usr/bin/env python3
"""Exercise real Daycast views in an isolated, never-visible AppKit host.

Requires Xcode. Builds a temporary project copy; never changes schemes, sends
system input, starts clipboard monitoring, or opens/replaces the user's app.
Pass --source-packages to reuse an existing Xcode SourcePackages checkout.
"""
import argparse
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import tempfile
import uuid


def instrument(source):
    # Geometry probes exist only in the disposable project, not the shipped app.
    head, marker, body = source.partition("struct ClipboardPreview: View")
    assert marker, "ClipboardPreview test seam changed"
    for needle, key in [
        (".padding(.horizontal, 12)", "viewport"),
        ("content(for: item)", "payload"),
        ("ClipboardInfoSection(item: item, imageURL: store.imageURL(for: item))", "info"),
    ]:
        assert needle in body, f"Missing geometry seam: {key}"
        probe = ('.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } '
                 f'action: {{ LayoutHarness.probes["{key}"] = $0 }}')
        replacement = probe + "\n" + needle if key == "viewport" else needle + "\n" + probe
        body = body.replace(needle, replacement, 1)
    return head + marker + body


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-packages", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    identity = "com.aaron.RePaste.LayoutHarness." + uuid.uuid4().hex
    env = os.environ.copy()
    if "DEVELOPER_DIR" not in env and Path("/Applications/Xcode.app").exists():
        env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    try:
        with tempfile.TemporaryDirectory(prefix="repaste-layout-") as tmp:
            root = Path(tmp)
            for name in ["Paste", "PasteCLI", "Paste.xcodeproj"]:
                shutil.copytree(repo / name, root / name, ignore=shutil.ignore_patterns("xcuserdata"))
            project = root / "Paste.xcodeproj/project.pbxproj"
            project.write_text(project.read_text()
                               .replace("com.aaron.RePaste", identity)
                               .replace("com.eli.Paste", identity))
            shutil.copyfile(repo / "PasteTests/Support/DaycastLayoutHarness.swift",
                            root / "Paste/App/PasteApp.swift")
            layout = root / "Paste/Features/RootPaletteView.swift"
            layout.write_text(layout.read_text().replace(
                "private final class DaycastSplitDividerView", "final class DaycastSplitDividerView"))
            preview = root / "Paste/Features/Clipboard/ClipboardView.swift"
            preview.write_text(instrument(preview.read_text()))
            command = ["xcodebuild", "-jobs", "2", "-project", str(root / "Paste.xcodeproj"),
                       "-scheme", "Paste", "-configuration", "Release", "-destination", "platform=macOS",
                       "-derivedDataPath", str(root / "build"), "ONLY_ACTIVE_ARCH=YES", "build"]
            if args.source_packages:
                command[1:1] = ["-clonedSourcePackagesDirPath", str(args.source_packages.resolve()),
                                "-disableAutomaticPackageResolution"]
            with (root / "build.log").open("w+") as log:
                result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT)
                if result.returncode:
                    log.seek(0)
                    print(log.read())
                    return result.returncode
            for app in (root / "build/Build/Products/Release").glob("*.app"):
                with (app / "Contents/Info.plist").open("rb") as file:
                    info = plistlib.load(file)
                if info.get("CFBundleIdentifier") == identity:
                    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
                    return subprocess.run([str(binary)], env=env, timeout=120).returncode
            raise RuntimeError("Isolated layout harness application was not built")
    finally:
        # The UUID profile is owned exclusively by this invocation.
        shutil.rmtree(Path.home() / "Library/Application Support" / identity, ignore_errors=True)
        subprocess.run(["defaults", "delete", identity], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    raise SystemExit(main())
