#!/usr/bin/env bash
#
# Build, install and check GDB with the AArch64 Darwin backend.
#
# This is the one command a new checkout needs.  It fetches the pinned
# upstream revision, applies the patch series, configures an out-of-tree
# build, installs into ./dist, signs the result and runs the smoke test.

set -eu -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/scripts/lib/common.sh"

PROG=$(basename -- "$0")
PREFIX=${GAD_PREFIX}
BUILD_DIR=${GAD_BUILD_DIR}
JOBS=${GAD_JOBS}
SOURCE_OPT=
IDENTITY=
DO_SIGN=1
DO_VERIFY=1
RECONFIGURE=0
CLEAN=0
DISTCLEAN=0
OFFLINE=0
VERIFY_TIMEOUT=180
STARTED_AT=$(date +%s)

usage()
{
	cat <<EOF
Usage: ${PROG} [options]

Build GDB with native AArch64 Darwin support, install it and verify that it
can debug a program.  Everything is installed under the prefix; nothing is
written outside the checkout except that directory.

What the script does:
  1. checks the toolchain, GMP/MPFR and a codesigning identity
  2. clones binutils-gdb once into .cache and applies patches/series
  3. configures an out-of-tree build in ${GAD_BUILD_DIR}
  4. runs "make all-gdb" and "make install-gdb"
  5. signs the installed GDB with com.apple.security.cs.debugger
  6. compiles tests/probe.c and runs the smoke test against the result

Options:
  --prefix DIR       Installation prefix (default: ${PREFIX})
  --jobs N           Parallel build jobs (default: number of CPUs)
  --source DIR       Use an existing binutils-gdb checkout instead of the
                     cache; useful for offline builds and for iterating on
                     the patches
  --identity NAME    Codesigning identity (default: first Apple Development)
  --build-dir DIR    Build directory (default: ${BUILD_DIR})
  --clean            Remove the build directory before configuring
  --distclean        Also remove the cached source and installed tree
  --reconfigure      Re-run configure even if config.status looks current
  --offline          Never touch the network
  --no-sign          Skip signing; the result cannot debug anything
  --no-verify        Skip the smoke test
  --timeout SECS     Smoke test timeout (default: ${VERIFY_TIMEOUT})
  --dry-run          Print the commands that would run
  --verbose          Show compiler and GDB output
  -h, --help         Show this help

Environment:
  GAD_PREFIX, GAD_BUILD_DIR, GAD_CACHE_DIR, GAD_SOURCE_DIR, GAD_JOBS,
  CODESIGN_IDENTITY, GAD_GMP_PREFIX, GAD_MPFR_PREFIX, CC, CXX, NO_COLOR

Examples:
  ./build.sh
  ./build.sh --prefix "\$HOME/Packages/gdb/aarch64-darwin"
  ./build.sh --source ../binutils-gdb --jobs 8 --verbose
  ./build.sh --clean --reconfigure
  ./build.sh --no-verify --dry-run

The build takes roughly 5 to 15 minutes on an Apple Silicon Mac.  Only the
first run downloads the upstream repository (about 600 MB).
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--prefix)
			need_value "$1" "$#"
			PREFIX=$2
			shift 2
			;;
		--jobs)
			need_value "$1" "$#"
			JOBS=$2
			shift 2
			;;
		--source)
			need_value "$1" "$#"
			SOURCE_OPT=$2
			shift 2
			;;
		--identity)
			need_value "$1" "$#"
			IDENTITY=$2
			shift 2
			;;
		--build-dir)
			need_value "$1" "$#"
			BUILD_DIR=$2
			shift 2
			;;
		--clean)
			CLEAN=1
			shift
			;;
		--distclean)
			DISTCLEAN=1
			shift
			;;
		--reconfigure)
			RECONFIGURE=1
			shift
			;;
		--offline)
			OFFLINE=1
			shift
			;;
		--no-sign)
			DO_SIGN=0
			shift
			;;
		--no-verify)
			DO_VERIFY=0
			shift
			;;
		--timeout)
			need_value "$1" "$#"
			VERIFY_TIMEOUT=$2
			shift 2
			;;
		--dry-run)
			GAD_DRY_RUN=1
			shift
			;;
		--verbose)
			GAD_VERBOSE=1
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

