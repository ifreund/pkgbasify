#!/usr/libexec/flua

-- SPDX-License-Identifier: BSD-2-Clause
--
-- Copyright(c) 2025 The FreeBSD Foundation.
--
-- This software was developed by Isaac Freund <ifreund@freebsdfoundation.org>
-- under sponsorship from the FreeBSD Foundation.

-- See also the pkgbase wiki page: https://wiki.freebsd.org/PkgBase

function main()
	if already_pkgbase() then
		fatal("The system is already using pkgbase.")
	end
	if not confirm_risk() then
		print("canceled")
		os.exit(1)
	end
	if capture("id -u") ~= "0" then
		fatal("This tool must be run as the root user.")
	end
	if not bootstrap_pkg() then
		fatal("Failed to bootstrap pkg.")
	end

	local workdir = capture("mktemp -d -t pkgbasify")

	local packages = setup_conversion(workdir)

	-- This is the point of no return, execute_conversion() will start mutating
	-- global system state.
	-- Before this point, any error should leave the system to exactly the state
	-- it was in before running pkgbasify.
	-- After this point, no error should be fatal and pkgbasify should attempt
	-- to finish conversion regardless of what happens.
	execute_conversion(workdir, packages)

	os.exit(0)
end

function setup_conversion(workdir)
	create_base_repo_conf()

	-- We must make a copy of the etcupdate db before running pkg install as
	-- the etcupdate db matching the pre-pkgbasify system state will be overwritten.
	assert(os.execute("cp -a /var/db/etcupdate/current " .. workdir .. "/current"))

	-- Use a temporary pkg db until we are sure we will carry through with the
	-- conversion to avoid polluting the standard one.
	local db = workdir .. "/pkgdb"
	assert(os.execute("mkdir -p " .. db))
	assert(os.execute("pkg -o PKG_DBDIR=" .. db .. " -o IGNORE_OSVERSION=yes update"))

	if not confirm_version_compatibility(db) then
		print("canceled")
		os.exit(1)
	end

	return select_packages(db)
end

function execute_conversion(workdir, packages)
	if capture("pkg config BACKUP_LIBRARIES") ~= "yes" then
		print("Adding BACKUP_LIBRARIES=yes to /usr/local/etc/pkg.conf")
		local f <close> = assert(io.open("/usr/local/etc/pkg.conf", "a"))
		assert(f:write("BACKUP_LIBRARIES=yes\n"))
	end

	-- pkg install is not necessarily fully atomic, even if it fails some subset
	-- of the packages may have been installed.
	err_if_fail(os.execute("pkg install -y -r FreeBSD-base " .. table.concat(packages, " ")))

	merge_pkgsaves(workdir)

	if os.execute("service sshd status > /dev/null 2>&1") then
		print("Restarting sshd")
		err_if_fail(os.execute("service sshd restart"))
	end

	err_if_fail(os.execute("pwd_mkdb -p /etc/master.passwd"))
	err_if_fail(os.execute("cap_mkdb /etc/login.conf"))

	-- From https://wiki.freebsd.org/PkgBase:
	-- linker.hints was recreated at kernel install time, when we had .pkgsave files
	-- of previous modules. A new linker.hints file will be created during the next
	-- boot of the OS.
	err_if_fail(os.remove("/boot/kernel/linker.hints"))
end

function already_pkgbase()
	return os.execute("pkg -N > /dev/null 2>&1") and
		os.execute("pkg which /usr/bin/uname > /dev/null 2>&1")
end

function bootstrap_pkg()
	-- Some versions of pkg do not handle `bootstrap -y` gracefully.
	-- This has been fixed in https://github.com/freebsd/pkg/pull/2426 but
	-- but we still need to check before running the bootstrap in case the pkg
	-- version has the broken behavior.
	if os.execute("pkg -N > /dev/null 2>&1") then
		return true
	else
		return os.execute("pkg bootstrap -y")
	end
end

function confirm_risk()
	print("Running this tool will irreversibly modify your system to use pkgbase.")
	print("This tool and pkgbase are experimental and may result in a broken system.")
	print("It is highly recommend to backup your system before proceeding.")
	return prompt_yn("Do you accept this risk and wish to continue?")
end

