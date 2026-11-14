#!/usr/bin/env bash
# Kernel source patching: SUSFS, path_umount backport, hide_stuff, manual hooks.
#
# Everything here is idempotent and version-aware. Each step is skipped with a
# clear message when it is unnecessary (feature already present) rather than
# failing, because these trees are frequently already partially patched.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
# Resolved from this file's location, not $PWD -- several helpers below run
# with the working directory changed into the kernel tree.
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# ====================================================================== SUSFS

# susfs_branch_for KVER -- map a kernel version onto a susfs4ksu branch.
#
# susfs4ksu is branched per kernel version. The GKI branches are named after
# the Android release they ship with; where a kernel version spans two Android
# releases (5.10 -> android12/android13, 5.15 -> android13/android14) we pick
# the older, which is the one the vast majority of trees are based on.
# Override with SUSFS_BRANCH when that guess is wrong.
susfs_branch_for() {
	case "$1" in
		4.9)  echo "kernel-4.9" ;;
		4.14) echo "kernel-4.14" ;;
		4.19) echo "kernel-4.19" ;;
		5.4)  echo "kernel-5.4" ;;
		5.10) echo "gki-android12-5.10" ;;
		5.15) echo "gki-android13-5.15" ;;
		6.1)  echo "gki-android14-6.1" ;;
		6.6)  echo "gki-android15-6.6" ;;
		6.12) echo "gki-android16-6.12" ;;
		*)    echo "" ;;
	esac
}

