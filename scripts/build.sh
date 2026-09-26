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
WORKSPACE=${WORKSPACE:?WORKSPACE must be set}
OUT="${WORKSPACE}/out"

prepare_defconfig() {
	group "Preparing defconfig"
	[ -f "${KERNEL_DIR}/arch/${ARCH}/configs/${KERNEL_CONFIG}" ] \
		|| die "defconfig not found: arch/${ARCH}/configs/${KERNEL_CONFIG}
Available configs: $(ls "${KERNEL_DIR}/arch/${ARCH}/configs/" | head -20 | tr '\n' ' ')"
	cp "${KERNEL_DIR}/arch/${ARCH}/configs/${KERNEL_CONFIG}" "${WORKSPACE}/defconfig.orig"
	local kver
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")
	if [ "${KSU_VARIANT:-none}" != "none" ]; then
		kconf_enable "${WORKSPACE}/defconfig.orig" CONFIG_KSU
		ksu_hook_configs "${KSU_VARIANT}" "${KSU_HOOK_MODE:-auto}" "${WORKSPACE}/defconfig.orig" "$kver"
		if is_true "${ENABLE_SUSFS:-false}"; then
			susfs_defconfig "${WORKSPACE}/defconfig.orig"
		fi
		if is_true "${ENABLE_KPM:-false}"; then
			# patch_linux resolves symbols at runtime, so kallsyms must be complete.
			kconf_set_many "${WORKSPACE}/defconfig.orig" \
				CONFIG_KPM=y CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y
		fi
	fi
	# Overlayfs backs KernelSU's module mounts and writes to /system.
	is_true "${ADD_OVERLAYFS_CONFIG:-false}" && kconf_enable "${WORKSPACE}/defconfig.orig" CONFIG_OVERLAY_FS
	# Kept as standalone toggle for kernels that need kprobes but not overlayfs.
	is_true "${ADD_KPROBES_CONFIG:-false}" && kconf_set_many "${WORKSPACE}/defconfig.orig" \
		CONFIG_MODULES=y CONFIG_KPROBES=y CONFIG_HAVE_KPROBES=y CONFIG_KPROBE_EVENTS=y

	if is_true "${DISABLE_LTO:-false}"; then
		kconf_set_many "${WORKSPACE}/defconfig.orig" \
			CONFIG_LTO=n CONFIG_LTO_CLANG=n CONFIG_LTO_CLANG_FULL=n \
			CONFIG_LTO_CLANG_THIN=n CONFIG_THINLTO=n
	fi
	is_true "${DISABLE_CC_WERROR:-false}" && kconf_disable "${WORKSPACE}/defconfig.orig" CONFIG_CC_WERROR

	# 关闭栈保护，解决 __stack_chk_guard 链接报错
	kconf_set_many "${WORKSPACE}/defconfig.orig" \
		CONFIG_STACKPROTECTOR=n \
		CONFIG_STACKPROTECTOR_STRONG=n

	# Free‑form extras: one CONFIG_x=y per line, or space separated.
	if [ -n "${EXTRA_DEFCONFIG:-}" ]; then
		local kv
		# shellcheck disable=SC2086
		for kv in $(printf '%s' "$EXTRA_DEFCONFIG" | tr '\n' ' '); do
			[ -n "$kv" ] || continue
			case "$kv" in
				*=*) kconf_set "${WORKSPACE}/defconfig.orig" "${kv%%=*}" "${kv#*=}" ;;
				*)   warn "ignoring malformed EXTRA_DEFCONFIG entry '${kv}' (want CONFIG_X=y)" ;;
			esac
		done
	fi

	# A stable LOCALVERSION keeps artifact filenames predictable.
	if [ -n "${KERNEL_NAME:-}" ]; then
		kconf_set "${WORKSPACE}/defconfig.orig" CONFIG_LOCALVERSION "\"-${KERNEL_NAME}\""
		if [ -f "${KERNEL_DIR}/scripts/setlocalversion" ]; then
			sed -i 's/echo "\$res"/echo "\$res"/; s/-dirty//g' "${KERNEL_DIR}/scripts/setlocalversion"
		fi
	fi

	info "defconfig changes:"
	diff -u "${KERNEL_DIR}/arch/${ARCH}/configs/${KERNEL_CONFIG}" "${WORKSPACE}/defconfig.orig" | sed -n '4,$p' | sed 's/^/    /' || true

	mkdir -p "$OUT"
	cp "${WORKSPACE}/defconfig.orig" "${OUT}/.config"
	cd "$KERNEL_DIR"
	make ${MAKE_ARGS:-} O="$OUT" olddefconfig >/dev/null
	cd - >/dev/null
	endgroup
}

build_kernel() {
	group "Building kernel"
	export PATH="${CLANG_PATH}:${PATH}"
	export LD_LIBRARY_PATH="${CLANG_PATH}/lib:${LD_LIBRARY_PATH:-}"

	local args
	args=$(make_args)
	# shellcheck disable=SC2086
	make -j"$(nproc)" ${args} O="$OUT" > build.log 2>&1 || {
		cat build.log
		die "kernel build failed"
	}
	endgroup
}

check_output() {
	group "Checking build output"
	local boot="${OUT}/arch/${ARCH}/boot"
	[ -d "$boot" ] || die "boot dir missing: ${boot}"

	# KPM rewrites image in‑place; must run after build before packaging.
	if is_true "${ENABLE_KPM:-false}"; then
		local img
		img=$(find "$boot" -maxdepth 1 -name 'Image*' | head -n1)
		[ -n "$img" ] && kpm_patch_image "$img"
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
