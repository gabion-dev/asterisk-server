#!/bin/bash
# build/build-macos.sh
#
# Builds Asterisk for macOS into a relocatable tree that carries the shared
# libraries macOS itself does not provide. Runs on a macOS machine with the
# Xcode command line tools, as an ordinary user:
#
#   build/build-macos.sh <asterisk-version> <output-dir>
#
# Result: <output-dir>/tree — the tree that goes into the release archive.
#
# Written for the bash 3.2 that macOS ships. The Linux counterpart is
# build.sh; the two differ where the platforms differ:
#
#   - What the host provides. macOS always has libxml2, SQLite, libedit, zlib
#     and the UUID functions in the system, so they are linked from there and
#     not bundled. It has no OpenSSL, so OpenSSL is built here from pinned
#     source — which also keeps the result independent of Homebrew.
#   - How libraries are found. There is no LD_LIBRARY_PATH equivalent that
#     survives every way a process is started on macOS, so the tree is made
#     self-locating: every reference to a bundled library is rewritten to be
#     relative to the executable.
#   - Signing. Apple Silicon refuses to run code whose signature does not
#     match its contents, and rewriting a reference changes the contents, so
#     every binary is re-signed (ad hoc) at the end.
set -euo pipefail

ASTERISK_VERSION="${1:?usage: build-macos.sh <asterisk-version> <output-dir>}"
OUT="${2:?usage: build-macos.sh <asterisk-version> <output-dir>}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "${OUT}"
OUT="$(cd "${OUT}" && pwd)"

# The oldest macOS the tree runs on. Everything that is not part of macOS is
# compiled here with this target, so nothing in the tree demands the OS
# version of the build machine.
export MACOSX_DEPLOYMENT_TARGET="13.0"

# Compile-time prefix of Asterisk. Nothing is ever installed there: the
# install goes into a staging directory, and the tree is relocatable.
PREFIX=/opt/asterisk-server
WORK="$(mktemp -d)"
DEPS="${WORK}/deps"
STAGE="${WORK}/stage"
TREE="${OUT}/tree"
CPUS="$(sysctl -n hw.ncpu)"

DOWNLOAD_BASE="https://downloads.asterisk.org/pub/telephony/asterisk/releases"
TARBALL="asterisk-${ASTERISK_VERSION}.tar.gz"

# OpenSSL: the long-term-support line. Version and checksum are pinned; a new
# OpenSSL is a deliberate edit of these two lines.
OPENSSL_VERSION="3.5.9"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"

# libsrtp encrypts the audio of browser calls; the same pinned version as in
# the Linux build, built against the OpenSSL above.
LIBSRTP_VERSION="2.8.1"
LIBSRTP_SHA256="ef5569220749529d778013aae1178391d972570a2b4f7288dda22effa875b07c"
LIBSRTP_URL="https://github.com/cisco/libsrtp/archive/refs/tags/v${LIBSRTP_VERSION}.tar.gz"

case "$(uname -m)" in
  arm64) OPENSSL_TARGET="darwin64-arm64-cc" ;;
  x86_64) OPENSSL_TARGET="darwin64-x86_64-cc" ;;
  *) echo "ERROR: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

required_modules() {
  cat "${HERE}/required-modules.txt" "${HERE}/required-modules.macos.txt" \
    | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'
}

# Download a file and stop the build if it is not the pinned one.
fetch_pinned() {
  local url="$1" file="$2" sha256="$3"
  curl --fail --silent --show-error --location --output "${file}" "${url}"
  echo "${sha256}  ${file}" | shasum -a 256 --check
}

# Replace a fixed string in a file and stop if it was not there: an edit that
# silently matches nothing would leave the build believing it was applied.
replace_or_fail() {
  local file="$1" from="$2" to="$3"
  if ! grep -qF -- "${from}" "${file}"; then
    echo "ERROR: expected text not found in ${file}: ${from}" >&2
    echo "The Asterisk build files changed in this version; review the edit." >&2
    exit 1
  fi
  FROM="${from}" TO="${to}" perl -0pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "${file}"
}

echo "=== OpenSSL ${OPENSSL_VERSION} ==="
cd "${WORK}"
fetch_pinned "${OPENSSL_URL}" "openssl-${OPENSSL_VERSION}.tar.gz" "${OPENSSL_SHA256}"
tar -xzf "openssl-${OPENSSL_VERSION}.tar.gz"
(
  cd "openssl-${OPENSSL_VERSION}"
  ./Configure "${OPENSSL_TARGET}" shared no-tests \
    --prefix="${DEPS}" --openssldir="${DEPS}/ssl"
  make -j"${CPUS}"
  make install_sw
)

