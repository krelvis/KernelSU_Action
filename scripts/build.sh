#!/usr/bin/env bash
# Prepare the defconfig and compile the kernel.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=scripts/kernelsu.sh
. "$(dirname "${BASH_SOURCE[0]}")/kernelsu.sh"
# shellcheck source=scripts/patches.sh
. "$(dirname "${BASH_SOURCE[0]}")/patches.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
OUT="${KERNEL_DIR}/out"

DEFCONFIG_PATH="${KERNEL_DIR}/arch/${ARCH}/configs/${KERNEL_CONFIG}"

# ------------------------------------------------------------- defconfig ---

prepare_defconfig() {
	group "Preparing defconfig"
	[ -f "$DEFCONFIG_PATH" ] \
		|| die "defconfig not found: arch/${ARCH}/configs/${KERNEL_CONFIG}
       Available: $(ls "${KERNEL_DIR}/arch/${ARCH}/configs/" | head -20 | tr '\n' ' ')"

	cp "$DEFCONFIG_PATH" "${WORKSPACE}/defconfig.orig"

	local kver
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")

	if [ "${KSU_VARIANT:-none}" != "none" ]; then
		kconf_enable "$DEFCONFIG_PATH" CONFIG_KSU
		ksu_hook_configs "${KSU_VARIANT}" "${KSU_HOOK_MODE:-auto}" "$DEFCONFIG_PATH" "$kver"

		if is_true "${ENABLE_SUSFS:-false}"; then
			susfs_defconfig "$DEFCONFIG_PATH"
		fi

		if is_true "${ENABLE_KPM:-false}"; then
			# patch_linux resolves symbols at runtime, so kallsyms must be complete.
			kconf_set_many "$DEFCONFIG_PATH" \
				CONFIG_KPM=y CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y
		fi
	fi

	# Overlayfs backs KernelSU's module mounts and system-partition writes.
	is_true "${ADD_OVERLAYFS_CONFIG:-false}" && kconf_enable "$DEFCONFIG_PATH" CONFIG_OVERLAY_FS

	# Kept as a standalone switch for kernels that need kprobes for their own
	# reasons, independent of the hook mode.
	if is_true "${ADD_KPROBES_CONFIG:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_MODULES=y CONFIG_KPROBES=y CONFIG_HAVE_KPROBES=y CONFIG_KPROBE_EVENTS=y
	fi

	if is_true "${DISABLE_LTO:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_LTO=n CONFIG_LTO_CLANG=n CONFIG_LTO_CLANG_FULL=n \
			CONFIG_LTO_CLANG_THIN=n CONFIG_THINLTO=n CONFIG_LTO_NONE=y
	fi

	is_true "${DISABLE_CC_WERROR:-false}" && kconf_disable "$DEFCONFIG_PATH" CONFIG_CC_WERROR

	# Free-form extras: one CONFIG_x=y per line, or space separated.
	if [ -n "${EXTRA_DEFCONFIG:-}" ]; then
		local kv
		# shellcheck disable=SC2086
		for kv in $(printf '%s' "$EXTRA_DEFCONFIG" | tr '\n' ' '); do
			[ -n "$kv" ] || continue
			case "$kv" in
				*=*) kconf_set "$DEFCONFIG_PATH" "${kv%%=*}" "${kv#*=}" ;;
				*)   warn "ignoring malformed EXTRA_DEFCONFIG entry '${kv}' (want CONFIG_X=y)" ;;
			esac
		done
	fi

	# A stable LOCALVERSION keeps artifact names predictable. Without this the
	# tree appends "-dirty" as soon as any patch above touches a tracked file.
	if [ -n "${KERNEL_NAME:-}" ]; then
		kconf_set "$DEFCONFIG_PATH" CONFIG_LOCALVERSION "\"-${KERNEL_NAME}\""
		if [ -f "${KERNEL_DIR}/scripts/setlocalversion" ]; then
			sed -i 's/echo "\$res"/echo "\$res"/; s/-dirty//g' "${KERNEL_DIR}/scripts/setlocalversion"
		fi
	fi

	info "defconfig changes:"
	diff -u "${WORKSPACE}/defconfig.orig" "$DEFCONFIG_PATH" | sed -n '4,$p' | sed 's/^/    /' || true
	endgroup
}

