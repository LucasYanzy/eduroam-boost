#!/usr/bin/env python3
"""Build the iPhone/iPad Shortcut "eduroam Boost" and sign it for sharing.

    python3 ios/build_shortcut.py          # writes ios/eduroam-Boost.shortcut (signed, needs macOS 12+)

The shortcut: Wi-Fi off -> wait 3 s -> Wi-Fi on -> wait 8 s -> notification.
iOS gives apps no way to pick a band or access point, but Shortcuts can toggle
Wi-Fi, and the fresh scan after turning it back on usually picks the strongest
(often 5 GHz) access point, the same trick the macOS tool uses.
"""
import os
import plistlib
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "eduroam-Boost.shortcut")


def action(identifier, **params):
    return {"WFWorkflowActionIdentifier": identifier, "WFWorkflowActionParameters": params}


def build():
    return {
        "WFWorkflowClientVersion": "2302.0.4",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 463140863, "WFWorkflowIconGlyphNumber": 59511},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowInputContentItemClasses": [],
        "WFWorkflowTypes": [],
        "WFWorkflowHasShortcutInputVariables": False,
        "WFWorkflowActions": [
            action("is.workflow.actions.wifi.set", OnValue=False),
            action("is.workflow.actions.delay", WFDelayTime=3),
            action("is.workflow.actions.wifi.set", OnValue=True),
            action("is.workflow.actions.delay", WFDelayTime=8),
            action("is.workflow.actions.notification",
                   WFNotificationActionTitle="eduroam Boost",
                   WFNotificationActionBody="Wi-Fi reconnected / Wi-Fi 已重连"),
        ],
    }


def main():
    with tempfile.TemporaryDirectory() as tmp:
        unsigned = os.path.join(tmp, "unsigned.shortcut")
        with open(unsigned, "wb") as fh:
            plistlib.dump(build(), fh, fmt=plistlib.FMT_BINARY)
        if "--unsigned" in sys.argv:
            os.replace(unsigned, OUT)
        else:
            subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", unsigned, "--output", OUT], check=True)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
