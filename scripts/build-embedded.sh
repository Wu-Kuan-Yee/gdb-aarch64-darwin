#!/usr/bin/env bash
#
# Build a GDB whose Python and Guile runtimes are linked statically and
# shipped inside the installation prefix.
#
# By default the static archives are taken from Homebrew (fast, but the
# build machine needs it).  With --from-source every dependency is built
# from its pinned upstream tarball instead, so a fresh macOS with only the
# command line tools can produce the same result.

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
FROM_SOURCE=0

CPYTHON_VERSION=3.12.7
CPYTHON_SHA256=73ac8fe780227bf371add8373c3079f42a0dc62deff8d612cd15a618082ab623

usage()
{
	cat <<EOF
Usage: ${PROG} [options]

Build GDB with static Python and Guile, and install their runtime data in
the prefix.  The resulting bin/gdb is a real executable (not a launcher)
and links only against macOS system libraries.

Options:
  --prefix DIR    Installation prefix (default: ${PREFIX})
  --jobs N        Parallel build jobs
  --latest        Build the current upstream master instead of the pin
  --clean         Remove the build directory before configuring
  --from-source   Build every dependency from source instead of using
                  Homebrew archives; only the Xcode command line tools are
                  required
  --dry-run       Print the plan and exit
  -h, --help      Show this help

Dependencies are staged under ${GAD_CACHE_DIR}/embedded and reused on the
next run.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--prefix) need_value "$1" "$#"; PREFIX=$2; shift 2 ;;
		--jobs) need_value "$1" "$#"; JOBS=$2; shift 2 ;;
		--latest) LATEST=1; shift ;;
		--clean) CLEAN=1; shift ;;
		--from-source) FROM_SOURCE=1; shift ;;
		--dry-run) DRY_RUN=1; GAD_DRY_RUN=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1 (try --help)" ;;
	esac
done

require_macos
require_arm64
require_cmd curl
require_cmd shasum
require_cmd tar
require_cmd make

[ -z "${JOBS}" ] && JOBS=$(default_jobs)
case "${JOBS}" in ''|*[!0-9]*) die "--jobs expects a positive integer" ;; esac

PREFIX=$(abspath "${PREFIX}") || die "cannot resolve ${PREFIX}"
WORK="${GAD_CACHE_DIR}/embedded"
DEPS="${GAD_CACHE_DIR}/deps"
SRC="${WORK}/src"

info "prefix:  ${PREFIX}"
info "staging: ${WORK}"
info "mode:    $([ "${FROM_SOURCE}" -eq 1 ] && echo 'from source' || echo 'Homebrew archives')"

if [ "${DRY_RUN}" -eq 1 ]; then
	info "would prepare the static dependencies"
	info "would build CPython ${CPYTHON_VERSION}"
	info "would build GDB, install it and bundle the runtimes"
	exit 0
fi

mkdir -p "${WORK}"

formula_prefix()
{
	local formula=$1 prefix
	prefix=$(brew_prefix "${formula}")
	if [ -z "${prefix}" ]; then
		prefix=$(brew --prefix "${formula}" 2>/dev/null || true)
	fi
	printf '%s\n' "${prefix}"
}

# Render the guile-3.0.pc that GDB's configure reads.  The archive and
# include directories differ between the two modes; everything else is the
# same.
write_guile_pc()
{
	local libs=$1 cflags=$2 guild=$3
	mkdir -p "${WORK}/pc"
	cat > "${WORK}/pc/guile-3.0.pc" <<PC
prefix=${WORK}/guile
libdir=\${prefix}/lib
includedir=\${prefix}/include
guild=${guild}
Name: GNU Guile
Description: GNU's Ubiquitous Intelligent Language for Extension (static)
Version: 3.0.11
Libs: ${libs}
Cflags: ${cflags}
PC
}

