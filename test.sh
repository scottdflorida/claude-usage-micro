#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
module_cache="$project_dir/build/StrictModuleCache"
test_binary="$project_dir/build/ClaudeUsageMicroTests"
fake_claude_binary="$project_dir/build/FakeClaude"
fake_claude_trust_binary="$project_dir/build/FakeClaudeTrust"
fake_claude_usage_binary="$project_dir/build/FakeClaudeUsage"
orphaning_helper_binary="$project_dir/build/OrphaningHelper"
source_files=("$project_dir"/Sources/*.swift(N))
# The test binary excludes ClaudeUsageMicro.swift (conflicting @main) and AppDelegate.swift (app-lifecycle glue).
test_sources=(${source_files:#*/ClaudeUsageMicro.swift})
test_sources=(${test_sources:#*/AppDelegate.swift})
test_files=("$project_dir"/Tests/*.swift(N))

for script in "$project_dir/build.sh" "$project_dir/install.sh" "$project_dir/package-release.sh"; do
  zsh -n "$script"
done

if (( ${#source_files} == 0 || ${#test_files} == 0 )); then
  echo "Test sources are incomplete" >&2
  exit 1
fi

xcrun swift-format lint \
  --strict \
  --recursive \
  --configuration "$project_dir/.swift-format" \
  "$project_dir/Sources" "$project_dir/Tests"

mkdir -p "$module_cache"

swiftc \
  -typecheck \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$module_cache" \
  -framework AppKit \
  -framework Foundation \
  "${source_files[@]}"

for fixture_source in "$project_dir"/Tests/Fixtures/*.c(N); do
  xcrun clang \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -mmacosx-version-min=13.0 \
    "$fixture_source" \
    -o "$project_dir/build/${fixture_source:t:r}"
done

swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$module_cache" \
  -framework AppKit \
  -framework Foundation \
  "${test_sources[@]}" \
  "${test_files[@]}" \
  -o "$test_binary"

CLAUDE_USAGE_FAKE_EXECUTABLE="$fake_claude_binary" \
  CLAUDE_USAGE_FAKE_TRUST_EXECUTABLE="$fake_claude_trust_binary" \
  CLAUDE_USAGE_FAKE_USAGE_EXECUTABLE="$fake_claude_usage_binary" \
  CLAUDE_USAGE_ORPHANING_HELPER="$orphaning_helper_binary" \
  MENU_BAR_TEST_BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$project_dir/Info.plist") \
  "$test_binary"

trust_output=$(
  /usr/bin/expect \
    "$project_dir/Scripts/claude-usage.exp" \
    "$fake_claude_trust_binary" \
    "" \
    --trust-controlled-workspace
)
if [[ $trust_output != *"__CLAUDE_USAGE_MICRO_BEGIN__"*"Weekly limit - all models"*"__CLAUDE_USAGE_MICRO_END__"* ]]; then
  echo "Expect helper did not capture the schema-variant usage screen" >&2
  exit 1
fi

set +e
untrusted_output=$(
  /usr/bin/expect \
    "$project_dir/Scripts/claude-usage.exp" \
    "$fake_claude_trust_binary" \
    "" \
    2>&1
)
untrusted_exit=$?
set -e
if [[ $untrusted_exit -ne 2 ]] || [[ $untrusted_output != *"unexpected workspace trust"* ]]; then
  echo "Expect helper accepted workspace trust without the controlled-workspace flag" >&2
  exit 1
fi

set +e
helper_output=$(/usr/bin/expect "$project_dir/Scripts/claude-usage.exp" 2>&1)
helper_exit=$?
set -e

if [[ $helper_exit -ne 64 ]] || [[ $helper_output != "Usage: claude-usage.exp /path/to/claude ?child-pid-file? ?--trust-controlled-workspace?" ]]; then
  echo "Expect helper argument validation failed" >&2
  exit 1
fi
