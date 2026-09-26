#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift scripts/generate-app-icon.swift
iconutil -c icns assets/AppIcon/AppIcon.iconset -o assets/AppIcon/AppIcon.icns
