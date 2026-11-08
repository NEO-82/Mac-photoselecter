#!/usr/bin/env python3
"""Test packaging failure handling with fixture tools, not a macOS build.

No fake .dmg is published in the checkout: all fixtures live in TemporaryDirectory.
Run with python3 scripts/test-packaging.py on either Linux or macOS.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().with_name("package-macos.sh")
TOOL = r'''
import json, os, pathlib, plistlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
failure = os.environ.get("PACKAGE_TEST_FAILURE", "")
with open(os.environ["PACKAGE_TEST_TRACE"], "a") as trace:
    trace.write(json.dumps([name, *args]) + "\n")
if name == "uname":
    print("Darwin")
elif name == "xcrun":
    if args[0] == "--find":
        print("/fixture/" + args[1])
    elif args[:2] == ["swift", "test"]:
        if failure == "xctest": sys.exit(32)
    elif args[:2] == ["lipo", "-archs"]:
        print("x86_64" if failure == "architecture" else "arm64")
    else:
        raise RuntimeError(args)
elif name == "xcodebuild":
    if args == ["-version"]:
        print("Xcode fixture (not a real build)")
    else:
        if failure == "xcodebuild": sys.exit(33)
        assert "ARCHS=arm64" in args and "CODE_SIGNING_ALLOWED=NO" in args
        app = pathlib.Path(args[args.index("-derivedDataPath") + 1]) / "Build/Products/Release/정광이의 MAC 포토셀렉터.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        binary = app / "Contents/MacOS/PhotoSelect"
        binary.write_text("TEST FIXTURE: not a Mach-O binary\n")
        binary.chmod(0o755)
        with open(app / "Contents/Info.plist", "wb") as file:
            plistlib.dump({"CFBundleExecutable": "PhotoSelect",
                          "CFBundleName": "정광이의 MAC 포토셀렉터",
                          "CFBundleDisplayName": "정광이의 MAC 포토셀렉터",
                          "CFBundleIconFile": "AppIcon.icns"}, file)
        (app / "Contents/Resources").mkdir()
        (app / "Contents/Resources/AppIcon.icns").write_bytes(b"icnsTEST FIXTURE")
elif name == "plutil":
    with open(args[-1], "rb") as file:
        print(plistlib.load(file)[args[args.index("-extract") + 1]])
elif name == "ditto":
    shutil.copytree(args[0], args[1], symlinks=True)
elif name == "codesign":
    app = pathlib.Path(args[-1])
    signature = app / "fixture-signature"
    if "--force" in args:
        assert "-" in args
        signature.write_text("fixture signature, not a valid code signature")
    else:
        assert signature.exists()
        if failure == "mounted-signature" and app.parent.name == "mount": sys.exit(36)
elif name == "hdiutil":
    state = pathlib.Path(os.environ["PACKAGE_TEST_STATE"])
    if args[0] == "create":
        source = pathlib.Path(args[args.index("-srcfolder") + 1])
        assert (source / "설치 안내.txt").is_file()
        assert os.readlink(source / "Applications") == "/Applications"
        shutil.copytree(source, state, symlinks=True)
        pathlib.Path(args[-1]).write_bytes(b"TEST FIXTURE: not a disk image\n")
    elif args[0] == "verify":
        if failure == "image-verify": sys.exit(35)
    elif args[0] == "attach":
        mount = pathlib.Path(args[args.index("-mountpoint") + 1])
        shutil.copytree(state, mount, symlinks=True, dirs_exist_ok=True)
    elif args[0] == "detach":
        mount = pathlib.Path(args[1])
        for child in mount.iterdir():
            if child.is_dir() and not child.is_symlink(): shutil.rmtree(child)
            else: child.unlink()
    else:
        raise RuntimeError(args)
else:
    raise RuntimeError(name)
'''


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="photoselect-packaging-tests-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / "repo with spaces"
        (self.repo / "scripts").mkdir(parents=True)
        self.script = self.repo / "scripts/package-macos.sh"
        shutil.copy2(SCRIPT, self.script)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        for name in ("uname", "xcrun", "xcodebuild", "ditto", "codesign", "hdiutil", "plutil"):
            path = self.bin / name
            path.write_text(f"#!{sys.executable}\n" + TOOL)
            path.chmod(0o755)
        self.trace = self.base / "trace.jsonl"
        self.output = self.repo / "dist/PhotoSelect-0.1.0-1-arm64"

    def run_package(self, failure="", **overrides):
        env = dict(os.environ)
        env.update(PATH=str(self.bin) + os.pathsep + env["PATH"],
                   PHOTOSELECT_VERSION="0.1.0", PHOTOSELECT_BUILD_NUMBER="1",
                   PACKAGE_TEST_TRACE=str(self.trace),
                   PACKAGE_TEST_STATE=str(self.base / "image-fixture"),
                   PACKAGE_TEST_FAILURE=failure)
        env.update(overrides)
        return subprocess.run(["/bin/bash", str(self.script)], cwd=self.base, env=env,
                              text=True, capture_output=True, timeout=30)

    def events(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []

    def test_success_checks_mounted_app_and_checksum(self):
        result = self.run_package()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        dmg = self.output / "PhotoSelect-0.1.0-1-arm64.dmg"
        self.assertEqual((self.output / "SHA256SUMS").read_text().split()[0], hashlib.sha256(dmg.read_bytes()).hexdigest())
        events = self.events()
        self.assertTrue(any(e[0] == "codesign" and "--verify" in e and "/mount/정광이의 MAC 포토셀렉터.app" in e[-1] for e in events))
        self.assertEqual(len([e for e in events if e[:2] == ["hdiutil", "detach"]]), 1)
        self.assertFalse(list((self.repo / ".build").iterdir()))

    def test_xctest_failure_stops_before_app_build(self):
        result = self.run_package("xctest")
        self.assertEqual(result.returncode, 32, result.stdout + result.stderr)
        self.assertFalse(any(e[0] == "xcodebuild" and "build" in e for e in self.events()))
        self.assertFalse(self.output.exists())
        self.assertFalse(list((self.repo / ".build").iterdir()))

    def test_build_failure_stops_before_image_creation(self):
        result = self.run_package("xcodebuild")
        self.assertEqual(result.returncode, 33, result.stdout + result.stderr)
        self.assertFalse(any(e[0] == "hdiutil" for e in self.events()))
        self.assertFalse(self.output.exists())

    def test_wrong_architecture_cannot_be_packaged(self):
        result = self.run_package("architecture")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(e[0] == "hdiutil" for e in self.events()))
        self.assertFalse(self.output.exists())

    def test_corrupt_disk_image_is_not_published(self):
        result = self.run_package("image-verify")
        self.assertEqual(result.returncode, 35, result.stdout + result.stderr)
        self.assertFalse(any(e[:2] == ["hdiutil", "attach"] for e in self.events()))
        self.assertFalse(self.output.exists())

    def test_failed_mounted_signature_detaches_and_does_not_publish(self):
        result = self.run_package("mounted-signature")
        self.assertEqual(result.returncode, 36, result.stdout + result.stderr)
        self.assertTrue(any(e[:2] == ["hdiutil", "detach"] for e in self.events()))
        self.assertFalse(self.output.exists())
        self.assertFalse(list((self.repo / ".build").iterdir()))

    def test_existing_output_is_preserved(self):
        self.output.mkdir(parents=True)
        marker = self.output / "existing-user-file"
        marker.write_text("keep")
        result = self.run_package()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(marker.read_text(), "keep")
        self.assertFalse(any(e[:2] == ["xcrun", "swift"] for e in self.events()))

    def test_untrusted_version_is_rejected_before_any_build(self):
        result = self.run_package(PHOTOSELECT_VERSION="../escape;echo invalid")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.events(), [["uname", "-s"]])
        self.assertFalse((self.repo / "dist").exists())

    @unittest.skipUnless(sys.platform.startswith("linux"), "Exercises the real Linux platform guard")
    def test_real_linux_cannot_publish_an_installer(self):
        result = subprocess.run(["/bin/bash", str(self.script)], text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Linux", result.stderr)
        self.assertFalse((self.repo / "dist").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
