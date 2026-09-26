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

prepare_defconfig() {
	group "Preparing defconfig"
	[ -f "$DEFCONFIG_PATH" ] \
		|| die "defconfig not found: arch/${ARCH}/configs/${KERNEL_CONFIG}
       Available: $(ls "${KERNEL_DIR}/arch/${ARCH}/configs/" | head -20 | tr '\n' ' ')"
	cp "$DEFCONFIG_PATH" "${WORKSPACE}/defconfig.orig"
	local kver
	kver=$(kernel_version "$KERNEL_DIR")
	info "Kernel version detected: $kver"

	# 关闭栈保护，解决 __stack_chk_guard 链接错误，不触碰vendor驱动
	kconf_set_many "$DEFCONFIG_PATH" \
		CONFIG_STACKPROTECTOR=n \
		CONFIG_STACKPROTECTOR_STRONG=n

	kconf_enable "$DEFCONFIG_PATH" CONFIG_CGROUPS
	kconf_enable "$DEFCONFIG_PATH" CONFIG_CGROUP_FREEZER
	kconf_enable "$DEFCONFIG_PATH" CONFIG_PROC_PID_CPUSET

	info "defconfig changes:"
	diff -u "${WORKSPACE}/defconfig.orig" "$DEFCONFIG_PATH" | sed -n '4,$p' | sed 's/^/    /' || true
	endgroup
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
		info "ccache enabled"
	fi

	cd "$KERNEL_DIR"
	# 关键：注释掉高危的patch_vendor_drivers，不再修改datarmnet/mihw驱动
	# patch_vendor_drivers

	mkdir -p "$OUT"
	info "make ${args} defconfig (copied from ${KERNEL_CONFIG})"
	cp "$DEFCONFIG_PATH" "${OUT}/.config"
	make -j"$(nproc --all)" CC=clang $args olddefconfig \
		|| die "defconfig generation failed"

	info "Starting kernel compile, make args: $args"
	make -j"$(nproc --all)" CC="$cc" $args \
		|| die "kernel build failed"
	endgroup
}

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
		[ -f "${boot}/dtbo.img" ] || warn "dtbo.img not generated"
		ok "dtbo.img found"
	fi

	if [ -f "${OUT}/include/generated/utsrelease.h" ]; then
		local rel
		rel=$(sed -n 's/^#define UTS_RELEASE "\(.*\)"/\1/p' "${OUT}/include/generated/utsrelease.h")
		export_env KERNEL_RELEASE "$rel"
		ok "kernel release: ${rel}"
		summary "| Kernel Release | \`${rel}\` |"
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
