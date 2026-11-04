#!/usr/bin/env python3
"""Reject APK/AAB native libraries that cannot load on 16 KB Android devices."""

import argparse
import struct
import zipfile


def verify(archive_path):
    libraries = 0
    failures = []
    with zipfile.ZipFile(archive_path) as archive:
        for member in archive.namelist():
            if not member.endswith(".so"):
                continue
            libraries += 1
            data = archive.read(member)
            # The supported arm64-v8a and x86_64 ABIs both use little-endian ELF64.
            if data[:6] != b"\x7fELF\x02\x01":
                failures.append(f"{member}: expected little-endian ELF64")
                continue
            table = struct.unpack_from("<Q", data, 32)[0]
            entry_size, count = struct.unpack_from("<HH", data, 54)
            alignments = []
            for index in range(count):
                entry = table + index * entry_size
                if struct.unpack_from("<I", data, entry)[0] != 1:  # PT_LOAD
                    continue
                offset, address = struct.unpack_from("<QQ", data, entry + 8)
                alignment = struct.unpack_from("<Q", data, entry + 48)[0]
                alignments.append(alignment)
                if alignment < 16384 or (offset - address) % 16384:
                    failures.append(f"{member}: LOAD segment is not 16 KB aligned (alignment={alignment})")
            if not alignments:
                failures.append(f"{member}: no LOAD segments")
            else:
                print(f"{member}: minimum LOAD alignment {min(alignments)} bytes")
    if not libraries:
        failures.append("Release archive contains no native libraries")
    if failures:
        raise SystemExit("\n".join(failures))
    print(f"Verified {libraries} native libraries for 16 KB page alignment.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", help="Signed release AAB or APK")
    verify(parser.parse_args().archive)
