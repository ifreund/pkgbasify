# pkgbasify

Automatically convert a FreeBSD system to use [pkgbase].

This project is sponsored by the [FreeBSD Foundation](https://freebsdfoundation.org/).

## Disclaimer

Both the pkgbasify tool and pkgbase itself are experimental.
Running pkgbasify may result in irreversible data loss and/or a system that fails to boot.
It is highly recommended to make backups before running this tool.

The pkgbasify tool can download over 1GB of packages which when installed will take even more than that.
Since [pkg install does not check for available space](https://github.com/freebsd/pkg/issues/75), and exhausting the available disk space is possible,it is also important that one understands their available disk space.

The downloaded packages may also be in the /var/cache/pkg, depending on your configuration.

That said, I am not aware of any bugs in pkgbasify and have done my best to make it as robust as possible.
I currently believe pkgbasify to be as reliable as manual conversion if not better.

If you find a bug in pkgbasify please open an issue!

## Usage

Download the script, give it permission to execute, run it as root:

1. `fetch https://github.com/FreeBSDFoundation/pkgbasify/raw/refs/heads/main/pkgbasify.lua`
2. `chmod +x ./pkgbasify.lua`
3. `./pkgbasify.lua`

If conversion succeeds:

4. restart the system.

## Behavior

pkgbasify performs the following steps:

1. Make a copy of the [etcupdate(8)] current database (`/var/db/etcupdate/current`).
   This makes it possible for pkgbasify to merge config files after converting the system.
2. Select a repository based on the output of [freebsd-version(1)] and create `/usr/local/etc/pkg/repos/FreeBSD-base.conf`.
3. Select packages that correspond to the currently installed base system components.
   - For example: if the lib32 component is not already installed,
     pkgbasify will skip installation of lib32 packages.
4. Prompt the user to create a "pre-pkgbasify" boot environment using [bectl(8)] if possible.
5. Install the selected packages with [pkg(8)],
   overwriting base system files and creating `.pkgsave` files as per standard [pkg(8)] behavior.
6. Run a three-way-merge between the `.pkgsave` files (ours),
   the new files installed by pkg (theirs),
   and the old files in the copy of the etcupdate database.
   - If there are merge conflicts, an error is logged and manual intervention may be required.
   - `.pkgsave` files without a corresponding entry in the old etcupdate database are skipped.
7. If [sshd(8)] is running, restart the service.
8. Run [pwd_mkdb(8)] and [cap_mkdb(1)].
9. Remove `/boot/kernel/linker.hints`.

[bectl(8)]: https://man.freebsd.org/cgi/man.cgi?query=bectl&sektion=8&manpath=freebsd-release
[pkgbase]: https://wiki.freebsd.org/PkgBase
[etcupdate(8)]: https://man.freebsd.org/cgi/man.cgi?query=etcupdate&sektion=8&manpath=freebsd-release
[freebsd-version(1)]: https://man.freebsd.org/cgi/man.cgi?query=freebsd-version&sektion=1&manpath=freebsd-release
[pkg(8)]: https://man.freebsd.org/cgi/man.cgi?query=pkg&sektion=8&manpath=freebsd-ports
[sshd(8)]: https://man.freebsd.org/cgi/man.cgi?query=sshd&sektion=8&manpath=freebsd-release
[pwd_mkdb(8)]: https://man.freebsd.org/cgi/man.cgi?query=pwd_mkdb&sektion=8&manpath=freebsd-release
[cap_mkdb(1)]: https://man.freebsd.org/cgi/man.cgi?query=cap_mkdb&sektion=1&manpath=freebsd-release