echo "=== libsrtp ${LIBSRTP_VERSION} (OpenSSL backend) ==="
cd "${WORK}"
fetch_pinned "${LIBSRTP_URL}" "libsrtp-${LIBSRTP_VERSION}.tar.gz" "${LIBSRTP_SHA256}"
tar -xzf "libsrtp-${LIBSRTP_VERSION}.tar.gz"
(
  cd "libsrtp-${LIBSRTP_VERSION}"
  ./configure --prefix="${DEPS}" --enable-openssl --with-openssl-dir="${DEPS}"
  make -j"${CPUS}" shared_library
  make install
)

echo "=== Source ==="
cd "${WORK}"
curl --fail --silent --show-error --location --remote-name "${DOWNLOAD_BASE}/${TARBALL}"
curl --fail --silent --show-error --location --remote-name \
  "${DOWNLOAD_BASE}/asterisk-${ASTERISK_VERSION}.sha256"
# The published checksum file names the tarball; a mismatch stops the build.
shasum -a 256 --check "asterisk-${ASTERISK_VERSION}.sha256"
tar -xzf "${TARBALL}"
cd "asterisk-${ASTERISK_VERSION}"

echo "=== Build-file edits for current macOS ==="
# The only changes made to the Asterisk source tree, both in build files and
# both about one compiler flag: Asterisk asks for macOS 10.6 as the oldest
# supported system, a target the current toolchain no longer accepts as
# written. It is replaced with the deployment target of this build.
replace_or_fail Makefile \
  "-mmacosx-version-min=10.6" "-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
replace_or_fail main/Makefile \
  "-mmacosx-version-min=10.6" "-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"

echo "=== Configure ==="
# The bundled OpenSSL and libsrtp are named explicitly so that nothing is
# picked up from Homebrew or any other location on the build machine.
export PKG_CONFIG_PATH="${DEPS}/lib/pkgconfig"
./configure \
  --prefix="${PREFIX}" \
  --with-pjproject-bundled \
  --with-jansson-bundled \
  --with-ssl="${DEPS}" \
  --with-crypto="${DEPS}" \
  --with-srtp="${DEPS}" \
  --disable-xmldoc \
  CC=clang CXX=clang++ \
  CFLAGS="-I${DEPS}/include" \
  LDFLAGS="-L${DEPS}/lib"

echo "=== Module selection ==="
make menuselect.makeopts
# BUILD_NATIVE tunes the code for the CPU of the build machine. Sound packs
# and music are not shipped: prompts come from the application.
MENUSELECT_ARGS=(
  --disable BUILD_NATIVE
  --disable-category MENUSELECT_CORE_SOUNDS
  --disable-category MENUSELECT_EXTRA_SOUNDS
  --disable-category MENUSELECT_MOH
  --disable-category MENUSELECT_ADDONS
)
while read -r module; do
  MENUSELECT_ARGS+=(--enable "${module}")
done < <(required_modules)
menuselect/menuselect "${MENUSELECT_ARGS[@]}" menuselect.makeopts

echo "=== Compile ==="
make -j"${CPUS}"
make install DESTDIR="${STAGE}"

echo "=== Assemble the tree ==="
rm -rf "${TREE}"
mkdir -p "${TREE}"
cp -a "${STAGE}${PREFIX}/sbin" "${TREE}/sbin"
cp -a "${STAGE}${PREFIX}/lib" "${TREE}/lib"
cp -a "${STAGE}${PREFIX}/var" "${TREE}/var"
# The libraries built above, with their version links.
cp -a "${DEPS}"/lib/libssl*.dylib "${DEPS}"/lib/libcrypto*.dylib \
  "${DEPS}"/lib/libsrtp2*.dylib "${TREE}/lib/"

MODULES_DIR="${TREE}/lib/asterisk/modules"

echo "=== Guard: every required module was built ==="
missing=0
while read -r module; do
  if [ ! -f "${MODULES_DIR}/${module}.so" ]; then
    echo "ERROR: required module not built: ${module}" >&2
    missing=1
  fi
