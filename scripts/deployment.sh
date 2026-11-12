#!/bin/bash
# Sourced by install.sh and rollback.sh.
source scripts/bundle.sh
umask 077
state="$HOME/Library/Application Support/Notch Two/Backups"
data="$HOME/Library/Containers/$bundle_id/Data"
target="/Applications/Notch Two.app"
stage=
lock_owned=false
stopped=false
swapped=false

lock_deployment() {
    mkdir -p "$state"
    mkdir "$state/.lock" 2>/dev/null || fail "Another deployment owns $state/.lock."
    lock_owned=true
    trap recover EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

running_apps() {
    /usr/bin/osascript -l JavaScript - "$1" "$target" "${2:-$bundle_id}" <<'JS'
ObjC.import('AppKit')
function run(argv) {
    const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(argv[2])
    const paths = []
    for (let i = 0; i < apps.count; i++) {
        const app = apps.objectAtIndex(i)
        const path = ObjC.unwrap(app.bundleURL.path)
        if (!path) throw Error('Could not identify running Notch Two')
        if (argv[0] === 'quit') {
            if (path !== argv[1]) throw Error('Unexpected Notch Two path: ' + path)
            if (!app.terminate) throw Error('Notch Two refused to quit')
        } else {
            paths.push(path)
        }
    }
    return paths.join('\n')
}
JS
}

quit_target() {
    local paths
    paths=$(running_apps list theboringteam.boringnotch) || fail "Could not check whether Boring Notch is running."
    [[ -z "$paths" ]] || fail "Quit Boring Notch before starting Notch Two."
    paths=$(running_apps list)
    [[ -z "$paths" || "$paths" == "$target" ]] || fail "Unexpected Notch Two instance(s): $paths"
    if [[ -n "$paths" ]]; then
        stopped=true
        running_apps quit >/dev/null
        for ((attempt=0; attempt<30; attempt++)); do
            paths=$(running_apps list) || fail "Could not verify that the old process exited."
            if [[ -z "$paths" ]]; then return; fi
            sleep 1
        done
        fail "Notch Two did not quit cleanly."
    fi
}

stage_bundle() {
    stage=$(mktemp -d '/Applications/.notch-two-swap.XXXXXX')
    /usr/bin/ditto "$1" "$stage/candidate.app"
    verify_bundle "$stage/candidate.app"
    [[ "$(bundle_hash "$1")" == "$(bundle_hash "$stage/candidate.app")" ]] || fail "Staged signature differs."
}

swap_and_launch() {
    if [[ -e "$target" || -L "$target" ]]; then
        verify_bundle "$target"
        /bin/mv "$target" "$stage/previous.app"
    fi
    /bin/mv "$stage/candidate.app" "$target"
    swapped=true
    /usr/bin/open "$target"
    for ((attempt=0; attempt<20; attempt++)); do
        if [[ "$(running_apps list)" == "$target" ]]; then
            sleep 3
            [[ "$(running_apps list)" == "$target" ]] && return
        fi
        sleep 1
    done
    fail "The installed candidate did not stay running as a single instance."
}

recover() {
    local status=$? paths
    set +e
    if [[ "$status" != 0 && -n "$stage" && ( -d "$stage/previous.app" || "$swapped" == true ) ]]; then
        running_apps quit >/dev/null
        for ((attempt=0; attempt<10; attempt++)); do
            if paths=$(running_apps list) && [[ -z "$paths" ]]; then break; fi
            sleep 1
        done
        if paths=$(running_apps list) && [[ -z "$paths" ]]; then
            if [[ -e "$target" ]]; then /bin/mv "$target" "$stage/failed.app"; fi
            if [[ -d "$stage/previous.app" ]]; then /bin/mv "$stage/previous.app" "$target"; fi
        fi
        if [[ -d "$stage/previous.app" ]]; then
            printf 'Recovery needs attention. Previous bundle is at %s\n' "$stage/previous.app" >&2
            stage=
        fi
    fi
    if [[ "$status" != 0 && "$stopped" == true && -d "$target" ]] \
        && paths=$(running_apps list) && [[ -z "$paths" ]]; then
        /usr/bin/open "$target"
    fi
    if [[ -n "$stage" ]]; then /bin/rm -rf "$stage"; fi
    if [[ "$lock_owned" == true ]]; then rmdir "$state/.lock"; fi
    exit "$status"
}