[ "$#" -eq 0 ] || die "unexpected argument: $1"

if [ "${DO_SIGN}" -eq 0 ] && [ "${DO_VERIFY}" -eq 1 ]; then
	warn "the smoke test needs a signed GDB; skipping it because --no-sign was given"
	DO_VERIFY=0
fi

on_interrupt()
{
	printf '\n' >&2
	warn "interrupted; the build tree is left in place for a later --clean run"
	exit 130
}
trap on_interrupt INT TERM

# run_logged LOGFILE COMMAND...: run COMMAND, append its output to LOGFILE and
# print the tail when it fails.
run_logged()
{
	local logfile=$1 status=0
	shift
	if [ "${GAD_DRY_RUN}" -eq 1 ]; then
		print_command "$@"
		return 0
	fi
	"$@" >>"${logfile}" 2>&1 || status=$?
	if [ "${status}" -ne 0 ]; then
		printf '\n' >&2
		error "command failed with status ${status}: $*"
		info "last lines of ${logfile}:"
		tail -n 40 -- "${logfile}" >&2 || true
		exit "${status}"
	fi
}

# Compare the configuration actually recorded by configure against the current
# prefix and source directory.  config.status --config prints the original
# arguments; its own variables are not a reliable record (srcdir is stored
# relative or with symlinks resolved).
config_is_current()
{
	local config="${BUILD_DIR}/config.status" args prefix_real source_real
	[ -f "${config}" ] || return 1
	args=$(cd -- "${BUILD_DIR}" && sh ./config.status --config 2>/dev/null) || return 1
	prefix_real=$(cd -- "${PREFIX}" 2>/dev/null && pwd -P) || prefix_real=${PREFIX}
	source_real=$(cd -- "${SOURCE_DIR}" 2>/dev/null && pwd -P) || source_real=${SOURCE_DIR}
	printf '%s' "${args}" | grep -Fq -- "--prefix=${prefix_real}" || return 1
	printf '%s' "${args}" | grep -Fq -- "--srcdir=${source_real}" || return 1
	return 0
}

banner()
{
	printf '%s\n' "${C_BOLD}gdb-aarch64-darwin${C_RESET}"
	printf 'GDB with a native AArch64 Darwin backend\n\n'
}

banner
require_macos
require_arm64

[ -z "${JOBS}" ] && JOBS=$(default_jobs)
case "${JOBS}" in
	''|*[!0-9]*) die "--jobs expects a positive integer, got: ${JOBS}" ;;
esac
[ "${JOBS}" -gt 0 ] || die "--jobs expects a positive integer"

require_cmd make
require_cmd bison "install the Xcode command line tools"
require_cmd flex "install the Xcode command line tools"
require_cmd tar
require_cmd shasum
[ "${OFFLINE}" -eq 1 ] || require_cmd git "needed to fetch the upstream source"

[ -x /usr/bin/cc ] || die "/usr/bin/cc is missing; install the Xcode command line tools"
[ -x /usr/bin/c++ ] || die "/usr/bin/c++ is missing; install the Xcode command line tools"

SDK=$(sdk_path)
[ -n "${SDK}" ] && [ -d "${SDK}" ] || die "cannot find the macOS SDK; run xcode-select --install"

GMP_PREFIX=$(find_gmp_prefix)
MPFR_PREFIX=$(find_mpfr_prefix)
library_prefix_ok "${GMP_PREFIX}" gmp.h libgmp ||
	die "GMP not found; install it with: brew install gmp (or set GAD_GMP_PREFIX)"
library_prefix_ok "${MPFR_PREFIX}" mpfr.h libmpfr ||
	die "MPFR not found; install it with: brew install mpfr (or set GAD_MPFR_PREFIX)"

