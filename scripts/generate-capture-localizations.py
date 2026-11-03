#!/usr/bin/env python3
"""Keep shared controls and native recording UI on one complete translation table."""
import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "apple/Sources/Logseq/Resources/CaptureLocalizations.json"
TARGET = ROOT / "shared/src/logseq/localization.ml"
BEGIN = "(* BEGIN generated capture translations; scripts/generate-capture-localizations.py *)"
END = "(* END generated capture translations *)"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    translations = json.loads(SOURCE.read_text())
    model = (ROOT / "shared/src/logseq/model.ml").read_text()
    choices = model.split("let settings_language_choices () =", 1)[1].split("let settings_community_links", 1)[0]
    languages = {value.lower() for value in re.findall(r'id = "([^"]+)"', choices) if value != "system"}
    assert {value.lower() for value in translations} == languages, "Missing or unexpected capture languages"
    keys = set(translations["en"])
    for locale, entries in translations.items():
        assert set(entries) == keys and all(isinstance(value, str) and value.strip() for value in entries.values()), locale
    quote = lambda value: json.dumps(value, ensure_ascii=False)
    lines = [BEGIN, "let capture_dictionaries = ["]
    for locale, entries in translations.items():
        lines += [f"  ({quote(locale)}, ["]
        lines += [f"    ({quote(key)}, {quote(value)});" for key, value in entries.items()]
        lines += ["  ]);"]
    lines += ["]", "let dictionaries = capture_dictionaries @ dictionaries", END, ""]
    block = "\n".join(lines)
    current = TARGET.read_text()
    if BEGIN in current:
        before, rest = current.split(BEGIN, 1)
        _, after = rest.split(END, 1)
        updated = before + block.rstrip("\n") + after
    else:
        updated = current.replace("let resolve language system_language =", block + "\nlet resolve language system_language =", 1)
    if args.check:
        if updated != current:
            raise SystemExit("Capture translations are stale; run scripts/generate-capture-localizations.py")
    else:
        TARGET.write_text(updated)
    print(f"Verified {len(languages)} capture languages and {len(keys)} strings per language")


if __name__ == "__main__":
    main()
