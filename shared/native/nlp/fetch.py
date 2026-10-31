"""Fetch checksum-pinned build dependencies and bundle Chrono's English parser."""
import hashlib
import io
import json
import os
from pathlib import Path
import posixpath
import re
import sys
import tarfile
import tempfile
import urllib.request


def archive(spec):
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "logseq/native-dependencies"
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / spec["sha256"]
    data = target.read_bytes() if target.exists() else urllib.request.urlopen(spec["url"], timeout=60).read()
    if hashlib.sha256(data).hexdigest() != spec["sha256"]:
        raise RuntimeError("Dependency checksum mismatch: " + spec["url"])
    if not target.exists():
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as output:
            output.write(data)
            temporary = Path(output.name)
        temporary.replace(target)
    return tarfile.open(fileobj=io.BytesIO(data), mode="r:*")


def main():
    lock = json.loads(Path(sys.argv[1]).read_text())
    output = Path(sys.argv[2])
    output.mkdir(parents=True, exist_ok=True)
    with archive(lock["quickjs"]) as source:
        names = ["quickjs.c", "quickjs.h", "quickjs-atom.h", "quickjs-opcode.h",
                 "cutils.c", "cutils.h", "dtoa.c", "dtoa.h", "list.h", "libregexp.c",
                 "libregexp.h", "libregexp-opcode.h", "libunicode.c", "libunicode.h", "libunicode-table.h"]
        members = {Path(member.name).name: member for member in source.getmembers() if member.isfile()}
        for name in names:
            (output / name).write_bytes(source.extractfile(members[name]).read())
    with archive(lock["chrono-node"]) as source:
        files = {member.name.removeprefix("package/"): source.extractfile(member).read().decode()
                 for member in source.getmembers() if member.isfile() and member.name.endswith(".js")}
    modules, identifiers = [], {}
    requires = re.compile(r"""require\(["']([^"']+)["']\)""")

    def include(path):
        if path in identifiers:
            return identifiers[path]
        identifier = identifiers[path] = len(modules)
        modules.append("")

        def dependency(match):
            request = match[1]
            if not request.startswith("."):
                raise RuntimeError("Unexpected external JavaScript dependency: " + request)
            base = posixpath.normpath(posixpath.join(posixpath.dirname(path), request))
            resolved = next((name for name in [base, base + ".js", base + "/index.js"] if name in files), None)
            if resolved is None:
                raise RuntimeError("Missing JavaScript module: " + base)
            return "load(" + str(include(resolved)) + ")"

        modules[identifier] = "function(module,exports){\n" + requires.sub(dependency, files[path]) + "\n}"
        return identifier

    entry = include("dist/cjs/locales/en/index.js")
    bundle = "(function(){const modules=[" + ",\n".join(modules) + "],cache={};\n"
    bundle += "function load(id){if(cache[id])return cache[id].exports;const m=cache[id]={exports:{}};modules[id](m,m.exports);return m.exports;}\n"
    bundle += "const chrono=load(" + str(entry) + ");\n"
    bundle += """globalThis.logseqParseDate=function(text,now){
const result=chrono.parse(text,new Date(now))[0];
if(!result)return null;
const start=result.start;
return JSON.stringify({day:start.get("year")*10000+start.get("month")*100+start.get("day"),
timestamp:start.date().getTime()});
};})();\n"""
    data = bundle.encode()
    header = "/* Generated from checksum-pinned chrono-node; never evaluated during app startup. */\n"
    header += "static const unsigned char logseq_chrono_bundle[] = {\n"
    header += ",\n".join(",".join(str(byte) for byte in data[index:index + 32]) for index in range(0, len(data), 32))
    header += ",0};\n"
    (output / "chrono_bundle.h").write_text(header)


if __name__ == "__main__":
    main()