if [ "${DO_SIGN}" -eq 1 ]; then
	if [ -z "${IDENTITY}" ]; then
		IDENTITY=${CODESIGN_IDENTITY:-}
	fi
	if [ -z "${IDENTITY}" ]; then
		IDENTITY=$(select_signing_identity "") || IDENTITY=
	fi
	if [ -z "${IDENTITY}" ]; then
		error "no codesigning identity is available"
		info "GDB must be signed with a real identity before macOS lets it debug anything."
		info "Create one in Xcode > Settings > Accounts > Manage Certificates, then re-run."
		info "Use --no-sign to build without signing (the result cannot debug)."
		exit 1
	fi
	if ! codesign_identities | grep -Fxq -- "${IDENTITY}"; then
		die "codesigning identity not found: ${IDENTITY}"
	fi
fi

run mkdir -p -- "${PREFIX}"
PREFIX=$(abspath "${PREFIX}") || die "cannot resolve prefix: ${PREFIX}"
BUILD_DIR=$(abspath "${BUILD_DIR}") || die "cannot resolve build directory: ${BUILD_DIR}"

info "prefix:     ${PREFIX}"
info "build dir:  ${BUILD_DIR}"
info "gmp/mpfr:   ${GMP_PREFIX} / ${MPFR_PREFIX}"
info "jobs:       ${JOBS}"
if [ "${DO_SIGN}" -eq 1 ]; then
	info "identity:   ${IDENTITY}"
fi

if [ "${DISTCLEAN}" -eq 1 ]; then
	step "removing build, cache and installation"
	remove_tree "${BUILD_DIR}"
	remove_tree "${GAD_CACHE_DIR}"
	remove_tree "${PREFIX}"
fi

if [ "${CLEAN}" -eq 1 ]; then
	step "removing build directory"
	remove_tree "${BUILD_DIR}"
fi

