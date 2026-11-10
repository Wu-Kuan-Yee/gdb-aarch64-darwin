#!/usr/bin/env bash
#
# Build a GDB whose Python and Guile runtimes are linked statically and
# shipped inside the installation prefix.
#
# The result needs nothing outside /usr/lib and /System at run time: the
# interpreters are static archives, their data directories live in the
# prefix, and GDB finds them through GDB_EMBEDDED_ROOT (see patch 0012).

set -eu -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

PROG=$(basename -- "$0")
PREFIX=${GAD_PREFIX}
JOBS=${GAD_JOBS:-}
LATEST=0
CLEAN=0
DRY_RUN=0

CPYTHON_VERSION=3.12.7
CPYTHON_SHA256=73ac8fe780227bf371add8373c3079f42a0dc62deff8d612cd15a618082ab623

usage()
{
	cat <<EOF
Usage: ${PROG} [options]

Build GDB with static Python and Guile, and install their runtime data in
the prefix.  The resulting bin/gdb is a real executable (not a launcher)
and links only against macOS system libraries.

This mode needs Homebrew for the static archives it cannot build itself:
openssl@3, xz, libb2, zstd and guile (with bdw-gc, libunistring, libtool).
CPython is built from the pinned upstream tarball.

Options:
  --prefix DIR   Installation prefix (default: ${PREFIX})
  --jobs N       Parallel build jobs
  --latest       Build the current upstream master instead of the pin
  --clean        Remove the build directory before configuring
  --dry-run      Print the plan and exit
  -h, --help     Show this help

The build is staged under ${GAD_CACHE_DIR}/embedded and can be reused by
running the script again.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--prefix) need_value "$1" "$#"; PREFIX=$2; shift 2 ;;
		--jobs) need_value "$1" "$#"; JOBS=$2; shift 2 ;;
		--latest) LATEST=1; shift ;;
		--clean) CLEAN=1; shift ;;
		--dry-run) DRY_RUN=1; GAD_DRY_RUN=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1 (try --help)" ;;
	esac
done

require_macos
require_arm64
require_cmd brew "install Homebrew from https://brew.sh"
require_cmd curl
require_cmd shasum
require_cmd tar

[ -z "${JOBS}" ] && JOBS=$(default_jobs)
case "${JOBS}" in ''|*[!0-9]*) die "--jobs expects a positive integer" ;; esac

PREFIX=$(abspath "${PREFIX}") || die "cannot resolve ${PREFIX}"
WORK="${GAD_CACHE_DIR}/embedded"
DEPS="${GAD_CACHE_DIR}/deps"

info "prefix:  ${PREFIX}"
info "staging: ${WORK}"

if [ "${DRY_RUN}" -eq 1 ]; then
	info "would stage static libraries under ${WORK}"
	info "would build CPython ${CPYTHON_VERSION} under ${WORK}/python"
	info "would build GDB and install it into ${PREFIX}"
	info "would copy the Python standard library and Guile Scheme sources"
	exit 0
fi

mkdir -p "${WORK}" "${DEPS}"

# brew_prefix already falls back to the standard Homebrew prefixes for gmp
# and mpfr; use it for everything this mode needs.
formula_prefix()
{
	local formula=$1 prefix
	prefix=$(brew_prefix "${formula}")
	if [ -z "${prefix}" ]; then
		prefix=$(brew --prefix "${formula}" 2>/dev/null || true)
	fi
	[ -n "${prefix}" ] ||
		die "${formula} is required; install it with: brew install ${formula}"
	printf '%s\n' "${prefix}"
}

stage_static()
{
	local name=$1 prefix=$2 header=$3 archive=$4
	local dir="${WORK}/${name}"
	if [ -f "${dir}/lib/${archive}" ] && [ -f "${dir}/include/${header}" ]; then
		return
	fi
	step "staging static ${name}"
	mkdir -p "${dir}/include" "${dir}/lib"
	cp -p "${prefix}/include/${header}" "${dir}/include/" ||
		die "cannot copy ${prefix}/include/${header}"
	cp -p "${prefix}/lib/${archive}" "${dir}/lib/" ||
		die "cannot copy ${prefix}/lib/${archive} (is the static archive installed?)"
}

# Static GMP is needed by Guile as well as by GDB.
"${SCRIPT_DIR}/build-deps.sh" --prefix "${DEPS}" >/dev/null ||
	die "cannot stage static GMP/MPFR"

O=$(formula_prefix openssl@3)
if [ ! -f "${WORK}/openssl/lib/libssl.a" ]; then
	step "staging static OpenSSL"
	mkdir -p "${WORK}/openssl/include" "${WORK}/openssl/lib"
	cp -R "${O}/include/openssl" "${WORK}/openssl/include/"
	cp -p "${O}/lib/libssl.a" "${O}/lib/libcrypto.a" "${WORK}/openssl/lib/"
