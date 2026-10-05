# asterisk-server (Linux and macOS, amd64 / arm64)

Relocatable builds of the [Asterisk](https://www.asterisk.org/) telephony
server for Linux and macOS: the server, its modules, and every shared library
they need that the platform itself does not provide — so Asterisk runs from
any directory on a clean host, with no root and nothing installed.

## What this solves

Asterisk is distributed as source. Distribution packages lag behind (the
features these builds exist for arrived in 22.6 and 22.8), install into system
directories, and need root; for macOS there are no packages at all. This
repository builds one tree per platform and architecture that:

- runs **from any location** — every directory Asterisk uses is given at
  start through `asterisk.conf`, and the tree finds its own libraries;
- carries **its own libraries** — on Linux everything but glibc (OpenSSL,
  libsrtp, libxml2, SQLite and the rest), on macOS everything macOS does not
  ship (OpenSSL and libsrtp);
- is the **same artifact** for a development machine and for a telephony node.

The builds exist for the [Gabion](https://github.com/gabion-dev) framework,
which runs Asterisk as its telephony node, but nothing in the tree is specific
to Gabion: it is stock Asterisk.

## What ships

Each release publishes one archive per platform and architecture, plus its
SHA-256:

| Archive                               | Platform                 |
|---------------------------------------|--------------------------|
| `asterisk-server-linux-amd64.tar.gz`  | Linux x64, glibc 2.34+   |
| `asterisk-server-linux-arm64.tar.gz`  | Linux ARM64, glibc 2.34+ |
| `asterisk-server-darwin-arm64.tar.gz` | macOS 13+, Apple Silicon |
| `asterisk-server-darwin-amd64.tar.gz` | macOS 13+, Intel         |

A release is published only when every one of the four built and passed
verification.

Inside the archive:

| Path                       | Contents                                                        |
|----------------------------|-----------------------------------------------------------------|
| `sbin/asterisk`            | The server                                                      |
| `lib/asterisk/modules/`    | Asterisk modules                                                |
| `lib/`                     | Bundled shared libraries                                        |
| `var/lib/asterisk/`        | Static data Asterisk expects next to itself                     |
| `LICENSES/`                | License of Asterisk and of every bundled library                |
| `BUILD-INFO.txt`           | Asterisk version, source checksum, build base, full module list |

No configuration files, sound packs or music are shipped: configuration is
the job of whoever runs the server, and prompts come from the application.

Release tags are `<asterisk-version>-r<revision>`, for example `22.11.0-r1`.
The revision counts changes of this recipe for one Asterisk version.

## Platforms

- **Linux with glibc 2.34 or newer** — AlmaLinux / Rocky / RHEL 9+, Ubuntu
  22.04+, Debian 12+, Fedora, and WSL 2 with any of them.
- **macOS 13 or newer** — Apple Silicon and Intel.
- **Older glibc** — not covered. The tree is built on AlmaLinux 9, and glibc is
  backward compatible only upward.
- **musl (Alpine)** — not covered. glibc-linked libraries do not load on musl.
- **Windows** — Asterisk does not exist for Windows. Under Windows it runs
  inside WSL 2.

The Asterisk project itself supports Linux; macOS is a platform it leaves to
the community. These builds make the macOS tree pass the same verification as
the Linux one, and that verification is what the macOS support here amounts
to — it is meant for development machines, not for production telephony.

## Usage

Extract the archive anywhere and start Asterisk with a configuration that
names its directories:

```sh
mkdir asterisk && tar -xzf asterisk-server-linux-amd64.tar.gz -C asterisk
export LD_LIBRARY_PATH="$PWD/asterisk/lib"   # Linux only
asterisk/sbin/asterisk -V
```

On macOS no variable is needed: the tree finds its libraries relative to the
executable.

To run it, write an `asterisk.conf` whose `[directories]` section points
`astmoddir` at `lib/asterisk/modules` and `astvarlibdir` / `astdatadir` at
`var/lib/asterisk` inside the extracted tree, and every writable directory
(`astdbdir`, `astspooldir`, `astrundir`, `astlogdir`, `astkeydir`) wherever
you keep state — then start `sbin/asterisk -C /path/to/asterisk.conf -f`.

[`build/verify.sh`](build/verify.sh) does exactly this and is the working
reference: it writes a minimal configuration into a temporary directory,
boots Asterisk from the tree, and checks the loaded modules.

## How it is built

### Linux

1. [`build/build.sh`](build/build.sh) runs inside a clean AlmaLinux 9
   container. It downloads the **unmodified** Asterisk release tarball,
   checks it against the checksum Asterisk publishes, and builds it with the
   pjproject and jansson versions that Asterisk itself pins.

2. libsrtp is built from pinned source against OpenSSL instead of being taken
   from the base system. The system package encrypts with NSS, which loads its
   cipher modules at run time by name; no link-time inspection sees that
   dependency, and the library fails to initialize on a clean host.

3. Every shared library the server and its modules link against is copied
   into the tree, except the glibc family. Each one is recorded in
   `LICENSES/bundled/PACKAGES.txt` with its package, version and license.

4. The build stops if any required module was not built. The list is
   [`build/required-modules.txt`](build/required-modules.txt) plus the
   platform's own file (`required-modules.linux.txt` or
   `required-modules.macos.txt`).

5. [`build/verify.sh`](build/verify.sh) then runs on five clean images
   (AlmaLinux 9, Ubuntu 22.04, Ubuntu 24.04, Debian 12, Fedora) with nothing
   installed. On each it **boots Asterisk** from the tree and requires every
   required module to be running. Printing a version is not accepted as
   proof: a module whose library is missing fails when it is loaded, not when
   it is built.

### macOS

1. [`build/build-macos.sh`](build/build-macos.sh) runs on a macOS machine with
   the Xcode command line tools. OpenSSL and libsrtp are built from pinned
   source for macOS 13; libxml2, SQLite, libedit and zlib are the ones macOS
   ships. Nothing is taken from Homebrew.

2. Two edits are made to the Asterisk build files — no line of C is touched,
   and `BUILD-INFO.txt` records both:
   - Asterisk asks the compiler for macOS 10.6 as the oldest supported
     system, a target the current toolchain no longer accepts as written; the
     flag is replaced with the deployment target of the build.
   - The macOS branch that links the bundled SIP library names its archives
     with the machine name of one particular Mac, written into the file as a
     literal; it is replaced with the variable that holds the real name.

   Each edit stops the build if the text it expects is no longer there.

3. The tree is made self-locating: every reference to a bundled library is
   rewritten to be relative to the executable, the build stops if any binary
   still references a path outside the tree and macOS, and every binary is
   re-signed.

4. `build/verify.sh` — the same script as on Linux — runs on **other
   machines** than the one that built the tree (macOS 14 and 15 on Apple
   Silicon, macOS 15 on Intel), so a reference to a build directory that
   survived fails to load there.

Every architecture builds and verifies on a native runner, without emulation.

The glibc floor is AlmaLinux 9 rather than something older on purpose. The
bundled libraries come from the build base, so the base has to be a system
that still receives security patches: on a telephony node this server faces
the network. AlmaLinux 9 is supported until 2032.

### Building locally

The scripts are the whole recipe; the workflow only calls them.

```sh
# Linux
mkdir -p out
docker run --rm -v "$PWD:/src:ro" -v "$PWD/out:/out" almalinux:9 \
  bash /src/build/build.sh 22.11.0 /out
docker run --rm -v "$PWD:/src:ro" -v "$PWD/out:/out:ro" ubuntu:24.04 \
  bash /src/build/verify.sh /out/tree

# macOS
bash build/build-macos.sh 22.11.0 out
bash build/verify.sh out/tree
```

### Releasing

Run the **Build Asterisk** workflow with the Asterisk version and the recipe
revision. Published archive names are part of the contract with downloaders
that build the address from the name and the tag — do not rename them.

## What is not included

- **Opus transcoding.** Asterisk's `codec_opus` is a closed binary that Sangoma
  distributes separately from the Asterisk source; it is not shipped here. Browser calls work without it — browsers
  also speak G.711, which Asterisk transcodes itself.
- **Everything outside the telephony node's needs** whose build dependency was
  left out on purpose: database backends, LDAP, SNMP, speech engines and the
  like. `BUILD-INFO.txt` lists what was built.

## Source & License

Built from the release tarballs published at
[downloads.asterisk.org](https://downloads.asterisk.org/pub/telephony/asterisk/releases/):
unmodified on Linux, with two edits to build files on macOS (described
above). The complete corresponding source of a release is that tarball plus the
recipe of this repository at the release tag; `BUILD-INFO.txt` names the
tarball, its checksum and any edit.

Distributed under the [GNU General Public License v2.0](LICENSE), the same
license as Asterisk. Bundled libraries keep their own licenses, listed in
`LICENSES/bundled/` inside each archive.

Asterisk is a registered trademark of Sangoma Technologies. This project is
NOT affiliated with, endorsed by, or sponsored by Sangoma Technologies or the
Asterisk project.
