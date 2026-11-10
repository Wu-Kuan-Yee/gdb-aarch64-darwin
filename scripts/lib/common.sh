# shellcheck shell=bash
#
# Shared helpers for the gdb-aarch64-darwin scripts.
#
# Source this file, do not execute it.  Everything here has to work with the
# bash 3.2 that ships with macOS, so the code avoids associative arrays,
# namerefs and the other bash 4 extensions.

if [ -n "${GAD_COMMON_SH:-}" ]; then
	return 0
fi
GAD_COMMON_SH=1

GAD_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
GAD_ROOT=$(cd -- "${GAD_LIB_DIR}/../.." && pwd -P)
readonly GAD_ROOT

# Upstream GDB revision this patch series was written against.  Keep the full
# object name: abbreviated names are resolved differently by different git
# versions once the upstream history grows.
UPSTREAM_URL=${GAD_UPSTREAM_URL:-https://sourceware.org/git/binutils-gdb.git}
UPSTREAM_REV=${GAD_UPSTREAM_REV:-7e7dd6cfcf60cda2506d19d88ff98622bf670dbd}

# Where things go.  Every path can be overridden from the environment, and the
# command line options of the individual scripts take precedence over both.
GAD_PREFIX=${GAD_PREFIX:-${GAD_ROOT}/dist}
GAD_BUILD_DIR=${GAD_BUILD_DIR:-${GAD_ROOT}/build}
GAD_CACHE_DIR=${GAD_CACHE_DIR:-${GAD_ROOT}/.cache}
GAD_SOURCE_DIR=${GAD_SOURCE_DIR:-${GAD_CACHE_DIR}/binutils-gdb}
GAD_JOBS=${GAD_JOBS:-}

# Homebrew prefixes for the two libraries GDB requires.
GAD_GMP_PREFIX=${GAD_GMP_PREFIX:-}
GAD_MPFR_PREFIX=${GAD_MPFR_PREFIX:-}

GAD_DRY_RUN=${GAD_DRY_RUN:-0}
GAD_VERBOSE=${GAD_VERBOSE:-0}

#
# Output
#

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
	C_RESET=$'\033[0m'
	C_BOLD=$'\033[1m'
	C_RED=$'\033[31m'
	C_GREEN=$'\033[32m'
	C_YELLOW=$'\033[33m'
	C_BLUE=$'\033[34m'
	C_DIM=$'\033[2m'
else
	C_RESET=
	C_BOLD=
	C_RED=
	C_GREEN=
	C_YELLOW=
	C_BLUE=
	C_DIM=
fi

# Diagnostics go to stderr so a script can return a value on stdout.
info()
{
	printf '%s\n' "$*" >&2
}

step()
{
	printf '%s==>%s %s\n' "${C_BOLD}${C_BLUE}" "${C_RESET}" "$*" >&2
}

ok()
{
	printf '%s ok %s %s\n' "${C_GREEN}" "${C_RESET}" "$*" >&2
}

warn()
{
	printf '%swarn%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2
}

error()
{
	printf '%sfail%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2
}

die()
{
	error "$*"
	exit 1
}

debug()
{
	if [ "${GAD_VERBOSE}" -eq 1 ]; then
		printf '%sdebug%s %s\n' "${C_DIM}" "${C_RESET}" "$*" >&2
	fi
}

# Print a command exactly as it would be executed.  Used by the dry-run paths.
print_command()
{
	local arg
	printf '+' >&2
	for arg in "$@"; do
		printf ' %q' "${arg}" >&2
	done
	printf '\n' >&2
}

# Run a command, or print it when GAD_DRY_RUN is set.
run()
{
	if [ "${GAD_DRY_RUN}" -eq 1 ]; then
		print_command "$@"
		return 0
	fi
	"$@"
}

#
# Environment checks
#

have()
{
	command -v "$1" >/dev/null 2>&1
}

require_cmd()
{
	local cmd=$1
	local hint=${2:-}
	if ! have "${cmd}"; then
		if [ -n "${hint}" ]; then
			die "required command not found: ${cmd} (${hint})"
		fi
		die "required command not found: ${cmd}"
	fi
}

require_macos()
{
	if [ "$(uname -s)" != "Darwin" ]; then
		die "this project only builds on macOS, but $(uname -s) was detected"
	fi
}

require_arm64()
{
	if [ "$(uname -m)" != "arm64" ]; then
		die "this project requires Apple Silicon (arm64), but $(uname -m) was detected"
	fi
}

macos_version()
{
	sw_vers -productVersion 2>/dev/null || printf '0.0.0\n'
}

# version_ge A B: succeed when A is at least B.
version_ge()
{
	awk -v a="$1" -v b="$2" 'BEGIN {
		n = split(a, x, "."); m = split(b, y, ".")
		for (i = 1; i <= 3; i++) {
			ai = (i <= n) ? x[i] + 0 : 0
			bi = (i <= m) ? y[i] + 0 : 0
			if (ai > bi) exit 0
			if (ai < bi) exit 1
		}
		exit 0
	}'
}

