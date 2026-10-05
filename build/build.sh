#!/usr/bin/env bash
# build/build.sh
#
# Builds Asterisk for Linux into a relocatable tree that carries every shared
# library it needs except the glibc family. Runs as root inside the
# glibc-floor container (AlmaLinux 9); the workflow and a local run call it
# the same way (the macOS counterpart is build-macos.sh):
#
#   build/build.sh <asterisk-version> <output-dir>
#
# Result: <output-dir>/tree — the tree that goes into the release archive.
set -euo pipefail

ASTERISK_VERSION="${1:?usage: build.sh <asterisk-version> <output-dir>}"
OUT="${2:?usage: build.sh <asterisk-version> <output-dir>}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUIRED_MODULES_FILES=(
  "${HERE}/required-modules.txt"
  "${HERE}/required-modules.linux.txt"
)

# Compile-time prefix. The tree is relocatable regardless of it: every
# directory Asterisk uses is set at start through asterisk.conf, and the
# bundled libraries are found through LD_LIBRARY_PATH.
PREFIX=/opt/asterisk-server
WORK=/tmp/asterisk-build
STAGE="${WORK}/stage"
TREE="${OUT}/tree"

DOWNLOAD_BASE="https://downloads.asterisk.org/pub/telephony/asterisk/releases"
TARBALL="asterisk-${ASTERISK_VERSION}.tar.gz"

# libsrtp encrypts the audio of browser calls. It is built here instead of
# taken from the base system: the system package uses NSS for its ciphers,
# and NSS loads its cipher modules at run time by name — a dependency no
# link-time inspection sees, so the library fails to initialize on a clean
# host. Built against OpenSSL it needs only libcrypto, which the tree
# already carries. The version and checksum are pinned; a new libsrtp is a
# deliberate edit of these two lines.
LIBSRTP_VERSION="2.8.1"
LIBSRTP_SHA256="ef5569220749529d778013aae1178391d972570a2b4f7288dda22effa875b07c"
LIBSRTP_URL="https://github.com/cisco/libsrtp/archive/refs/tags/v${LIBSRTP_VERSION}.tar.gz"
LIBSRTP_PREFIX=/opt/libsrtp

required_modules() {
  cat "${REQUIRED_MODULES_FILES[@]}" \
    | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'
}

echo "=== Build dependencies ==="
dnf -y install dnf-plugins-core
dnf config-manager --set-enabled crb
dnf -y install \
  gcc gcc-c++ make patch bzip2 xz tar gzip wget file findutils diffutils which \
  pkgconf-pkg-config \
  libedit-devel libuuid-devel libxml2-devel sqlite-devel openssl-devel

rm -rf "${WORK}"
mkdir -p "${WORK}"

echo "=== libsrtp ${LIBSRTP_VERSION} (OpenSSL backend) ==="
cd "${WORK}"
wget --no-verbose -O "libsrtp-${LIBSRTP_VERSION}.tar.gz" "${LIBSRTP_URL}"
echo "${LIBSRTP_SHA256}  libsrtp-${LIBSRTP_VERSION}.tar.gz" | sha256sum --check
tar -xzf "libsrtp-${LIBSRTP_VERSION}.tar.gz"
(
  cd "libsrtp-${LIBSRTP_VERSION}"
  ./configure --prefix="${LIBSRTP_PREFIX}" --enable-openssl
  make -j"$(nproc)" shared_library
  make install
)

echo "=== Source ==="
cd "${WORK}"
wget --no-verbose "${DOWNLOAD_BASE}/${TARBALL}"
wget --no-verbose "${DOWNLOAD_BASE}/asterisk-${ASTERISK_VERSION}.sha256"
# The published checksum file names the tarball; a mismatch stops the build.
sha256sum --check "asterisk-${ASTERISK_VERSION}.sha256"
tar -xzf "${TARBALL}"
cd "asterisk-${ASTERISK_VERSION}"

echo "=== Configure ==="
# pjproject and jansson are built from the versions Asterisk pins, so the SIP
# stack matches what this Asterisk release was tested with. The XML
# documentation is not built: nothing reads it on a node.
./configure \
  --prefix="${PREFIX}" \
  --with-pjproject-bundled \
  --with-jansson-bundled \
  --with-srtp="${LIBSRTP_PREFIX}" \
  --disable-xmldoc

echo "=== Module selection ==="
make menuselect.makeopts
# Only the required modules are built, together with whatever they depend on
# (menuselect enables the dependencies of a module it is told to enable).
# Building everything that happens to compile would put unused code on a
# node that faces the network, and on macOS it would also make the build
# hostage to modules nobody maintains for that platform.
#
# So: every module category is switched off, then the required list is
# switched on. BUILD_NATIVE tunes the code for the CPU of the build machine
# and would crash on an older one. Sound packs and music are not shipped:
# prompts come from the application.
MENUSELECT_ARGS=(--disable BUILD_NATIVE)
for category in \
  MENUSELECT_ADDONS MENUSELECT_APPS MENUSELECT_BRIDGES MENUSELECT_CDR \
  MENUSELECT_CEL MENUSELECT_CHANNELS MENUSELECT_CODECS MENUSELECT_FORMATS \
  MENUSELECT_FUNCS MENUSELECT_PBX MENUSELECT_RES MENUSELECT_TESTS \
  MENUSELECT_AGIS MENUSELECT_CORE_SOUNDS MENUSELECT_EXTRA_SOUNDS \
  MENUSELECT_MOH; do
  MENUSELECT_ARGS+=(--disable-category "${category}")
