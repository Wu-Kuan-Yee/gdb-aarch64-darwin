#!/usr/bin/env bash
#
# Print shell commands that put the installed GDB on PATH.
#
#   eval "$(./scripts/env.sh)"
#   ./scripts/env.sh --shell fish | source

set -eu -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

PROG=$(basename -- "$0")
SHELL_NAME=auto
CHECK=0

usage()
{
	cat <<EOF
Usage: ${PROG} [options]

Print shell code that adds the installed GDB to PATH and MANPATH, so that
\`eval "\$(${PROG})"\` is enough to start using it.

Options:
  --prefix DIR            Installation prefix (default: ${GAD_PREFIX})
  --shell bash|zsh|fish|sh
                          Shell syntax to emit; the default detects the
                          current \$SHELL
  --check                 Exit with status 1 when the installation is missing
  -h, --help              Show this help

Examples:
  eval "\$(${PROG})"
  ${PROG} --shell fish | source
  ${PROG} --check && gdb --version
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--prefix)
			need_value "$1" "$#"
			GAD_PREFIX=$2
			shift 2
			;;
		--shell)
			need_value "$1" "$#"
			SHELL_NAME=$2
			shift 2
			;;
		--check)
			CHECK=1
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
GDB="${PREFIX}/bin/gdb"

if [ "${CHECK}" -eq 1 ]; then
	[ -x "${GDB}" ] || {
		printf '%s\n' "GDB is not installed at ${GDB}" >&2
		exit 1
	}
	"${GDB}" --version 2>/dev/null | head -n 1
	exit 0
fi

if [ "${SHELL_NAME}" = "auto" ]; then
	case "$(basename -- "${SHELL:-/bin/bash}")" in
		fish) SHELL_NAME=fish ;;
		sh) SHELL_NAME=sh ;;
		*) SHELL_NAME=bash ;;
	esac
fi

case "${SHELL_NAME}" in
	bash|zsh)
		printf 'export PATH="%s/bin:$PATH"\n' "${PREFIX}"
		printf 'export MANPATH="%s/share/man:${MANPATH:-}"\n' "${PREFIX}"
		;;
	sh)
		printf 'PATH="%s/bin:$PATH"; export PATH\n' "${PREFIX}"
		printf 'MANPATH="%s/share/man:${MANPATH:-}"; export MANPATH\n' "${PREFIX}"
		;;
	fish)
		printf 'set -gx PATH "%s/bin" $PATH\n' "${PREFIX}"
		printf 'set -gx MANPATH "%s/share/man" $MANPATH\n' "${PREFIX}"
		;;
	*)
		die "unsupported shell: ${SHELL_NAME} (use bash, zsh, fish or sh)"
		;;
esac

if [ ! -x "${GDB}" ]; then
	printf 'warning: %s does not exist yet; run ./build.sh first\n' "${GDB}" >&2
fi
