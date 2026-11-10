#!/usr/bin/env bash
#
# Build every third-party library GDB needs, from source, as static archives.
#
# This removes the build-time dependency on Homebrew: a fresh macOS with
# only the command line tools can produce the embedded GDB.  The result is
# staged under .cache/embedded/src, one prefix per library, and is consumed
# by `./build.sh --embedded --from-source`.

set -eu -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

PROG=$(basename -- "$0")
DEPS_PREFIX="${GAD_CACHE_DIR}/embedded/src"
JOBS="${GAD_JOBS:-}"
FORCE=0

usage()
{
	cat <<EOF
Usage: ${PROG} [options]

Download and build, as static archives, everything the embedded GDB links
against: pkgconf, GMP, MPFR, OpenSSL, xz, zstd, libb2, libunistring,
bdw-gc, libltdl and Guile.  CPython is built later by build-embedded.sh.

Nothing outside the macOS command line tools is needed.

Options:
  --prefix DIR   Staging prefix (default: ${DEPS_PREFIX})
  --jobs N       Parallel jobs (default: number of CPUs)
  --force        Rebuild every dependency
  -h, --help     Show this help
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--prefix) need_value "$1" "$#"; DEPS_PREFIX=$2; shift 2 ;;
		--jobs) need_value "$1" "$#"; JOBS=$2; shift 2 ;;
		--force) FORCE=1; shift ;;
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

DEPS_PREFIX=$(abspath "${DEPS_PREFIX}") || die "cannot resolve ${DEPS_PREFIX}"
DL="${DEPS_PREFIX}/downloads"
BUILD="${DEPS_PREFIX}/build"
mkdir -p "${DL}" "${BUILD}"

# Every build uses the system compiler and, for every configure script, the
# pkgconf we build first.
BUILD_ENV_CC=(env CC=/usr/bin/cc CXX=/usr/bin/c++ MAKEINFO=true)

fetch()
{
	local url=$1 sha=$2 file
	file="${DL}/$(basename "${url}")"
	if [ ! -f "${file}" ]; then
		step "downloading $(basename "${url}")"
		curl -fL --retry 2 "${url}" -o "${file}" || die "cannot download ${url}"
	fi
	local actual
	actual=$(shasum -a 256 "${file}" | awk '{ print $1 }')
	[ "${actual}" = "${sha}" ] || die "checksum mismatch for ${file}"
	printf '%s\n' "${file}"
}

# ensure NAME VERSION URL SHA FUNC: skip when the prefix is already built.
ensure()
{
	local name=$1 version=$2 url=$3 sha=$4 func=$5
	local dir="${DEPS_PREFIX}/${name}"
	if [ "${FORCE}" -eq 0 ] && [ -f "${dir}/.built" ]; then
		ok "${name}"
		return
	fi
	step "building ${name} ${version}"
	rm -rf -- "${dir}" "${BUILD}/${name}-${version}"
	local tarball
	tarball=$(fetch "${url}" "${sha}")
	mkdir -p "${BUILD}"
	(cd "${BUILD}" && tar -xf "${tarball}") ||
		die "cannot extract ${tarball}"
	"${func}" "${BUILD}/${name}-${version}" "${dir}"
	touch "${dir}/.built"
	ok "${name}"
}

build_pkgconf()
{
	local src=$1 prefix=$2
	(
		cd "${src}"
		"${BUILD_ENV_CC[@]}" ./configure --prefix="${prefix}" --disable-shared >configure.log 2>&1 ||
			die "pkgconf configure failed"
		make -j "${JOBS}" >>configure.log 2>&1 || die "pkgconf build failed"
		make install >>configure.log 2>&1 || die "pkgconf install failed"
		ln -sf pkgconf "${prefix}/bin/pkg-config"
	)
}

build_gmp()
{
	local src=$1 prefix=$2
	(
		cd "${src}"
		"${BUILD_ENV_CC[@]}" ./configure --prefix="${prefix}" --disable-shared --enable-static \
			--enable-cxx >configure.log 2>&1 || die "gmp configure failed"
		make -j "${JOBS}" >>configure.log 2>&1 || die "gmp build failed"
		make install >>configure.log 2>&1 || die "gmp install failed"
	)
}