done
while read -r module; do
  MENUSELECT_ARGS+=(--enable "${module}")
done < <(required_modules)
# menuselect always writes menuselect.makeopts in the current directory; the
# argument names the existing selection it starts from.
menuselect/menuselect "${MENUSELECT_ARGS[@]}" menuselect.makeopts

echo "=== Compile ==="
make -j"$(nproc)"
rm -rf "${STAGE}"
make install DESTDIR="${STAGE}"

echo "=== Assemble the tree ==="
rm -rf "${TREE}"
mkdir -p "${TREE}"
cp -a "${STAGE}${PREFIX}/sbin" "${TREE}/sbin"
cp -a "${STAGE}${PREFIX}/lib" "${TREE}/lib"
cp -a "${STAGE}${PREFIX}/var" "${TREE}/var"

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

echo "=== Bundle shared libraries ==="
# Everything the binary and the modules link against, except the glibc
# family: glibc is the floor the host provides, and mixing a bundled glibc
# with the host loader does not work. The libraries come from the supported
# base system of this container, so they carry its security patches as of
# the build day.
mkdir -p "${TREE}/LICENSES/bundled"
: > "${TREE}/LICENSES/bundled/PACKAGES.txt"
export LD_LIBRARY_PATH="${TREE}/lib:${LIBSRTP_PREFIX}/lib"
mapfile -t ELF_FILES < <(
  find "${TREE}/sbin" "${TREE}/lib" -type f \
    \( -name 'asterisk' -o -name '*.so' -o -name '*.so.*' \)
)
LDD_OUTPUT="$(ldd "${ELF_FILES[@]}" 2>&1 || true)"
if grep -q 'not found' <<<"${LDD_OUTPUT}"; then
  echo "ERROR: unresolved shared libraries:" >&2
  grep -B1 'not found' <<<"${LDD_OUTPUT}" >&2 || true
  exit 1
fi
awk '/=> \// {print $3}' <<<"${LDD_OUTPUT}" | sort -u | while read -r lib; do
  case "${lib}" in
    "${TREE}"/*) continue ;;
  esac
  base="$(basename "${lib}")"
  case "${base}" in
    ld-linux*|ld64*|libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|librt.so.*|libresolv.so.*|libnsl.so.*|libutil.so.*|libanl.so.*)
      echo "skip floor : ${base}" ;;
    *)
      cp -L "${lib}" "${TREE}/lib/"
      echo "bundle     : ${base}"
      real="$(readlink -f "${lib}")"
      case "${real}" in
        "${LIBSRTP_PREFIX}"/*)
          # Built above from pinned source, not from a system package.
          echo "${base}: libsrtp ${LIBSRTP_VERSION} (BSD-3-Clause), built from ${LIBSRTP_URL}" \
            >> "${TREE}/LICENSES/bundled/PACKAGES.txt"
          mkdir -p "${TREE}/LICENSES/bundled/libsrtp"
          cp "${WORK}/libsrtp-${LIBSRTP_VERSION}/LICENSE" "${TREE}/LICENSES/bundled/libsrtp/"
          ;;
        *)
          # Every bundled system library is recorded with its package,
          # version and license; license texts are copied where the package
          # ships them. A library no package owns stops the build: it could
          # not be attributed.
          pkg="$(rpm -qf --queryformat '%{NAME}' "${real}")"
          echo "${base}: $(rpm -q --queryformat '%{NAME} %{VERSION}-%{RELEASE} (%{LICENSE})' "${pkg}")" \
            >> "${TREE}/LICENSES/bundled/PACKAGES.txt"
          while read -r license_file; do
            [ -f "${license_file}" ] || continue
            mkdir -p "${TREE}/LICENSES/bundled/${pkg}"
            cp "${license_file}" "${TREE}/LICENSES/bundled/${pkg}/"
          done < <(rpm -q --licensefiles "${pkg}")
          ;;
      esac
      ;;
  esac
done
unset LD_LIBRARY_PATH

echo "=== Strip debug information ==="
find "${TREE}/sbin" "${TREE}/lib" -type f \
  \( -name 'asterisk' -o -name '*.so' -o -name '*.so.*' \) \
  -exec strip --strip-unneeded {} +

echo "=== Licenses and build record ==="
cp COPYING "${TREE}/LICENSES/asterisk-COPYING"
cp LICENSE "${TREE}/LICENSES/asterisk-LICENSE"
{
  echo "asterisk-version: ${ASTERISK_VERSION}"
  echo "source: ${DOWNLOAD_BASE}/${TARBALL}"
  echo "source-sha256: $(sha256sum "${WORK}/${TARBALL}" | cut -d' ' -f1)"
  echo "libsrtp-version: ${LIBSRTP_VERSION} (OpenSSL backend)"
  echo "built-on: $(. /etc/os-release && echo "${PRETTY_NAME}")"
  echo "glibc-floor: $(ldd --version | head -n1 | awk '{print $NF}')"
  echo "architecture: $(uname -m)"
  echo "modules:"
  find "${MODULES_DIR}" -name '*.so' -printf '  %f\n' | sort
} > "${TREE}/BUILD-INFO.txt"

echo "=== Done ==="
du -sh "${TREE}"