# --------------------------------------------------------------- warnings ---

# 4.19 vendor trees hard-code -Werror in per-directory flags
# (techpack/display/oplus, drivers/input/touchscreen/oplus_touchscreen, ...).
# Those are expanded inside c_flags *after* KBUILD_CFLAGS, so the
# KCFLAGS=-Wno-error passed to make cannot neutralise them, and clang 14 then
# rejects decades-old vendor code GCC compiled happily:
#   error: this old-style function definition is not preceded by a prototype
#   [-Werror,-Wstrict-prototypes]
# Rewrite every occurrence in the tree and append the flag to c_flags as a
# belt-and-braces measure. Warnings stay visible; only their promotion to
# errors is removed.
neutralize_werror() {
	is_true "${DISABLE_CC_WERROR:-false}" || return 0
	group "Neutralising -Werror"

	local f count=0
	while IFS= read -r -d '' f; do
		grep -q -- '-Werror' "$f" 2>/dev/null || continue
		sed -i 's/-Werror/-Wno-error/g' "$f"
		count=$((count + 1))
	done < <(find "$KERNEL_DIR" -path "${KERNEL_DIR}/out" -prune -o \
		\( -name 'Makefile' -o -name 'Makefile.*' -o -name 'Kbuild' -o -name '*.mk' \) \
		-type f -print0)

	if [ "$count" -eq 0 ]; then
		info "no -Werror flags found in the tree"
	else
		ok "neutralised -Werror in ${count} makefile(s)"
	fi

	local lib="${KERNEL_DIR}/scripts/Makefile.lib"
	if [ -f "$lib" ] && ! grep -q 'KernelSU_Action: keep vendor -Werror' "$lib"; then
		printf '\n# KernelSU_Action: keep vendor -Werror flags from breaking clang builds\nc_flags += -Wno-error\n' >>"$lib"
		ok "appended -Wno-error to c_flags in scripts/Makefile.lib"
	fi
	endgroup
}

# lld rejects absolute relocations that a CONFIG_RELOCATABLE arm64 link emits:
#   ld.lld: error: relocation R_AARCH64_ABS32 cannot be used against symbol
#   '__crc_gsi_write_channel_scratch'; recompile with -fPIC
# The __crc_* symbols come from CONFIG_MODVERSIONS, and lld treats the
# -shared/-Bsymbolic vmlinux link as PIC. Newer arm64 Makefiles pass -z notext
# for exactly this; 4.19 predates the workaround, so add it. GNU ld also
# accepts the flag, so this is safe if LD is not lld.
ensure_lld_notext() {
	local mk="${KERNEL_DIR}/arch/${ARCH}/Makefile"
	[ -f "$mk" ] || return 0
	if grep -q 'KernelSU_Action: allow lld text relocations' "$mk"; then
		return 0
	fi
	printf '\n# KernelSU_Action: allow lld text relocations\nLDFLAGS_vmlinux += -z notext\n' >>"$mk"
	ok "appended '-z notext' to LDFLAGS_vmlinux"
}

# ----------------------------------------------------------------- build ---

make_args() {
	printf '%s' "O=out ARCH=${ARCH}"
	[ -n "${CUSTOM_CMDS:-}" ] && printf ' %s' "$CUSTOM_CMDS"
	[ -n "${EXTRA_CMDS:-}"  ] && printf ' %s' "$EXTRA_CMDS"
	[ -n "${GCC_64:-}"      ] && printf ' %s' "$GCC_64"
	[ -n "${GCC_32:-}"      ] && printf ' %s' "$GCC_32"
	if is_true "${USE_LLVM:-false}"; then
		printf ' LLVM=1 LLVM_IAS=1'
		[ -n "${GCC_64:-}" ] || printf ' CROSS_COMPILE=aarch64-linux-gnu-'
	fi
}

