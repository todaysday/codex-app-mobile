#!/usr/bin/env python3
"""Inspect Xcode, run simulator tests, and package a verified unsigned device build."""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "CodexAppMobile.xcodeproj"
CI = ROOT / ".build/ci"
DERIVED = ROOT / ".build/CI-DerivedData"
DISTRIBUTION = ROOT / ".build/distribution"
PROJECT_NOTICES = (
    "Attribution/Project/CodexAppMobile-MIT.txt",
    "Attribution/Project/ChatGPT-WebView-MIT.txt",
    "Attribution/Project/THIRD_PARTY_LICENSES.md",
)


def run(command, name, *, cwd=ROOT):
    """Keep complete compiler output without flooding the console with every line."""
    print(f"[{name}] {' '.join(map(str, command))}", flush=True)
    CI.mkdir(parents=True, exist_ok=True)
    stdout = CI / f"{name}.log"
    stderr = CI / f"{name}.stderr.log"
    with stdout.open("w") as out, stderr.open("w") as err:
        result = subprocess.run(command, cwd=cwd, stdout=out, stderr=err)
    if result.returncode:
        for path in (stdout, stderr):
            print("\n".join(path.read_text(errors="replace").splitlines()[-100:]), file=sys.stderr)
        raise RuntimeError(f"{name} failed ({result.returncode}); see {stdout.relative_to(ROOT)}")
    return stdout.read_text()


def select_scheme(listing):
    schemes = listing.get("project", {}).get("schemes", [])
    candidates = []
    for path in (PROJECT / "xcshareddata/xcschemes").glob("*.xcscheme"):
        scheme = ET.parse(path).getroot()
        references = scheme.findall("./BuildAction/BuildActionEntries/BuildActionEntry/BuildableReference")
        if path.stem in schemes and any(ref.get("BuildableName", "").endswith(".app") for ref in references):
            candidates.append(path.stem)
    if len(candidates) != 1:
        raise ValueError(f"Expected one shared app scheme reported by Xcode, found {candidates}")
    return candidates[0]


def app_build_settings(settings):
    apps = [entry["buildSettings"] for entry in settings
            if entry.get("buildSettings", {}).get("PRODUCT_TYPE") == "com.apple.product-type.application"]
    if len(apps) != 1:
        raise ValueError(f"Expected one application target, found {len(apps)}")
    app = apps[0]
    for key in ("TARGET_BUILD_DIR", "FULL_PRODUCT_NAME", "PRODUCT_BUNDLE_IDENTIFIER"):
        if not app.get(key):
            raise ValueError(f"Missing Xcode build setting: {key}")
    if app.get("PLATFORM_NAME") != "iphoneos" or app.get("CODE_SIGNING_ALLOWED") != "NO":
        raise ValueError("Packaging requires an unsigned iphoneos build")
    if not app["FULL_PRODUCT_NAME"].endswith(".app") or Path(app["FULL_PRODUCT_NAME"]).name != app["FULL_PRODUCT_NAME"]:
        raise ValueError("Unexpected application product name")
    if app["PRODUCT_BUNDLE_IDENTIFIER"].startswith(("com.example.", "com.openai.")):
        raise ValueError("The application needs its own Bundle ID")
    return app


def select_simulator(devices):
    """Prefer an available iOS 18 iPhone, exercising our oldest supported UI path."""
    candidates = []
    for runtime, values in devices.get("devices", {}).items():
        marker = "com.apple.CoreSimulator.SimRuntime.iOS-"
        if not runtime.startswith(marker):
            continue
        try:
            version = tuple(int(part) for part in runtime[len(marker):].split("-"))
        except ValueError:
            continue
        if version < (18,):
            continue
        for device in values:
            if device.get("isAvailable") and device.get("name", "").startswith("iPhone") and device.get("udid"):
                candidates.append((version[0] == 18, version, device["name"] == "iPhone 16", runtime, device))
    if not candidates:
        raise ValueError("No supported iPhone simulator installed. Run: make setup-ios-runtime")
    selected = max(candidates, key=lambda item: item[:3])
    return {"runtime": selected[3], "name": selected[4]["name"], "udid": selected[4]["udid"]}


