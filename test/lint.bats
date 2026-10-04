#!/usr/bin/env bats
# Every shell script in the repository, through shellcheck. Scripts are
# discovered rather than listed, so a new one is covered the moment it is
# added and nobody has to remember to add it here.

setup() {
    load 'test_helper/common'
    load 'test_helper/sv'
    common_setup
}

shell_scripts() {
    # Tracked files only - no submodule contents, no build output, no
    # untracked scratch work sitting in the checkout.
    local file
    git -C "$REPO_ROOT" ls-files -z | while IFS= read -r -d '' file; do
        case "$file" in
            test/bats/*|test/test_helper/bats-*) continue ;;
        esac
        [ -f "$REPO_ROOT/$file" ] || continue
        case "$(head -c 2 "$REPO_ROOT/$file" 2>/dev/null)" in
            '#!') ;;
            *) continue ;;
        esac
        case "$(head -1 "$REPO_ROOT/$file")" in
            *sh|*bash|*' sh'*|*' bash'*) printf '%s\n' "$file" ;;
        esac
    done
}

@test "there are shell scripts to check" {
    run shell_scripts
    assert_success
    refute_output ""
}

@test "every shell script passes shellcheck" {
    require_commands shellcheck
    # No -s: each script declares its own dialect in its shebang, and
    # forcing one would check the bash test helpers as POSIX sh.

    local failures="" file
    while IFS= read -r file; do
        if ! output=$(shellcheck "$REPO_ROOT/$file" 2>&1); then
            failures="$failures
--- $file ---
$output"
        fi
    done < <(shell_scripts)

    if [ -n "$failures" ]; then
        fail "shellcheck reported problems:$failures"
    fi
}
