"""Regenerate or verify the bundled, signed "支出を検索" personal shortcuts on macOS.

python3 ci_scripts/siri_expense_shortcut.py verify
python3 ci_scripts/siri_expense_shortcut.py sign --variant development
"""

import argparse
import json
from pathlib import Path
import plistlib
import struct
import subprocess
from tempfile import TemporaryDirectory
from uuid import uuid4


ROOT = Path(__file__).resolve().parents[1]
INTENT = "SiriFindExpenseCardsIntent"
CONFIGURATIONS = {"development": "Debug", "production": "Release"}


def descriptor(variant):
    """Resolve the same target settings used by the iOS build."""
    project_file = ROOT / "Budgety.xcodeproj/project.pbxproj"
    project = json.loads(subprocess.check_output(
        ["plutil", "-convert", "json", "-o", "-", str(project_file)]))
    objects = project["objects"]
    target = next(item for item in objects.values()
                  if item["isa"] == "PBXNativeTarget" and item["name"] == "Budgety")
    settings = {}
    for owner in (objects[project["rootObject"]], target):
        configs = objects[owner["buildConfigurationList"]]["buildConfigurations"]
        config = next(objects[k] for k in configs if objects[k]["name"] == CONFIGURATIONS[variant])
        settings.update(config["buildSettings"])
    bundle = settings["PRODUCT_BUNDLE_IDENTIFIER"].replace("$(BUNDLE_ID_SUFFIX)", settings["BUNDLE_ID_SUFFIX"])
    if bundle not in ("com.tento.budgety.dev", "com.tento.budgety"):
        raise ValueError(f"Unrecognized Budgety bundle ID {bundle}")
    return {"AppIntentIdentifier": INTENT, "BundleIdentifier": bundle,
            "TeamIdentifier": settings["DEVELOPMENT_TEAM"], "Name": settings["INFOPLIST_KEY_CFBundleDisplayName"]}


def output(uuid, name):
    attachment = {"Type": "ActionOutput", "OutputUUID": uuid, "OutputName": name}
    return {"WFSerializationType": "WFTextTokenString",
            "Value": {"string": "\ufffc", "attachmentsByRange": {"{0, 1}": attachment}}}


def action(identifier, **parameters):
    return {"WFWorkflowActionIdentifier": identifier, "WFWorkflowActionParameters": parameters}


def actions(app, ask_id, lookup_id):
    return [
        action("is.workflow.actions.ask", UUID=ask_id, WFAskActionPrompt="どの支出名を検索しますか？"),
        action(app["BundleIdentifier"] + "." + INTENT, UUID=lookup_id, AppIntentDescriptor=app,
               expenseName=output(ask_id, "入力を要求")),
    ]


def sign(path, app, scratch):
    workflow = {
        "WFWorkflowName": "支出を検索",
        "WFWorkflowMinimumClientVersionString": "900", "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowClientVersion": "4018.0.4",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 946986751, "WFWorkflowIconGlyphNumber": 61446},
        "WFWorkflowTypes": [], "WFWorkflowInputContentItemClasses": [],
        "WFWorkflowActions": actions(app, str(uuid4()).upper(), str(uuid4()).upper()),
    }
    raw = scratch / "支出を検索.shortcut"
    raw.write_bytes(plistlib.dumps(workflow, fmt=plistlib.FMT_BINARY))
    subprocess.run(["shortcuts", "sign", "--mode", "anyone", "-i", str(raw), "-o", str(path)], check=True)


def verify(path, expected_app, scratch):
    archive = path.read_bytes()
    if archive[:4] != b"AEA1":
        raise ValueError(f"{path.name} is not signed")
    auth_size = struct.unpack_from("<I", archive, 8)[0]
    certificate = plistlib.loads(archive[12:12 + auth_size])["SigningCertificateChain"][0]
    public_key = scratch / "signer.pem"
    public_key.write_bytes(subprocess.run(["openssl", "x509", "-inform", "DER", "-noout", "-pubkey"],
                                          input=certificate, capture_output=True, check=True).stdout)
    verified = scratch / "verified.aar"
    subprocess.run(["aea", "decrypt", "-i", str(path), "-o", str(verified), "-sign-pub", str(public_key)], check=True)
    subprocess.run(["aa", "extract", "-i", str(verified), "-d", str(scratch)], check=True, capture_output=True)
    actual = plistlib.loads((scratch / "Shortcut.wflow").read_bytes())["WFWorkflowActions"]
    ask_id, lookup_id = (a["WFWorkflowActionParameters"]["UUID"] for a in actual[:2])
    if actual != actions(expected_app, ask_id, lookup_id):
        raise ValueError(f"Unexpected actions or bundle ID in {path.name}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("sign", "verify"))
    parser.add_argument("--variant", choices=CONFIGURATIONS)
    args = parser.parse_args()
    for variant in ([args.variant] if args.variant else CONFIGURATIONS):
        path = ROOT / "Budgety/Resources" / f"SiriExpenseSearch-{variant}.shortcut"
        app = descriptor(variant)
        with TemporaryDirectory() as tmp:
            if args.command == "sign":
                sign(path, app, Path(tmp))
            verify(path, app, Path(tmp))
        print(f"Verified {path.name} ({app['BundleIdentifier']})")
