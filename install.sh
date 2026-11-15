#!/bin/sh

REPO_URL='https://github.com/NotMephisto/pbr-rules-collection.git'
BRANCH='master'
PBR_DIR='/usr/share/pbr'
SETTINGS_FILE="$PBR_DIR/settings"

fail() {
    printf 'PBR installer: %s\n' "$*" >&2
    exit 1
}

ask_yes_no() {
    printf '%s [y/N]: ' "$1"
    IFS= read -r answer || answer=''
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

[ "$(id -u)" = 0 ] || fail 'run this script as root'
[ -f /etc/config/pbr ] && [ -x /etc/init.d/pbr ] || fail 'PBR is not installed'

for cmd in id find sed uci ubus mkdir cp chmod mv rm cat mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required"
done

printf '%s\n' '================================'
printf '%s\n' ' PBR Rules Collection Installer'
printf '%s\n' '================================'

if [ -d "$PBR_DIR" ]; then
    existing_files=$(find "$PBR_DIR" -type f -print 2>/dev/null)
    if [ -n "$existing_files" ]; then
        printf '\nExisting files in %s:\n%s\n' "$PBR_DIR" "$existing_files"
        printf '%s\n' 'Files with matching names will be overwritten; other files will be left untouched.'
        ask_yes_no 'Continue installation?' || {
            echo 'Installation cancelled.'
            exit 0
        }
    fi
fi

# git-http provides Git's HTTPS transport and depends on the git package.
MISSING_PACKAGES=''
GIT_EXEC_PATH=''
if command -v git >/dev/null 2>&1; then
    GIT_EXEC_PATH=$(git --exec-path 2>/dev/null || true)
fi

if [ -z "$GIT_EXEC_PATH" ] || [ ! -x "$GIT_EXEC_PATH/git-remote-https" ]; then
    MISSING_PACKAGES="$MISSING_PACKAGES git-http"
fi

command -v jsonfilter >/dev/null 2>&1 || MISSING_PACKAGES="$MISSING_PACKAGES jsonfilter"

if [ -n "$MISSING_PACKAGES" ]; then
    if command -v apk >/dev/null 2>&1; then
        apk update || fail 'cannot update apk package indexes'
        apk add $MISSING_PACKAGES || fail 'cannot install required packages'
    elif command -v opkg >/dev/null 2>&1; then
        opkg update || fail 'cannot update opkg package lists'
        opkg install $MISSING_PACKAGES || fail 'cannot install required packages'
    else
        fail 'neither apk nor opkg is available to install required packages'
    fi
fi

command -v git >/dev/null 2>&1 || fail 'git is not installed'
command -v jsonfilter >/dev/null 2>&1 || fail 'jsonfilter is not installed'

GIT_EXEC_PATH=$(git --exec-path 2>/dev/null) || fail 'cannot determine Git exec path'
[ -x "$GIT_EXEC_PATH/git-remote-https" ] || fail 'Git HTTPS transport is not installed'

umask 077
TMP_DIR=$(mktemp -d /tmp/pbr-rules.XXXXXX) || fail 'mktemp failed'

cleanup() {
    [ -z "${rule_tmp:-}" ] || rm -f "$rule_tmp"
    [ -z "${settings_tmp:-}" ] || rm -f "$settings_tmp"
    rm -rf "$TMP_DIR"
}

trap cleanup 0
trap 'exit 1' HUP INT TERM

REPO_DIR="$TMP_DIR/repository"

GIT_TERMINAL_PROMPT=0 git clone --depth 1 --single-branch --branch "$BRANCH" \
    "$REPO_URL" "$REPO_DIR" || fail 'repository clone failed'

mkdir -p "$TMP_DIR/prepared" || fail 'cannot create staging directory'

LIST_FILE="$TMP_DIR/installed.list"
: > "$LIST_FILE"
COUNT=0

for src in "$REPO_DIR"/src/pbr.user.*; do
    [ -f "$src" ] || continue

    name=${src##*/}

    sh -n "$src" || fail "shell syntax error in $name"

    cp "$src" "$TMP_DIR/prepared/$name" || fail "cannot stage $name"
    chmod 644 "$TMP_DIR/prepared/$name" || fail "cannot set permissions on $name"

    printf '%s\n' "$name" >> "$LIST_FILE"
    COUNT=$((COUNT + 1))
done

[ "$COUNT" -gt 0 ] || fail 'no pbr.user.* files found in repository src/'

TARGET_TABLE='inet fw4'

if [ -r "$SETTINGS_FILE" ]; then
    . "$SETTINGS_FILE" || fail "cannot read $SETTINGS_FILE"
    TARGET_TABLE=${TARGET_TABLE:-inet fw4}
fi

printf '\nPBR interface name [tun0]: '
IFS= read -r INPUT_INTERFACE || fail 'cannot read interface name'

TARGET_INTERFACE=${INPUT_INTERFACE:-tun0}

case "$TARGET_INTERFACE" in
    ''|*[!a-zA-Z0-9_.-]*) fail 'invalid interface name' ;;
esac

mkdir -p "$PBR_DIR" || fail "cannot create $PBR_DIR"

# Keep unrelated local settings and replace only the shared PBR values.
settings_tmp="$PBR_DIR/.settings.$$"

{
    if [ -f "$SETTINGS_FILE" ]; then
        sed '/^TARGET_TABLE=/d; /^TARGET_INTERFACE=/d' "$SETTINGS_FILE" ||
            fail 'cannot read existing settings'
    fi

    printf "\nTARGET_TABLE='%s'\nTARGET_INTERFACE='%s'\n" \
        "$TARGET_TABLE" "$TARGET_INTERFACE"
} > "$settings_tmp" || fail 'cannot write settings'

chmod 600 "$settings_tmp" || fail 'cannot set settings permissions'

mv -f "$settings_tmp" "$SETTINGS_FILE" || fail 'cannot install settings'
settings_tmp=''

# Install source files unchanged; each rule manages its own settings checks.
while IFS= read -r name; do
    rule_tmp="$PBR_DIR/.$name.$$"

    cp "$TMP_DIR/prepared/$name" "$rule_tmp" ||
        fail "cannot stage $name for installation"

    chmod 644 "$rule_tmp" || fail "cannot set permissions on $name"

    mv -f "$rule_tmp" "$PBR_DIR/$name" ||
        fail "cannot install $name"

    rule_tmp=''
done < "$LIST_FILE"

SECTIONS_FILE="$TMP_DIR/sections.list"
: > "$SECTIONS_FILE"

while IFS= read -r name; do
    path="$PBR_DIR/$name"
    section=''

    for candidate in $(uci -q show pbr |
        sed -n 's/^\(pbr\.[^.]*\)\.path=.*/\1/p'); do

        if [ "$(uci -q get "$candidate.path")" = "$path" ]; then
            section=$candidate
            break
        fi
    done

    if [ -z "$section" ]; then
        section=$(uci add pbr include) || fail "cannot register $path"
        section="pbr.$section"
    fi

    uci set "$section.path=$path" || fail "cannot set path for $path"
    uci set "$section.enabled=0" || fail "cannot disable $path"

    printf '%s\n' "$section" >> "$SECTIONS_FILE"
done < "$LIST_FILE"

printf '\n'

if ask_yes_no 'Enable all downloaded rules in PBR now?'; then
    while IFS= read -r section; do
        uci set "$section.enabled=1" || fail "cannot enable $section"
    done < "$SECTIONS_FILE"

    ENABLED=1
else
    ENABLED=0
fi

uci commit pbr || fail 'cannot save PBR configuration'

printf '\nInstalled %s PBR rules.\n' "$COUNT"
printf 'Interface: %s\n' "$TARGET_INTERFACE"
printf 'Rules enabled: %s\n' "$([ "$ENABLED" = 1 ] && echo yes || echo no)"
printf 'Settings: %s\n' "$SETTINGS_FILE"

PBR_STATUS=$(ubus call service list '{"name":"pbr"}' 2>/dev/null || true)

PBR_RUNNING=$(jsonfilter -s "$PBR_STATUS" \
    -e '@.pbr.instances.main.running' 2>/dev/null)

if [ "$PBR_RUNNING" = 'true' ]; then
    if ask_yes_no 'PBR is running. Restart PBR now to apply the changes?'; then
        /etc/init.d/pbr restart || fail 'PBR restart failed; inspect logread'
    else
        echo 'PBR was left running; changes will apply at its next restart.'
    fi
else
    echo 'PBR is not running; its service was not started or restarted.'
fi

echo 'Installation completed.'
