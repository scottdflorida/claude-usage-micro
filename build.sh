#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
app_name="Claude Usage Micro"
app_dir="$project_dir/build/$app_name.app"
staging_root=$(mktemp -d "${TMPDIR:-/private/tmp}/claude-usage-micro-build.XXXXXX")
staging_app="$staging_root/$app_name.app"
contents_dir="$staging_app/Contents"
binary_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"

trap 'rm -rf "$staging_root"' EXIT

mkdir -p "$binary_dir" "$resources_dir" "$project_dir/build/ModuleCache"

swiftc \
  -O \
  -parse-as-library \
  -target arm64-apple-macosx13.0 \
  -module-cache-path "$project_dir/build/ModuleCache" \
  -framework AppKit \
  -framework Foundation \
  "$project_dir/Sources/ClaudeUsageMicro.swift" \
  "$project_dir/Sources/RefreshConfiguration.swift" \
  -o "$binary_dir/ClaudeUsageMicro"

cp "$project_dir/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Scripts/claude-usage.exp" "$resources_dir/claude-usage.exp"
chmod +x "$resources_dir/claude-usage.exp"

if [[ -e "$app_dir" ]]; then
  rm -rf "$app_dir"
fi
ditto --noextattr --noqtn "$staging_app" "$app_dir"
xattr -cr "$app_dir"
codesign --force --sign - "$app_dir"
xattr -d com.apple.FinderInfo "$app_dir" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$app_dir" 2>/dev/null || true
codesign --verify --deep --strict "$app_dir"

echo "$app_dir"