function prompt_yn(question)
	while true do
		io.write(question .. " (y/n) ")
		local input = io.read()
		if input == "y" or input == "Y" then
			return true
		elseif input == "n" or input == "N" then
			return false
		end
	end
end

function create_base_repo_conf()
	-- TODO add an option to specify an alternative directory for FreeBSD-base.conf
	-- TODO using grep and test here is not idiomatic lua, improve this
	local conf_dir = "/usr/local/etc/pkg/repos/"
	if not os.execute("pkg config REPOS_DIR | grep " .. conf_dir .. " > /dev/null 2>&1") then
		fatal("non-standard pkg REPOS_DIR config does not include " .. conf_dir)
	end

	local conf_file = conf_dir .. "FreeBSD-base.conf"
	if os.execute("test -e " .. conf_file) then
		if not prompt_yn("Overwrite " .. conf_file .. "?") then
			print("canceled")
			os.exit(1)
		end
		print("Overwriting " .. conf_file)
	else
		print("Creating " .. conf_file)
	end

	assert(os.execute("mkdir -p " .. conf_dir))
	local f <close> = assert(io.open(conf_file, "w"))
	assert(f:write(string.format([[
FreeBSD-base: {
  url: "%s",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
]], base_repo_url())))
end

-- Returns the URL for the pkgbase repository that matches the version
-- reported by freebsd-version(1)
function base_repo_url()
	-- e.g. 15.0-CURRENT, 14.2-STABLE, 14.1-RELEASE, 14.1-RELEASE-p6,
	local raw = capture("freebsd-version")
	local major, minor, branch = assert(raw:match("(%d+)%.(%d+)%-(%u+)"))

	if math.tointeger(major) < 14 then
		fatal("unsupported FreeBSD version: " .. raw)
	end

	if branch == "RELEASE" then
		return "pkg+https://pkg.FreeBSD.org/${ABI}/base_release_" .. minor
	elseif branch == "CURRENT" or branch == "STABLE" then
		return "pkg+https://pkg.FreeBSD.org/${ABI}/base_latest"
	else
		fatal("unsupported FreeBSD version: " .. raw)
	end
end

function confirm_version_compatibility(db)
	local osversion_local = math.tointeger(capture("pkg config osversion"))
	local osversion_remote = rquery_osversion(db)
	if osversion_remote < osversion_local then
		-- This may be overly restrictive, having to wait for remote repositories to
		-- update before the system can be pkgbasified is poor UX.
		print(string.format("System has newer __FreeBSD_version than remote pkgbase packages (%d vs %d).",
			osversion_local, osversion_remote))
		return prompt_yn(string.format("Continue anyway and downgrade the system to %d?", osversion_remote))
	elseif osversion_remote > osversion_local then
		print(string.format("System has older __FreeBSD_version than remote pkgbase packages (%d vs %d).",
			osversion_local, osversion_remote))
		print("It is recommended to update your system before running pkgbasify.")
		return prompt_yn("Ignore the osversion and continue anyway?")
	end
	assert(osversion_local == osversion_remote)
	return true
end

-- Returns the osversion as an integer
function rquery_osversion(db)
	-- It feels like pkg should provide a less ugly way to do this.
	-- TODO is FreeBSD-runtime the correct pkg to check against?
	local tags = capture("pkg -o PKG_DBDIR=" .. db ..
		" rquery -r FreeBSD-base %At FreeBSD-runtime"):gmatch("[^\n]+")
	local values = capture("pkg -o PKG_DBDIR=" .. db ..
		" rquery -r FreeBSD-base %Av FreeBSD-runtime"):gmatch("[^\n]+")
	while true do
		local tag = tags()
		local value = values()
		if not tag or not value then
			break
		end
		if tag == "FreeBSD_version" then
			return math.tointeger(value)
		end
	end
	fatal("Missing FreeBSD_version annotation for FreeBSD-runtime package")
end

-- Returns a list of pkgbase packages matching the files present on the system
function select_packages(db)
	local kernel = {}
	local kernel_dbg = {}
	local base = {}
	local base_dbg = {}
	local lib32 = {}
	local lib32_dbg = {}
	local src = {}
	local tests = {}
	
	local rquery = capture("pkg -o PKG_DBDIR=" .. db .. " rquery -r FreeBSD-base %n")
	for package in rquery:gmatch("[^\n]+") do
		if package == "FreeBSD-src" or package:match("FreeBSD%-src%-.*") then
			table.insert(src, package)
		elseif package == "FreeBSD-tests" or package:match("FreeBSD%-tests%-.*") then
			table.insert(tests, package)
		elseif package:match("FreeBSD%-kernel%-.*") then
			-- Kernels other than FreeBSD-kernel-generic are ignored
			if package == "FreeBSD-kernel-generic" then
				table.insert(kernel, package)
			elseif package == "FreeBSD-kernel-generic-dbg" then
				table.insert(kernel_dbg, package)
			end
		elseif package:match(".*%-dbg%-lib32") then
			table.insert(lib32_dbg, package)
		elseif package:match(".*%-lib32") then
			table.insert(lib32, package)
		elseif package:match(".*%-dbg") then
			table.insert(base_dbg, package)
		else
			table.insert(base, package)
		end
	end
	assert(#kernel == 1)
	assert(#kernel_dbg == 1)
	assert(#base > 0)
	assert(#base_dbg > 0)
	assert(#lib32 > 0)
	assert(#lib32_dbg > 0)
	assert(#src > 0)
	assert(#tests > 0)

	local selected = {}
	append_list(selected, kernel)
	append_list(selected, base)

	if non_empty_dir("/usr/lib/debug/boot/kernel") then
		append_list(selected, kernel_dbg)
	end
	if os.execute("test -e /usr/lib/debug/lib/libc.so.7.debug") then
		append_list(selected, base_dbg)
	end
	-- Checking if /usr/lib32 is non-empty is not sufficient, as base.txz
	-- includes several empty /usr/lib32 subdirectories.
	if os.execute("test -e /usr/lib32/libc.so.7") then
		append_list(selected, lib32)
	end
	if os.execute("test -e /usr/lib/debug/usr/lib32/libc.so.7.debug") then
		append_list(selected, lib32_dbg)
	end
	if non_empty_dir("/usr/src") then
		append_list(selected, src)
	end
	if non_empty_dir("/usr/tests") then
		append_list(selected, tests)
	end
	
	return selected
end

-- Returns true if the path is a non-empty directory.
-- Returns false if the path is empty, not a directory, or does not exist.
function non_empty_dir(path)
	local p = io.popen("find " .. path .. " -maxdepth 0 -type d -not -empty 2>/dev/null")
	local output = p:read("*a"):gsub("%s+", "") -- remove whitespace
	local success = p:close()
	return output ~= "" and success
end

function merge_pkgsaves(workdir)
	for ours in capture("find / -name '*.pkgsave'"):gmatch("[^\n]+") do
		local theirs = assert(ours:match("(.-)%.pkgsave"))
		local old = workdir .. "/current/" .. theirs
		-- Only attempt to merge if we have a common ancestor from the
		-- pre-conversion snapshot of the etcupdate database.
		if os.execute("test -e " .. old) then
			local merged = workdir .. "/merged/" .. theirs
			err_if_fail(os.execute("mkdir -p " .. merged:match(".*/")))
			if os.execute("diff3 -m " .. ours .. " " .. old .. " " .. theirs .. " > " .. merged) and
					os.execute("mv " .. merged .. " " .. theirs) then
				print("Merged " .. theirs)
			else
				print("Failed to merge " .. theirs .. ", manual intervention may be necessary")
			end
		end
	end
end

-- Run a command using the OS shell and capture the stdout
-- Strips exactly one trailing newline if present, does not strip any other whitespace.
-- Asserts that the command exits cleanly
function capture(command)
	local p = io.popen(command)
	local output = p:read("*a")
	assert(p:close())
	-- Strip exactly one trailing newline from the output, if there is one
	return output:match("(.-)\n$")
end

function append_list(list, other)
	for _, item in ipairs(other) do
		table.insert(list, item)
	end
end

function err_if_fail(ok, err_msg)
	if not ok then
		err(err_msg)
	end
end

function fatal(msg)
	err(msg)
	os.exit(1)
end

function err(msg)
	io.stderr:write("Error: " .. msg .. "\n")
end

main()
