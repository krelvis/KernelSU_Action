#!/bin/bash
# Build & sign the fgetpriority LKM against this build's kernel tree.
#
# Why here: the OnePlus 9R kernel is 4.19 non-GKI with CONFIG_MODULE_SIG_FORCE=y,
# so the upstream module's prebuilt GKI kos (android12-5.10 .. android17-6.12)
# can neither match vermagic nor pass signature verification. Building against
# the very tree this run just compiled gives a vermagic- and modversions-exact
# ko, and signing it with the tree's own generated module key
# (CONFIG_MODULE_SIG_KEY=certs/signing_key.pem, auto-added to the builtin
# keyring) makes it loadable under SIG_FORCE.
#
# Output: kernel_workspace/fgetpriority-module-4.19.zip (KSU module, manager-installable)
set -euo pipefail

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
OUT="$KERNEL_DIR/out"
SRC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOD_SRC="$SRC_ROOT/fgetpriority"
ZIP_OUT="$WORKSPACE/fgetpriority-module-4.19.zip"

group() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

group "fgetpriority: prepare source"
# The vendored Makefile gates the object behind CONFIG_FGETPRIORITY, which is
# not in our defconfig. Force it to a plain obj-m for the external-module build.
sed -i 's/obj-\$(CONFIG_FGETPRIORITY)/obj-m/' "$MOD_SRC/kernel/Makefile"
grep -n 'obj-m' "$MOD_SRC/kernel/Makefile" | head -n1

group "fgetpriority: build ko (CC=clang, same tree/flags as the kernel)"
export PATH="${CLANG_PATH:-}:${PATH}"
# shellcheck disable=SC2086  -- make_args word list, replicate build.sh exactly:
# GCC_64 carries CROSS_COMPILE (drives clang --target on 4.19; without it clang
# compiles for x86_64 - CI runs 44039990492/44047879097), GCC_32 the 32-bit
# CROSS_COMPILE_ARM32, CUSTOM_CMDS the CLANG_TRIPLE fallback.
make -C "$KERNEL_DIR" O=out ARCH=arm64 CC=clang ${CUSTOM_CMDS:-} ${EXTRA_CMDS:-} \
	${GCC_64:-} ${GCC_32:-} \
	M="$MOD_SRC/kernel" CONFIG_FGETPRIORITY=m modules

KO="$MOD_SRC/kernel/fgetpriority.ko"
if [ ! -f "$KO" ]; then
	echo "::error::fgetpriority.ko was not produced"
	exit 1
fi
echo "ko size: $(wc -c < "$KO") bytes"
strings "$KO" | grep -m1 vermagic || true

group "fgetpriority: sign ko"
# The kernel build generated the module-signing key (CONFIG_MODULE_SIG_KEY).
# In 4.19 the combined PEM lives under certs/ (srctree or out/ with O= builds).
SIGKEY=""
for d in "$KERNEL_DIR/certs" "$KERNEL_DIR/out/certs"; do
	if [ -f "$d/signing_key.pem" ]; then SIGKEY="$d/signing_key.pem"; break; fi
done
if [ -z "$SIGKEY" ]; then
	echo "::warning::signing_key.pem not found; shipping UNSIGNED ko (MODULE_SIG_FORCE=y will reject it!)"
else
	X509="$(dirname "$SIGKEY")/signing_key.x509"
	[ -f "$X509" ] || X509="$SIGKEY"
	# with O= builds the HOSTCC'd sign-file lives in out/scripts/, not srctree
	SIGN_FILE=""
	for d in "$OUT/scripts" "$KERNEL_DIR/scripts"; do
		[ -x "$d/sign-file" ] && SIGN_FILE="$d/sign-file" && break
	done
	if [ -z "$SIGN_FILE" ]; then
		echo "::warning::sign-file not found; ko left unsigned (MODULE_SIG_FORCE=y will reject it!)"
	else
		"$SIGN_FILE" sha512 "$SIGKEY" "$X509" "$KO"
		echo "ko signed: sign-file=$SIGN_FILE key=$SIGKEY cert=$X509"
	fi
fi

group "fgetpriority: package module zip"
mkdir -p "$MOD_SRC/module/ko"
cp -f "$KO" "$MOD_SRC/module/ko/fgetpriority.ko"
rm -f "$ZIP_OUT"
# module.prop etc. must sit at the ZIP ROOT for ksud module install;
# zipping from inside the module dir avoids a module/ prefix layer.
(cd "$MOD_SRC/module" && zip -qr9 "$ZIP_OUT" .)
echo "module zip: $ZIP_OUT ($(wc -c < "$ZIP_OUT") bytes)"
unzip -l "$ZIP_OUT"
