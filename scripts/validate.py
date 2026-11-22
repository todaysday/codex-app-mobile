#!/usr/bin/env python3
"""Portable repository checks; these do not replace Xcode compilation or device tests."""

import json
from pathlib import Path
import plistlib
import re
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_project():
    project = ROOT / "CodexAppMobile.xcodeproj"
    pbx = (project / "project.pbxproj").read_text()
    references = {}
    for match in re.finditer(r"([A-F0-9]{24})[^=\n]*=\s*\{([^{}]*\bisa\s*=\s*PBXFileReference;[^{}]*)\};", pbx):
        path = re.search(r'\bpath\s*=\s*("(?:[^"\\]|\\.)*"|[^;]+);', match[2])
        if not path:
            continue
        value = path[1].strip().strip('"')
        if not value.endswith(".swift"):
            continue
        candidates = [ROOT / value, ROOT / "CodexAppMobile" / value, ROOT / "CodexAppMobileTests" / value]
        existing = [candidate.resolve() for candidate in candidates if candidate.is_file()]
        require(len(existing) == 1, f"Missing or ambiguous Swift file reference: {value}")
        references[match[1]] = existing[0]

    build_refs = dict(re.findall(
        r"([A-F0-9]{24})[^=\n]*=\s*\{\s*isa\s*=\s*PBXBuildFile;\s*fileRef\s*=\s*([A-F0-9]{24})", pbx))
    compiled = set()
    source_phases = {}
    for phase_id, phase in re.findall(r"([A-F0-9]{24})[^=\n]*=\s*\{\s*isa\s*=\s*PBXSourcesBuildPhase;(.*?)runOnlyForDeploymentPostprocessing", pbx, re.S):
        phase_sources = set()
        for build_id in re.findall(r"[A-F0-9]{24}", phase):
            require(build_id in build_refs, f"Source phase references missing build file {build_id}")
            file_id = build_refs[build_id]
            require(file_id in references, f"Source build file references missing Swift file {file_id}")
            require(references[file_id] not in compiled, f"Duplicate source membership: {references[file_id].name}")
            compiled.add(references[file_id])
            phase_sources.add(references[file_id])
        source_phases[phase_id] = phase_sources
    actual = {path.resolve() for folder in ("CodexAppMobile", "CodexAppMobileTests") for path in (ROOT / folder).rglob("*.swift")}
    require(compiled == actual, f"Unregistered Swift files: {sorted(str(path.relative_to(ROOT)) for path in actual - compiled)}")
    for target in re.findall(r"isa\s*=\s*PBXNativeTarget;([^{}]+)\};", pbx):
        product = re.search(r'productType\s*=\s*"([^"]+)";', target)
        folder = {"com.apple.product-type.application": "CodexAppMobile",
                  "com.apple.product-type.bundle.unit-test": "CodexAppMobileTests"}.get(product[1] if product else "")
        if not folder:
            continue
        phases = re.search(r"buildPhases\s*=\s*\((.*?)\);", target, re.S)
        require(phases is not None, f"No build phases for {folder}")
        registered = set().union(*(source_phases.get(phase, set()) for phase in re.findall(r"[A-F0-9]{24}", phases[1])))
        expected = {path.resolve() for path in (ROOT / folder).rglob("*.swift")}
        require(registered == expected, f"Incorrect target membership for {folder}")

    for bundle_id in re.findall(r"PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);", pbx):
        require(not bundle_id.strip('" ').startswith(("com.example.", "com.openai.")), "Replace upstream/official Bundle IDs")
    for team in re.findall(r"DEVELOPMENT_TEAM\s*=\s*([^;]*);", pbx):
        require(not team.strip('" '), "A developer team must not be committed for unsigned builds")
    require(set(re.findall(r"IPHONEOS_DEPLOYMENT_TARGET\s*=\s*([^;]+);", pbx)) == {"18.0"}, "Keep iOS 18 deployment support")

    schemes = list((project / "xcshareddata/xcschemes").glob("*.xcscheme"))
    require(bool(schemes), "A shared Xcode scheme is required for CI")
    for path in schemes:
        scheme = ET.parse(path).getroot()
        require(bool(scheme.findall("./TestAction/Testables/TestableReference/BuildableReference")), f"No tests in {path.name}")
    resolved = json.loads((project / "project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())
    require(bool(resolved.get("pins")), "Swift packages must be pinned")
    for pin in resolved["pins"]:
        require(bool(re.fullmatch(r"[a-f0-9]{40}", pin["state"].get("revision", ""))), f"Unpinned dependency: {pin['identity']}")
    resources = "\n".join(re.findall(r"isa\s*=\s*PBXResourcesBuildPhase;(.*?)runOnlyForDeploymentPostprocessing", pbx, re.S))
    for resource in ("Attribution", "PrivacyInfo.xcprivacy"):
        require(f"/* {resource} in Resources */" in resources, f"Resource is not bundled: {resource}")
    print(f"Project: {len(compiled)} Swift sources registered; schemes and dependency revisions valid")


def validate_plists():
    for name in ("Info.Debug.plist", "Info.Release.plist"):
        with (ROOT / "CodexAppMobile" / name).open("rb") as handle:
            info = plistlib.load(handle)
        for key in ("NSMicrophoneUsageDescription", "NSCameraUsageDescription", "NSLocalNetworkUsageDescription"):
            require(bool(info.get(key, "").strip()), f"{name}: missing {key}")
        require(info.get("CFBundleDisplayName") != "shot star", f"{name}: replace upstream display name")
        if name == "Info.Release.plist":
            ats = info.get("NSAppTransportSecurity", {})
            for key in ("NSAllowsArbitraryLoads", "NSAllowsArbitraryLoadsInWebContent", "NSAllowsArbitraryLoadsForMedia"):
                require(ats.get(key) is not True, f"Release must not disable ATS using {key}")
    with (ROOT / "CodexAppMobile/PrivacyInfo.xcprivacy").open("rb") as handle:
        privacy = plistlib.load(handle)
    accessed = privacy.get("NSPrivacyAccessedAPITypes", [])
    require(any(entry.get("NSPrivacyAccessedAPIType") == "NSPrivacyAccessedAPICategoryUserDefaults"
                and "CA92.1" in entry.get("NSPrivacyAccessedAPITypeReasons", []) for entry in accessed),
            "Declare app-local UserDefaults usage in the privacy manifest")
    print("Plists: privacy prompts, app-local defaults declaration, and release ATS enabled")


def validate_specs():
    folder = ROOT / "openspec"
    require((folder / "project.md").is_file(), "Missing openspec/project.md")
    changes = [path for path in (folder / "changes").iterdir() if path.is_dir() and path.name != "archive"]
    require(bool(changes), "At least one OpenSpec change is required")
    count = 0
    for change in changes:
        for name in ("proposal.md", "tasks.md"):
            require((change / name).is_file(), f"Missing {change.name}/{name}")
        specs = list((change / "specs").rglob("*.md"))
        require(bool(specs), f"No capability specs in {change.name}")
        for spec in specs:
            text = spec.read_text()
            require(bool(re.search(r"^## (ADDED|MODIFIED|REMOVED) Requirements", text, re.M)), f"Missing delta operation: {spec}")
            requirements = re.split(r"^### Requirement: ", text, flags=re.M)[1:]
            require(bool(requirements), f"No requirements: {spec}")
            for requirement in requirements:
                title = requirement.splitlines()[0]
                require("SHALL" in requirement, f"{spec.name}/{title}: missing SHALL")
                require("#### Scenario:" in requirement, f"{spec.name}/{title}: missing scenario")
                count += 1
    print(f"OpenSpec: {len(changes)} change(s), {count} requirements with scenarios")


def validate_workflow():
    path = ROOT / ".github/workflows/ios-unsigned-ipa.yml"
    text = path.read_text()
    # YAML parsing is optional locally; Actions parses it again on the server.
    try:
        import yaml
    except ImportError:
        print("Workflow: PyYAML unavailable; server-side Actions syntax check still required")
    else:
        workflow = yaml.load(text, Loader=yaml.BaseLoader)
        require("workflow_dispatch" in workflow["on"], "Manual build trigger missing")
        require("main" in workflow["on"]["push"]["branches"], "Main-branch build trigger missing")
        require(workflow["permissions"] == {"contents": "read"}, "Build workflow needs read-only permissions")
        require(workflow["jobs"]["build"]["runs-on"] == "macos-15", "Expected inspected macOS runner")
        print("Workflow: YAML parsed, push/manual triggers and read-only permissions valid")


def main():
    validate_project()
    validate_plists()
    validate_specs()
    validate_workflow()
    for name in ("LICENSE", "THIRD_PARTY_LICENSES.md"):
        require((ROOT / name).is_file(), f"Missing {name}")
    attribution = ROOT / "CodexAppMobile/Resources/Attribution/Project"
    for source, resource in (("LICENSE", "CodexAppMobile-MIT.txt"),
                             ("docs/licenses/ChatGPT-WebView-MIT.txt", "ChatGPT-WebView-MIT.txt"),
                             ("docs/licenses/OpenAI-Codex-APACHE-2.0.txt", "OpenAI-Codex-APACHE-2.0.txt"),
                             ("docs/licenses/OpenAI-Codex-NOTICE.txt", "OpenAI-Codex-NOTICE.txt"),
                             ("THIRD_PARTY_LICENSES.md", "THIRD_PARTY_LICENSES.md")):
        require((attribution / resource).read_bytes() == (ROOT / source).read_bytes(),
                f"Bundled attribution differs from source: {resource}")
    print("Repository validation passed (not a Swift compile or real-device test)")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, ET.ParseError) as error:
        print(f"validation failed: {error}", file=sys.stderr)
        sys.exit(1)