susfs_apply() {
	local repo=${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}
	local branch=${SUSFS_BRANCH:-auto}
	local kver
	kver=$(kernel_version "$KERNEL_DIR") || die "cannot read kernel version from ${KERNEL_DIR}/Makefile"

	group "Applying SUSFS"

	if [ "$branch" = "auto" ]; then
		branch=$(susfs_branch_for "$kver")
		[ -n "$branch" ] || die "no susfs4ksu branch is known for kernel ${kver}; set SUSFS_BRANCH explicitly.
       Available: $(git ls-remote --heads "$repo" | awk '{print $2}' | sed 's@refs/heads/@@' | tr '\n' ' ')"
		info "kernel ${kver} -> susfs branch '${branch}'"
	fi

	ref_exists "$repo" "$branch" \
		|| die "susfs4ksu has no branch '${branch}'.
       Available: $(git ls-remote --heads "$repo" | awk '{print $2}' | sed 's@refs/heads/@@' | tr '\n' ' ')"

	local susfs_dir="${WORKSPACE}/susfs4ksu"
	rm -rf "$susfs_dir"
	retry 3 git clone -q --depth=1 -b "$branch" "$repo" "$susfs_dir" \
		|| die "failed to clone ${repo} @ ${branch}"

	local kp="${susfs_dir}/kernel_patches"
	[ -d "$kp" ] || die "unexpected susfs4ksu layout: ${kp} missing"

	# 1. Drop in the SUSFS sources. The non-GKI branches carry sus_su.c too.
	info "copying SUSFS sources into the kernel tree"
	cp -v "${kp}/fs/"*.c              "${KERNEL_DIR}/fs/"            2>/dev/null || true
	cp -v "${kp}/include/linux/"*.h   "${KERNEL_DIR}/include/linux/" 2>/dev/null || true

	# 1.5 Bridge SukiSU-Ultra's builtin tree (SUSFS v2.x client) to kernel-side
	#    SUSFS v1.5.5: rename the 1.5.5 user-facing functions to susfs155_* and
	#    compile fs/susfs_compat_v2.c, which implements the v2 names/signatures
	#    (supercall surface, selinux sid stubs, task-state helpers) on top of
	#    them. v2-only features degrade to -ENOTSUPP.
	if [ "${KSU_NAME:-}" = "SukiSU-Ultra" ] && [ "${KSU_REF_RESOLVED:-}" = "builtin" ]; then
		info "bridging SukiSU builtin (v2 client) to kernel-side SUSFS v1.5.5"
		sed -i -E \
			-e 's/susfs_add_sus_path\(/susfs155_add_sus_path(/g' \
			-e 's/susfs_add_sus_kstat\(/susfs155_add_sus_kstat(/g' \
			-e 's/susfs_update_sus_kstat\(/susfs155_update_sus_kstat(/g' \
			-e 's/susfs_set_uname\(/susfs155_set_uname(/g' \
			-e 's/susfs_set_cmdline_or_bootconfig\(/susfs155_set_cmdline_or_bootconfig(/g' \
			-e 's/susfs_add_open_redirect\(/susfs155_add_open_redirect(/g' \
			"${KERNEL_DIR}/fs/susfs.c" "${KERNEL_DIR}/include/linux/susfs.h" \
			|| die "failed to rename 1.5.5 susfs entry points for the builtin bridge"

		cp "${REPO_ROOT}/patches/susfs/include/susfs_compat_v2.h" \
			"${KERNEL_DIR}/include/linux/susfs_compat_v2.h" \
			|| die "failed to install susfs_compat_v2.h"
		cp "${REPO_ROOT}/patches/susfs/fs_susfs_compat_v2.c" \
			"${KERNEL_DIR}/fs/susfs_compat_v2.c" \
			|| die "failed to install fs_susfs_compat_v2.c"

		grep -q 'susfs_compat_v2\.o' "${KERNEL_DIR}/fs/Makefile" \
			|| printf 'obj-$(CONFIG_KSU_SUSFS) += susfs_compat_v2.o\n' >>"${KERNEL_DIR}/fs/Makefile"

		local ksu_inc_h="${KERNEL_DIR}/${KSU_DIR:-KernelSU}/kernel/kernel_includes.h"
		if [ -f "$ksu_inc_h" ] && ! grep -q 'susfs_compat_v2\.h' "$ksu_inc_h"; then
			sed -i 's@#include <linux/susfs\.h>@#include <linux/susfs.h>\n#include <linux/susfs_compat_v2.h>@' "$ksu_inc_h"
			grep -q 'susfs_compat_v2\.h' "$ksu_inc_h" \
				|| warn "susfs_compat_v2.h was not wired into kernel_includes.h"
		fi
		ok "SUSFS v2<->v1.5.5 bridge installed"
	fi

	# 2. Patch the kernel itself.
	# A repo-local adapted patch (patches/susfs/50_add_susfs_in_<branch>_oplus_adapted.patch)
	# takes precedence: non-GKI OPLUS/OnePlusOSS trees need hand-ported hunks
	# (may_create signature, OPLUS namespace.c header block, fdinfo.c mask
	# helper, sched.h without ANDROID_KABI_RESERVE slots).
	local kernel_patch="${REPO_ROOT}/patches/susfs/50_add_susfs_in_${branch}_oplus_adapted.patch"
	if [ -f "$kernel_patch" ]; then
		info "using repo-local adapted SUSFS patch: patches/susfs/50_add_susfs_in_${branch}_oplus_adapted.patch"
	else
		kernel_patch="${kp}/50_add_susfs_in_${branch}.patch"
		[ -f "$kernel_patch" ] || {
			# Fall back to whatever 50_* patch the branch actually ships.
			kernel_patch=$(find "$kp" -maxdepth 1 -name '50_add_susfs_in_*.patch' | head -n1)
		}
	fi
	[ -n "$kernel_patch" ] && [ -f "$kernel_patch" ] \
		|| die "no 50_add_susfs_in_*.patch found in ${kp}"

	( cd "$KERNEL_DIR" && apply_patch "$kernel_patch" 1 ) \
		|| die "the SUSFS kernel patch did not apply cleanly.
       This usually means SUSFS_BRANCH does not match your kernel. Detected
       kernel ${kver}, used branch '${branch}'."

	# 3. Patch the KernelSU side -- but only when the variant does not already
	#    ship SUSFS support. SukiSU-Ultra's 'builtin' branch, for instance,
	#    declares CONFIG_KSU_SUSFS itself; applying the patch on top conflicts.
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"
	local ksu_patch="${kp}/KernelSU/10_enable_susfs_for_ksu.patch"

	if susfs_is_bundled; then
		info "${KSU_NAME:-the selected variant} already bundles SUSFS at ref '${KSU_REF_RESOLVED:-}'; skipping 10_enable_susfs_for_ksu.patch"
	elif [ ! -d "$ksu_dir" ]; then
		warn "KernelSU directory ${ksu_dir} not found; skipping the KernelSU-side SUSFS patch"
	elif [ ! -f "$ksu_patch" ]; then
		warn "branch ${branch} ships no KernelSU/10_enable_susfs_for_ksu.patch; skipping"
	else
		( cd "$ksu_dir" && apply_patch "$ksu_patch" 1 ) || {
			warn "the KernelSU-side SUSFS patch did not apply."
			warn "susfs4ksu's non-GKI branches were last updated in early 2025 and still"
			warn "target the old flat KernelSU layout; modern forks have since moved to a"
			warn "modular kernel/ tree. Try a variant/ref whose layout matches, or a fork"
			warn "that bundles SUSFS itself (e.g. KSU_VARIANT=sukisu-ultra KSU_REF=builtin)."
			die "SUSFS integration failed"
		}
	fi

	# Record the SUSFS version for the build summary.
	local sv
	sv=$(sed -nE 's/.*SUSFS_VERSION[[:space:]]+"([^"]+)".*/\1/p' \
		"${KERNEL_DIR}/include/linux/susfs.h" 2>/dev/null | head -n1)
	export_env SUSFS_VERSION "${sv:-unknown}"
	export_env SUSFS_BRANCH_RESOLVED "$branch"
	ok "SUSFS ${sv:-?} applied from branch ${branch}"
	summary "| SUSFS | \`${sv:-unknown}\` (branch \`${branch}\`) |"
	endgroup
}

