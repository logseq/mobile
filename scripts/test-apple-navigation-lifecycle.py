#!/usr/bin/env python3
"""Render navigation lifecycle transitions without the XCTest runner or simulator."""
from pathlib import Path
import subprocess
import re

root = Path(__file__).resolve().parents[1]
manifest = (root / "apple/Package.swift").read_text()
lui_revision = re.search(r'lui\.git", revision: "([0-9a-f]+)"', manifest).group(1)
package = root / "_build/apple-navigation-lifecycle"
(package / "Sources/NavigationLifecycle").mkdir(parents=True, exist_ok=True)
(package / "Package.swift").write_text(f'''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "NavigationLifecycle",
    platforms: [.macOS(.v26)],
    dependencies: [.package(url: "ssh://git@github.com/logseq/lui.git", revision: "{lui_revision}")],
    targets: [.executableTarget(name: "NavigationLifecycle", dependencies: [
        .product(name: "LUIAppleBackendStatic", package: "lui")
    ])]
)
''')
(package / "Sources/NavigationLifecycle/main.swift").write_bytes(
    (root / "tests/apple-navigation-lifecycle/main.swift").read_bytes()
)
for filename in ["LGNavigationExtension.swift", "LGLiquidGlassTweak.swift", "LogseqThemeSettings.swift"]:
    source = (root / "apple/Sources/Logseq" / filename).read_text()
    if filename == "LGNavigationExtension.swift":
        # The search presentation uses iOS-only fullScreenCover; exercise the
        # navigation implementation unchanged on the native macOS SwiftUI host.
        start = source.index("@MainActor\nenum LGSearchPresentationExtension")
        end = source.index("@MainActor\nprivate struct LGNavigationContent")
        source = source[:start] + source[end:]
    (package / "Sources/NavigationLifecycle" / filename).write_text(source)
# Compile the production icon policy without the iOS-only application entry point.
renderer_source = (root / "apple/Sources/Logseq/LGRenderer.swift").read_text()
icon_policy = renderer_source.split("enum LGIconPolicy {", 1)[1].split("\n@MainActor", 1)[0]
(package / "Sources/NavigationLifecycle/LGIconPolicy.swift").write_text(
    "import LUIAppleBackend\n\nenum LGIconPolicy {" + icon_policy
)
scratch = root / "apple/.build/navigation-lifecycle"
subprocess.run([
    "swift", "build", "--disable-sandbox", "--package-path", str(package),
    "--scratch-path", str(scratch), "-c", "release", "--product", "NavigationLifecycle",
], check=True)
subprocess.run([str(scratch / "release/NavigationLifecycle")], check=True, timeout=45)
