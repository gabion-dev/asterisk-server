#!/usr/bin/env bash
# build/verify.sh
#
# Proves that a built tree works on a host with nothing installed: starts
# Asterisk from it with every module of the tree, as a node starts it, waits
# until it is fully booted, and requires every module of the tree to be
# running and every required module to be among them. A tree that merely
# exists, or a binary that only prints its version, is not accepted — a
# module whose shared library is missing fails at load time, not at build
# time.
#
#   build/verify.sh <tree-dir>
#
# Runs on Linux and on macOS; written for the bash 3.2 that macOS ships.
#
# The runtime directory written here is also the reference for how a tree is
# started from any location: every path Asterisk uses is given in
# asterisk.conf. On Linux the bundled libraries are found through
# LD_LIBRARY_PATH; on macOS the tree finds them by itself, relative to the
# executable.
set -euo pipefail

TREE="$(cd "${1:?usage: verify.sh <tree-dir>}" && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$(uname -s)" in
  Linux) PLATFORM=linux ;;
  Darwin) PLATFORM=macos ;;
  *) echo "ERROR: unsupported platform $(uname -s)" >&2; exit 1 ;;
esac

required_modules() {
  cat "${HERE}/required-modules.txt" "${HERE}/required-modules.${PLATFORM}.txt" \
    | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'
}

# Every module of the tree, from its build record — the list a node loads.
# The required modules alone are not enough to start: with autoload off,
# Asterisk loads no module that is not listed, the modules they depend on
# included, and a module whose dependency is not loaded declines.
tree_modules() {
  sed -n '/^modules:$/,$p' "${TREE}/BUILD-INFO.txt" | sed -n 's/^  \(.*\)\.so$/\1/p'
}

RUNTIME="$(mktemp -d)"
ETC="${RUNTIME}/etc"
mkdir -p "${ETC}" "${RUNTIME}/db" "${RUNTIME}/keys" "${RUNTIME}/spool" \
  "${RUNTIME}/run" "${RUNTIME}/log"

ASTERISK="${TREE}/sbin/asterisk"
if [ "${PLATFORM}" = linux ]; then
  export LD_LIBRARY_PATH="${TREE}/lib"
fi

echo "=== Version ==="
"${ASTERISK}" -V

if [ "${PLATFORM}" = linux ]; then
  echo "=== Shared libraries resolve on this host ==="
  ELF_FILES=()
  while IFS= read -r file; do
    ELF_FILES+=("${file}")
  done < <(
    find "${TREE}/sbin" "${TREE}/lib" -type f \
      \( -name 'asterisk' -o -name '*.so' -o -name '*.so.*' \)
  )
  LDD_OUTPUT="$(ldd "${ELF_FILES[@]}" 2>&1 || true)"
  if grep -q 'not found' <<<"${LDD_OUTPUT}"; then
    echo "ERROR: unresolved shared libraries on this host:" >&2
    grep -B1 'not found' <<<"${LDD_OUTPUT}" >&2 || true
    exit 1
  fi
fi

echo "=== Runtime configuration ==="
cat > "${ETC}/asterisk.conf" <<CONF
[directories]
astetcdir => ${ETC}
astmoddir => ${TREE}/lib/asterisk/modules
astvarlibdir => ${TREE}/var/lib/asterisk
astdatadir => ${TREE}/var/lib/asterisk
astagidir => ${TREE}/var/lib/asterisk/agi-bin
astsbindir => ${TREE}/sbin
astdbdir => ${RUNTIME}/db
astkeydir => ${RUNTIME}/keys
astspooldir => ${RUNTIME}/spool
astrundir => ${RUNTIME}/run
astlogdir => ${RUNTIME}/log
CONF

{
  echo "[modules]"
  echo "autoload = no"
  while read -r module; do
    echo "load = ${module}.so"
  done < <(tree_modules)
} > "${ETC}/modules.conf"

cat > "${ETC}/logger.conf" <<'CONF'
[general]
[logfiles]
console => notice,warning,error
CONF

cat > "${ETC}/http.conf" <<'CONF'
[general]
enabled = yes
bindaddr = 127.0.0.1
bindport = 18088
CONF

cat > "${ETC}/ari.conf" <<'CONF'
[general]
enabled = yes

[verify]
type = user
read_only = no
password = verify
CONF

cat > "${ETC}/pjsip.conf" <<'CONF'
[transport-ws]
type = transport
protocol = ws
bind = 127.0.0.1
CONF

cat > "${ETC}/extensions.conf" <<'CONF'
[default]
CONF

: > "${ETC}/websocket_client.conf"

# The module of call records (cdr_csv) loads only with its section holding
# at least one setting; without it the module declines and is not running.
cat > "${ETC}/cdr.conf" <<'CONF'
[csv]
usegmtime = yes
CONF

echo "=== Start ==="
"${ASTERISK}" -C "${ETC}/asterisk.conf" -f > "${RUNTIME}/log/console.log" 2>&1 &
ASTERISK_PID=$!

fail() {
  echo "ERROR: $1" >&2
  echo "--- console log ---" >&2
  cat "${RUNTIME}/log/console.log" >&2 || true
  kill "${ASTERISK_PID}" 2>/dev/null || true
  exit 1
}

# The gate has two outcomes and no clock: Asterisk says it has fully
# booted, or the process is gone. "core waitfullybooted" blocks until the
# boot has finished; the loop covers the moment before the control socket
# exists. The verdict is read from the answer, not from the exit code: the
# remote console exits with success even when Asterisk dies mid-boot and
# drops the connection.
until "${ASTERISK}" -C "${ETC}/asterisk.conf" -rx "core waitfullybooted" \
  2> /dev/null | grep -q "fully booted"; do
  if ! kill -0 "${ASTERISK_PID}" 2>/dev/null; then
    fail "Asterisk exited before it finished booting"
  fi
  sleep 0.2
done

echo "=== Every module of the tree is running ==="
MODULE_TABLE="$("${ASTERISK}" -C "${ETC}/asterisk.conf" -rx "module show")" \
  || fail "Asterisk stopped answering after it reported a finished boot"
# A module that declined to load is listed with the status "Not Running",
# which contains "Running": the status is judged by its whole words.
not_running=0
while read -r module; do
  line="$(grep -E "^${module}\.so[[:space:]]" <<<"${MODULE_TABLE}" || true)"
  if [ -z "${line}" ] \
    || grep -q "[[:space:]]Not Running[[:space:]]" <<<"${line}" \
    || ! grep -q "[[:space:]]Running[[:space:]]" <<<"${line}"; then
    echo "NOT RUNNING: ${module}" >&2
    not_running=1
  fi
done < <(tree_modules)
TREE_MODULES="$(tree_modules)"
while read -r module; do
  if ! grep -qx "${module}" <<<"${TREE_MODULES}"; then
    echo "NOT IN THE TREE: ${module}" >&2
    not_running=1
  fi
done < <(required_modules)
if [ "${not_running}" -ne 0 ]; then
  echo "--- module table ---" >&2
  echo "${MODULE_TABLE}" >&2
  fail "modules of the tree are not running, or required ones are missing"
fi
echo "${MODULE_TABLE}" | tail -n 1

echo "=== Stop ==="
"${ASTERISK}" -C "${ETC}/asterisk.conf" -rx "core stop now" > /dev/null 2>&1 || true
wait "${ASTERISK_PID}" || true
rm -rf "${RUNTIME}"

echo "OK: Asterisk booted from ${TREE} with every module of the tree running"
