#!/usr/bin/env bash
# Install a KernelSU variant into the kernel tree.
#
# Every variant ships a near-identical kernel/setup.sh that clones itself next
# to the kernel tree and symlinks drivers/kernelsu at it. They differ in three
# ways that matter, all of which are encoded in the registry below:
#
#   * the directory the clone lands in (KernelSU vs KernelSU-Next),
#   * what "no argument" means -- most check out the latest tag, ReSukiSU
#     checks out main,
#   * which ref carries non-GKI support and which carries SUSFS.
#
# The critical safety property: every variant's setup.sh ends its checkout with
#     git checkout "$1" ... || echo "[-] Checkout default branch"
# so an invalid ref does NOT fail the script -- it silently leaves the tree on
# the default branch. A build asking for SukiSU's SUSFS-capable 'builtin'
# branch and typing 'susfs-main' (which does not exist) would quietly produce a
# kernel with no SUSFS at all. So we validate the ref before calling setup.sh
# and verify the checkout afterwards.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}

# ------------------------------------------------------------- registry -----
#
# Fields, '|'-separated:
#   1 repo URL
#   2 ref the setup.sh script itself is fetched from
#   3 directory setup.sh clones into, relative to the kernel tree
#   4 default ref for modern (>= 5.10) kernels; empty means "let setup.sh pick"
#   5 default ref for legacy (< 5.10) kernels
#   6 refs that already contain SUSFS support (space separated; '-' for none)
#   7 human-readable name
#
# Verified against each repo's live branch/tag list on 2026-07-27.

ksu_registry() {
	case "$1" in
	kernelsu)
		# Official upstream. Dropped non-GKI support at v1.0, so legacy kernels
		# are pinned to the last release that supports them.
		echo "https://github.com/tiann/KernelSU|main|KernelSU||v0.9.5|-|KernelSU" ;;
	kernelsu-next)
		# 'next' was renamed to 'legacy' and the default branch is now 'dev'.
		# Raw URLs containing /next/ only still work via GitHub's rename
		# redirect, so we address the real branches directly.
		echo "https://github.com/KernelSU-Next/KernelSU-Next|dev|KernelSU-Next|dev|legacy|-|KernelSU-Next" ;;
	sukisu-ultra)
		# Repo moved from the personal ShirkNeko account into its own org.
		# 'main' is the modular v4 tree (KPM, no SUSFS); 'builtin' is the
		# non-GKI/source-integrated tree and is the only one with SUSFS Kconfig.
		echo "https://github.com/SukiSU-Ultra/SukiSU-Ultra|main|KernelSU|main|builtin|builtin|SukiSU-Ultra" ;;
	resukisu)
		# Re-fork of SukiSU-Ultra aimed at legacy/non-GKI kernels. The project
		# renamed itself to BakaSU; ReSukiSU/ReSukiSU only still resolves via a
		# GitHub redirect, and its setup.sh clones Baka-SU/BakaSU regardless.
		# Validate the ref against the repo that is actually cloned, otherwise a
		# branch name taken from the redirect target looks valid while the
		# checkout lands somewhere else.
		echo "https://github.com/Baka-SU/BakaSU|main|KernelSU|main|main|-|ReSukiSU" ;;
	rsuntk)
		echo "https://github.com/rsuntk/KernelSU|main|KernelSU|main|main|susfs-rksu-master|RKSU (rsuntk)" ;;
	backslashxx)
		echo "https://github.com/backslashxx/KernelSU|master|KernelSU|master|master|-|backslashxx KernelSU" ;;
	*)
		die "unknown KSU_VARIANT '$1'" ;;
	esac
}

ksu_field() { ksu_registry "$1" | cut -d'|' -f"$2"; }

# ReSukiSU's setup.sh checks out 'main' when given no argument, while every
# other variant checks out the latest tag. Call that out so an unpinned CI
# build is not silently tracking a moving branch.
ksu_default_is_branch() { [ "$1" = "resukisu" ]; }

# ksu_ref_owner REF -- which variant's registry entry mentions REF?
#
# Mixing up variants is the usual reason a ref "does not exist": the dispatch
# form remembers the last value typed into ksu_ref, so a build switched from
# SukiSU-Ultra to ReSukiSU keeps asking for SukiSU's 'builtin' branch, which
# ReSukiSU has never had. Printing the owner turns a bare branch list into a
# diagnosis.
ksu_ref_owner() {
	local want=$1 v mref lref srefs owned
	for v in kernelsu kernelsu-next sukisu-ultra resukisu rsuntk backslashxx; do
		IFS='|' read -r _ _ _ mref lref srefs _ <<<"$(ksu_registry "$v")"
		for owned in $mref $lref $srefs; do
			[ "$owned" = "$want" ] && { printf '%s' "$v"; return 0; }
		done
	done
	return 1
}