# Does the selected variant+ref already contain SUSFS?
susfs_is_bundled() {
	local bundled=${KSU_SUSFS_BUNDLED_REFS:--} ref=${KSU_REF_RESOLVED:-}
	[ "$bundled" = "-" ] && return 1
	local r
	for r in $bundled; do
		[ "$r" = "$ref" ] && return 0
	done
	# Fall back to inspecting the tree, which is authoritative.
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"
	[ -d "$ksu_dir" ] && grep -rqs 'CONFIG_KSU_SUSFS\|config KSU_SUSFS' "${ksu_dir}/kernel/Kconfig" 2>/dev/null
}

susfs_defconfig() {
	local defconfig=$1
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"

	# The SUSFS option set is NOT stable across branches, so it is discovered
	# from the Kconfig that was actually patched in rather than hardcoded.
	#
	# Concretely: the GKI branches ship SUSFS v2.x, which declares SUS_MAP and
	# has dropped the AUTO_ADD_*/SUS_OVERLAYFS/HAS_MAGIC_MOUNT knobs. The
	# non-GKI branches are still on v1.5.5 (last touched early 2025), which is
	# the exact opposite: it has the AUTO_ADD_* family and no SUS_MAP. A
	# hardcoded list is therefore wrong on one side or the other -- and wrong
	# in the silent direction, since an unknown symbol in a defconfig is simply
	# dropped, leaving the feature off with no warning.
	local syms
	syms=$(grep -rhoE '^[[:space:]]*config[[:space:]]+KSU_SUSFS[A-Z_]*' \
			"$ksu_dir" "${KERNEL_DIR}/fs/Kconfig" "${KERNEL_DIR}/drivers/kernelsu" 2>/dev/null \
		| awk '{print $2}' | sort -u)

	if [ -z "$syms" ]; then
		die "found no KSU_SUSFS Kconfig symbols to enable.
       The SUSFS sources are in the tree but nothing declares its options, so
       the feature would silently compile out and you would ship a kernel that
       looks patched but hides nothing. Check that the KernelSU-side patch
       applied, or pick a variant that bundles SUSFS."
	fi

	local s enabled=0
	for s in $syms; do
		case "$s" in
			# sus_su is the legacy in-kernel su backend, superseded by the
			# manager; overlayfs hiding conflicts with magic mount. Both are
			# off in the reference builds.
			KSU_SUSFS_SUS_SU | KSU_SUSFS_SUS_OVERLAYFS)
				kconf_disable "$defconfig" "CONFIG_${s}" ;;
			*)
				kconf_enable "$defconfig" "CONFIG_${s}"; enabled=$((enabled + 1)) ;;
		esac
	done
	ok "enabled ${enabled} SUSFS options discovered from Kconfig"
	debug "SUSFS symbols: $(printf '%s ' $syms)"
}

# =============================================================== path_umount

# path_umount() landed upstream in Linux 5.9. KernelSU uses it to unmount its
# own overlays before handing control to an app that is checking for root, so
# on older trees it has to be backported or module unmounting silently no-ops.
#
# The body below is upstream's, unchanged. It is inserted immediately before
# the comment that introduces the umount syscall, which puts it after
# do_umount() -- its only forward dependency -- in every tree from 4.9 to 5.4.
path_umount_apply() {
	local ns="${KERNEL_DIR}/fs/namespace.c"
	group "Backporting path_umount()"

	local kver
	kver=$(kernel_version "$KERNEL_DIR") || die "cannot read kernel version"

	if ver_ge "$kver" "5.9"; then
		info "kernel ${kver} already provides path_umount() upstream; nothing to do"
		endgroup; return 0
	fi
	[ -f "$ns" ] || die "fs/namespace.c not found"

	if grep -q '^int path_umount\|^static int path_umount' "$ns"; then
		info "path_umount() is already present in fs/namespace.c; nothing to do"
		endgroup; return 0
	fi

	local anchor='Now umount can handle mount points as well as block devices'
	grep -q "$anchor" "$ns" \
		|| die "could not find the insertion point in fs/namespace.c; patch this kernel manually"

	local snippet
	snippet=$(mktemp)
	# 'can_umount' is a separate helper upstream; guard it in case a partial
	# backport already added it.
	if ! grep -q 'static int can_umount' "$ns"; then
		cat >>"$snippet" <<'EOF'
static int can_umount(const struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);

	if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))
		return -EINVAL;
	if (!may_mount())
		return -EPERM;
	if (path->dentry != path->mnt->mnt_root)
		return -EINVAL;
	if (!check_mnt(mnt))
		return -EINVAL;
	if (mnt->mnt.mnt_flags & MNT_LOCKED) /* Check optimistically */
		return -EINVAL;
	if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))
		return -EPERM;
	return 0;
}

