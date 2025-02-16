# pkgbasify

Automatically convert a FreeBSD system to use
[PkgBase](https://wiki.freebsd.org/PkgBase).

## Disclaimer

Both the pkgbasify tool and PkgBase itself are experimental and running
this tool may result in irreversible data loss and/or a system that fails to boot.
It is highly recommended to make backups before running this tool.

## Behavior

The pkgbasify tool performs the following steps:

1. Make a copy of the `etcupdate(8)` current database (`/var/db/etcupdate/current`)
   so that pkgbasify can merge config files after converting the system to use pkgbase.

2. Select a pkgbase repository based on the output of `freebsd-version(1)`
   and create `/usr/local/etc/pkg/repos/FreeBSD-base.conf`.

3. Select packages from the repository corresponding to the currently
   installed FreeBSD base system components. For example, if the lib32
   component is not installed on the system pkgbasify will skip installation
   of lib32 packages.

4. Install the selected packages with `pkg(8)`, overwriting the files of the base
   system and creating `.pkgsave` files as per standard `pkg(8)` behavior.

5. Run a 3-way-merge between the `.pkgsave` files (ours), the new files
   installed by pkg (theirs), and the old files in the etcupdate database copy
   created in step 1. If there are merge conflicts, an error is logged and
   manual intervention may be required. `.pkgsave` files without a corresponding
   entry in the old etcupdate database are skipped.

6. Restart `sshd(8)` and run `pwd_mkdb(8)`/`cap_mkdb(8)`.