sdk_path()
{
	xcrun --sdk macosx --show-sdk-path 2>/dev/null || true
}

cpu_count()
{
	sysctl -n hw.ncpu 2>/dev/null || printf '4\n'
}

default_jobs()
{
	local jobs
	jobs=$(cpu_count)
	printf '%s\n' "${jobs}"
}

format_duration()
{
	local total=$1 hours minutes seconds
	hours=$((total / 3600))
	minutes=$(((total % 3600) / 60))
	seconds=$((total % 60))
	if [ "${hours}" -gt 0 ]; then
		printf '%dh %dm %ds' "${hours}" "${minutes}" "${seconds}"
	elif [ "${minutes}" -gt 0 ]; then
		printf '%dm %ds' "${minutes}" "${seconds}"
	else
		printf '%ds' "${seconds}"
	fi
}

#
# Paths
#

# Resolve a path that may not exist yet.  Fails when the parent directory does
# not exist either.
abspath()
{
	local path=$1 dir base
	if [ -d "${path}" ]; then
		(cd -- "${path}" && pwd -P)
		return
	fi
	dir=$(cd -- "$(dirname -- "${path}")" 2>/dev/null && pwd -P) || return 1
	base=$(basename -- "${path}")
	printf '%s/%s\n' "${dir}" "${base}"
}

# Print the Homebrew prefix of a formula, or nothing.
brew_prefix()
{
	local formula=$1 prefix=
	if have brew; then
		prefix=$(brew --prefix "${formula}" 2>/dev/null || true)
	fi
	if [ -z "${prefix}" ]; then
		case "${formula}" in
			gmp) [ -d /opt/homebrew/opt/gmp ] && prefix=/opt/homebrew/opt/gmp ;;
			mpfr) [ -d /opt/homebrew/opt/mpfr ] && prefix=/opt/homebrew/opt/mpfr ;;
		esac
	fi
	printf '%s\n' "${prefix}"
}

# GMP/MPFR prefix resolution, in order: environment, Homebrew.
find_gmp_prefix()
{
	if [ -n "${GAD_GMP_PREFIX}" ]; then
		printf '%s\n' "${GAD_GMP_PREFIX}"
	else
		brew_prefix gmp
	fi
}

find_mpfr_prefix()
{
	if [ -n "${GAD_MPFR_PREFIX}" ]; then
		printf '%s\n' "${GAD_MPFR_PREFIX}"
	else
		brew_prefix mpfr
	fi
}

# A GMP/MPFR prefix is usable when the header and at least one library are
# there.  The library prefix is a stem such as "libgmp" so that the check
# accepts both the dynamic and the static form.
library_prefix_ok()
{
	local prefix=$1 header=$2 stem=$3 found
	[ -n "${prefix}" ] || return 1
	[ -f "${prefix}/include/${header}" ] || return 1
	found=$(compgen -G "${prefix}/lib/${stem}*" || true)
	[ -n "${found}" ]
}

#
# Code signing
#

# Print one codesigning identity per line.  The output of
# `security find-identity` looks like:
#
#   1) 3C8E... "Apple Development: Name (TEAMID)"
#      1 valid identities found
codesign_identities()
{
	security find-identity -v -p codesigning 2>/dev/null |
		sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-Fa-f][0-9A-Fa-f]* "\(.*\)"$/\1/p'
}

# Pick the identity to sign with.  Prints the name and returns 0; prints
# nothing and returns 1 when no usable identity exists.
select_signing_identity()
{
	local requested=${1:-} identities identity
	identities=$(codesign_identities)
	if [ -z "${identities}" ]; then
		return 1
	fi
	if [ -n "${requested}" ]; then
		if printf '%s\n' "${identities}" | grep -Fxq -- "${requested}"; then
			printf '%s\n' "${requested}"
			return 0
		fi
		return 1
	fi
	identity=$(printf '%s\n' "${identities}" | grep -m 1 '^Apple Development:' || true)
	if [ -z "${identity}" ]; then
		identity=$(printf '%s\n' "${identities}" | grep -m 1 '^Developer ID Application:' || true)
	fi
	if [ -z "${identity}" ]; then
		identity=$(printf '%s\n' "${identities}" | head -n 1)
	fi
	printf '%s\n' "${identity}"
}

#
# Argument parsing helpers
#

# need_value OPTION VALUE_COUNT: fail with a useful message when an option is
# missing its argument.
need_value()
{
	local option=$1 count=$2
	if [ "${count}" -lt 2 ]; then
		die "option ${option} requires a value"
	fi
}

# Print the contents of a file, or a placeholder when it is empty or missing.
read_first_line()
{
	local file=$1
	if [ -r "${file}" ]; then
		head -n 1 -- "${file}"
	fi
}