EOF
	fi
	cat >>"$snippet" <<'EOF'
int path_umount(struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);
	int ret;

	ret = can_umount(path, flags);
	if (!ret)
		ret = do_umount(mnt, flags);

	/* we mustn't call path_put() as that would clear mnt_expiry_mark */
	dput(path->dentry);
	mntput_no_expire(mnt);
	return ret;
}

EOF

	# Insert before the line *above* the anchor comment body, i.e. at the '/*'
	# that opens it.
	local lineno
	lineno=$(grep -n "$anchor" "$ns" | head -n1 | cut -d: -f1)
	# Walk back to the opening '/*' of that comment block.
	local start=$lineno
	while [ "$start" -gt 1 ] && ! sed -n "${start}p" "$ns" | grep -q '/\*'; do
		start=$((start - 1))
	done

	local tmp
	tmp=$(mktemp)
	head -n "$((start - 1))" "$ns" >"$tmp"
	cat "$snippet" >>"$tmp"
	tail -n "+${start}" "$ns" >>"$tmp"
	mv "$tmp" "$ns"
	rm -f "$snippet"

	grep -q '^int path_umount' "$ns" || die "path_umount() insertion failed"
	ok "path_umount() backported into fs/namespace.c (kernel ${kver})"
	summary "| path_umount | backported (kernel ${kver}) |"
	endgroup
}

