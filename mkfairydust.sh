#!/usr/bin/env bash

# based on https://github.com/bharambetejas/asahi-fairydust-display

set -eo pipefail

if [ "$EUID" = 0 ]; then
	echo "must be run as a non-root user" >&2
	exit 1
fi
if [ "$(sed -n 's/^ID_LIKE=\"*\(.*\)\"*/\1/p' </etc/os-release)" != fedora ]; then
	echo "must be run on fedora" >&2
	exit 1
fi
if [ "$(uname -m)" != aarch64 ]; then
	echo "must be run on arm64" >&2
	exit 1
fi
if [ "$(df -B G / | awk 'NR == 2 {print $4}' | tr -d G)" -lt 33 ]; then
	echo "must have >= 33 GiB storage available" >&2
	exit 1
fi
if ! : >/dev/tcp/cloudflare.com/80; then
	echo "must have internet connection" >&2
	exit 1
fi
script_dir="$(realpath "$(dirname "$BASH_SOURCE")")"
sudo dnf install \
	gcc gcc-c++ make bc bison flex elfutils-libelf-devel \
	ncurses-devel python3 zlib-devel libuuid-devel dwarves \
	xz zstd clang llvm lld git \
	openssl openssl-devel \
	rust rust-std-static bindgen-cli rust-src
if [ ! -f /usr/lib/rustlib/src/rust/library/core/src/lib.rs ]; then
	echo "couldn't find rust stdlib from the \"rust-src\" package" >&2
	exit 1
fi
export PATH="/usr/bin:$PATH"
export RUST_LIB_SRC="/usr/lib/rustlib/src/rust/library"
if [ ! -d linux ]; then
	git clone -b fairydust --single-branch --filter=blob:none https://github.com/AsahiLinux/linux.git
fi
cd linux
for i in "$script_dir"/patches/*.patch; do
	if git apply -R --check "$i"; then
		continue
	fi
	if ! git apply --check "$i"; then
		echo "can't apply patch \"$i\"" >&2
		exit 1
	fi
	git apply "$i"
done
if [ ! -f .config ]; then
	make distclean
	cp "/boot/config-$(uname -r)" .config
	make olddefconfig
	make rustavailable
	scripts/config --enable RUST
	scripts/config --module DRM_ASAHI
	scripts/config --enable RUST_FW_LOADER_ABSTRACTIONS
	scripts/config --enable RUST_DRM_SCHED
	scripts/config --enable RUST_DRM_GEM_SHMEM_HELPER
	scripts/config --enable RUST_DRM_GPUVM
	scripts/config --enable RUST_APPLE_MAILBOX
	scripts/config --enable RUST_APPLE_RTKIT
	scripts/config --module TYPEC_DP_ALTMODE
	scripts/config --module TYPEC_NVIDIA_ALTMODE
	scripts/config --module TYPEC_TBT_ALTMODE
	scripts/config --module DRM_APPLE
	sed -i 's/CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-fairydust"/' .config
	scripts/config --set-str EFI_SBAT_FILE ""
	scripts/config --disable QRTR_MHI
	scripts/config --disable MODULE_SIG
	scripts/config --disable MODULE_SIG_ALL
	scripts/config --disable MODULE_SIG_FORCE
	scripts/config --set-str MODULE_SIG_KEY ""
	scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
	scripts/config --set-str SYSTEM_REVOCATION_KEYS ""
	make olddefconfig
fi
make -O -j "$(nproc)"
sudo make INSTALL_MOD_STRIP=1 modules_install
sudo make dtbs_install
sudo make vdso_install
kver="$(make -s kernelrelease)"
sudo ln -sf "/boot/dtbs/$kver" "/lib/modules/$kver/dtb"
sudo make install
sudo ln -sfn "$PWD" /usr/src/linux
sudo ln -sfn "/boot/dtbs/$kver" /boot/dtb
sudo update-m1n1
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
echo -e "typec_displayport\ntypec_nvidia\ntypec_thunderbolt" | sudo tee /etc/modules-load.d/fairydust-typec.conf >/dev/null
sudo grub2-editenv - unset menu_auto_hide
echo "done, you can now reboot in the *-fairydust kernel"
