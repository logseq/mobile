#!/usr/bin/env python3
"""Bundle the graph icon sets used by master, without a runtime web dependency.

Usage: import-node-icons.py LOGSEQ_MASTER_DIR TABLER_WEBFONT_TGZ
Create the archive with npm pack @tabler/icons-webfont@3.44.0.
Master supplies @tabler/icons@3.44.0 and @emoji-mart/data@1.2.1.
"""

import json
from pathlib import Path
import re
import struct
import sys
import tarfile


def distinct_font_name(data, family):
    """Give the filled face its own family; upstream ships both as tabler-icons."""
    count = struct.unpack_from(">H", data, 4)[0]
    tables = {}
    for index in range(count):
        tag, _, offset, size = struct.unpack_from(">4sIII", data, 12 + 16 * index)
        tables[tag] = data[offset:offset + size]
    names = tables[b"name"]
    _, count, offset = struct.unpack_from(">HHH", names)
    records, strings = bytearray(), bytearray()
    for index in range(count):
        platform, encoding, language, name_id, length, start = struct.unpack_from(">HHHHHH", names, 6 + 12 * index)
        value = names[offset + start:offset + start + length]
        if name_id in (1, 3, 4, 6, 16):
            value = family.encode("utf-16-be" if platform in (0, 3) else "ascii")
        records.extend(struct.pack(">HHHHHH", platform, encoding, language, name_id, len(value), len(strings)))
        strings.extend(value)
    tables[b"name"] = struct.pack(">HHH", 0, count, 6 + len(records)) + records + strings
    tables[b"head"] = tables[b"head"][:8] + b"\0" * 4 + tables[b"head"][12:]

    def padded(value):
        return value + b"\0" * (-len(value) % 4)

    def checksum(value):
        value = padded(value)
        return sum(struct.unpack(">" + "I" * (len(value) // 4), value)) & 0xffffffff

    result = bytearray(data[:12] + b"\0" * (16 * len(tables)))
    head_offset = 0
    for index, (tag, value) in enumerate(sorted(tables.items())):
        start = len(result)
        struct.pack_into(">4sIII", result, 12 + 16 * index, tag, checksum(value), start, len(value))
        result.extend(padded(value))
        if tag == b"head":
            head_offset = start
    struct.pack_into(">I", result, head_offset + 8, (0xb1b0afba - checksum(result)) & 0xffffffff)
    return bytes(result)

master, archive = map(Path, sys.argv[1:])
root = Path(__file__).resolve().parent.parent
tabler = json.loads((master / "node_modules/@tabler/icons/icons.json").read_text())
emoji = json.loads((master / "node_modules/@emoji-mart/data/sets/15/native.json").read_text())
glyphs = {}
for name, metadata in tabler.items():
    for style, glyph in metadata["styles"].items():
        key = re.sub("[^a-z0-9]", "", name.lower()) + ("filled" if style == "filled" else "")
        glyphs[key] = [int(glyph["unicode"], 16), style == "filled"]
emojis = {key: [skin["native"] for skin in value["skins"]] for key, value in emoji["emojis"].items()}
for alias, key in emoji["aliases"].items():
    if key in emojis:
        emojis[alias] = emojis[key]
data = json.dumps({"tabler": glyphs, "emoji": emojis}, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
with tarfile.open(archive) as package:
    files = {name: package.extractfile("package/dist/fonts/" + name).read()
             for name in ["tabler-icons.ttf", "tabler-icons-filled.ttf"]}
    files["Tabler-LICENSE.txt"] = package.extractfile("package/LICENSE").read()
files["tabler-icons-filled.ttf"] = distinct_font_name(files["tabler-icons-filled.ttf"], "tabler-icons-filled")
files["node-icons.json"] = data.encode()
files["Emoji-Mart-LICENSE.txt"] = (master / "node_modules/@emoji-mart/data/LICENSE").read_bytes()
for destination in [root / "apple/Sources/Logseq/Resources/NodeIcons", root / "android/app/src/main/assets/node-icons"]:
    destination.mkdir(parents=True, exist_ok=True)
    for name, content in files.items():
        (destination / name).write_bytes(content)
print(f"Bundled {len(glyphs)} Tabler glyphs and {len(emojis)} emoji names for iOS and Android")
