# Adds or removes address ranges in macOS's local-network allow list
# (Apple Technote TN3179, macOS 15.5+): every program may reach an
# address in these ranges without the per-app Local Network permission.
# Mosaic runs this as root (macOS asks for an administrator password)
# from Settings -> "Always allow the NDI network". The values live in
# root's preferences; check them with
#   sudo defaults read com.apple.network.local-network
# A restart is needed for macOS to apply a change.
#
# Mosaic prepends four lines before this text:
#   D=<defaults domain>   (com.apple.network.local-network)
#   MODE=1 | 0            (1 = add the ranges, 0 = remove them)
#   ETH="<CIDR ...>"      (ranges for wired Ethernet interfaces)
#   WIFI="<CIDR ...>"     (ranges for Wi-Fi interfaces)
#
# Adding never touches entries that are already there and reports, one
# line each, what it did: "ADDED <key> <cidr>" for a range it added,
# "HAD <key> <cidr>" for one that was already allowed. Mosaic later removes
# only ranges it ADDED, so entries that existed before (an administrator's,
# another account's) are never removed. Any failure exits non-zero.

merge() {
    K=$1
    shift
    # Current entries, one CIDR per line (defaults prints a quoted list).
    CUR=$(/usr/bin/defaults read "$D" "$K" 2>/dev/null \
        | /usr/bin/sed -n 's/^[[:space:]]*"\{0,1\}\([0-9a-fA-F.:/]*\)"\{0,1\},\{0,1\}[[:space:]]*$/\1/p')
    NEW=""
    for c in $CUR; do
        keep=1
        if [ "$MODE" = 0 ]; then
            for x in "$@"; do
                [ "$c" = "$x" ] && keep=0
            done
        fi
        [ $keep = 1 ] && NEW="$NEW $c"
    done
    if [ "$MODE" = 1 ]; then
        for x in "$@"; do
            have=0
            for c in $CUR; do
                [ "$c" = "$x" ] && have=1
            done
            if [ $have = 1 ]; then
                echo "HAD $K $x"
            else
                NEW="$NEW $x"
                echo "ADDED $K $x"
            fi
        done
    fi
    if [ -n "$(echo $NEW)" ]; then
        /usr/bin/defaults write "$D" "$K" -array $NEW || return 1
    else
        # Nothing left: remove the key (missing already is fine).
        /usr/bin/defaults delete "$D" "$K" 2>/dev/null
    fi
    return 0
}

if [ -n "$ETH" ]; then merge AllowedEthernetLocalNetworkAddresses $ETH || exit 1; fi
if [ -n "$WIFI" ]; then merge AllowedWiFiLocalNetworkAddresses $WIFI || exit 1; fi
exit 0