def verify_app(app, settings):
    if not app.is_dir():
        raise ValueError(f"Xcode's reported app product does not exist: {app}")
    with (app / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != settings["PRODUCT_BUNDLE_IDENTIFIER"]:
        raise ValueError("Built app Bundle ID differs from inspected target settings")
    executable = info.get("CFBundleExecutable", "")
    binary = app / executable
    if (not executable or Path(executable).name != executable or not binary.is_file()
            or binary.stat().st_size == 0 or not os.access(binary, os.X_OK)):
        raise ValueError("Built application executable is missing")
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
        raise ValueError("A simulator app must never be packaged as a device IPA")
    if any(app.rglob("embedded.mobileprovision")) or any(app.rglob("_CodeSignature")):
        raise ValueError("Unexpected provisioning profile or signature in unsigned product")
    for resource in (*PROJECT_NOTICES, "PrivacyInfo.xcprivacy"):
        if not (app / resource).is_file() or (app / resource).stat().st_size == 0:
            raise ValueError(f"Required app resource is missing: {resource}")
    return info


def verify_ipa(ipa, product_name):
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        if not names or archive.testzip() is not None:
            raise ValueError("IPA archive failed integrity validation")
        prefix = f"Payload/{product_name}/"
        if f"{prefix}Info.plist" not in names or any(name != "Payload/" and not name.startswith(prefix) for name in names):
            raise ValueError("IPA must contain exactly Payload/<the inspected app>.app")
        if any(".." in Path(name).parts for name in names):
            raise ValueError("Unsafe archive member")
        info = plistlib.loads(archive.read(f"{prefix}Info.plist"))
        executable = info.get("CFBundleExecutable", "")
        if not executable or Path(executable).name != executable:
            raise ValueError("Packaged application has no valid executable name")
        binary = f"{prefix}{executable}"
        if binary not in names or archive.getinfo(binary).file_size == 0:
            raise ValueError("Packaged application executable is missing or empty")
        mode = archive.getinfo(binary).external_attr >> 16
        if not stat.S_ISREG(mode) or not mode & 0o111:
            raise ValueError("Packaged application executable lost its executable permissions")
        if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
            raise ValueError("Packaged application is not an iPhoneOS product")
        for resource in (*PROJECT_NOTICES, "PrivacyInfo.xcprivacy"):
            member = f"{prefix}{resource}"
            if member not in names or archive.getinfo(member).file_size == 0:
                raise ValueError(f"Packaged app resource is missing: {resource}")


def bundle_dependency_licenses(app, pins, checkout_root):
    """Include notices from the exact source revisions Xcode resolved, including vendored code."""
    notices = []
    for pin in pins:
        identity = pin["identity"]
        checkout = checkout_root / identity
        if not checkout.is_dir():
            raise ValueError(f"Dependency checkout missing for license collection: {identity}")
        revision = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
        if revision != pin["state"]["revision"]:
            raise ValueError(f"Dependency checkout revision differs from Package.resolved: {identity}")
        sources = [path for path in checkout.rglob("*")
                   if path.is_file() and not any(part.startswith(".") for part in path.relative_to(checkout).parts)
                   and re.fullmatch(r"(?:licen[cs]e|notice|copying)(?:\..*)?", path.name, re.I)]
        if not sources:
            raise ValueError(f"Dependency has no distributable license notice: {identity}")
        for source in sources:
            if not source.resolve().is_relative_to(checkout.resolve()):
                raise ValueError(f"License symlink escapes checkout: {identity}")
            destination = app / "Attribution/Dependencies" / identity / source.relative_to(checkout)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
            notices.append(str(destination.relative_to(app)))
    return sorted(notices)


def main():
    if sys.platform != "darwin" or not shutil.which("xcodebuild"):
        raise RuntimeError("Building iOS requires macOS with Xcode 26.2. Use the iOS unsigned IPA GitHub Actions workflow.")
    CI.mkdir(parents=True, exist_ok=True)
    xcode_version = run(["xcodebuild", "-version"], "xcode-version").strip()
    if not xcode_version.startswith("Xcode 26."):
        raise RuntimeError("Use Xcode 26 (CI pins 26.2); the existing UI requires the iOS 26 SDK.")

    package_args = ["-clonedSourcePackagesDirPath", str(ROOT / ".build/SourcePackages"),
                    "-onlyUsePackageVersionsFromResolvedFile"]
    listing = json.loads(run(["xcodebuild", "-project", str(PROJECT), "-list", "-json", *package_args], "project-list"))
    scheme = select_scheme(listing)
    common = ["xcodebuild", "-project", str(PROJECT), "-scheme", scheme,
              "-derivedDataPath", str(DERIVED), *package_args,
              "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "DEVELOPMENT_TEAM="]
    build_number = os.environ.get("GITHUB_RUN_NUMBER")
    if build_number:
        if not build_number.isdecimal():
            raise ValueError("GITHUB_RUN_NUMBER must be numeric")
        common.append(f"CURRENT_PROJECT_VERSION={build_number}")
    release = [*common, "-configuration", "Release", "-sdk", "iphoneos", "-destination", "generic/platform=iOS"]
    settings = app_build_settings(json.loads(run([*release, "-showBuildSettings", "-json"], "build-settings")))
    app = (Path(settings["TARGET_BUILD_DIR"]) / settings["FULL_PRODUCT_NAME"]).resolve()
    if not app.is_relative_to(DERIVED.resolve()):
        raise ValueError("Build product must be inside this script's derived data directory")

    simulator = select_simulator(json.loads(run(["xcrun", "simctl", "list", "devices", "available", "--json"], "simulators")))
    print(f"Testing on {simulator['name']} / {simulator['runtime']}", flush=True)
    result_bundle = CI / "Tests.xcresult"
    if result_bundle.exists():
        shutil.rmtree(result_bundle)
    run([*common, "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={simulator['udid']}",
         "-destination-timeout", "120",
         "-parallel-testing-enabled", "NO", "-resultBundlePath", str(result_bundle), "test"], "simulator-tests")
    run([*release, "build"], "device-build")
    info = verify_app(app, settings)
    signed = subprocess.run(["codesign", "-dv", str(app)], capture_output=True)
    if signed.returncode == 0:
        raise ValueError("Device app is signed; expected an unsigned artifact")
    architectures = run(["xcrun", "lipo", "-archs", str(app / info["CFBundleExecutable"])], "device-architectures").split()
    if not architectures or not set(architectures).issubset({"arm64", "arm64e"}):
        raise ValueError(f"Unexpected device executable architectures: {architectures}")

    if DISTRIBUTION.exists():
        shutil.rmtree(DISTRIBUTION)
    DISTRIBUTION.mkdir(parents=True, exist_ok=True)
    ipa = DISTRIBUTION / "CodexMobile-unsigned.ipa"
    ipa.unlink(missing_ok=True)
    dependency_pins = json.loads((PROJECT / "project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())["pins"]
    with tempfile.TemporaryDirectory(prefix="ipa-", dir=ROOT / ".build") as staging:
        payload = Path(staging) / "Payload"
        payload.mkdir()
        staged_app = payload / app.name
        shutil.copytree(app, staged_app, symlinks=True)
        notices = bundle_dependency_licenses(staged_app, dependency_pins, ROOT / ".build/SourcePackages/checkouts")
        run(["/usr/bin/zip", "-qry", str(ipa), "Payload"], "package-ipa", cwd=staging)
    verify_ipa(ipa, app.name)
    checksum = hashlib.sha256(ipa.read_bytes()).hexdigest()
    (DISTRIBUTION / "SHA256SUMS").write_text(f"{checksum}  {ipa.name}\n")
    provenance = {
        "commit": run(["git", "rev-parse", "HEAD"], "git-commit").strip(),
        "xcode": xcode_version, "scheme": scheme, "simulator": simulator,
        "bundleIdentifier": info["CFBundleIdentifier"], "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"), "minimumOSVersion": info.get("MinimumOSVersion"),
        "unsigned": True, "sha256": checksum, "architectures": architectures,
        "repository": os.environ.get("GITHUB_REPOSITORY"),
        "workflowRun": os.environ.get("GITHUB_RUN_ID"),
        "dependencies": dependency_pins, "bundledDependencyNotices": notices,
    }
    (DISTRIBUTION / "build-info.json").write_text(json.dumps(provenance, indent=2) + "\n")
    (DISTRIBUTION / "INSTALL.txt").write_text(
        "Codex Mobile — unsigned iOS application\n\n"
        "Extract the Actions artifact ZIP and save CodexMobile-unsigned.ipa to Files.\n"
        "In SideStore choose My Apps > + and install it as a standalone application.\n"
        "Do not import this app into LiveContainer. Signing is performed by your installation tool.\n"
        "Keep the same Bundle ID and signing identity for updates that preserve local data.\n"
        "See docs/DEVICE_ACCEPTANCE.md for actual iPhone login, account isolation, and refresh checks.\n"
        "Passing CI does not verify ChatGPT OAuth, Pro features, or SideStore signing on a device.\n"
    )
    print(f"Created {ipa.relative_to(ROOT)} (SHA-256 {checksum})", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError, ET.ParseError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
