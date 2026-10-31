"""Bundle CodeMirror's DOM-free tokenizer and lazily loaded language modes."""
from pathlib import Path
import json
import posixpath
import re


def bundle_syntax(source, output):
    files = {member.name.removeprefix("package/"): source.extractfile(member).read().decode()
             for member in source.getmembers() if member.isfile() and member.name.endswith(".js")}
    # The Node entry aliases the browser editor through require.cache. Our
    # CommonJS loader aliases it directly and never includes the browser editor.
    core = files["addon/runmode/runmode.node.js"]
    core = re.sub(r"^require\.cache\[.*$", "", core, flags=re.MULTILINE)
    core = core.replace('require("../../lib/codemirror")', "exports")
    files["lib/codemirror.js"] = core
    modules, identifiers = [], {}
    requires = re.compile(r"""require\(["']([^"']+)["']\)""")

    def include(path):
        if path in identifiers:
            return identifiers[path]
        identifier = identifiers[path] = len(modules)
        modules.append("")

        def dependency(match):
            base = posixpath.normpath(posixpath.join(posixpath.dirname(path), match[1]))
            resolved = next((name for name in [base, base + ".js"] if name in files), None)
            if resolved is None:
                raise RuntimeError("Missing CodeMirror module: " + base)
            if resolved in ("addon/runmode/runmode.js", "addon/runmode/runmode.node.js"):
                resolved = "lib/codemirror.js"
            return "load(" + str(include(resolved)) + ")"

        modules[identifier] = "function(module,exports){\n" + requires.sub(dependency, files[path]) + "\n}"
        return identifier

    entry = include("lib/codemirror.js")
    metadata = include("mode/meta.js")
    modes = {path.split("/")[1]: include(path) for path in sorted(files)
             if re.fullmatch(r"mode/([^/]+)/\1\.js", path)}
    license_member = source.getmember("package/LICENSE")
    license_text = source.extractfile(license_member).read().decode()
    bundle = "/*\n" + license_text + "\n*/\n(function(){const modules=[" + ",\n".join(modules) + "],cache={};\n"
    bundle += "function load(id){if(cache[id])return cache[id].exports;const m=cache[id]={exports:{}};modules[id](m,m.exports);return m.exports;}\n"
    bundle += "const CodeMirror=load(" + str(entry) + ");load(" + str(metadata) + ");\n"
    bundle += "const modes=" + json.dumps(modes, separators=(",", ":")) + ";\n"
    bundle += Path(__file__).with_name("syntax.js").read_text() + "\n})();\n"
    data = bundle.encode()
    header = "/* Generated from checksum-pinned CodeMirror 5 (MIT); loaded only for visible code. */\n"
    header += "static const unsigned char logseq_codemirror_bundle[] = {\n"
    header += ",\n".join(",".join(str(byte) for byte in data[index:index + 32]) for index in range(0, len(data), 32))
    header += ",0};\n"
    (output / "codemirror_bundle.h").write_text(header)
