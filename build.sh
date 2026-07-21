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
module_cache="$project_dir/build/ModuleCache"
source_files=("$project_dir"/Sources/**/*.swift(N))

trap 'rm -rf "$staging_root"' EXIT

if (( ${#source_files} == 0 )); then
  echo "No Swift sources found" >&2
  exit 1
fi

plutil -lint "$project_dir/Info.plist" >/dev/null
mkdir -p "$binary_dir" "$resources_dir" "$module_cache"

xcrun swiftc \
  -O \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target arm64-apple-macosx13.0 \
  -module-cache-path "$module_cache" \
  -framework AppKit \
  -framework Foundation \
  "${source_files[@]}" \
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
