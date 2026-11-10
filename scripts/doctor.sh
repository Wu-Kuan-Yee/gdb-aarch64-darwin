#!/usr/bin/env bash
#
# Check whether this machine can build and use gdb-aarch64-darwin.
#
# The doctor is read-only: it never installs anything and never changes the
# build tree.  Run it first when a build fails for a reason that is not
# obviously the source code.

set -eu -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

PROG=$(basename -- "$0")
QUIET=0
STRICT=0
FAILURES=0
WARNINGS=0

usage()
{
	cat <<EOF
Usage: ${PROG} [options]

Check that this Mac has everything needed to build GDB with the AArch64
Darwin backend: a native toolchain, GMP/MPFR, a code signing identity and
enough disk space.  Nothing is installed or modified.

Options:
  --prefix DIR   Installation prefix to inspect (default: ${GAD_PREFIX})
  --quiet        Only print problems, not the passing checks
  --strict       Treat warnings as errors
  -h, --help     Show this help

Exit status is 0 when the machine looks usable, 1 when a required component
is missing or, with --strict, when there is any warning.

Examples:
  ./scripts/doctor.sh
  ./scripts/doctor.sh --prefix "\$HOME/Packages/gdb/aarch64-darwin"
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--prefix)
			need_value "$1" "$#"
			GAD_PREFIX=$2
			shift 2
			;;
		--quiet)
			QUIET=1
			shift
			;;
		--strict)
			STRICT=1
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

pass()
{
	[ "${QUIET}" -eq 1 ] || printf '  %s ok %s %s\n' "${C_GREEN}" "${C_RESET}" "$*"
}

note()
{
	[ "${QUIET}" -eq 1 ] || printf '  %s  - %s %s\n' "${C_DIM}" "${C_RESET}" "$*"
}

warn_check()
{
	WARNINGS=$((WARNINGS + 1))
	warn "$*"
}

fail_check()
{
	FAILURES=$((FAILURES + 1))
	error "$*"
}

section()
{
	if [ "${QUIET}" -eq 0 ]; then
		printf '\n%s%s%s\n' "${C_BOLD}" "$*" "${C_RESET}"
	fi
}

check_system()
{
	local version
	section "System"

	if [ "$(uname -s)" != "Darwin" ]; then
		fail_check "this project only builds on macOS (detected $(uname -s))"
		return
	fi
	pass "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"

	if [ "$(uname -m)" != "arm64" ]; then
		fail_check "Apple Silicon required, this Mac reports $(uname -m)"
		return
	fi
	pass "architecture arm64"

	version=$(macos_version)
	if version_ge "${version}" "13.0"; then
		pass "macOS ${version} is supported"
	else
		warn_check "macOS ${version} is older than 13.0; the build may still work but is untested"
	fi
}

check_xcode()
{
	local developer sdk clang_output

	section "Xcode toolchain"

	developer=$(xcode-select -p 2>/dev/null || true)
	if [ -z "${developer}" ]; then
		fail_check "no active developer directory; run: xcode-select --install"
		return
	fi
	pass "developer directory: ${developer}"

	if ! have xcrun; then
		fail_check "xcrun is missing; install the Xcode command line tools"
		return
	fi

	sdk=$(sdk_path)
	if [ -n "${sdk}" ] && [ -d "${sdk}" ]; then
		pass "macOS SDK: ${sdk}"
	else
		fail_check "cannot locate the macOS SDK; run: xcode-select --install"
	fi

	if have /usr/bin/cc; then
		clang_output=$(/usr/bin/cc --version 2>/dev/null | head -n 1)
		pass "C compiler: ${clang_output}"
	else
		fail_check "/usr/bin/cc is missing"
	fi

	if [ -x /usr/bin/c++ ]; then
		pass "C++ compiler: /usr/bin/c++"
	else
		fail_check "/usr/bin/c++ is missing"
	fi
}

check_tools()
{
	local tool missing

	section "Build tools"

	missing=0
	for tool in make bison flex m4 perl tar curl git patch; do
		if have "${tool}"; then
			note "${tool}: $(command -v "${tool}")"
		else
			fail_check "missing build tool: ${tool}"
			missing=1
		fi
	done
	[ "${missing}" -eq 0 ] && pass "all required build tools are present"
	true
}