# ksu_default_ref VARIANT KVER -- the ref the variant itself would pick.
ksu_default_ref() {
	local variant=$1 kver=$2 mref lref
	IFS='|' read -r _ _ _ mref lref _ _ <<<"$(ksu_registry "$variant")"
	if ver_ge "$kver" "5.10"; then printf '%s' "$mref"; else printf '%s' "$lref"; fi
}

# ---------------------------------------------------------------- install ---

ksu_install() {
	local variant=$1 requested_ref=${2-}

	[ "$variant" = "none" ] && { info "KernelSU integration disabled"; return 0; }

	local repo setup_ref dir modern_ref legacy_ref susfs_refs name
	IFS='|' read -r repo setup_ref dir modern_ref legacy_ref susfs_refs name <<<"$(ksu_registry "$variant")"

	group "Installing ${name}"
	info "repository: ${repo}"

	# Decide which ref to check out.
	local kver ref=$requested_ref
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")
	if [ -z "$ref" ]; then
		ref=$(ksu_default_ref "$variant" "$kver")
		if [ -n "$ref" ]; then
			if ver_ge "$kver" "5.10"; then
				info "kernel ${kver}; defaulting to ref '${ref}'"
			else
				info "kernel ${kver} is pre-GKI; defaulting to ref '${ref}'"
			fi
		fi
	fi

	# Validate before handing the ref to setup.sh, which would swallow a typo.
	#
	# A ref that exists in a *different* variant is not a typo, it is a stale
	# workflow input -- the dispatch form keeps ksu_ref between runs, so a build
	# switched from SukiSU-Ultra to ReSukiSU keeps asking for SukiSU's 'builtin'.
	# Falling back to this variant's own default (loudly) keeps an otherwise
	# correct build from dying on a leftover string. A ref nobody owns is still
	# fatal: that is a real typo and setup.sh would silently ignore it.
	if [ -n "$ref" ]; then
		info "validating ref '${ref}' exists in ${repo}"
		local owner
		if ref_exists "$repo" "$ref"; then
			ok "ref '${ref}' exists"
		elif owner=$(ksu_ref_owner "$ref"); then
			warn "KSU_REF='${ref}' is a ref of ${owner}, not ${name}; ignoring the workflow input."
			ref=$(ksu_default_ref "$variant" "$kver")
			warn "using ${name}'s own default for kernel ${kver}: '${ref:-latest tag}'"
		else
			local avail
			avail=$(git ls-remote --heads "$repo" 2>/dev/null | awk '{print $2}' \
				| sed 's@refs/heads/@@' | grep -v dependabot | tr '\n' ' ')
			die "ref '${ref}' does not exist in ${repo}.
      setup.sh would silently fall back to the default branch and you would
      get a kernel without the feature you asked for.
      Available branches: ${avail}
      hint: leave KSU_REF empty to use this variant's own default
      (pre-5.10: '${legacy_ref}', 5.10+: '${modern_ref:-latest tag}')."
		fi
	else
		warn "no ref pinned; setup.sh will pick the latest tag. Set KSU_REF for reproducible builds."
	fi

	if [ -z "$requested_ref" ] && ksu_default_is_branch "$variant"; then
		warn "${name}'s setup.sh defaults to the moving 'main' branch rather than a tag."
		warn "Pin KSU_REF (e.g. a tag) if you need reproducible builds."
	fi

	# Run the variant's own installer.
	local setup_url="https://raw.githubusercontent.com/${repo#https://github.com/}/${setup_ref}/kernel/setup.sh"
	info "running ${setup_url}"
	(
		cd "$KERNEL_DIR"
		if [ -n "$ref" ]; then
			fetch_stdout "$setup_url" | bash -s "$ref"
		else
			fetch_stdout "$setup_url" | bash
		fi
	) || die "${name} setup.sh failed"

	# --- verify the installer actually did what it claims ------------------
	local ksu_dir="${KERNEL_DIR}/${dir}"
	[ -d "$ksu_dir" ] || die "${name} setup.sh finished but ${dir}/ is missing"

	local link="${KERNEL_DIR}/drivers/kernelsu"
	[ -e "$link" ] || die "drivers/kernelsu symlink was not created"

	# setup.sh only checks whether the word "kernelsu" already appears.  Some
	# vendor trees carry an obsolete line guarded by CONFIG_WITH_KERNEL_SU, so
	# setup.sh reports success without adding the CONFIG_KSU rule and the final
	# link fails with every ksu_handle_* symbol undefined.  Normalize any stale
	# rule to the symbol declared by the installed Kconfig.
	local driver_makefile="${KERNEL_DIR}/drivers/Makefile"
	if ! grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile"; then
		if grep -qE '^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile"; then
			sed -i -E 's@^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$@obj-$(CONFIG_KSU) += kernelsu/@' "$driver_makefile"
			warn "normalized stale drivers/Makefile KernelSU guard to CONFIG_KSU"
		else
			printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >>"$driver_makefile"
			warn "added missing CONFIG_KSU rule to drivers/Makefile"
		fi
	fi

	grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile" \
		|| die "drivers/Makefile was not wired to CONFIG_KSU for kernelsu"
	grep -q 'drivers/kernelsu/Kconfig' "${KERNEL_DIR}/drivers/Kconfig" \
		|| die "drivers/Kconfig was not wired up for kernelsu"

	# --- non-GKI compat fixes ----------------------------------------------
	# SukiSU-Ultra's kernel_includes.h pulls in 5.10+-only headers
	# unconditionally. None of them is referenced anywhere in the KSU tree
	# (verified on the builtin branch), so a plain version guard is enough
	# for pre-GKI kernels. Without this, 4.19 dies with
	# "fatal error: 'linux/static_call.h' file not found".
	local inc_h
	inc_h="${ksu_dir}/kernel/kernel_includes.h"
	if [ -f "$inc_h" ] && ! ver_ge "$kver" "5.10"; then
		if grep -q '<linux/static_call\.h>' "$inc_h"; then
			sed -i 's@^#include <linux/static_call\.h>$@#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n#include <linux/static_call.h>\n#endif@' "$inc_h"
			warn "guarded <linux/static_call.h> for kernel ${kver} (header not present pre-5.3)"
		fi
		if grep -q '<linux/hex\.h>' "$inc_h"; then
			sed -i 's@^#include <linux/hex\.h>$@#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 13, 0)\n#include <linux/hex.h>\n#endif@' "$inc_h"
			warn "guarded <linux/hex.h> for kernel ${kver} (header not present pre-5.13)"
		fi
		if grep -q '<uapi/linux/mount\.h>' "$inc_h"; then
			sed -i 's@^#include <uapi/linux/mount\.h>$@#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 11, 0)\n#include <uapi/linux/mount.h>\n#endif@' "$inc_h"
			warn "guarded <uapi/linux/mount.h> for kernel ${kver} (uapi header not present pre-5.11)"
		fi
	fi

	# kpm.c calls the 5.0+-style two-argument access_ok() directly, bypassing
	# the ksu_access_ok() shim in kernel_compat.h (which already handles the
	# pre-5.0 three-argument form via VERIFY_READ). KPM is disabled for this
	# build but the file is still compiled (it is #included by ksu_main.c),
	# so fix the call site instead of skipping it. Only applies pre-5.0.
	local kpm_c
	kpm_c="${ksu_dir}/kernel/extension/kpm/kpm.c"
	if [ -f "$kpm_c" ] && ! ver_ge "$kver" "5.0"; then
		if grep -q 'access_ok(u64_to_user_ptr(cmd.result_code), sizeof(result))' "$kpm_c"; then
			sed -i 's@access_ok(u64_to_user_ptr(cmd.result_code), sizeof(result))@access_ok(VERIFY_WRITE, u64_to_user_ptr(cmd.result_code), sizeof(result))@' "$kpm_c"
			warn "fixed two-argument access_ok() in kpm.c for kernel ${kver}"
		fi
	fi

	# Confirm we landed on the ref we asked for, catching the silent fallback.
	local head_desc head_sha
	head_sha=$(git -C "$ksu_dir" rev-parse --short HEAD)
	head_desc=$(git -C "$ksu_dir" describe --tags --always 2>/dev/null || echo "$head_sha")
	if [ -n "$ref" ]; then
		local want
		want=$(git -C "$ksu_dir" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null || true)
		if [ -n "$want" ] && [ "$want" != "$(git -C "$ksu_dir" rev-parse HEAD)" ]; then
			die "${name} is checked out at ${head_desc}, not the requested ref '${ref}'"
		fi
	fi
	ok "${name} installed at ${head_desc} (${head_sha})"

	# --- publish facts the later steps need --------------------------------
	local count version_label
	count=$(git -C "$ksu_dir" rev-list --count HEAD 2>/dev/null || echo 0)
	if git -C "$ksu_dir" describe --exact-match --tags >/dev/null 2>&1; then
		version_label=$(git -C "$ksu_dir" describe --exact-match --tags)
	else
		version_label="${ref:-HEAD}-${head_sha}"
	fi

	export_env KSU_DIR "$dir"
	export_env KSU_NAME "$name"
	export_env KSU_REF_RESOLVED "${ref:-<latest-tag>}"
	export_env KSU_VERSION_LABEL "$version_label"
	export_env KSU_COMMIT_COUNT "$count"
	export_env KSU_SUSFS_BUNDLED_REFS "$susfs_refs"
	export_env UPLOADNAME "-${name// /_}_${version_label}"

	ksu_resolve_hook_mode "${KSU_HOOK_MODE:-auto}" "$kver"

	summary "| KernelSU variant | \`${name}\` |"
	summary "| KernelSU ref | \`${ref:-latest tag}\` -> \`${version_label}\` |"

	endgroup
}

