"""Find an installed iPhone simulator compatible with the Patchbridge scheme."""
import json
import re
import subprocess
import sys


def select_destination(inventory, destinations):
    phone_types = {
        item["identifier"] for item in inventory["devicetypes"]
        if item.get("productFamily") == "iPhone"
    }
    compatible = {}
    for line in destinations.splitlines():
        if "Ineligible destinations" in line or "Destinations incompatible" in line:
            break
        if "platform:iOS Simulator," not in line or "error:" in line:
            continue
        match = re.search(r"\bid:([0-9A-Fa-f-]{36}), OS:([0-9.]+)", line)
        if match:
            compatible[match[1]] = tuple(map(int, match[2].split(".")))
    candidates = [
        device for devices in inventory["devices"].values() for device in devices
        if device.get("isAvailable")
        and device.get("deviceTypeIdentifier") in phone_types
        and device["udid"] in compatible
    ]
    if not candidates:
        raise ValueError(
            "No available iPhone simulator is compatible with Patchbridge. "
            "Install an iOS simulator in Xcode or set TEST_DESTINATION."
        )
    device = max(candidates, key=lambda d: (
        "patchbridge" in d["name"].lower(),
        compatible[d["udid"]],
        d["name"],
        d["udid"],
    ))
    return device


def main():
    inventory = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "--json"], text=True,
    ))
    destinations = subprocess.check_output([
        "xcodebuild", "-showdestinations",
        "-project", "ios/Patchbridge.xcodeproj", "-scheme", "Patchbridge",
    ], text=True)
    device = select_destination(inventory, destinations)
    print(f'Selected simulator: {device["name"]} ({device["udid"]})', file=sys.stderr)
    print(f'platform=iOS Simulator,id={device["udid"]}')


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(f"Simulator selection failed: {error}")
