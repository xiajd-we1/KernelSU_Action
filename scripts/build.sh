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
			kconf_set_many "$DEFCONFIG_PATH" \
				CONFIG_KPM=y CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y
		fi
	fi

	kconf_set_many "$DEFCONFIG_PATH" \
		CONFIG_CGROUPS=y CONFIG_CGROUP_SCHED=y CONFIG_CGROUP_FREEZER=y \
		CONFIG_NETFILTER=y CONFIG_NETFILTER_ADVANCED=y \
		CONFIG_NF_CONNTRACK=y CONFIG_NETFILTER_XTABLES=y

	is_true "${ADD_OVERLAYFS_CONFIG:-false}" && kconf_enable "$DEFCONFIG_PATH" CONFIG_OVERLAY_FS

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

	if [ -n "${EXTRA_DEFCONFIG:-}" ]; then
		local kv
		for kv in $(printf '%s' "$EXTRA_DEFCONFIG" | tr '\n' ' '); do
			[ -n "$kv" ] || continue
			case "$kv" in
				*=*) kconf_set "$DEFCONFIG_PATH" "${kv%%=*}" "${kv#*=}" ;;
				*)   warn "ignoring malformed EXTRA_DEFCONFIG entry '${kv}' (want CONFIG_x=y)" ;;
			esac
		done
	fi

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

patch_one_vendor_file() {
	local file="$1" header="$2"
	[ -f "$file" ] || return 0
	grep -q "$header" "$file" && return 0

	python3 - "$file" "$header" <<'PYEOF'
import sys
path, header = sys.argv[1], sys.argv[2]
with open(path, "r") as f:
    content = f.read()
with open(path, "w") as f:
    f.write(header + "\n" + content)
PYEOF
	info "patched $(basename "$file")"
}

patch_vendor_drivers() {
	local mihw="${KERNEL_DIR}/drivers/mihw"
	[ -d "$mihw" ] || return 0

	patch_one_vendor_file "${mihw}/millet_core.c" \
		"#include <linux/cgroup.h>
#include <linux/cgroup-defs.h>"

	local pkg_file="${mihw}/millet_pkg.c"
	if [ -f "$pkg_file" ]; then
		python3 - "$pkg_file" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, "r") as f:
    content = f.read()

header = """#include <linux/netfilter.h>
#include <linux/netfilter_ipv4.h>
#include <linux/netfilter_ipv6.h>

extern int nf_register_net_hooks(struct net *net,
                                 const struct nf_hook_ops *reg);
extern void nf_unregister_net_hooks(struct net *net,
                                    const struct nf_hook_ops *reg);
"""

content = content.replace(
    "nf_register_net_hooks(net, pkg_nf_ops, ARRAY_SIZE(pkg_nf_ops))",
    "nf_register_net_hooks(net, pkg_nf_ops)"
).replace(
    "nf_unregister_net_hooks(net, pkg_nf_ops, ARRAY_SIZE(pkg_nf_ops))",
    "nf_unregister_net_hooks(net, pkg_nf_ops)"
)

with open(path, "w") as f:
    f.write(header + content)
PYEOF
		info "patched millet_pkg.c (2-arg netfilter calls)"
	fi
}

build_kernel() {
	group "Building kernel"
	export PATH="${CLANG_PATH:-}:${PATH}"
	export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-Github-Action}
	export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-kernelsu-action}
	unset DISABLE_LTO

	if [ -n "${KSU_EXPECTED_SIZE:-}" ] && [ -n "${KSU_EXPECTED_HASH:-}" ]; then
		export KSU_EXPECTED_SIZE KSU_EXPECTED_HASH
		info "using custom manager signature (size=${KSU_EXPECTED_SIZE})"
	fi

	local cc="clang" args
	args=$(make_args)
	if is_true "${ENABLE_CCACHE:-true}" && command -v ccache >/dev/null; then
		cc="ccache clang"
		export CCACHE_DIR="${CCACHE_DIR:-${WORKSPACE}/.ccache}"
		info "ccache enabled (dir: ${CCACHE_DIR})"
	fi

	cd "$KERNEL_DIR"
	patch_vendor_drivers

	mkdir -p "$OUT"
	info "make ${args} defconfig (copied from ${KERNEL_CONFIG})"
	cp "$DEFCONFIG_PATH" "${OUT}/.config"
	make -j"$(nproc --all)" CC=clang $args olddefconfig \
		|| die "defconfig generation failed"

	info "make ${args}"
	make -j"$(nproc --all)" CC="$cc" $args \
		|| die "kernel build failed"
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

	if is_true "${ENABLE_KPM:-false}"; then
		kpm_patch_image "$image"
	fi

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
