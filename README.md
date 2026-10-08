# asterisk-server (Linux and macOS, amd64 / arm64)

Prebuilt [Asterisk®](https://www.asterisk.org/) for Linux (x86-64, ARM64) and
macOS (Apple Silicon, Intel). Each release archive is a directory tree that
runs from wherever it is extracted: the Asterisk server, its modules, and the
shared libraries the platform does not provide. There is no installer, and
root is not needed.

The archives are built by GitHub Actions from the Asterisk release tarball,
with the scripts in [`build/`](build/). The set of modules is the one the
telephony node of the [Gabion](https://github.com/gabion-dev) framework loads.
Gabion downloads these archives itself; the archives do not need Gabion.

This project is not affiliated with, endorsed by, or sponsored by Sangoma or
the Asterisk project.

## Releases

A release tag is `<asterisk-version>-r<revision>`, for example `22.11.0-r1`:
Asterisk 22.11.0, revision 1 of this recipe for it. Each release has four
archives, each with a `.sha256` file next to it:

- `asterisk-server-linux-amd64.tar.gz` — Linux, x86-64
- `asterisk-server-linux-arm64.tar.gz` — Linux, ARM64
- `asterisk-server-darwin-arm64.tar.gz` — macOS, Apple Silicon
- `asterisk-server-darwin-amd64.tar.gz` — macOS, Intel

A release is published only after all four archives were built and passed the
check described under [Where it has run](#where-it-has-run).

## Download and check

```sh
TAG=22.11.0-r1
ARCHIVE=asterisk-server-linux-amd64.tar.gz
BASE="https://github.com/gabion-dev/asterisk-server/releases/download/${TAG}"
curl -fLO "${BASE}/${ARCHIVE}"
curl -fLO "${BASE}/${ARCHIVE}.sha256"

sha256sum --check "${ARCHIVE}.sha256"         # Linux
shasum -a 256 --check "${ARCHIVE}.sha256"     # macOS

mkdir asterisk-server
tar -xzf "${ARCHIVE}" -C asterisk-server
```

The `.sha256` file holds one line, `<hash>  <archive name>`. It comes from the
same release as the archive, so it detects a damaged download, not a replaced
release.

## What is in an archive

The archive has no top-level directory; extract it into one you create.

```
sbin/asterisk            the server
sbin/                    the other programs Asterisk installs (astcanary,
                         astdb2sqlite3, astgenkey, rasterisk, …)
lib/asterisk/modules/    the modules
lib/                     the bundled shared libraries
var/lib/asterisk/        rest-api/ (the ARI API descriptions), static-http/,
                         images/, scripts/; sounds/, moh/ and the other
                         directories Asterisk creates are empty
var/cache/, var/log/,
var/run/, var/spool/     empty directories
LICENSES/                license texts (see Source and licenses)
BUILD-INFO.txt           how this archive was built
```

**Modules.** The modules listed in
[`build/required-modules.txt`](build/required-modules.txt) plus the platform's
own file —
[`required-modules.linux.txt`](build/required-modules.linux.txt)
(`res_timing_timerfd`) or
[`required-modules.macos.txt`](build/required-modules.macos.txt)
(`res_timing_pthread`) — and the modules they depend on. In `22.11.0-r1` that
is 58 modules: the 56 listed, `res_ari_model` and `res_pjsip_pubsub`. They
cover ARI, WebSocket (`chan_websocket`, `res_websocket_client`), PJSIP, RTP
with SRTP, bridging, the G.711 codecs, and the dialplan applications Dial,
Playback, Record and MixMonitor. Every other module is left out, among them
voicemail (`app_voicemail`), conferencing (`app_confbridge`), queues
(`app_queue`) and every CDR backend.

**Bundled libraries.** The shared libraries the server and its modules need
beyond what the platform provides: on Linux everything except the glibc
family, on macOS OpenSSL, libsrtp and Asterisk's own `libasteriskpj` and
`libasteriskssl`. `BUILD-INFO.txt` records how the archive was built.

**Not included:**

- configuration files — Asterisk reads them from a directory you name (see
  [Run](#run));
- sound prompts and music on hold;
- the Opus codec: `codec_opus` is not part of the Asterisk source tarball.
  RFC 7874 requires WebRTC endpoints to implement both Opus and G.711 (PCMA and
  PCMU), so a browser can also use G.711, which the archive has (`codec_alaw`,
  `codec_ulaw`);
- Asterisk's XML documentation (built with `--disable-xmldoc`).

## Where it has run

"Ran" below means: Asterisk was started from the tree, reported that it had
fully booted, and every module of the required list was `Running` — the check
[`build/verify.sh`](build/verify.sh) makes.

For `22.11.0-r1`:

- **Linux x86-64 and ARM64** — AlmaLinux 9, Ubuntu 22.04, Ubuntu 24.04,
  Debian 12 and Fedora (containers of the stock images, GitHub Actions,
  5 October 2026); Ubuntu 26.04 LTS x86-64 directly on a host, as an
  ordinary user;
- **macOS** — 14.8.9, 15.7.9 and 26.6.2 on Apple Silicon; 15.7.9 and 26.6.1
  on Intel (GitHub Actions, 5 October 2026), as the machine's ordinary user.

**Not built:** Linux with musl libc (Alpine Linux is built around musl),
Windows, BSD.

## Requirements

**Linux.** x86-64 or ARM64 with glibc that provides the symbol version
`GLIBC_2.35`: glibc 2.35 or newer, or the glibc 2.34 of AlmaLinux 9, which
provides it.

**macOS.** Apple Silicon or Intel; the versions it has run on are listed under
[Where it has run](#where-it-has-run).

**Both.** No root and no packages. Use the archive of your machine's
architecture.

## Run

On Linux the server finds its bundled libraries through `LD_LIBRARY_PATH`;
set it for every call of `sbin/asterisk`, including the remote console. On
macOS no variable is needed.

```sh
TREE="$PWD/asterisk-server"         # the extracted archive
export LD_LIBRARY_PATH="$TREE/lib"  # Linux only
"$TREE/sbin/asterisk" -V
```

Asterisk needs an `asterisk.conf` whose `[directories]` section names every
directory it uses — name them all, or a directory left out falls back to a
compiled-in default outside the tree. In the configuration below the tree is
only read, and everything Asterisk writes goes into a directory you choose:

```sh
STATE="$HOME/asterisk-state"        # everything Asterisk writes
mkdir -p "$STATE/etc" "$STATE/db" "$STATE/keys" "$STATE/spool" \
         "$STATE/run" "$STATE/log" "$STATE/cache"
cat > "$STATE/etc/asterisk.conf" <<CONF
[directories]
astetcdir => $STATE/etc
astmoddir => $TREE/lib/asterisk/modules
astvarlibdir => $TREE/var/lib/asterisk
astdatadir => $TREE/var/lib/asterisk
astagidir => $TREE/var/lib/asterisk/agi-bin
astsbindir => $TREE/sbin
astdbdir => $STATE/db
astkeydir => $STATE/keys
astspooldir => $STATE/spool
astrundir => $STATE/run
astlogdir => $STATE/log
astcachedir => $STATE/cache
CONF
```

- `astetcdir` is where Asterisk reads every other configuration file
  (`modules.conf`, `pjsip.conf`, `http.conf`, `ari.conf`, …). None are shipped;
  [`build/verify.sh`](build/verify.sh) writes a minimal set with which Asterisk
  boots with every module running.
- Asterisk appends to some of these paths: the keys go to
  `<astkeydir>/keys`, the database is `<astdbdir>/astdb.sqlite3`.
- Keep the path of `astrundir` short. The control socket `asterisk.ctl` is
  created there, and a Unix socket path is limited to 108 bytes on Linux
  (`unix(7)`) and 104 on macOS (`sys/un.h`); with a longer path the remote
  console cannot connect.

Start the server in the foreground:

```sh
"$TREE/sbin/asterisk" -C "$STATE/etc/asterisk.conf" -f
```

The remote console needs the same `-C`: it finds the control socket through
`astrundir`.

```sh
"$TREE/sbin/asterisk" -C "$STATE/etc/asterisk.conf" -rx "core show settings"
```

## Security updates

Everything in the tree is fixed on the build day. On Linux the bundled system
libraries are copies from AlmaLinux 9 packages, each listed with its package
version in `LICENSES/bundled/PACKAGES.txt`; libsrtp, and on macOS OpenSSL, are
built from pinned source, with their versions in `BUILD-INFO.txt`. Updating
the host does not change them. What the tree takes from the host — glibc on
Linux, the system libraries on macOS — is updated with the host.

A fix in Asterisk or in a bundled library reaches you only through a new
release of this repository: a new revision for the same Asterisk version, or a
new Asterisk version. Releases are listed on the
[releases page](https://github.com/gabion-dev/asterisk-server/releases).

## Build it yourself

Linux (Docker):

```sh
mkdir -p out
docker run --rm -v "$PWD:/src:ro" -v "$PWD/out:/out" almalinux:9 \
  bash /src/build/build.sh 22.11.0 /out
docker run --rm -v "$PWD:/src:ro" -v "$PWD/out:/out:ro" ubuntu:24.04 \
  bash /src/build/verify.sh /out/tree
```

macOS (Xcode command line tools):

```sh
bash build/build-macos.sh 22.11.0 out
bash build/verify.sh out/tree
```

The tree is in `out/tree`. To add a module, add its name to
`build/required-modules.txt` (or to the platform's file) and build again.

## Source and licenses

The archives are built from the Asterisk release tarball at
[downloads.asterisk.org](https://downloads.asterisk.org/pub/telephony/asterisk/releases/),
checked against the checksum published next to it, by the scripts in
[`build/`](build/) at the release tag. `BUILD-INFO.txt` names the tarball and
its SHA-256.

- **Linux:** the Asterisk source is used unmodified.
- **macOS:** two edits to Asterisk's build files (`Makefile`,
  `main/Makefile`) and two added compiler flags,
  `-DTCP_KEEPIDLE=TCP_KEEPALIVE -Wno-macro-redefined`; no C file is edited.
  `BUILD-INFO.txt` lists each of them.

Other sources that go into an archive:

- pjproject 2.17 (`lib/libasteriskpj.*`) and jansson 2.15.1 (linked into
  `sbin/asterisk`) — the versions Asterisk 22.11.0 pins; its build downloads
  them from [asterisk/third-party](https://github.com/asterisk/third-party);
- libsrtp 2.8.1, from [cisco/libsrtp](https://github.com/cisco/libsrtp);
- macOS: OpenSSL 3.5.9, from [openssl/openssl](https://github.com/openssl/openssl);
- Linux: the bundled system libraries, from AlmaLinux 9 binary packages.

This repository is licensed under the [GNU General Public License v2.0](LICENSE).
Asterisk is distributed under the GPL version 2; its `COPYING` and `LICENSE`
are in `LICENSES/` of every archive. Bundled libraries keep their own
licenses.

The Asterisk name and logos are trademarks owned by Sangoma US Inc.
