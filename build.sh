#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
app_name="Claude Usage Micro"
app_dir="$project_dir/build/$app_name.app"
temporary_root=${TMPDIR:-/private/tmp}
staging_root=$(mktemp -d "${temporary_root%/}/claude-usage-micro-build.XXXXXX")
staging_app="$staging_root/$app_name.app"
contents_dir="$staging_app/Contents"
binary_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
module_cache="$project_dir/build/ModuleCache"
source_files=("$project_dir"/Sources/*.swift(N))
preserve_staging=0

cleanup_staging() {
  if (( preserve_staging == 0 )); then
    rm -rf "$staging_root"
  fi
}

remove_output_bundle() {
  if [[ -L "$app_dir" || -f "$app_dir" ]]; then
    rm -f "$app_dir"
  elif [[ -d "$app_dir" ]]; then
    rm -rf "$app_dir"
  fi
}

install_in_place() {
  remove_output_bundle
  ditto --noextattr --noqtn "$staging_app" "$app_dir" || return 1
  xattr -cr "$app_dir" || return 1
  codesign --verify --deep --strict "$app_dir" >/dev/null 2>&1 || return 1
  # In iCloud-synced directories, fileproviderd re-adds xattrs moments after the copy,
  # breaking the ad-hoc signature; wait it out and verify a second time.
  sleep 2
  codesign --verify --deep --strict "$app_dir" >/dev/null 2>&1
}

chmod 700 "$staging_root"
trap cleanup_staging EXIT

if (( ${#source_files} == 0 )); then
  echo "No Swift sources found" >&2
  exit 1
fi

mkdir -p "$binary_dir" "$resources_dir" "$module_cache"

swiftc \
  -O \
  -whole-module-optimization \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$module_cache" \
  -framework AppKit \
  -framework Foundation \
  "${source_files[@]}" \
  -o "$binary_dir/ClaudeUsageMicro"

plutil -lint "$project_dir/Info.plist" >/dev/null
cp "$project_dir/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Scripts/claude-usage.exp" "$resources_dir/claude-usage.exp"
chmod +x "$resources_dir/claude-usage.exp"

xattr -cr "$staging_app"
codesign --force --sign - "$staging_app"
codesign --verify --deep --strict "$staging_app"

# When File Provider keeps corrupting the copied bundle, fall back to a symlink into
# the staging directory so a verified, signed build is still available to launch.
if ! install_in_place; then
  remove_output_bundle
  preserve_staging=1
  if ! ln -s "$staging_app" "$app_dir"; then
    preserve_staging=0
    exit 1
  fi
  if ! codesign --verify --deep --strict "$app_dir"; then
    rm -f "$app_dir"
    preserve_staging=0
    exit 1
  fi
  print -u2 -- "File Provider modified the copied bundle; using the signed external build."
fi

echo "$app_dir"
