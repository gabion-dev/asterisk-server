#!/usr/bin/env bash
# build/build.sh
#
# Builds Asterisk for Linux into a relocatable tree that carries every shared
# library it needs except the glibc family. Runs as root inside an AlmaLinux 9
# container; the workflow and a local run call it the same way (the macOS
# counterpart is build-macos.sh):
#
#   build/build.sh <asterisk-version> <output-dir>
#
# Result: <output-dir>/tree — the tree that goes into the release archive;
# <output-dir>/sources — the source of everything in the tree, published
# next to the archives.
set -euo pipefail
# A failing command inside $(…) stops the build too, not only the command
# around it.
shopt -s inherit_errexit

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
SOURCES="${OUT}/sources"
# The Asterisk build downloads pjproject and jansson itself, into this
# directory; the tarballs are recorded and shipped from here.
EXTERNALS="${WORK}/externals"

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
LIBSRTP_TARBALL="libsrtp-${LIBSRTP_VERSION}.tar.gz"
LIBSRTP_PREFIX=/opt/libsrtp

required_modules() {
  cat "${REQUIRED_MODULES_FILES[@]}" \
    | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'
}

# Every ELF file of the tree, one per line.
elf_files() {
  find "${TREE}/sbin" "${TREE}/lib" -type f \
    \( -name 'asterisk' -o -name '*.so' -o -name '*.so.*' \)
}

# The license files an installed package ships, one per line.
package_license_files() {
  rpm -q --licensefiles "$1" | while IFS= read -r file; do
    if [ -f "${file}" ]; then
      echo "${file}"
    fi
  done
}

# Copies the license texts of a bundled system package into the tree and
# prints what PACKAGES.txt should add about where they came from. A package
# that ships no texts takes them from an installed package built from the
# same source package: the texts cover the whole source package, and the
# distribution puts them into one of its binary packages (libstdc++ has
# them in libgcc, ncurses-libs in ncurses-base). A package with no text
# anywhere is accepted only when it is in the public domain — there is no
# text to ship. Anything else stops the build: it could not be attributed.
bundle_license_texts() {
  local package="$1" source_package texts from sibling
  from="${package}"
  texts="$(package_license_files "${package}")"
  if [ -z "${texts}" ]; then
    source_package="$(rpm -q --queryformat '%{SOURCERPM}' "${package}")"
    while read -r sibling; do
      texts="$(package_license_files "${sibling}")"
      if [ -n "${texts}" ]; then
        from="${sibling}"
        break
      fi
    done < <(
      rpm -qa --queryformat '%{NAME} %{SOURCERPM}\n' \
        | awk -v source="${source_package}" '$2 == source {print $1}' | sort
    )
  fi
  if [ -z "${texts}" ]; then
    if [ "$(rpm -q --queryformat '%{LICENSE}' "${package}")" = "Public Domain" ]; then
      echo "; public domain, no license text"
      return
    fi
    echo "ERROR: no license text for ${package} or its source package" >&2
    exit 1
  fi
  mkdir -p "${TREE}/LICENSES/bundled/${package}"
  while IFS= read -r file; do
    cp "${file}" "${TREE}/LICENSES/bundled/${package}/"
  done <<<"${texts}"
  if [ "${from}" != "${package}" ]; then
    echo "; license texts from ${from}, built from the same source package"
  fi
}

echo "=== Build dependencies ==="
# The container image is as old as its last rebuild; upgrading it first makes
# the bundled libraries those of the build day, and makes every installed
# package one the repositories still offer — its source package is
# downloaded by exact version below.
dnf -y upgrade
dnf -y install dnf-plugins-core
dnf config-manager --set-enabled crb
dnf -y install \
  gcc gcc-c++ make patch bzip2 xz tar gzip wget file findutils diffutils which \
  pkgconf-pkg-config \
  libedit-devel libuuid-devel libxml2-devel sqlite-devel openssl-devel

rm -rf "${WORK}" "${SOURCES}"
mkdir -p "${WORK}" "${EXTERNALS}" "${SOURCES}"

