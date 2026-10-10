#!/bin/zsh
# Checks that every localizable string in the code has a Japanese translation, and that the tables have no
# keys the code no longer uses.
#
# The compiler lists the strings passed to localizing APIs (Text, Button, String(localized:), ...) when
# given -emit-localized-strings. A string passed as a plain String is not localized and not listed.
set -euo pipefail
cd "$(dirname "$0")"

KEYS_DIR="$(mktemp -d)"
trap 'rm -rf "$KEYS_DIR"' EXIT

swift build -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$KEYS_DIR"

plutil -convert json -o "$KEYS_DIR/ja.json" Localizations/ja.lproj/Localizable.strings
plutil -convert json -o "$KEYS_DIR/ja-plural.json" Localizations/ja.lproj/Localizable.stringsdict
plutil -convert json -o "$KEYS_DIR/en-plural.json" Localizations/en.lproj/Localizable.stringsdict

python3 -I - "$KEYS_DIR" <<'PY'
import glob, json, re, sys

keys_dir = sys.argv[1]
paths = glob.glob(f"{keys_dir}/*.stringsdata")
if not paths:
    sys.exit("error: the build listed no strings")
code = set()
for path in paths:
    for table, entries in json.load(open(path))["tables"].items():
        if table != "Localizable":
            sys.exit(f"error: {path}: strings in table {table!r} would not be found")
        code.update(entry["key"] for entry in entries)
# Strings without letters, such as "" or "#", read the same in every language
code = {key for key in code if re.search(r"[A-Za-z]", re.sub(r"%[0-9$.#@a-z]*", "", key))}

ja_strings = set(json.load(open(f"{keys_dir}/ja.json")))
ja_plural = set(json.load(open(f"{keys_dir}/ja-plural.json")))
en_plural = set(json.load(open(f"{keys_dir}/en-plural.json")))
ja = ja_strings | ja_plural

problems = [f"missing from ja.lproj: {key!r}" for key in sorted(code - ja)]
problems += [f"unused in ja.lproj: {key!r}" for key in sorted(ja - code)]
problems += [f"unused in en.lproj: {key!r}" for key in sorted(en_plural - code)]
problems += [f"in both ja.lproj tables: {key!r}" for key in sorted(ja_strings & ja_plural)]
# A bundle may take a key from en.lproj's .stringsdict before ja.lproj's .strings, so every key with
# English plural forms needs its Japanese in ja.lproj's .stringsdict
problems += [f"missing from ja.lproj/Localizable.stringsdict: {key!r}" for key in sorted(en_plural - ja_plural)]
for problem in problems:
    print(f"error: {problem}", file=sys.stderr)
if problems:
    sys.exit(1)
print(f"{len(code)} localizable strings, all translated")
PY