# A failing make only surfaces as a one-line die() message, and the job log
# needs authentication to download. Re-emit the tail as annotations so the
# real compiler error is readable straight from the public check-runs API.
dump_make_log() {
	local log=$1
	[ -s "$log" ] || return 0
	# One annotation, not one per line: GitHub keeps only the first 10
	# annotations of a step, so a 40-line dump would hide the real error at the
	# bottom. %0A is the workflow-command escape for a newline.
	#
	# clang 14 on a GCC-era tree emits hundreds of "unknown warning option"
	# warnings, and a plain tail of the log is nothing but that noise -- the
	# actual diagnostic scrolls well past it. Prefer real error lines, and only
	# fall back to the tail when the build failed for some other reason.
	local lines
	lines=$(grep -aE 'error:|Error [0-9]|\*\*\* |undefined symbol|No rule to make|fatal error|ld\.lld: error' "$log" 2>/dev/null | tail -n 40)
	if [ -z "$lines" ]; then
		info "last 80 lines of ${log}:"
		lines=$(tail -n 80 "$log")
	else
		info "error lines from ${log}:"
	fi
	local msg
	msg=$(printf '%s\n' "$lines" | tr -d '\r' | awk '{ gsub(/%/,"%25"); printf "%s%%0A", $0 }')
	[ -n "$msg" ] && echo "::error::make output tail:%0A${msg}"
}

build_kernel() {
	group "Building kernel"
	export PATH="${CLANG_PATH:-}:${PATH}"
	export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-Github-Action}
	export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-kernelsu-action}

	# DISABLE_LTO is this action's boolean configuration switch, but several
	# Android kernel trees use the same Make variable for compiler flags (for
	# example, "-fno-lto").  Leaving our value in the environment makes a
	# non-LTO build invoke `clang ... false ...`, treating "false" as an input
	# file.  prepare_defconfig() has already consumed the action setting, so let
	# Kbuild own the name from this point on.
	unset DISABLE_LTO

	# Custom manager signature, when the user builds their own manager APK.
	if [ -n "${KSU_EXPECTED_SIZE:-}" ] && [ -n "${KSU_EXPECTED_HASH:-}" ]; then
		export KSU_EXPECTED_SIZE KSU_EXPECTED_HASH
		info "using custom manager signature (size=${KSU_EXPECTED_SIZE})"
	fi

	local cc="clang" args
	args=$(make_args)

	neutralize_werror
	ensure_lld_notext

	# CONFIG_CC_WERROR only exists on 5.15+; this 4.19 vendor tree hard-codes
	# -Werror in KBUILD_CFLAGS instead, so kconf_disable above cannot reach it
	# and clang 14 turns warnings GCC never emitted into hard errors
	# (drivers/vservices/session.c: unused-but-set variable). KCFLAGS is
	# expanded after KBUILD_CFLAGS, so -Wno-error neutralises it. This replaces
	# the KCFLAGS coming from EXTRA_CMDS, which only carried a narrower
	# -Wno-error=strict-prototypes.
	if is_true "${DISABLE_CC_WERROR:-false}"; then
		args="$args KCFLAGS=-Wno-error"
	fi

	# OPLUS gates whole objects on make variables that its Android build exports
	# from oplus_native_features.mk. OplusKernelEnvConfig.mk only turns the same
	# names into -D macros (its ALLOWED_MCROS list is unconditional), so a bare
	# `make` compiles every caller but skips the callee objects, and vmlinux
	# then fails to link:
	#   ld.lld: error: undefined symbol: ufsf_init
	#   ld.lld: error: undefined symbol: create_signal_quality_proc
	#   ld.lld: error: undefined symbol: is_reclaim_should_cancel
	# Forward every switch in that file, which is exactly what the Android build
	# passes on the make command line. OPLUS_NATIVE_FEATURE_SET is a space
	# separated name list, not a switch, so it is dropped.
	if [ -f "${KERNEL_DIR}/oplus_native_features.mk" ]; then
		local oplus_vars
		oplus_vars=$(sed -nE '/^OPLUS_NATIVE_FEATURE_SET=/d
			s/^(OPLUS_[A-Za-z0-9_]+)=([^[:space:]]+)$/\1=\2/p' \
			"${KERNEL_DIR}/oplus_native_features.mk" | tr '\n' ' ')
		args="$args ${oplus_vars}"
		info "exporting $(printf '%s' "$oplus_vars" | wc -w) OPLUS switch(es) to make"
	fi
	if is_true "${ENABLE_CCACHE:-true}" && command -v ccache >/dev/null; then
		cc="ccache clang"
		export CCACHE_DIR="${CCACHE_DIR:-${WORKSPACE}/.ccache}"
		info "ccache enabled (dir: ${CCACHE_DIR})"
	fi

	cd "$KERNEL_DIR"
	local build_log="${WORKSPACE}/build.log"
	: > "$build_log"

	info "make ${args} ${KERNEL_CONFIG}"
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC=clang $args "${KERNEL_CONFIG}" 2>&1 | tee -a "$build_log" \
		|| { dump_make_log "$build_log"; die "defconfig generation failed"; }

	# Build the image target explicitly. On Qualcomm trees the default goal is
	# "Image dtbs", and dtbs pulls in arch/arm64/boot/dts/vendor, which needs the
	# camera/video submodules this dump does not ship. AnyKernel3 only replaces
	# the kernel image, so the devicetrees are dead weight for this package.
	info "make ${args} ${KERNEL_IMAGE_NAME}"
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC="$cc" $args "${KERNEL_IMAGE_NAME}" 2>&1 | tee -a "$build_log" \
		|| { dump_make_log "$build_log"; die "kernel build failed"; }

	endgroup
}