# ------------------------------------------------------------ hook config ---
#
# Which hook mechanism a variant should use is genuinely version- and
# fork-specific. 'auto' picks the option that the variant actually declares.

# Resolve 'auto' into a concrete mode and publish it.
#
# This has to happen once, early, and be reused by BOTH the source-patching
# step and the defconfig step. Resolving it independently in each place is how
# you end up setting CONFIG_KSU_MANUAL_HOOK on a tree whose syscall entry
# points were never actually patched -- which builds fine and then does
# nothing at runtime.
ksu_resolve_hook_mode() {
	local mode=${1:-auto} kver=$2
	if [ "$mode" = "auto" ]; then
		if ver_ge "$kver" "5.10"; then
			mode="kprobes"
		else
			# kprobes on pre-GKI kernels is the classic source of "KernelSU
			# installed but su does nothing" reports; manual hooks are patched
			# straight into the syscall entry points instead.
			mode="manual"
		fi
		info "hook mode 'auto' resolved to '${mode}' for kernel ${kver}"
	fi
	export_env KSU_HOOK_MODE_RESOLVED "$mode"
}

ksu_hook_configs() {
	local variant=$1 mode=$2 defconfig=$3 kver=$4

	if [ "$mode" = "auto" ]; then
		[ -n "${KSU_HOOK_MODE_RESOLVED:-}" ] || ksu_resolve_hook_mode "$mode" "$kver"
		mode=$KSU_HOOK_MODE_RESOLVED
	fi

	case "$mode" in
	none) return 0 ;;
	kprobes)
		kconf_enable "$defconfig" CONFIG_MODULES
		kconf_enable "$defconfig" CONFIG_KPROBES
		kconf_enable "$defconfig" CONFIG_HAVE_KPROBES
		kconf_enable "$defconfig" CONFIG_KPROBE_EVENTS
		kconf_enable "$defconfig" CONFIG_KRETPROBES
		[ "$variant" = "kernelsu-next" ] && kconf_enable "$defconfig" CONFIG_KSU_KPROBES_HOOK
		;;
	manual)
		case "$variant" in
			kernelsu-next)  kconf_enable "$defconfig" CONFIG_KSU_MANUAL_HOOK ;;
			sukisu-ultra)
				kconf_enable "$defconfig" CONFIG_KSU_MANUAL_HOOK ;;
			resukisu)
				# ReSukiSU's non-GKI static export check requires the complete
				# kallsyms table unless every internal SELinux symbol is exported
				# manually by the vendor tree.
				#
				# The three AUTO_* options are not optional in practice: the
				# scope-minimized hook patch only patches execveat/faccessat/
				# stat/reboot, while tools/manual_hook_check.mk hard-fails the
				# build for every hook it cannot find. These options supply the
				# remaining setresuid / sys_read / input hooks through LSM and
				# input_handler instead of more source patches. They are
				# unusable on 6.8+, so the fork only defaults them on for the
				# legacy kernels this variant targets.
				kconf_set_many "$defconfig" \
					CONFIG_KSU_MANUAL_HOOK=y CONFIG_DEBUG_KERNEL=y \
					CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y \
					CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y \
					CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y \
					CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y ;;
			*) : ;;  # tiann/KernelSU 0.9.x infers manual hooks from the source patch
		esac
		;;
	tracepoint)
		[ "$variant" = "resukisu" ] || [ "$variant" = "sukisu-ultra" ] \
			|| warn "hook mode 'tracepoint' is only declared by ReSukiSU/SukiSU-Ultra; ignoring for ${variant}"
		kconf_enable "$defconfig" CONFIG_KSU_TRACEPOINT_HOOK
		;;
	syscall)
		kconf_enable "$defconfig" CONFIG_KSU_SYSCALL_HOOK
		;;
	esac
}

# Only run the installer when sourced as a script entry point.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	ksu_install "${KSU_VARIANT:-none}" "${KSU_REF:-}"
fi
