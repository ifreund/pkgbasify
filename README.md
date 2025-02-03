# pkgbasify

A tool to automatically convert a FreeBSD system to use
[PkgBase](https://wiki.freebsd.org/PkgBase).

## Disclaimer

Both the pkgbasify tool and PkgBase itself are experimental and running
this tool may result in irreversible data loss and/or a system that fails to boot.
It is highly recommended to make backups before running this tool.

## Behavior

The pkgbasify tool performs the following steps:

1. Select a pkgbase repository based on the output of `freebsd-version(1)`
   and create `/usr/local/etc/pkg/repos/FreeBSD-base.conf`.

2. Select packages from the repository corresponding to the currently
   installed FreeBSD base system components. For example, if the lib32
   component is not installed on the system pkgbasify will skip installation
   of lib32 packages.

3. Install the selected packages with `pkg(8)`, overwriting the files of the base
   system and creating `.pkgsave` files as per standard `pkg(8)` behavior.

4. Restore critical `.pkgsave` files such as `/etc/master.passwd` and
   `/etc/ssh/sshd_config` and restart sshd.

## Limitations

The handling of `.pkgsave` files is not sufficient for systems with extensive
customizations. The user is currently required to manually identify and handle
`.pkgsave` files not included in the small list of "critical" files.

It should be possible to further automate this by comparing .pkgsave files to a
pristine copy from the .txz distribution files corresponding to the system's
freebsd-version. `.pkgsave` files that match the pristine copy can be safely
deleted while files that have been modified by the user could trigger a prompt
for user action.
