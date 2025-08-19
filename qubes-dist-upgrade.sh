#!/bin/bash

# Frédéric Pierret (fepitre) frederic.pierret@qubes-os.org

set -e
shopt -s nullglob
if [ "${VERBOSE:-0}" -ge 2 ] || [ "${DEBUG:-0}" -eq 1 ]; then
    set -x
fi

scriptsdir=/usr/lib/qubes

#-----------------------------------------------------------------------------#

usage() {
echo "Usage: $0 --releasever=VERSION [OPTIONS]...

This script is used for updating QubesOS to the next release.

Options:
    --releasever=VERSION               Specify target release, for example 4.3 or 4.2.
"

if [ -n "$releasever" ]; then
    $scriptsdir/qubes-dist-upgrade-r"$releasever".sh --help
else
    echo "Release specific options are listed only if --releasever option is given."
fi

exit 1
}

#-----------------------------------------------------------------------------#

ORIG_ARGV=("$@")
OPTS=$(getopt -q -o h  --long help,releasever: -n "$0" -- "$@") || :

eval set -- "$OPTS"

releasever=
help=

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help) help=1 ;;
        --releasever)
            case "$2" in
            4.2|4.3) releasever="$2"; shift ;;
            *) echo "Invalid --releasever value: $2" >&2; exit 2;;
            esac
            ;;
    esac
    shift
done

if [ -z "$releasever" ] || [ -n "$help" ]; then
    usage
fi

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run with root permissions"
   exit 1
fi

exec "$scriptsdir/qubes-dist-upgrade-r$releasever.sh" "${ORIG_ARGV[@]}"