echo "=== libsrtp ${LIBSRTP_VERSION} (OpenSSL backend) ==="
cd "${WORK}"
wget --no-verbose -O "${LIBSRTP_TARBALL}" "${LIBSRTP_URL}"
echo "${LIBSRTP_SHA256}  ${LIBSRTP_TARBALL}" | sha256sum --check
tar -xzf "${LIBSRTP_TARBALL}"
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
# The versions of pjproject and jansson this Asterisk release pins; the file
# is written to be read by the shell.
# shellcheck source=/dev/null
. third-party/versions.mak

echo "=== Configure ==="
# pjproject and jansson are built from the versions Asterisk pins, so the SIP
# stack matches what this Asterisk release was tested with. The XML
# documentation is not built: nothing reads it on a node.
#
# --disable-rpath: with a prefix other than /usr, configure writes the
# library directory of the prefix into every binary it links, as DT_RPATH.
# The loader searches DT_RPATH before LD_LIBRARY_PATH, so on a host where
# that directory exists the tree would load the libraries found there. The
# tree finds its libraries through LD_LIBRARY_PATH only; a guard below stops
# the build if any search path is left in a file.
./configure \
  --prefix="${PREFIX}" \
  --with-pjproject-bundled \
  --with-jansson-bundled \
  --with-srtp="${LIBSRTP_PREFIX}" \
  --with-externals-cache="${EXTERNALS}" \
  --disable-rpath \
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

PJPROJECT_TARBALL="pjproject-${PJPROJECT_VERSION}.tar.bz2"
JANSSON_TARBALL="jansson-${JANSSON_VERSION}.tar.bz2"
for tarball in "${PJPROJECT_TARBALL}" "${JANSSON_TARBALL}"; do
  if [ ! -f "${EXTERNALS}/${tarball}" ]; then
    echo "ERROR: the Asterisk build did not leave ${tarball} in ${EXTERNALS}" >&2
    echo "Its source could not be recorded and shipped." >&2
    exit 1
  fi
done

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
#
# Asterisk's own libasteriskpj and libasteriskssl are already in the tree;
# pjproject and jansson are recorded below, with the Asterisk source.
mkdir -p "${TREE}/LICENSES/bundled"
: > "${TREE}/LICENSES/bundled/PACKAGES.txt"
: > "${WORK}/bundled-packages.txt"
export LD_LIBRARY_PATH="${TREE}/lib:${LIBSRTP_PREFIX}/lib"
mapfile -t ELF_FILES < <(elf_files)
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
          # version and license, and with the license texts. A library no
          # package owns stops the build: it could not be attributed.
          pkg="$(rpm -qf --queryformat '%{NAME}' "${real}")"
          note="$(bundle_license_texts "${pkg}")"
          echo "${base}: $(rpm -q --queryformat '%{NAME} %{VERSION}-%{RELEASE} (%{LICENSE})' "${pkg}")${note}" \
            >> "${TREE}/LICENSES/bundled/PACKAGES.txt"
          rpm -q "${pkg}" >> "${WORK}/bundled-packages.txt"
          ;;
      esac
      ;;
  esac
done
unset LD_LIBRARY_PATH

echo "=== Guard: no library search path is written into the tree ==="
# The tree finds its libraries through LD_LIBRARY_PATH only. A DT_RPATH or
# DT_RUNPATH left in any file — Asterisk's own or a bundled one — names a
# directory that the loader searches on every host where it exists.
search_paths=0
while IFS= read -r file; do
  if readelf -d "${file}" | grep -E '\((RPATH|RUNPATH)\)'; then
    echo "ERROR: ${file} carries a library search path" >&2
    search_paths=1
  fi
done < <(elf_files)
if [ "${search_paths}" -ne 0 ]; then
  exit 1
fi

echo "=== Strip debug information ==="
elf_files | xargs strip --strip-unneeded