step "preparing the source tree"
BOOTSTRAP_ARGS=()
if [ -n "${SOURCE_OPT}" ]; then
	BOOTSTRAP_ARGS[${#BOOTSTRAP_ARGS[@]}]=--source
	BOOTSTRAP_ARGS[${#BOOTSTRAP_ARGS[@]}]=${SOURCE_OPT}
fi
if [ "${OFFLINE}" -eq 1 ]; then
	BOOTSTRAP_ARGS[${#BOOTSTRAP_ARGS[@]}]=--offline
fi
if [ "${#BOOTSTRAP_ARGS[@]}" -gt 0 ]; then
	SOURCE_DIR=$("${SCRIPT_DIR}/scripts/bootstrap.sh" "${BOOTSTRAP_ARGS[@]}")
else
	SOURCE_DIR=$("${SCRIPT_DIR}/scripts/bootstrap.sh")
fi
[ -n "${SOURCE_DIR}" ] || die "bootstrap did not return a source directory"
SOURCE_DIR=$(cd -- "${SOURCE_DIR}" && pwd -P) || die "cannot resolve source directory: ${SOURCE_DIR}"
ok "source: ${SOURCE_DIR}"

CONFIGURE_ARGS=(
	"--srcdir=${SOURCE_DIR}"
	"--prefix=${PREFIX}"
	--disable-sim
	--disable-werror
	--enable-codesign=-
	"--with-gmp=${GMP_PREFIX}"
	"--with-mpfr=${MPFR_PREFIX}"
)

if [ "${RECONFIGURE}" -eq 1 ] || ! config_is_current; then
	if [ -f "${BUILD_DIR}/config.status" ]; then
		note "existing configure results do not match this prefix/source; reconfiguring"
	fi
	step "configuring"
	run mkdir -p -- "${BUILD_DIR}" "${PREFIX}"
	if [ "${GAD_DRY_RUN}" -eq 1 ]; then
		print_command env \
			"CC=/usr/bin/cc" \
			"CXX=/usr/bin/c++" \
			"SDKROOT=${SDK}" \
			"GMPINC=-I${GMP_PREFIX}/include -I${MPFR_PREFIX}/include" \
			"GMPLIBS=-L${GMP_PREFIX}/lib -L${MPFR_PREFIX}/lib -lmpfr -lgmp" \
			"${SOURCE_DIR}/configure" "${CONFIGURE_ARGS[@]}"
	else
		status=0
		(
			cd -- "${BUILD_DIR}"
			env \
				"CC=/usr/bin/cc" \
				"CXX=/usr/bin/c++" \
				"SDKROOT=${SDK}" \
				"GMPINC=-I${GMP_PREFIX}/include -I${MPFR_PREFIX}/include" \
				"GMPLIBS=-L${GMP_PREFIX}/lib -L${MPFR_PREFIX}/lib -lmpfr -lgmp" \
				"${SOURCE_DIR}/configure" "${CONFIGURE_ARGS[@]}"
		) >"${BUILD_DIR}/configure.log" 2>&1 || status=$?
		if [ "${status}" -ne 0 ]; then
			error "configure failed with status ${status}"
			tail -n 40 -- "${BUILD_DIR}/configure.log" >&2 || true
			exit "${status}"
		fi
	fi
	ok "configured"
else
	ok "configure results are current"
fi

# Building the whole gdb target also builds bfd, whose info manual needs
# makeinfo.  Texinfo is not otherwise required, so tell make to skip the
# manual instead of failing the build when it is absent.
MAKE_DOC_ARGS=()
if ! have makeinfo; then
	warn "makeinfo not found; skipping the generated manuals"
	MAKE_DOC_ARGS[${#MAKE_DOC_ARGS[@]}]=MAKEINFO=true
fi

step "building GDB (this takes several minutes)"
if [ "${#MAKE_DOC_ARGS[@]}" -gt 0 ]; then
	run_logged "${BUILD_DIR}/build.log" \
		make -C "${BUILD_DIR}" -j "${JOBS}" "${MAKE_DOC_ARGS[@]}" all-gdb
else
	run_logged "${BUILD_DIR}/build.log" \
		make -C "${BUILD_DIR}" -j "${JOBS}" all-gdb
fi
ok "compiled"

step "installing into ${PREFIX}"
run mkdir -p -- "${PREFIX}"
if [ "${#MAKE_DOC_ARGS[@]}" -gt 0 ]; then
	run_logged "${BUILD_DIR}/install.log" \
		make -C "${BUILD_DIR}" -j "${JOBS}" "${MAKE_DOC_ARGS[@]}" install-gdb
else
	run_logged "${BUILD_DIR}/install.log" \
		make -C "${BUILD_DIR}" -j "${JOBS}" install-gdb
fi

INSTALLED_GDB="${PREFIX}/bin/gdb"
if [ "${GAD_DRY_RUN}" -eq 0 ]; then
	[ -x "${INSTALLED_GDB}" ] || die "installation finished but ${INSTALLED_GDB} is missing"
	[ -d "${PREFIX}/share/gdb" ] || warn "runtime data directory is missing: ${PREFIX}/share/gdb"
fi
ok "installed ${INSTALLED_GDB}"

if [ "${DO_SIGN}" -eq 1 ]; then
	step "signing GDB"
	"${SCRIPT_DIR}/scripts/sign.sh" --gdb "${INSTALLED_GDB}" --identity "${IDENTITY}"
elif [ "${GAD_DRY_RUN}" -eq 0 ]; then
	warn "GDB was not signed; starting an inferior will block in taskgated"
fi

if [ "${DO_VERIFY}" -eq 1 ]; then
	step "verifying the debugger"
	"${SCRIPT_DIR}/scripts/verify.sh" --gdb "${INSTALLED_GDB}" --timeout "${VERIFY_TIMEOUT}"
fi

ELAPSED=$(( $(date +%s) - STARTED_AT ))
printf '\n'
if [ "${GAD_DRY_RUN}" -eq 1 ]; then
	ok "dry run finished in $(format_duration "${ELAPSED}")"
	exit 0
fi

VERSION=$("${INSTALLED_GDB}" --version 2>/dev/null | head -n 1 || true)
ok "build finished in $(format_duration "${ELAPSED}")"
printf '\n  %s\n' "${VERSION}"
printf '  installed at %s\n\n' "${INSTALLED_GDB}"
printf 'Use it with:\n'
printf '  eval "\$(%s/scripts/env.sh)"\n' "${SCRIPT_DIR}"
printf '  gdb ./your-program\n\n'
printf 'Documentation: %s/docs/BUILDING.md\n' "${SCRIPT_DIR}"