write_zstd_pc()
{
	local prefix=$1
	mkdir -p "${WORK}/pc"
	cat > "${WORK}/pc/libzstd.pc" <<PC
prefix=${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: zstd
Description: fast lossless compression (static)
Version: 1.5.7
Libs: -L\${libdir} -lzstd
Cflags: -I\${includedir}
PC
}

if [ "${FROM_SOURCE}" -eq 1 ]; then
	"${SCRIPT_DIR}/build-deps-source.sh" --prefix "${SRC}" --jobs "${JOBS}" ||
		die "cannot build the static dependencies from source"

	PC_BIN="${SRC}/pkgconf/bin/pkg-config"
	[ -x "${PC_BIN}" ] || die "pkgconf was not built"
	export PATH="${SRC}/pkgconf/bin:${PATH}"

	GMP_PREFIX="${SRC}/gmp"
	MPFR_PREFIX="${SRC}/mpfr"
	OPENSSL_PREFIX="${SRC}/openssl"
	XZ_PREFIX="${SRC}/xz"
	LIBB2_PREFIX="${SRC}/libb2"
	ZSTD_PREFIX="${SRC}/zstd"
	GU="${SRC}/guile"
	GUILD="${GU}/bin/guild"
	GU_SHARE="${GU}/share/guile"
	GU_CCACHE="${GU}/lib/guile/3.0/ccache"

	# One private prefix for GDB's pkg-config: headers and the archives the
	# static Guile needs, so nothing points back at the build tree.
	STAGE_GU="${WORK}/guile"
	step "staging the Guile link prefix"
	rm -rf -- "${STAGE_GU}"
	mkdir -p "${STAGE_GU}/lib" "${STAGE_GU}/include"
	cp -R "${GU}/include/guile/3.0" "${STAGE_GU}/include/guile-3.0"
	cp -R "${SRC}/gc/include/gc" "${STAGE_GU}/include/" 2>/dev/null || true
	cp -p "${GU}/lib/libguile-3.0.a" "${STAGE_GU}/lib/" ||
		die "libguile-3.0.a missing from the source build"
	cp -p "${SRC}/gc/lib/libgc.a" "${STAGE_GU}/lib/" ||
		die "libgc.a missing"
	cp -p "${SRC}/libunistring/lib/libunistring.a" "${STAGE_GU}/lib/" ||
		die "libunistring.a missing"
	cp -p "${SRC}/libtool/lib/libltdl.a" "${STAGE_GU}/lib/" ||
		die "libltdl.a missing"
	cp -p "${SRC}/gmp/lib/libgmp.a" "${STAGE_GU}/lib/"
	cp -p "${SRC}/gmp/include/gmp.h" "${STAGE_GU}/include/"
	cp -p "${SRC}/gc/include/gc.h" "${STAGE_GU}/include/" 2>/dev/null || true
	write_guile_pc \
		"-L${STAGE_GU}/lib -lguile-3.0 -lgc -lunistring -lltdl -lgmp -lffi -liconv -lm -framework CoreFoundation" \
		"-I${STAGE_GU}/include/guile-3.0 -I${STAGE_GU}/include -D_THREAD_SAFE" \
		"${GUILD}"
	write_zstd_pc "${ZSTD_PREFIX}"
else
	require_cmd brew "install Homebrew, or pass --from-source"

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

	"${SCRIPT_DIR}/build-deps.sh" --prefix "${DEPS}" >/dev/null ||
		die "cannot stage static GMP/MPFR"
	GMP_PREFIX="${DEPS}/gmp"
	MPFR_PREFIX="${DEPS}/mpfr"
	PC_BIN=$(command -v pkg-config || true)
	[ -n "${PC_BIN}" ] || die "pkg-config not found; install it or use --from-source"

	O=$(formula_prefix openssl@3)
	[ -n "${O}" ] || die "openssl@3 is required; install it with: brew install openssl@3"
	if [ ! -f "${WORK}/openssl/lib/libssl.a" ]; then
		step "staging static OpenSSL"
		mkdir -p "${WORK}/openssl/include" "${WORK}/openssl/lib"
		cp -R "${O}/include/openssl" "${WORK}/openssl/include/"
		cp -p "${O}/lib/libssl.a" "${O}/lib/libcrypto.a" "${WORK}/openssl/lib/"
	fi
	OPENSSL_PREFIX="${WORK}/openssl"

	stage_static xz "$(formula_prefix xz)" lzma.h liblzma.a
	cp -R "$(formula_prefix xz)/include/lzma" "${WORK}/xz/include/" 2>/dev/null || true
	XZ_PREFIX="${WORK}/xz"

	stage_static libb2 "$(formula_prefix libb2)" blake2.h libb2.a
	LIBB2_PREFIX="${WORK}/libb2"
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
	ZSTD_PREFIX="${WORK}/zstd"
	write_zstd_pc "${ZSTD_PREFIX}"

	GUILD=$(command -v guild || true)
	[ -n "${GUILD}" ] || die "guild not found; install guile with: brew install guile"
	GU="${WORK}/guile"
	if [ ! -f "${GU}/lib/libguile-3.0.a" ]; then
		step "staging static Guile"
		mkdir -p "${GU}/include" "${GU}/lib"
		cp -R "$(formula_prefix guile)/include/guile/3.0" "${GU}/include/guile-3.0" ||
			die "cannot copy Guile headers"
		cp -p "$(formula_prefix guile)/lib/libguile-3.0.a" "${GU}/lib/" ||
			die "libguile-3.0.a not found; Homebrew guile ships a dylib only?"
		cp -p "$(formula_prefix bdw-gc)/lib/libgc.a" "${GU}/lib/"
		cp -p "$(formula_prefix libunistring)/lib/libunistring.a" "${GU}/lib/"
		cp -p "$(formula_prefix libtool)/lib/libltdl.a" "${GU}/lib/"
		cp -p "${GMP_PREFIX}/lib/libgmp.a" "${GU}/lib/"
		cp -p "${GMP_PREFIX}/include/gmp.h" "${GU}/include/"
		cp -R "$(formula_prefix bdw-gc)/include/gc" "${GU}/include/" 2>/dev/null || true
	fi
	write_guile_pc \
		"-L${GU}/lib -lguile-3.0 -lgc -lunistring -lltdl -lgmp -lffi -liconv -lm -framework CoreFoundation" \
		"-I${GU}/include/guile-3.0 -I${GU}/include -D_THREAD_SAFE" \
		"${GUILD}"
	GU_SHARE="$(formula_prefix guile)/share/guile"
	CELLAR=$(brew --cellar guile 2>/dev/null || true)
	GU_CCACHE=$(ls -d "${CELLAR}"/*/lib/guile/3.0/ccache 2>/dev/null | head -1)
	[ -n "${GU_CCACHE}" ] || GU_CCACHE="$(formula_prefix guile)/lib/guile/3.0/ccache"
fi

# A static CPython; Homebrew only provides a dylib.  The interpreter is
# rebuilt when the dependency mode changes, since its extension modules
# embed the OpenSSL/xz/libb2 they were linked against.
PY="${WORK}/python"
if [ "${FROM_SOURCE}" -eq 1 ]; then
	PY_MODE="source:${OPENSSL_PREFIX}"
else
	PY_MODE="brew:${OPENSSL_PREFIX}"
fi
if [ -f "${PY}/lib/libpython3.12.a" ] &&
	[ "$(cat "${PY}/.deps-mode" 2>/dev/null)" != "${PY_MODE}" ]; then
	step "dependency mode changed; rebuilding CPython"
	rm -rf -- "${PY}" "${WORK}/Python-${CPYTHON_VERSION}"
fi
if [ ! -f "${PY}/lib/libpython3.12.a" ]; then
	SRC_PY="${WORK}/Python-${CPYTHON_VERSION}"
	TARBALL="${WORK}/Python-${CPYTHON_VERSION}.tgz"
	if [ ! -f "${TARBALL}" ]; then
		step "downloading Python ${CPYTHON_VERSION}"
		curl -fL --retry 2 "https://www.python.org/ftp/python/${CPYTHON_VERSION}/Python-${CPYTHON_VERSION}.tgz" \
			-o "${TARBALL}" || die "cannot download Python ${CPYTHON_VERSION}"
	fi
	HASH=$(shasum -a 256 "${TARBALL}" | awk '{ print $1 }')
	[ "${HASH}" = "${CPYTHON_SHA256}" ] ||
		die "checksum mismatch for ${TARBALL}: ${HASH}"

	step "building CPython ${CPYTHON_VERSION} (static)"
	rm -rf -- "${SRC_PY}"
	tar -xzf "${TARBALL}" -C "${WORK}"
	(
		cd -- "${SRC_PY}"
		env PKG_CONFIG_LIBDIR=/usr/lib/pkgconfig \
			CPPFLAGS="-I${OPENSSL_PREFIX}/include -I${XZ_PREFIX}/include -I${LIBB2_PREFIX}/include" \
			LDFLAGS="-L${OPENSSL_PREFIX}/lib -L${XZ_PREFIX}/lib -L${LIBB2_PREFIX}/lib" \
			./configure --prefix="${PY}" --disable-shared --without-ensurepip \
				--with-openssl="${OPENSSL_PREFIX}" >configure.log 2>&1 ||
			die "CPython configure failed; see ${SRC_PY}/configure.log"
		make -j "${JOBS}" >build.log 2>&1 ||
			die "CPython build failed; see ${SRC_PY}/build.log"
		make install >>build.log 2>&1 ||
			die "CPython install failed; see ${SRC_PY}/build.log"
	)
fi
[ -f "${PY}/lib/libpython3.12.a" ] || die "static libpython was not produced"
printf '%s\n' "${PY_MODE}" > "${PY}/.deps-mode"

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
	GAD_GMP_PREFIX="${GMP_PREFIX}" \
	GAD_MPFR_PREFIX="${MPFR_PREFIX}" \
	PKG_CONFIG="${PC_BIN}" \
	PKG_CONFIG_PATH="${WORK}/pc" \
	PKG_CONFIG_LIBDIR="${WORK}/pc:/usr/lib/pkgconfig" \
	PYTHONHOME="${PY}" \
	CPPFLAGS="-include ${WORK}/embedded-root.h -I${XZ_PREFIX}/include -I${ZSTD_PREFIX}/include" \
	LDFLAGS="-Wl,-export_dynamic -L${XZ_PREFIX}/lib -L${ZSTD_PREFIX}/lib" \
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
cp -R "${GU_SHARE}/3.0" "${PREFIX}/share/guile/3.0"
[ -d "${GU_CCACHE}" ] || die "cannot find Guile's compiled cache (${GU_CCACHE})"
mkdir -p "${PREFIX}/lib/guile/3.0"
rm -rf -- "${PREFIX}/lib/guile/3.0/ccache"
cp -R "${GU_CCACHE}" "${PREFIX}/lib/guile/3.0/ccache"

step "verifying the embedded build"
"${SCRIPT_DIR}/verify.sh" --gdb "${PREFIX}/bin/gdb" --timeout 180

printf '\n'
ok "embedded build installed in ${PREFIX}"
printf '  python: %s (bundled in lib/python3.12)\n' \
	"$("${PREFIX}/bin/gdb" --batch -nx -q -ex 'python import sys; print(sys.version.split()[0])' 2>/dev/null | tail -1)"