build_mpfr()
{
	local src=$1 prefix=$2
	(
		cd "${src}"
		"${BUILD_ENV_CC[@]}" ./configure --prefix="${prefix}" --disable-shared --enable-static \
			--with-gmp="${DEPS_PREFIX}/gmp" >configure.log 2>&1 ||
			die "mpfr configure failed"
		make -j "${JOBS}" >>configure.log 2>&1 || die "mpfr build failed"
		make install >>configure.log 2>&1 || die "mpfr install failed"
	)
}

build_openssl()
{
	local src=$1 prefix=$2
	(
		cd "${src}"
		./Configure darwin64-arm64-cc no-shared no-tests no-docs \
			--prefix="${prefix}" --openssldir="${prefix}/ssl" >configure.log 2>&1 ||
			die "openssl Configure failed"
		make -j "${JOBS}" >>configure.log 2>&1 || die "openssl build failed"
		make install_sw >>configure.log 2>&1 || die "openssl install failed"
	)
}

build_xz()
{
	local src=$1 prefix=$2
	(
		cd "${src}"
		"${BUILD_ENV_CC[@]}" ./configure --prefix="${prefix}" --disable-shared --enable-static \
			--disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
			--disable-scripts --disable-doc >configure.log 2>&1 ||
			die "xz configure failed"
		make -j "${JOBS}" >>configure.log 2>&1 || die "xz build failed"
		make install >>configure.log 2>&1 || die "xz install failed"
	)
}

build_zstd()
{
	local src=$1 prefix=$2
	(
		cd "${src}"
		make -C lib -j "${JOBS}" libzstd.a >build.log 2>&1 || die "zstd build failed"
		mkdir -p "${prefix}/lib" "${prefix}/include"
		cp lib/libzstd.a "${prefix}/lib/"
		cp lib/zstd.h lib/zdict.h "${prefix}/include/" 2>/dev/null || true
	)
}

build_libb2()
{
	local src=$1 prefix=$2
	(
		cd "${src}"
		"${BUILD_ENV_CC[@]}" ./configure --prefix="${prefix}" --disable-shared --enable-static \
			>configure.log 2>&1 || die "libb2 configure failed"
		make -j "${JOBS}" >>configure.log 2>&1 || die "libb2 build failed"
		make install >>configure.log 2>&1 || die "libb2 install failed"
	)
}

build_unistring()
{
	local src=$1 prefix=$2
	(
		cd "${src}"
		"${BUILD_ENV_CC[@]}" am_cv_func_iconv=yes am_cv_lib_iconv=yes \
			am_cv_func_iconv_works=yes LIBICONV=-liconv \
			./configure --prefix="${prefix}" --disable-shared --enable-static \
			>configure.log 2>&1 || die "libunistring configure failed"
		make -j "${JOBS}" >>configure.log 2>&1 || die "libunistring build failed"
		make install >>configure.log 2>&1 || die "libunistring install failed"
	)
}

build_gc()
{
	local src=$1 prefix=$2
	(
		cd "${src}"
		"${BUILD_ENV_CC[@]}" ./configure --prefix="${prefix}" --disable-shared --enable-static \
			--enable-threads=posix --disable-docs >configure.log 2>&1 ||
			die "bdw-gc configure failed"
		make -j "${JOBS}" >>configure.log 2>&1 || die "bdw-gc build failed"
		make install >>configure.log 2>&1 || die "bdw-gc install failed"
	)
}

build_libtool()
{
	local src=$1 prefix=$2
	(
		cd "${src}/libltdl"
		mkdir -p "${prefix}"
		"${BUILD_ENV_CC[@]}" ./configure --prefix="${prefix}" --disable-shared --enable-static \
			--enable-ltdl-install \
			>configure.log 2>&1 || die "libltdl configure failed"
		make -j "${JOBS}" >>configure.log 2>&1 || die "libltdl build failed"
		make install >>configure.log 2>&1 || die "libltdl install failed"
	)
}

