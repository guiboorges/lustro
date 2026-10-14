#!/bin/zsh
# Lists text in the code that has no translation yet, and translations whose text no longer exists.
# Uses the compiler's own extraction (-emit-localized-strings), so placeholders match exactly.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
swift build --scratch-path "$SCRATCH/build" -Xswiftc -emit-localized-strings \
  -Xswiftc -emit-localized-strings-path -Xswiftc "$SCRATCH/strings" >/dev/null
python3 - "$SCRATCH/build" <<'PY'
import glob, json, pathlib, sys
keys = set()
for f in glob.glob(f"{sys.argv[1]}/**/*.stringsdata", recursive=True):
    for entries in json.load(open(f)).get("tables", {}).values():
        keys.update(e["key"] for e in entries)
# Text that comes from data files rather than code.
rules = json.load(open("Sources/LustroCore/Resources/rules.json"))
for c in rules["categories"]:
    keys.update([c["title"], c["detail"], c["section"]])
for app in json.load(open("Sources/LustroCore/Resources/apps.json"))["apps"]:
    keys.add(app["why"])
keys.update(["Projects", "Looking for support files…", "Done"])
# Info.plist text (see INFO_PLIST in build-localization.py).
keys.add("Lustro asks Finder to move apps installed by the App Store to the Trash. Finder then asks for your password.")
keys.discard("")
status = 0
for source in sorted(pathlib.Path("Localization").glob("*.json")):
    table = json.loads(source.read_text(encoding="utf-8"))
    missing = sorted(keys - table.keys())
    unused = sorted(table.keys() - keys)
    print(f"{source.stem}: {len(table)} strings, {len(missing)} missing, {len(unused)} unused")
    for key in missing:
        print(f"  missing: {key!r}")
    for key in unused:
        print(f"  unused:  {key!r}")
    status |= bool(missing)
sys.exit(status)
PY