fi
stage_static xz "$(formula_prefix xz)" lzma.h liblzma.a
cp -R "$(formula_prefix xz)/include/lzma" "${WORK}/xz/include/" 2>/dev/null || true
stage_static libb2 "$(formula_prefix libb2)" blake2.h libb2.a
mkdir -p "${WORK}/libb2/lib/pkgconfig"
cat > "${WORK}/libb2/lib/pkgconfig/libb2.pc" <<PC
prefix=${WORK}/libb2
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: libb2
Description: BLAKE2 (static)
Version: 0.98.1
Libs: -L\${libdir} -lb2
Cflags: -I\${includedir}
PC
stage_static zstd "$(formula_prefix zstd)" zstd.h libzstd.a

# Guile and the libraries its static archive calls at link time.
GUILD=$(command -v guild || true)
[ -n "${GUILD}" ] || die "guild not found; install guile with: brew install guile"
GU=${WORK}/guile
if [ ! -f "${GU}/lib/libguile-3.0.a" ]; then
	step "staging static Guile"
	mkdir -p "${GU}/include" "${GU}/lib" "${GU}/lib/pkgconfig"
	cp -R "$(formula_prefix guile)/include/guile/3.0" "${GU}/include/guile-3.0" ||
		die "cannot copy Guile headers"
	cp -p "$(formula_prefix guile)/lib/libguile-3.0.a" "${GU}/lib/" ||
		die "libguile-3.0.a not found; Homebrew guile now ships a dylib only?"
	cp -p "$(formula_prefix bdw-gc)/lib/libgc.a" "${GU}/lib/"
	cp -p "$(formula_prefix libunistring)/lib/libunistring.a" "${GU}/lib/"
	cp -p "$(formula_prefix libtool)/lib/libltdl.a" "${GU}/lib/"
	cp -p "${DEPS}/gmp/lib/libgmp.a" "${GU}/lib/"
	cp -p "${DEPS}/gmp/include/gmp.h" "${GU}/include/"
	cp -R "$(formula_prefix bdw-gc)/include/gc" "${GU}/include/" 2>/dev/null || true
	cat > "${GU}/lib/pkgconfig/guile-3.0.pc" <<PC
prefix=${GU}
libdir=\${prefix}/lib
includedir=\${prefix}/include
guild=${GUILD}
Name: GNU Guile
Description: GNU's Ubiquitous Intelligent Language for Extension (static)
Version: 3.0.11
Libs: -L\${libdir} -lguile-3.0 -lgc -lunistring -lltdl -lgmp -lffi -liconv -lm -framework CoreFoundation
Cflags: -I\${includedir}/guile-3.0 -I\${includedir} -D_THREAD_SAFE
PC
fi

# zstd pkg-config for GDB itself.
ZS=${WORK}/zstd
mkdir -p "${ZS}/lib/pkgconfig"
cat > "${ZS}/lib/pkgconfig/libzstd.pc" <<PC
prefix=${ZS}
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: zstd
Description: fast lossless compression (static)
Version: 1.5.7
Libs: -L\${libdir} -lzstd
Cflags: -I\${includedir}
PC

# A static CPython; Homebrew only provides a dylib.
PY=${WORK}/python
if [ ! -f "${PY}/lib/libpython${CPYTHON_VERSION%.*}.a" ]; then
	SRC=${WORK}/Python-${CPYTHON_VERSION}
	TARBALL=${WORK}/Python-${CPYTHON_VERSION}.tgz
	if [ ! -f "${TARBALL}" ]; then
		step "downloading Python ${CPYTHON_VERSION}"
		curl -fL --retry 2 "https://www.python.org/ftp/python/${CPYTHON_VERSION}/Python-${CPYTHON_VERSION}.tgz" \
			-o "${TARBALL}" || die "cannot download Python ${CPYTHON_VERSION}"
	fi
	HASH=$(shasum -a 256 "${TARBALL}" | awk '{ print $1 }')
	[ "${HASH}" = "${CPYTHON_SHA256}" ] ||
		die "checksum mismatch for ${TARBALL}: ${HASH}"

	step "building CPython ${CPYTHON_VERSION} (static)"
	rm -rf -- "${SRC}"
	tar -xzf "${TARBALL}" -C "${WORK}"
	(
		cd -- "${SRC}"
		env PKG_CONFIG_LIBDIR=/usr/lib/pkgconfig \
			CPPFLAGS="-I${WORK}/openssl/include -I${WORK}/xz/include -I${WORK}/libb2/include" \
			LDFLAGS="-L${WORK}/openssl/lib -L${WORK}/xz/lib -L${WORK}/libb2/lib" \
			./configure --prefix="${PY}" --disable-shared --without-ensurepip \
				--with-openssl="${WORK}/openssl" >configure.log 2>&1 ||
			die "CPython configure failed; see ${SRC}/configure.log"
		make -j "${JOBS}" >build.log 2>&1 ||
			die "CPython build failed; see ${SRC}/build.log"
		make install >>build.log 2>&1 ||
			die "CPython install failed; see ${SRC}/build.log"
	)