# The newest glibc symbol version any file of the tree requires: the real
# floor for a host. It is read from the files (readelf -V), not from the
# glibc of the build system — a bundled library can require a newer one than
# the build system's version number suggests (the glibc 2.34 of AlmaLinux 9
# provides some 2.35 symbols).
GLIBC_REQUIRED="$(
  elf_files | xargs readelf -V --wide \
    | grep -oE 'Name: GLIBC_[0-9]+(\.[0-9]+)+' | awk '{print $2}' \
    | sort -V | tail -n 1
)"
if [ -z "${GLIBC_REQUIRED}" ]; then
  echo "ERROR: no glibc symbol version found in the tree" >&2
  exit 1
fi

echo "=== Sources ==="
# The source of everything in the tree goes out with the archives: Asterisk,
# the pjproject and jansson it bundles, libsrtp, and the source package of
# every bundled system library — downloaded by exact version from the
# distribution's source repositories.
cp "${WORK}/${TARBALL}" "${WORK}/${LIBSRTP_TARBALL}" "${SOURCES}/"
cp "${EXTERNALS}/${PJPROJECT_TARBALL}" "${EXTERNALS}/${JANSSON_TARBALL}" "${SOURCES}/"
mapfile -t BUNDLED_PACKAGES < <(sort -u "${WORK}/bundled-packages.txt")
dnf download --source --destdir "${SOURCES}" "${BUNDLED_PACKAGES[@]}"
for package in "${BUNDLED_PACKAGES[@]}"; do
  source_package="$(rpm -q --queryformat '%{SOURCERPM}' "${package}")"
  if [ ! -f "${SOURCES}/${source_package}" ]; then
    echo "ERROR: source package ${source_package} of ${package} was not downloaded" >&2
    exit 1
  fi
done

echo "=== Licenses and build record ==="
cp COPYING "${TREE}/LICENSES/asterisk-COPYING"
cp LICENSE "${TREE}/LICENSES/asterisk-LICENSE"
mkdir -p "${TREE}/LICENSES/bundled/pjproject" "${TREE}/LICENSES/bundled/jansson"
cp third-party/pjproject/source/COPYING "${TREE}/LICENSES/bundled/pjproject/"
cp third-party/jansson/source/LICENSE "${TREE}/LICENSES/bundled/jansson/"
PJPROJECT_LIBRARY="$(cd "${TREE}/lib" && ls libasteriskpj.so.*)"
{
  echo "${PJPROJECT_LIBRARY}: pjproject ${PJPROJECT_VERSION} (GPL-2.0-or-later), bundled by Asterisk"
  echo "asterisk: jansson ${JANSSON_VERSION} (MIT), bundled by Asterisk and linked statically"
} >> "${TREE}/LICENSES/bundled/PACKAGES.txt"
sha256_of() {
  sha256sum "$1" | cut -d' ' -f1
}
{
  echo "asterisk-version: ${ASTERISK_VERSION}"
  echo "source: ${DOWNLOAD_BASE}/${TARBALL}"
  echo "source-sha256: $(sha256_of "${WORK}/${TARBALL}")"
  echo "pjproject-version: ${PJPROJECT_VERSION} (bundled by Asterisk)"
  echo "pjproject-sha256: $(sha256_of "${EXTERNALS}/${PJPROJECT_TARBALL}")"
  echo "jansson-version: ${JANSSON_VERSION} (bundled by Asterisk)"
  echo "jansson-sha256: $(sha256_of "${EXTERNALS}/${JANSSON_TARBALL}")"
  echo "libsrtp-version: ${LIBSRTP_VERSION} (OpenSSL backend)"
  echo "libsrtp-sha256: ${LIBSRTP_SHA256}"
  echo "built-on: $(. /etc/os-release && echo "${PRETTY_NAME}")"
  echo "built-on-glibc: $(ldd --version | head -n1 | awk '{print $NF}')"
  echo "requires-glibc-symbol-version: ${GLIBC_REQUIRED}"
  echo "architecture: $(uname -m)"
  echo "modules:"
  find "${MODULES_DIR}" -name '*.so' -printf '  %f\n' | sort
} > "${TREE}/BUILD-INFO.txt"

echo "=== Done ==="
du -sh "${TREE}" "${SOURCES}"