# --------------------------------------------------------------- verify ---

check_output() {
	group "Checking build output"
	local boot="${OUT}/arch/${ARCH}/boot"
	local image="${boot}/${KERNEL_IMAGE_NAME}"

	[ -f "$image" ] || die "expected kernel image not found: ${image}
       Built files: $(ls "$boot" 2>/dev/null | tr '\n' ' ')
       Check that KERNEL_IMAGE_NAME matches what your kernel produces."

	ok "kernel image: ${KERNEL_IMAGE_NAME} ($(du -h "$image" | cut -f1))"
	export_env CHECK_FILE_IS_OK true

	if is_true "${NEED_DTBO:-false}"; then
		[ -f "${boot}/dtbo.img" ] || die "NEED_DTBO=true but ${boot}/dtbo.img was not produced"
		export_env CHECK_DTBO_IS_OK true
		ok "dtbo.img present"
	fi

	# KPM rewrites the image in place, so it has to happen after the build and
	# before packaging.
	if is_true "${ENABLE_KPM:-false}"; then
		kpm_patch_image "$image"
	fi

	# Record the version string the kernel actually reports.
	if [ -f "${OUT}/include/generated/utsrelease.h" ]; then
		local rel
		rel=$(sed -nE 's/.*UTS_RELEASE[[:space:]]+"([^"]+)".*/\1/p' "${OUT}/include/generated/utsrelease.h")
		export_env KERNEL_RELEASE "$rel"
		ok "kernel release: ${rel}"
		summary "| Kernel release | \`${rel}\` |"
	fi
	endgroup
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		defconfig) prepare_defconfig ;;
		compile)   build_kernel ;;
		check)     check_output ;;
		all)       prepare_defconfig; build_kernel; check_output ;;
		*) die "unknown build step '$1'" ;;
	esac
fi
