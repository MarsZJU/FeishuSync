#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
MODULE_CACHE="${TMPDIR:-/tmp}/FeishuSync-module-cache"
mkdir -p build "$MODULE_CACHE"
/usr/bin/swiftc -swift-version 5 -module-cache-path "$MODULE_CACHE" -target arm64-apple-macosx13.0 Sources/Core.swift Tests/Tests.swift -o build/FeishuSyncTests -framework AppKit -framework PDFKit
build/FeishuSyncTests