fi

LIBPY=$(ls "${PY}"/lib/libpython3.12.a 2>/dev/null | head -1)
[ -n "${LIBPY}" ] || die "static libpython was not produced"

cat > "${WORK}/embedded-root.h" <<EOF
/* Generated by build-embedded.sh: installation root of the bundled runtimes. */
#define GDB_EMBEDDED_ROOT "${PREFIX}"
EOF

step "building GDB with static Python and Guile"
BUILD_ARGS=(--prefix "${PREFIX}" --jobs "${JOBS}" --no-verify)
[ "${LATEST}" -eq 1 ] && BUILD_ARGS[${#BUILD_ARGS[@]}]=--latest
[ "${CLEAN}" -eq 1 ] && BUILD_ARGS[${#BUILD_ARGS[@]}]=--clean

env \
	GAD_PYTHON="${PY}/bin/python3.12" \
	GAD_GMP_PREFIX="${DEPS}/gmp" \
	GAD_MPFR_PREFIX="${DEPS}/mpfr" \
	PKG_CONFIG_PATH="${GU}/lib/pkgconfig:${ZS}/lib/pkgconfig" \
	PKG_CONFIG_LIBDIR="${GU}/lib/pkgconfig:${ZS}/lib/pkgconfig:/usr/lib/pkgconfig" \
	PYTHONHOME="${PY}" \
	CPPFLAGS="-include ${WORK}/embedded-root.h -I${WORK}/xz/include -I${WORK}/zstd/include" \
	LDFLAGS="-Wl,-export_dynamic -L${WORK}/xz/lib -L${WORK}/zstd/lib" \
	"${SCRIPT_DIR}/../build.sh" "${BUILD_ARGS[@]}" ||
	die "the GDB build failed"

step "installing the embedded runtimes"
rm -rf -- "${PREFIX:?}/lib/python3.12"
mkdir -p "${PREFIX}/lib"
cp -R "${PY}/lib/python3.12" "${PREFIX}/lib/python3.12"
rm -rf -- "${PREFIX}/lib/python3.12/test" \
	"${PREFIX}/lib/python3.12/idlelib" \
	"${PREFIX}/lib/python3.12/tkinter" \
	"${PREFIX}/lib/python3.12/turtledemo" \
	"${PREFIX}/lib/python3.12/ensurepip" \
	"${PREFIX}/lib/python3.12/lib2to3" \
	"${PREFIX}/lib/python3.12/pydoc_data" \
	"${PREFIX}"/lib/python3.12/config-3.12-darwin
rm -f "${PREFIX}"/lib/python3.12/lib-dynload/_tkinter*.so
mkdir -p "${PREFIX}/share/guile"
rm -rf -- "${PREFIX}/share/guile/3.0"
cp -R "$(formula_prefix guile)/share/guile/3.0" "${PREFIX}/share/guile/3.0"

# Guile's compiler is written in Scheme and bootstraps from a compiled
# cache.  Without one, every module would be recompiled (and the compiler
# itself cannot start), so ship the cache that was built with this Guile.
CELLAR=$(brew --cellar guile 2>/dev/null || true)
CCACHE=$(ls -d "${CELLAR}"/*/lib/guile/3.0/ccache 2>/dev/null | head -1)
[ -n "${CCACHE}" ] || CCACHE=$(ls -d "$(formula_prefix guile)"/lib/guile/3.0/ccache 2>/dev/null | head -1)
[ -n "${CCACHE}" ] || die "cannot find Guile's compiled cache (ccache)"
mkdir -p "${PREFIX}/lib/guile/3.0"
rm -rf -- "${PREFIX}/lib/guile/3.0/ccache"
cp -R "${CCACHE}" "${PREFIX}/lib/guile/3.0/ccache"

step "verifying the embedded build"
"${SCRIPT_DIR}/verify.sh" --gdb "${PREFIX}/bin/gdb" --timeout 180

printf '\n'
ok "embedded build installed in ${PREFIX}"
printf '  python: %s (bundled in lib/python3.12)\n' "$("${PREFIX}/bin/gdb" --batch -nx -q -ex 'python import sys; print(sys.version.split()[0])' 2>/dev/null | tail -1)"
