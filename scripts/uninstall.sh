#!/usr/bin/env bash
#
# Remove an installation created by ./build.sh.

set -eu -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

PROG=$(basename -- "$0")
CONFIRM=0

usage()
{
	cat <<EOF
Usage: ${PROG} [options]

Remove the GDB installation at the prefix.  The script refuses to touch a
directory that does not look like an installation (no bin/gdb inside), and
requires --yes before deleting anything.

Options:
  --prefix DIR   Installation prefix (default: ${GAD_PREFIX})
  --yes          Really delete; without it the script only reports
  --dry-run      Print what would be removed
  -h, --help     Show this help

Examples:
  ${PROG} --dry-run
  ${PROG} --prefix "\$HOME/Packages/gdb/aarch64-darwin" --yes
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--prefix)
			need_value "$1" "$#"
			GAD_PREFIX=$2
			shift 2
			;;
		--yes)
			CONFIRM=1
			shift
			;;
		--dry-run)
			GAD_DRY_RUN=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown argument: $1 (try --help)"
			;;
	esac
done

PREFIX=$(abspath "${GAD_PREFIX}") || die "cannot resolve prefix: ${GAD_PREFIX}"

case "${PREFIX}" in
	""|"/"|"//"|"$HOME")
		die "refusing to remove ${PREFIX}"
		;;
esac

if [ ! -d "${PREFIX}" ]; then
	ok "nothing to remove: ${PREFIX} does not exist"
	exit 0
fi

if [ ! -x "${PREFIX}/bin/gdb" ] && [ ! -d "${PREFIX}/share/gdb" ]; then
	die "${PREFIX} does not look like a GDB installation; refusing to remove it"
fi

SIZE=$(du -sh "${PREFIX}" 2>/dev/null | awk '{ print $1 }')
info "prefix: ${PREFIX}"
info "size:   ${SIZE:-unknown}"

if [ "${CONFIRM}" -eq 0 ] && [ "${GAD_DRY_RUN}" -eq 0 ]; then
	printf '\nRe-run with --yes to delete this directory.\n'
	exit 1
fi

step "removing ${PREFIX}"
run rm -rf -- "${PREFIX}"
ok "removed"
