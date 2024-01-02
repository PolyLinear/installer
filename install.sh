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
			export device_to_install=$device
			break
		fi

	done
	sgdisk --zap-all "${device_to_install}"
	sgdisk --clear \
		--new=1:0:+1G --typecode=1:ef00 --change-name=1:"boot" \
		--new=2:0:0 --typecode=2:8309 --change-name=2:"cryptlvm" "${device_to_install}"

	cryptsetup luksFormat -s 512 "${device_to_install}2"
	cryptsetup open "${device_to_install}2" cryptlvm
	pvcreate /dev/mapper/cryptlvm
	vgcreate vgsystem /dev/mapper/cryptlvm
	lvcreate -L 4G vgsystem -n swap
	lvcreate -l '100%FREE' vgsystem -n root

	mkfs.ext4 /dev/vgsystem/root
	mkswap /dev/vgsystem/swap
	mkfs.fat -F 32 "${device_to_install}1"

	mount /dev/vgsystem/root /mnt
	mount --mkdir "${device_to_install}1" /mnt/boot
	swapon /dev/vgsystem/swap

}

function installation() {

	packages="base linux linux-firmware util-linux mkinitcpio lvm2 dhcpcd wpa_supplicant networkmanager dracut efibootmgr git"
	pacstrap -K /mnt $packages

	genfstab -U /mnt >>/mnt/etc/fstab
	cp "$0" /mnt/"$0"
	cp packages.txt /mnt/
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

	#get ucode for either intel or amd
	ucode=""
	if grep -m 1 GenuineIntel /proc/cpuinfo >/dev/null; then
		ucode="intel-ucode"
	elif grep -m 1 AuthenticAMD /proc/cpuinfo >/dev/null; then
		ucode="amd-ucode"
	fi

	#install ucode
	[[ -n $ucode ]] && pacman --noconfirm -S "$ucode"

	#don't make the random seed file world accessable
	sed -i '/\/boot.*/s/fmask=[0-9]*,dmask=[0-9]*/fmask=0137,dmask=0027/' /etc/fstab

	#systemd-boot configuration
	systemd-machine-id-setup
	bootctl --path=/boot install

	#initrd /intel-ucode.img
	#create bootloader entry
	cat <<EOF >/boot/loader/entries/arch.conf
title   Arch
linux   /vmlinuz-linux $([[ -n $ucode ]] && printf "\n%s\n" "initrd  /${ucode}.img")
initrd  /initramfs-linux.img
options cryptdevice=UUID=$(blkid -s UUID -o value "${device_to_install}2"):cryptlvm root=/dev/vgsystem/root rw
EOF

	#configuration information
	cat <<EOF >/boot/loader/loader.conf
default arch
timeout 0
editor  0
EOF

	#adding hooks for encryption in /etc/mkinitcpio.conf
	sed -i '/^\(HOOKS\)=/s/block/block encrypt lvm2/' /etc/mkinitcpio.conf

	#regenerate mkinitcpio
	mkinitcpio -P

}

function pacman_setup() {
	#setup reflector, install packages specified in packages.txt
	pacman --noconfirm -Sy reflector pacutils archlinux-keyring
	sed -i '/ParallelDownloads/s/^#//' /etc/pacman.conf

	reflector --latest 25 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
}

#TODO: setup sudoers file, enable wifi and firewall support
function base() {

	#create initial user
	useradd -m -U $username
	passwd $username

	pacinstall --no-confirm --resolve-replacements=provided --resolve-conflicts=provided $(awk '/^[^\[]/ {print $1}' /packages.txt)

	#enable necessary daemons
	systemctl enable tlp.service
	systemctl enable NetworkManager.service
	systemctl enable firewalld.service
	systemctl enable libvirtd.service
	systemctl enable libvirtd.socket

	#allow members of wheel to use sudo
	sed -i -E '/%wheel\s+ALL=\(ALL:ALL\)\s+ALL/s/^#\s*//' /etc/sudoers

	#add secondary groups to user, not that base packages are installed
	usermod -a -G wheel,libvirt $username
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

	#code taken from vim-plug github repo
	sh -c 'curl -fLo "${XDG_DATA_HOME:-$HOME/.local/share}"/nvim/site/autoload/plug.vim --create-dirs \
       https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'

	nvim +PlugInstall +qall
	systemctl --user enable mpd.service
	xdg-settings set default-web-browser firefox.desktop
	xdg-user-dirs-update --force
}

function configure() {
	mkdir /run/user/$(id -u "$username")
	export -f user_specific_configurations
	su $username -c "user_specific_configurations"
	cp /home/$username/.dotfiles/99-myfavoritetrackpoint.rules /etc/udev/rules.d/
}

function cleanup() {
	rm /mnt/install.sh /mnt/packages.txt
	umount -qR /mnt
}

if [[ "$1" = "setup" ]]; then
	pacman_setup
	locale_and_time
	bootloader
	base
	configure
else
	partition
	installation
	cleanup
fi