check_libraries()
{
	local gmp mpfr

	section "GMP and MPFR"

	gmp=$(find_gmp_prefix)
	if library_prefix_ok "${gmp}" gmp.h libgmp; then
		pass "GMP: ${gmp}"
	else
		fail_check "GMP not found; install it with: brew install gmp"
	fi

	mpfr=$(find_mpfr_prefix)
	if library_prefix_ok "${mpfr}" mpfr.h libmpfr; then
		pass "MPFR: ${mpfr}"
	else
		fail_check "MPFR not found; install it with: brew install mpfr"
	fi
}

check_signing()
{
	local identities count development

	section "Code signing"

	if ! have security; then
		fail_check "the security tool is missing; code signing is impossible"
		return
	fi

	identities=$(codesign_identities)
	count=$(printf '%s\n' "${identities}" | grep -c . || true)
	if [ "${count}" -eq 0 ]; then
		fail_check "no code signing identity found; GDB cannot be authorised to debug"
		note "create one in Xcode > Settings > Accounts > Manage Certificates"
		return
	fi

	if printf '%s\n' "${identities}" | grep -q '^Apple Development:'; then
		development=$(printf '%s\n' "${identities}" | grep -m 1 '^Apple Development:')
		pass "Apple Development identity: ${development}"
	else
		warn_check "no Apple Development identity; a Developer ID or other identity will be used"
	fi
	note "${count} codesigning identity/identities available"
}

check_disk()
{
	local available_kib available_gib

	section "Resources"

	available_kib=$(df -Pk "${GAD_ROOT}" 2>/dev/null | awk 'NR == 2 { print $4 }')
	if [ -z "${available_kib}" ]; then
		warn_check "cannot determine free disk space"
	else
		available_gib=$((available_kib / 1024 / 1024))
		if [ "${available_gib}" -ge 15 ]; then
			pass "free disk space: ${available_gib} GiB"
		elif [ "${available_gib}" -ge 7 ]; then
			warn_check "only ${available_gib} GiB free; the source, build and install trees need about 6 GiB"
		else
			fail_check "only ${available_gib} GiB free; at least 7 GiB are required"
		fi
	fi

	pass "logical CPUs: $(cpu_count)"
	pass "memory: $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 )) GiB"
}

check_installation()
{
	local gdb version signature

	section "Existing installation"

	gdb="${GAD_PREFIX}/bin/gdb"
	if [ ! -x "${gdb}" ]; then
		note "nothing installed at ${GAD_PREFIX} yet"
		return
	fi

	version=$("${gdb}" --version 2>/dev/null | head -n 1 || true)
	if [ -n "${version}" ]; then
		pass "installed: ${version}"
	else
		warn_check "${gdb} exists but does not run"
	fi

	signature=$(codesign -dvvv "${gdb}" 2>&1 | grep -E '^(Authority|Signature)=' | head -n 2 || true)
	if [ -n "${signature}" ]; then
		note "${signature}"
	else
		warn_check "${gdb} is not signed; run ./scripts/sign.sh"
	fi
}

check_sources()
{
	section "Project"

	pass "repository: ${GAD_ROOT}"
	if [ -r "${GAD_ROOT}/patches/series" ]; then
		pass "patch series: $(grep -c . "${GAD_ROOT}/patches/series") patches"
	else
		fail_check "patches/series is missing from ${GAD_ROOT}"
	fi
	note "pinned upstream revision: ${UPSTREAM_REV}"
}

printf '%s\n' "${C_BOLD}gdb-aarch64-darwin doctor${C_RESET}"

check_system
check_xcode
check_tools
check_libraries
check_signing
check_disk
check_installation
check_sources

printf '\n'
if [ "${FAILURES}" -gt 0 ]; then
	error "${FAILURES} blocking problem(s), ${WARNINGS} warning(s)"
	printf 'Fix the problems above, then run the doctor again.\n' >&2
	exit 1
fi

if [ "${WARNINGS}" -gt 0 ]; then
	warn "no blocking problems, ${WARNINGS} warning(s)"
	if [ "${STRICT}" -eq 1 ]; then
		exit 1
	fi
else
	ok "everything needed to build and debug is available"
fi