# ===================================================== modversions tolerance
#
# The ColorOS vendor module tree (/vendor/lib/modules, 45 .ko) was compiled
# from OPPO's internal tree, which has drifted from the public OnePlusOSS
# tree this build uses. genksyms hashes every type reachable from a symbol's
# prototype, so even benign drift (config key renames, reordered headers)
# changes the CRCs -- the ABI itself still matches. Unpatched, check_version()
# rejects every such module with "disagrees about version of symbol ...
# (err -22)" and the device boots with no Wi-Fi, no audio and 0 vendor
# modules.
#
# The fix downgrades a CRC mismatch to a warning and loads the module anyway.
# module_layout used to be the one exception: its CRC covers struct module, so
# a mismatch there *could* mean kernel and module disagree about memory layout.
# Forensics on build 43521515272 (stock 75/75 CRCs present, SUSFS 27/75, working
# tree 75/75) proved the drift is a genksyms text cascade -- SUSFS only
# tail-appends to task_struct and uses ANDROID_KABI_USE slots in vfsmount, and
# nothing (SUSFS patch, ksu_hooks patch, KSU tree) touches include/linux/module.h.
# The CRC hashes change; the struct module ABI does not. module_layout is
# therefore tolerated as well, with a loud warning kept for forensics.
modversions_tolerance_apply() {
	local mc="${KERNEL_DIR}/kernel/module.c"
	group "Applying MODVERSIONS CRC tolerance"

	[ -f "$mc" ] || die "kernel/module.c not found under ${KERNEL_DIR}"

	if grep -q 'MODVERSIONS CRC tolerance' "$mc"; then
		info "kernel/module.c already carries the CRC tolerance edit; nothing to do"
		endgroup; return 0
	fi

	grep -q 'disagrees about version of symbol' "$mc" \
		|| die "could not find the bad_version anchor in kernel/module.c; the tree has drifted from 4.19 upstream"

	# Anchor on the exact 4.19 bad_version block. If the tree ever reshapes
	# it the edit lands nowhere and the verification grep below fails loudly.
	perl -0pi -e '
s/bad_version:\n\tpr_warn\("%s: disagrees about version of symbol %s\\n",\n\t       info->name, symname\);\n\treturn 0;/bad_version:\n\tpr_warn("%s: disagrees about version of symbol %s\\n",\n\t       info->name, symname);\n\t\/* MODVERSIONS CRC tolerance: vendor modules were built from a tree\n\t * that diverged from this one, so many exported symbols hash differently\n\t * even though the ABI matches. Forensics (build 43521515272) proved the\n\t * drift is a genksyms text cascade from SUSFS tail-append and\n\t * ANDROID_KABI_USE edits -- struct module itself is untouched, so all\n\t * mismatches, module_layout included, are downgraded to a warning and\n\t * the modules still load. *\/\n\tif (strcmp(symname, "module_layout") == 0)\n\t\tpr_warn("%s: tolerating mismatched module_layout CRC (struct module ABI unchanged)\\n", info->name);\n\treturn 1;/
' "$mc"

	grep -q 'MODVERSIONS CRC tolerance' "$mc" \
		|| die "the CRC tolerance edit did not land; kernel/module.c no longer matches the 4.19 shape"

	ok "kernel/module.c: all CRC mismatches now warn and load (module_layout tolerated, loud warn kept)"
	summary "| MODVERSIONS tolerance | applied (all symbols, incl. module_layout) |"
	endgroup
}

# ================================================================= camx KMD
#
# OnePlus's Android 12+ OSS releases turn techpack/camera into an unfetchable
# submodule (no .gitmodules entry) and the workflow prunes the empty
# directory, so the camera kernel-mode driver is never compiled in. The
# vendor HAL then aborts in CamX::HwEnvironment::GetInstance() every 5
# seconds because /sys/class/video4linux has no camx nodes, and the device
# never reaches sys.boot_completed.
#
# The Android 11 branch of the same repository (oneplus/SM8250_R_11.0_9R)
# still ships the full kona camera KMD source. techpack/camera/Makefile is
# self-contained: with CONFIG_ARCH_KONA=y it includes config/konacamera.conf
# which forces CONFIG_SPECTRA_CAMERA=y, so dropping the directory into the
# tree is enough -- no defconfig change, no Kconfig hook.
camx_kmd_apply() {
	group "Restoring techpack/camera KMD"
	local camdir="${KERNEL_DIR}/techpack/camera"

	if [ -f "${camdir}/Makefile" ]; then
		info "techpack/camera already present; nothing to do"
		endgroup; return 0
	fi

	local src="${WORKSPACE}/camera-kmd-src"
	rm -rf "$src"
	retry 3 git clone -q --depth=1 --filter=blob:none --sparse \
		-b oneplus/SM8250_R_11.0_9R \
		https://github.com/OnePlusOSS/android_kernel_oneplus_sm8250.git "$src" \
		|| die "failed to clone the Android 11 kernel tree (camera KMD source)"
	( cd "$src" && git sparse-checkout set techpack/camera ) \
		|| die "sparse-checkout of techpack/camera failed"

	[ -f "${src}/techpack/camera/Makefile" ] \
		|| die "techpack/camera missing from the Android 11 branch; nothing to restore"

	cp -r "${src}/techpack/camera" "$camdir"
	[ -f "${camdir}/Makefile" ] || die "camera KMD copy failed"
	rm -rf "$src"

	ok "techpack/camera KMD restored (kona source from oneplus/SM8250_R_11.0_9R)"
	summary "| camera KMD | restored from oneplus/SM8250_R_11.0_9R |"
	endgroup
}

# ============================================================== extra patches

SUKISU_PATCH_REPO=${SUKISU_PATCH_REPO:-https://github.com/ShirkNeko/SukiSU_patch.git}

# Clone the shared patch/tool repo once, on demand.
sukisu_patch_dir() {
	local dir="${WORKSPACE}/SukiSU_patch"
	if [ ! -d "$dir" ]; then
		retry 3 git clone -q --depth=1 "$SUKISU_PATCH_REPO" "$dir" \
			|| die "failed to clone ${SUKISU_PATCH_REPO}"
	fi
	printf '%s' "$dir"
}

# hide_stuff removes the most obvious KernelSU fingerprints from the build.
hide_stuff_apply() {
	group "Applying hide_stuff"
	local dir patch
	dir=$(sukisu_patch_dir)
	patch="${dir}/69_hide_stuff.patch"
	[ -f "$patch" ] || { warn "69_hide_stuff.patch not found in the patch repo; skipping"; endgroup; return 0; }
	( cd "$KERNEL_DIR" && apply_patch "$patch" 1 ) || warn "hide_stuff did not apply cleanly; continuing"
	endgroup
}

# Manual/syscall hook patches for pre-GKI trees, used when the fork expects the
# hooks to already exist in the kernel source rather than hooking via kprobes.
hooks_patch_apply() {
	local variant=${KSU_VARIANT:-none} kver
	kver=$(kernel_version "$KERNEL_DIR") || return 0

	group "Applying manual syscall hooks (kernel ${kver})"

	# ReSukiSU publishes scope-minimised hook patches keyed by kernel version.
	#
	# This branch must NOT fall through to the bundled legacy script: that
	# script injects the KernelSU 0.9.x symbols (ksu_handle_execve and friends),
	# which ReSukiSU's tools/manual_hook_check.mk rejects outright with
	# "ksu_handle_execve is deprecated". Failing here with a clear message beats
	# a tree that is half-patched with the wrong hook API.
	if [ "$variant" = "resukisu" ]; then
		local dir="${WORKSPACE}/ReSukiSU_Patches"
		[ -d "$dir" ] || retry 3 git clone -q --depth=1 \
			https://github.com/ReSukiSU/ReSukiSU_Patches.git "$dir" || true
		local p="${dir}/scope-minimized/kernel-${kver}.patch"
		[ -f "$p" ] || die "ReSukiSU ships no scope-minimized hook patch for kernel ${kver}.
      Available: $(ls "${dir}/scope-minimized" 2>/dev/null | tr '\n' ' ')"
		( cd "$KERNEL_DIR" && apply_patch "$p" 1 ) \
			|| die "the ReSukiSU hook patch for kernel ${kver} did not apply.
      The vendor tree has diverged from the upstream file it was generated
      against; patch ${p} by hand or pick a fork that needs no hooks."
		endgroup
		return 0
	fi

	# SukiSU's patch repo carries per-version hook patches too.
	if [ "$variant" = "sukisu-ultra" ]; then
		local dir p
		dir=$(sukisu_patch_dir)
		for p in "${dir}/${kver}/"*hook*.patch "${dir}/hooks/syscall_hooks.patch"; do
			[ -f "$p" ] || continue
			if ( cd "$KERNEL_DIR" && apply_patch "$p" 1 ); then endgroup; return 0; fi
		done
	fi

	# Fall back to the in-repo sed script, which is what this action shipped
	# historically and still works for the 4.9-5.4 KernelSU 0.9.x hook API.
	info "falling back to the bundled legacy hook script"
	( cd "$KERNEL_DIR" && bash "${REPO_ROOT}/patches/legacy_ksu_hooks.sh" )
	endgroup
}

# SukiSU-Ultra's builtin branch flips ksu_handle_stat()/ksu_handle_faccessat()
# to `struct filename **` signatures when CONFIG_KSU_SUSFS is on. Those
# signatures only work for 5.10+ hook call sites (vfs_statx + getname);
# pre-GKI manual hook patches inject at the raw syscall layer where only
# `const char __user **` exists. Calling the struct-filename handler with a
# user-space string pointer crashes at init's first newfstatat: the handler
# dereferences user memory as if it were kernel struct filename ->
# "Unable to handle kernel access to user memory outside uaccess routines"
# (ESR 0x9600000f, PID 1, ~2.4s) -> panic("Attempted to kill init") ->
# boot loop. The compat patch hoists the user-pointer helpers out of the
# #else branch of sucompat.c and rewires the SUSFS-branch handlers back to
# user-pointer semantics, matching the call sites above.
sucompat_userptr_compat_apply() {
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"
	local patch="${REPO_ROOT}/patches/ksu/sukisu_susfs_sucompat_userptr_compat.patch"

	[ -f "$ksu_dir/kernel/feature/sucompat.h" ] || {
		warn "KernelSU tree not found at ${ksu_dir}; skipping sucompat compat"
		return 0
	}
	if ! grep -qF 'int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);' \
		"$ksu_dir/kernel/feature/sucompat.h"; then
		info "KSU tree does not use the SUSFS struct-filename stat signature; sucompat compat not needed"
		return 0
	fi

	group "Applying KSU sucompat user-pointer compat (SUSFS)"
	[ -f "$patch" ] || die "missing ${patch}"
	( cd "$ksu_dir" && apply_patch "$patch" 1 ) \
		|| die "the sucompat userptr compat patch did not apply"
	endgroup
}

# ================================================= SukiSU supercall bridge
#
# The SukiSU-Ultra builtin tree (CONFIG_KSU_SUSFS=y) defines
# ksu_supercall_reboot_handler() -- the callback that installs the
# [ksu_driver] anon fd the manager and ksud need for their ioctl
# supercalls -- but ksu_supercalls_init() in that build NEVER registers the
# reboot kprobe (that only happens in the non-SUSFS #else via a source-level
# ksu_handle_sys_reboot() injection, and the newer trees register the probe
# themselves). On 4.19 the hook patch repo ships no sys_reboot injection
# either, so the handler is orphan code: reboot(0xDEADBEEF, 0xCAFEBABE)
# returns -EINVAL, no fd is ever installed, and the manager reports "no
# SukiSU driver in kernel" even though every other KSU feature works.
#
# Fix: inject the call in SYSCALL_DEFINE4(reboot) in kernel/reboot.c, AFTER
# the local declarations (gnu89 forbids statements before them) but BEFORE
# the CAP_SYS_BOOT check -- exactly where the upstream kprobe's pre_handler
# would fire, and where non-root callers (the manager) can still reach it.
# Real reboots use LINUX_REBOOT_MAGIC1/2 and can never match the trick pair.
sukisu_supercall_reboot_apply() {
	local rc="${KERNEL_DIR}/kernel/reboot.c"
	group "Bridging SukiSU supercall reboot trick (kernel 4.19)"

	[ -f "$rc" ] || die "kernel/reboot.c not found under ${KERNEL_DIR}"

	if grep -q 'ksu_supercall_reboot_handler' "$rc"; then
		info "kernel/reboot.c already carries the supercall bridge; nothing to do"
		endgroup; return 0
	fi

	local ksud_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"
	grep -q 'ksu_supercall_reboot_handler' "${ksud_dir}/kernel/supercall/supercall.c" \
		|| die "the KSU tree at ${ksud_dir} does not define ksu_supercall_reboot_handler; the bridge does not apply to this tree"

	grep -q 'SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,' "$rc" \
		|| die "kernel/reboot.c does not match the 4.19 SYSCALL_DEFINE4(reboot) shape; the tree has drifted"

	perl -0pi -e '
s/(\tint ret = 0;\n)/$1\n\t\/* SukiSU supercall bridge (CONFIG_KSU_SUSFS builtin build): the tree
\t * defines ksu_supercall_reboot_handler() but never registers the reboot
\t * kprobe on this kernel, so the [ksu_driver] fd that the manager and
\t * ksud need for their ioctl supercalls can never be installed. Hook the
\t * reboot(2) magic trick here (0xDEADBEEF\/0xCAFEBABE), after the local
\t * declarations (gnu89) but before the CAP_SYS_BOOT check -- exactly
\t * where the upstream kprobe would fire. Real reboots use
\t * LINUX_REBOOT_MAGIC1\/2 and never match. *\/\n\tif (unlikely((unsigned int)magic1 == 0xDEADBEEFU &&\n\t\t     (unsigned int)magic2 == 0xCAFEBABEU)) {\n\t\textern int ksu_supercall_reboot_handler(void __user **arg);\n\t\tksu_supercall_reboot_handler((void __user **)&arg);\n\t}\n/
' "$rc"

	grep -q 'ksu_supercall_reboot_handler' "$rc" \
		|| die "the supercall bridge edit did not land; kernel/reboot.c no longer matches the 4.19 shape"

	ok "kernel/reboot.c: reboot(0xDEADBEEF, 0xCAFEBABE) now installs the [ksu_driver] fd"
	summary "| SukiSU supercall bridge | applied (sys_reboot magic trick) |"
	endgroup
}

# ------------------------------------------------ SukiSU manager fd bridge
#
# Even with the reboot trick bridged (sukisu_supercall_reboot_apply), the
# manager APP never calls it: it scans its own /proc/self/fd for the
# [ksu_driver] anon inode and relies on the kernel to install that fd into
# its process. Upstream does that from kernel/hook/setuid_hook.c
# (ksu_handle_setresuid -> ksu_install_fd when the new uid is the crowned
# manager), but the builtin branch this action pins for pre-GKI kernels does
# NOT ship setuid_hook.c at all -- so the manager keeps reporting "no SukiSU
# driver in kernel" even though the supercall fd machinery itself works.
#
# Fix: replicate the two-line core of upstream's setuid_hook inside
# __sys_setresuid() in kernel/sys.c. zygote drops every app into its uid via
# setresuid(3); when the new uid belongs to the crowned manager, install the
# fd. Injected AFTER the security hook (so retval is final and new->euid is
# set) but BEFORE commit_creds(), which the 4.19 code path returns directly.
# gnu89: the declarations must stay at the head of their own block.
sukisu_manager_fd_bridge_apply() {
	local sc="${KERNEL_DIR}/kernel/sys.c"
	group "Bridging SukiSU manager fd on setresuid (kernel 4.19)"

	[ -f "$sc" ] || die "kernel/sys.c not found under ${KERNEL_DIR}"

	if grep -q 'SukiSU manager fd bridge' "$sc"; then
		info "kernel/sys.c already carries the manager fd bridge; nothing to do"
		endgroup; return 0
	fi

	local ksud_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"
	grep -q 'ksu_manager_uid_authorized' "${ksud_dir}/kernel/manager/manager_identity.h" \
		|| die "the KSU tree at ${ksud_dir} does not expose ksu_manager_uid_authorized; the bridge does not apply to this tree"
	grep -q 'int ksu_install_fd(void)' "${ksud_dir}/kernel/supercall/supercall.h" \
		|| die "the KSU tree at ${ksud_dir} does not export ksu_install_fd; the bridge does not apply to this tree"

	grep -q 'security_task_fix_setuid(new, old, LSM_SETID_RES);' "$sc" \
		|| die "kernel/sys.c does not match the 4.19 __sys_setresuid shape; the tree has drifted"

	perl -0pi -e '
s/\tretval = security_task_fix_setuid\(new, old, LSM_SETID_RES\);\n\tif \(retval < 0\)\n\t\tgoto error;\n/\tretval = security_task_fix_setuid(new, old, LSM_SETID_RES);\n\tif (retval < 0)\n\t\tgoto error;\n\n\t\/* SukiSU manager fd bridge: the builtin tree build with
\t * CONFIG_KSU_SUSFS ships neither the reboot kprobe nor setuid_hook.c,
\t * so the manager process never receives its [ksu_driver] fd and the
\t * app reports "no SukiSU driver in kernel". zygote drops every app
\t * into its uid via setresuid(3) -- install the fd right here when the
\t * new uid is the crowned manager, exactly what upstream s
\t * setuid_hook does. Runs before commit_creds so the fd lands in the
\t * process that is about to become the manager. *\/\n\t{\n\t\textern bool ksu_manager_uid_authorized(uid_t uid);\n\t\textern int ksu_install_fd(void);\n\n\t\tif (unlikely(!retval && ksu_manager_uid_authorized(\n\t\t\t\t\t     from_kuid_munged(current_user_ns(), new->euid))))\n\t\t\tksu_install_fd();\n\t}\n/
' "$sc"

	grep -q 'SukiSU manager fd bridge' "$sc" \
		|| die "the manager fd bridge edit did not land; kernel/sys.c no longer matches the 4.19 shape"

	ok "kernel/sys.c: setresuid now installs the [ksu_driver] fd for the crowned manager"
	summary "| SukiSU manager fd bridge | applied (setresuid -> ksu_install_fd) |"
	endgroup
}

# ======================================================================== KPM

# SukiSU-Ultra's Kernel Patch Module support needs a post-link step: the
# patch_linux tool rewrites the built Image and emits oImage.
kpm_patch_image() {
	local image=$1
	group "Applying KPM (patch_linux)"
	local dir tool
	dir=$(sukisu_patch_dir)
	tool="${dir}/kpm/patch_linux"
	[ -f "$tool" ] || die "kpm/patch_linux not found in ${SUKISU_PATCH_REPO}"
	chmod +x "$tool"
	( cd "$(dirname "$image")" && "$tool" "$(basename "$image")" ) \
		|| die "patch_linux failed"
	local out
	out="$(dirname "$image")/oImage"
	[ -f "$out" ] || die "patch_linux did not produce oImage"
	mv -f "$out" "$image"
	ok "KPM applied to $(basename "$image")"
	summary "| KPM | applied |"
	endgroup
}

# --------------------------------------------------------------------- main ---

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		susfs)        susfs_apply ;;
		path_umount)  path_umount_apply ;;
		hide_stuff)   hide_stuff_apply ;;
		hooks)        hooks_patch_apply ;;
		kpm)          kpm_patch_image "$2" ;;
		all)
			# Order matters and this is the tested one (4.19 + SukiSU builtin
			# + SUSFS 1.5.5, no rejects):
			#   path_umount and the hook patches both key off textual anchors
			#   in files that SUSFS later rewrites, so they go first.
			if is_true "${ENABLE_PATH_UMOUNT:-false}"; then path_umount_apply; fi

			# Driven by the *resolved* hook mode, not the raw setting, so that
			# KSU_HOOK_MODE=auto on a pre-GKI kernel still gets its hooks
			# patched in rather than only getting the Kconfig symbol set.
			if [ "${KSU_VARIANT:-none}" != "none" ] &&
			   [ "${KSU_HOOK_MODE_RESOLVED:-}" = "manual" ]; then
				hooks_patch_apply
				# The manual hook call sites pass `const char __user **`; make
				# the KSU-side handlers accept that even under SUSFS. Self
				# -guarding: only fires when the struct-filename signature
				# (SUSFS variant) is present in the KSU tree.
				sucompat_userptr_compat_apply
				# Wire the orphaned ksu_supercall_reboot_handler() into
				# sys_reboot so the manager/ksud supercall fd can be installed.
				sukisu_supercall_reboot_apply
				# Give the crowned manager process its [ksu_driver] fd on the
				# zygote setresuid, so the app can actually use the supercall
				# surface (upstream ships this as setuid_hook.c; the builtin
				# branch does not).
				sukisu_manager_fd_bridge_apply
			fi

			if is_true "${ENABLE_SUSFS:-false}";      then susfs_apply;      fi
			if is_true "${ENABLE_HIDE_STUFF:-false}"; then hide_stuff_apply; fi
			if is_true "${ENABLE_MODVERSIONS_TOLERANCE:-false}"; then modversions_tolerance_apply; fi
			if is_true "${ENABLE_CAMX_KMD:-false}";   then camx_kmd_apply;   fi
			;;
			modversions_tolerance) modversions_tolerance_apply ;;
			camx_kmd)              camx_kmd_apply ;;
			sucompat_compat)       sucompat_userptr_compat_apply ;;
			supercall_reboot)      sukisu_supercall_reboot_apply ;;
		*) die "unknown patch step '$1'" ;;
	esac
fi
