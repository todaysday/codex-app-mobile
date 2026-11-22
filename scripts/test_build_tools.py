"""Tests for build-product and simulator selection; no Xcode execution is simulated."""

import copy
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest import mock
import zipfile

import build_ipa


class BuildToolTests(unittest.TestCase):
    def setUp(self):
        self.settings = [{"buildSettings": {
            "PRODUCT_TYPE": "com.apple.product-type.application",
            "TARGET_BUILD_DIR": "/example/device-products",
            "FULL_PRODUCT_NAME": "CustomName.app",
            "PRODUCT_BUNDLE_IDENTIFIER": "dev.test.codexmobile",
            "PLATFORM_NAME": "iphoneos", "CODE_SIGNING_ALLOWED": "NO",
        }}]

    def make_app(self, folder):
        app = Path(folder) / "CustomName.app"
        app.mkdir()
        info = {"CFBundleIdentifier": "dev.test.codexmobile", "CFBundleExecutable": "AppBinary",
                "CFBundleSupportedPlatforms": ["iPhoneOS"]}
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        binary = app / "AppBinary"
        binary.write_bytes(b"fixture executable; not an actual iOS build")
        binary.chmod(0o755)
        for name in build_ipa.PROJECT_NOTICES:
            resource = app / name
            resource.parent.mkdir(parents=True, exist_ok=True)
            resource.write_text("License fixture")
        (app / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps({"NSPrivacyAccessedAPITypes": []}))
        return app, info

    def make_archive(self, ipa, app):
        with zipfile.ZipFile(ipa, "w") as archive:
            for resource in app.rglob("*"):
                if resource.is_file():
                    archive.write(resource, Path("Payload") / app.name / resource.relative_to(app))

    def test_uses_xcode_product_and_rejects_wrong_platform_or_signing(self):
        self.assertEqual(build_ipa.app_build_settings(self.settings)["FULL_PRODUCT_NAME"], "CustomName.app")
        for key, value in (("PLATFORM_NAME", "iphonesimulator"), ("CODE_SIGNING_ALLOWED", "YES"),
                           ("FULL_PRODUCT_NAME", "../Wrong.app"), ("PRODUCT_BUNDLE_IDENTIFIER", "com.openai.chat")):
            settings = copy.deepcopy(self.settings)
            settings[0]["buildSettings"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                build_ipa.app_build_settings(settings)

    def test_rejects_ambiguous_app_targets(self):
        with self.assertRaises(ValueError):
            build_ipa.app_build_settings(self.settings + self.settings)

    def test_prefers_supported_ios18_iphone_and_ignores_unavailable_devices(self):
        devices = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-17-5": [{"name": "iPhone 15", "isAvailable": True, "udid": "old"}],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-6": [{"name": "iPhone 16", "isAvailable": True, "udid": "target"}],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-7": [{"name": "iPhone 16", "isAvailable": False, "udid": "missing"}],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [{"name": "iPhone 17", "isAvailable": True, "udid": "latest"}],
        }}
        self.assertEqual(build_ipa.select_simulator(devices)["udid"], "target")
        del devices["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-18-6"]
        self.assertEqual(build_ipa.select_simulator(devices)["udid"], "latest")
        with self.assertRaises(ValueError):
            build_ipa.select_simulator({"devices": {}})

    def test_checks_built_info_plist_executable_and_unsigned_bundle(self):
        with tempfile.TemporaryDirectory() as folder:
            app, info = self.make_app(folder)
            self.assertEqual(build_ipa.verify_app(app, self.settings[0]["buildSettings"]), info)
            (app / "embedded.mobileprovision").touch()
            with self.assertRaises(ValueError):
                build_ipa.verify_app(app, self.settings[0]["buildSettings"])

    def test_rejects_an_empty_executable_or_missing_license_resource(self):
        with tempfile.TemporaryDirectory() as folder:
            app, _ = self.make_app(folder)
            (app / build_ipa.PROJECT_NOTICES[0]).unlink()
            with self.assertRaisesRegex(ValueError, "Required app resource"):
                build_ipa.verify_app(app, self.settings[0]["buildSettings"])
            (app / "AppBinary").write_bytes(b"")
            with self.assertRaisesRegex(ValueError, "executable"):
                build_ipa.verify_app(app, self.settings[0]["buildSettings"])

    def test_rejects_extra_archive_payloads_and_wrong_app_name(self):
        with tempfile.TemporaryDirectory() as folder:
            ipa = Path(folder) / "app.ipa"
            app, _ = self.make_app(folder)
            self.make_archive(ipa, app)
            build_ipa.verify_ipa(ipa, "CustomName.app")
            with self.assertRaises(ValueError):
                build_ipa.verify_ipa(ipa, "GuessedName.app")
            with zipfile.ZipFile(ipa, "a") as archive:
                archive.writestr("private-key.txt", b"not an app resource")
            with self.assertRaises(ValueError):
                build_ipa.verify_ipa(ipa, "CustomName.app")

    def test_archive_verification_checks_executable_permissions_and_notices(self):
        with tempfile.TemporaryDirectory() as folder:
            ipa = Path(folder) / "app.ipa"
            app, _ = self.make_app(folder)
            (app / "AppBinary").chmod(0o644)
            self.make_archive(ipa, app)
            with self.assertRaisesRegex(ValueError, "executable permissions"):
                build_ipa.verify_ipa(ipa, app.name)
            (app / "AppBinary").chmod(0o755)
            (app / build_ipa.PROJECT_NOTICES[0]).unlink()
            self.make_archive(ipa, app)
            with self.assertRaisesRegex(ValueError, "Packaged app resource"):
                build_ipa.verify_ipa(ipa, app.name)

    def test_bundles_nested_notices_only_from_pinned_checkout(self):
        with tempfile.TemporaryDirectory() as folder:
            checkout_root = Path(folder) / "checkouts"
            checkout = checkout_root / "example"
            (checkout / "Sources/Vendor").mkdir(parents=True)
            (checkout / "LICENSE.txt").write_text("Main license")
            (checkout / "Sources/Vendor/NOTICE").write_text("Vendored notice")
            (checkout / "Sources/not-a-license.swift").write_text("not a notice")
            pins = [{"identity": "example", "state": {"revision": "a" * 40}}]
            app = Path(folder) / "App.app"
            with mock.patch("build_ipa.subprocess.check_output", return_value="a" * 40 + "\n"):
                notices = build_ipa.bundle_dependency_licenses(app, pins, checkout_root)
                self.assertEqual(len(notices), 2)
                self.assertEqual((app / "Attribution/Dependencies/example/Sources/Vendor/NOTICE").read_text(), "Vendored notice")
            with mock.patch("build_ipa.subprocess.check_output", return_value="b" * 40 + "\n"):
                with self.assertRaises(ValueError):
                    build_ipa.bundle_dependency_licenses(app, pins, checkout_root)


if __name__ == "__main__":
    unittest.main()