build_guile()
{
	local src=$1 prefix=$2
	(
		cd "${src}"
		"${BUILD_ENV_CC[@]}" \
			PKG_CONFIG_PATH="${DEPS_PREFIX}/pkgconf/lib/pkgconfig:${DEPS_PREFIX}/gc/lib/pkgconfig" \
			BDW_GC_CFLAGS="-I${DEPS_PREFIX}/gc/include" \
			BDW_GC_LIBS="-L${DEPS_PREFIX}/gc/lib -lgc" \
			CPPFLAGS="-I$(xcrun --show-sdk-path)/usr/include/ffi" \
			LDFLAGS="-L${DEPS_PREFIX}/gc/lib -L${DEPS_PREFIX}/libtool/lib -framework CoreFoundation" \
			./configure --prefix="${prefix}" --disable-shared --enable-static \
			--with-libunistring-prefix="${DEPS_PREFIX}/libunistring" \
			--with-libgmp-prefix="${DEPS_PREFIX}/gmp" \
			--with-bdw-gc="${DEPS_PREFIX}/gc" \
			--with-libltdl-prefix="${DEPS_PREFIX}/libtool" \
			>configure.log 2>&1 || die "guile configure failed"
		make -j "${JOBS}" >>configure.log 2>&1 || die "guile build failed"
		make install >>configure.log 2>&1 || die "guile install failed"
	)
}

ensure pkgconf 3.0.10 \
	https://distfiles.ariadne.space/pkgconf/pkgconf-3.0.10.tar.xz \
	9371b2f6372da574d4c6dc96fe9b1463037bcf6afcb6671c1555afde7b17e2de \
	build_pkgconf

export PATH="${DEPS_PREFIX}/pkgconf/bin:${PATH}"
export PKG_CONFIG_PATH="${DEPS_PREFIX}/pkgconf/lib/pkgconfig"

ensure gmp 6.3.0 \
	https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz \
	a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898 \
	build_gmp
ensure mpfr 4.2.2 \
	https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.2.tar.xz \
	b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01 \
	build_mpfr
ensure openssl 3.5.9 \
	https://www.openssl.org/source/openssl-3.5.9.tar.gz \
	603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a \
	build_openssl
ensure xz 5.8.4 \
	https://github.com/tukaani-project/xz/releases/download/v5.8.4/xz-5.8.4.tar.gz \
	0014c7886930454fe8bd4228665b51af55eeae560ea135c9c4cd33f55b2591d9 \
	build_xz
ensure zstd 1.5.7 \
	https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz \
	eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3 \
	build_zstd
ensure libb2 0.98.1 \
	https://github.com/BLAKE2/libb2/releases/download/v0.98.1/libb2-0.98.1.tar.gz \
	53626fddce753c454a3fea581cbbc7fe9bbcf0bc70416d48fdbbf5d87ef6c72e \
	build_libb2
ensure libunistring 1.5 \
	https://ftp.gnu.org/gnu/libunistring/libunistring-1.5.tar.xz \
	fe89007a8a414ae4790b816b86859e877d3ab135db3c37f06541ff7e85ac344b \
	build_unistring
ensure gc 8.2.12 \
	https://github.com/ivmai/bdwgc/releases/download/v8.2.12/gc-8.2.12.tar.gz \
	42e5194ad06ab6ffb806c83eb99c03462b495d979cda782f3c72c08af833cd4e \
	build_gc
ensure libtool 2.6.2 \
	https://ftp.gnu.org/gnu/libtool/libtool-2.6.2.tar.xz \
	2ef1067c16c97db930fd740cc9bc3d3ba9a583804ae5ac42cc3e8719e49e191e \
	build_libtool
ensure guile 3.0.11 \
	https://ftp.gnu.org/gnu/guile/guile-3.0.11.tar.xz \
	818c79d236657a7fa96fb364137cc7b41b3bdee0d65c6174ca03769559579460 \
	build_guile

ok "all static dependencies are in ${DEPS_PREFIX}"
