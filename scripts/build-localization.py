#!/usr/bin/env python3
"""Turns Localization/<language>.json into <language>.lproj/Localizable.strings inside an app's Resources folder.

Usage: scripts/build-localization.py <Resources folder>

Keys are the English text exactly as it appears in the code (with %@ / %lld placeholders), so English needs
no table: an empty en.lproj tells macOS that English is a supported language. "pt" (Apple's generic
Portuguese) gets the Brazilian table.
"""
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
out = pathlib.Path(sys.argv[1])


def escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


# Info.plist text macOS shows in its own dialogs, keyed by the English text in build-app.sh.
INFO_PLIST = {
    "NSAppleEventsUsageDescription":
        "Lustro asks Finder to move apps installed by the App Store to the Trash. Finder then asks for your password.",
}


def strings(table):
    return "\n".join(f'"{escape(k)}" = "{escape(v)}";' for k, v in sorted(table.items())) + "\n"


def write(language, table):
    folder = out / f"{language}.lproj"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "Localizable.strings").write_text(strings(table), encoding="utf-8")
    info = {key: table[text] for key, text in INFO_PLIST.items() if text in table}
    if info:
        (folder / "InfoPlist.strings").write_text(strings(info), encoding="utf-8")


write("en", {})
for source in sorted((root / "Localization").glob("*.json")):
    table = json.loads(source.read_text(encoding="utf-8"))
    write(source.stem, table)
    if source.stem == "pt-BR":
        write("pt", table)
