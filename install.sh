#!/bin/bash
#Script to create a bare minimum arch linux installation

#assuming internet is connected
language="en_US.UTF-8"
hostname="archlinux"
export username="user"
export dot_files="https://github.com/PolyLinear/dotfiles"
partition() {

	[[ $(cat /sys/firmware/efi/fw_platform_size) -eq 64 ]] || {
		printf "%s\n" "Please assure that the system is using a 64-bit x64 UEFI" \
			"Set up will not continue otherwise"
		exit 1
	}

	printf "%s\n\n" "Passed 64-bit x64 UEFI check"

	mapfile -t devices < <(lsblk -dpno name)

	declare device_to_install

	PS3="Select device to partition: "
	echo "Devices:"
	select device in "${devices[@]}"; do
		if [[ -n $device ]]; then
			printf "%s\n" "Are you sure you want to install onto ${device}?" \
				"This will wipe the device completely [y\n]"
			read -r decision
			if [[ $decision != "y" ]]; then
				continue
			fi
			device_to_install=$device
			break
		fi

	done

	#TODO: create trap. the following should not fail for any reason
	parted -f --script "$device_to_install" \
		mklabel gpt \
		mkpart '"EFI Partition"' fat32 1MiB 1GiB \
		set 1 esp on \
		mkpart '"Swap Partition"' linux-swap 1GiB 5GiB \
		mkpart '"Root Partition"' ext4 5GiB 100%

	mkfs.fat -F 32 "${device_to_install}1"

	mkswap "${device_to_install}2"
	swapon "${device_to_install}2"

	mkfs.ext4 "${device_to_install}3"

	mount "${device_to_install}3" /mnt
	mount --mkdir "${device_to_install}1" /mnt/boot

}

function installation() {

	pacstrap -K /mnt base linux linux-firmware

	genfstab -U /mnt >>/mnt/etc/fstab
	cp "$0" /mnt/"$0"
	arch-chroot /mnt ./install.sh "setup"

}

#TODO set time sync
function locale_and_time() {
	ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
	hwclock --systohc

	echo "LANG=${language}" >/etc/locale.conf
	sed -i "/${language}/s/^#//" /etc/locale.gen
	locale-gen

	echo "${hostname}" >/etc/hostname

	systemctl enable systemd-timesyncd.service

}

function bootloader() {

	if grep -m 1 GenuineIntel /proc/cpuinfo >/dev/null; then
		ucode="intel-ucode"
	elif grep -m 1 AuthenticAMD /proc/cpuinfo >/dev/null; then
		ucode="amd-ucode"
	else
		ucode=""
	fi

	pacman --noconfirm -S "$ucode" \
		grub \
		efibootmgr

	grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
	grub-mkconfig -o /boot/grub/grub.cfg
}

#TODO: create script to automatically encrypt drive
function encryption() {
	true
}

#TODO: setup sudoers file, enable wifi and firewall support
function base() {

	pacman --noconfirm -S reflector

	sed -i '/ParallelDownloads/s/^#//' /etc/pacman.conf

	#reflector --latest 25 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
	#pacman -S - <$(awk '/^[^\[]/ {print $1}' install.txt)
	 pacman -Sy acpi \
		bash-completion \
		firewalld \
		gnu-netcat \
		iptables-nft \
		linux-docs \
		lvm2 \
		man-db \
		man-pages \
		netstat-nat \
		networkmanager \
		polkit-gnome \
		posix-c-development \
		reflector \
		rsync \
		strace \
		tlp \
		traceroute \
		unzip \
		wpa_supplicant \
		zip \
		ntp \
		git \
		xdg-utils \
		xdg-user-dirs \
		sudo

	systemctl enable tlp.service
	systemctl enable NetworkManager.service
	systemctl enable firewalld.service

	sed -i -E '/%wheel\s+ALL=\(ALL:ALL\)\s+ALL/s/^#\s*//' /etc/sudoers
	useradd -m -U -G wheel $username
	passwd $username
}

#TODO enable virtual-machine functionality
function libvert-setup {

	systemctl enable libvirtd.service
	systemctl enable libvirtd.socket

	usermod -aG libvirt $username
}

#TODO fetch dot files from repo and apply
function user_specific_configurations() {
	git clone "$dot_files" ~/.dotfiles

	ln -sf ~/.dotfiles/.bashrc ~/.bashrc
	ln -sf ~/.dotfiles/.bash_profile ~/.bash_profile && source ~/.bash_profile

	define_XDG() {
		[[ -d "$1" ]] || mkdir -p "$1"
	}

	define_XDG "$XDG_DATA_HOME"
	define_XDG "$XDG_STATE_HOME"
	define_XDG "$XDG_CACHE_HOME"
	define_XDG "$XDG_CONFIG_HOME"

	for file in ~/.dotfiles/config/*; do
		ln -s "$file" "$XDG_CONFIG_HOME/$(basename "$file")"
	done

	ln -s ~/.dotfiles/scripts ~/scripts

	sh -c 'curl -fLo "${XDG_DATA_HOME:-$HOME/.local/share}"/nvim/site/autoload/plug.vim --create-dirs \
       https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'
}


#TODO set default programs for opening files using XDG
function set_defaults() {
	true
}
function configure() {
	libvert-setup
	export -f user_specific_configurations
	su $username -c "user_specific_configurations"
	mkdir /run/user/$(id -u "$username")
	cp /home/$username/.dotfiles/99-myfavoritetrackpoint.rules /etc/udev/rules.d/
	su $username -c "systemctl --user enable mpd.service; nvim +PlugInstall +qall; xdg-settings set default-web-browser firefox.desktop; xdg-user-dirs-update --force"
}

function cleanup() {

	rm install.sh
	exit
	umount -R /mnt
}

if [[ "$1" = "setup" ]]; then
	locale_and_time
	bootloader
	base
	configure
	cleanup
else
	partition
	installation
fi