done < <(required_modules)
if [ "${missing}" -ne 0 ]; then
  echo "A missing module means a build dependency is absent or the module was" >&2
  echo "renamed in this Asterisk version — the node would start without it." >&2
  exit 1
fi

# Every Mach-O file of the tree, one per line. Symbolic links are skipped:
# they point at files that are listed themselves.
macho_files() {
  find "${TREE}/sbin" "${TREE}/lib" -type f | while IFS= read -r file; do
    if file -b "${file}" | grep -q 'Mach-O'; then
      echo "${file}"
    fi
  done
}

echo "=== Strip debug information ==="
macho_files | while IFS= read -r file; do
  chmod u+w "${file}"
  strip -x "${file}"
done

echo "=== Make the tree self-locating ==="
# Each reference to a library that lives in a build directory is rewritten to
# @rpath/<name>; the executable gets one search path, relative to itself.
# Modules are loaded by the executable and inherit that path.
macho_files | while IFS= read -r file; do
  case "${file}" in
    *.dylib) install_name_tool -id "@rpath/$(basename "${file}")" "${file}" ;;
  esac
  otool -L "${file}" | tail -n +2 | awk '{print $1}' | while IFS= read -r dep; do
    case "${dep}" in
      "${DEPS}"/*|"${PREFIX}"/*|"${STAGE}"/*)
        install_name_tool -change "${dep}" "@rpath/$(basename "${dep}")" "${file}"
        ;;
    esac
  done
done
install_name_tool -add_rpath "@executable_path/../lib" "${TREE}/sbin/asterisk"

echo "=== Guard: nothing references a path outside the tree and macOS ==="
# After the rewrite a binary may reference only the tree (@rpath) and what
# every macOS has (/usr/lib, /System). Anything else is a path that exists on
# the build machine and nowhere else.
foreign=0
while IFS= read -r file; do
  while IFS= read -r dep; do
    case "${dep}" in
      @rpath/*|@executable_path/*|@loader_path/*|/usr/lib/*|/System/*) ;;
      *)
        echo "ERROR: ${file} references ${dep}" >&2
        foreign=1
        ;;
    esac
  done < <(otool -L "${file}" | tail -n +2 | awk '{print $1}')
done < <(macho_files)
if [ "${foreign}" -ne 0 ]; then
  exit 1
fi

echo "=== Sign ==="
macho_files | while IFS= read -r file; do
  codesign --force --sign - "${file}"
done

echo "=== Licenses and build record ==="
mkdir -p "${TREE}/LICENSES/bundled/openssl" "${TREE}/LICENSES/bundled/libsrtp"
cp COPYING "${TREE}/LICENSES/asterisk-COPYING"
cp LICENSE "${TREE}/LICENSES/asterisk-LICENSE"
cp "${WORK}/openssl-${OPENSSL_VERSION}/LICENSE.txt" "${TREE}/LICENSES/bundled/openssl/"
cp "${WORK}/libsrtp-${LIBSRTP_VERSION}/LICENSE" "${TREE}/LICENSES/bundled/libsrtp/"
{
  echo "libssl, libcrypto: OpenSSL ${OPENSSL_VERSION} (Apache-2.0), built from ${OPENSSL_URL}"
  echo "libsrtp2: libsrtp ${LIBSRTP_VERSION} (BSD-3-Clause), built from ${LIBSRTP_URL}"
} > "${TREE}/LICENSES/bundled/PACKAGES.txt"
{
  echo "asterisk-version: ${ASTERISK_VERSION}"
  echo "source: ${DOWNLOAD_BASE}/${TARBALL}"
  echo "source-sha256: $(shasum -a 256 "${WORK}/${TARBALL}" | cut -d' ' -f1)"
  echo "source-edits: -mmacosx-version-min=10.6 replaced with ${MACOSX_DEPLOYMENT_TARGET} in Makefile and main/Makefile"
  echo "openssl-version: ${OPENSSL_VERSION}"
  echo "libsrtp-version: ${LIBSRTP_VERSION} (OpenSSL backend)"
  echo "built-on: macOS $(sw_vers -productVersion)"
  echo "macos-floor: ${MACOSX_DEPLOYMENT_TARGET}"
  echo "architecture: $(uname -m)"
  echo "modules:"
  find "${MODULES_DIR}" -name '*.so' | sed 's|.*/|  |' | sort
} > "${TREE}/BUILD-INFO.txt"

echo "=== Done ==="
du -sh "${TREE}"
