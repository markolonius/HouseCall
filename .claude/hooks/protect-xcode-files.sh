#!/bin/bash
input=$(cat)
file_path=$(printf '%s' "$input" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("tool_input", {}).get("file_path", ""))')

case "$file_path" in
  *.pbxproj|*.xcscheme|*.entitlements|*.xcworkspacedata|*/xcshareddata/*|*/project.xcworkspace/*)
    echo "Blocked: $file_path is an Xcode project file. Create the Swift files on disk and tell the user which target to add them to in Xcode (or regenerate with XcodeGen)." >&2
    exit 2
    ;;
esac
exit 0
