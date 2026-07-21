#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
module_cache="$project_dir/build/TestModuleCache"
test_binary="$project_dir/build/ClaudeUsageMicroTests"
fake_claude_binary="$project_dir/build/FakeClaude"
test_arch=$(uname -m)
core_sources=("$project_dir"/Sources/Core/*.swift(N))
support_sources=("$project_dir"/Sources/App/ClaudeUsageClient.swift)
test_sources=("$project_dir"/Tests/*.swift(N))

if (( ${#core_sources} == 0 || ${#test_sources} == 0 )); then
  echo "Test sources are incomplete" >&2
  exit 1
fi

xcrun swift-format lint --strict --recursive "$project_dir/Sources" "$project_dir/Tests"

mkdir -p "$module_cache"
xcrun clang \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -mmacosx-version-min=13.0 \
  "$project_dir/Tests/Fixtures/FakeClaude.c" \
  -o "$fake_claude_binary"

xcrun swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target "$test_arch-apple-macosx13.0" \
  -module-cache-path "$module_cache" \
  "${core_sources[@]}" \
  "${support_sources[@]}" \
  "${test_sources[@]}" \
  -o "$test_binary"

CLAUDE_USAGE_FAKE_EXECUTABLE="$fake_claude_binary" "$test_binary"

set +e
helper_output=$(/usr/bin/expect "$project_dir/Scripts/claude-usage.exp" 2>&1)
helper_exit=$?
set -e

if [[ $helper_exit -ne 64 ]] || [[ $helper_output != "Usage: claude-usage.exp /path/to/claude ?child-pid-file?" ]]; then
  echo "Expect helper argument validation failed" >&2
  exit 1
fi
