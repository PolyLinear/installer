#!/bin/bash
#Script to create a bare minimum arch linux installation

#assuming internet is connected
language="en_US.UTF-8"
hostname="archlinux"
export username="user"
export dot_files="https://github.com/PolyLinear/dotfiles"
partition() {

	#check if running on 64bit efi. (install won't work otherise)
	[[ $(cat /sys/firmware/efi/fw_platform_size) -eq 64 ]] || {
		printf "%s\n" "Please assure that the system is using a 64-bit x64 UEFI" \
			"Set up will not continue otherwise"
		exit 1
	}

	printf "%s\n\n" "Passed 64-bit x64 UEFI check"

	#build selection of available block devices
	mapfile -t devices < <(lsblk -dpno name)

	#select device to install arch linux to
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

	#nvme drives don't follow the naming scheme as other sda or vda devices
	#need to add "p" before partition number if nvme is used
	if [[ "$device_to_install" =~ .*nvme.* ]]; then
		boot=p1
		root=p2
	else
		boot=1
		root=2
	fi

	#partitions of the system
	export boot_part="${device_to_install}${boot}"
	export root_part="${device_to_install}${root}"

	#create a 1GB boot directory. The rest of the space is dedicated to root and swap
	sgdisk --zap-all "${device_to_install}"
	sgdisk --clear \
		--new=1:0:+1G --typecode=1:ef00 --change-name=1:"boot" \
		--new=2:0:0 --typecode=2:8309 --change-name=2:"cryptlvm" "${device_to_install}"

	#setup LVM on LUKS
	cryptsetup luksFormat -s 512 "${root_part}"
	cryptsetup open "${root_part}" cryptlvm

	#physical volume
	pvcreate /dev/mapper/cryptlvm

	#volume group
	vgcreate vgsystem /dev/mapper/cryptlvm

	#first 4G are for swap, rest is for root
	lvcreate -L 4G vgsystem -n swap
	lvcreate -l '100%FREE' vgsystem -n root

	#format logical volumes and enable swap
	mkfs.ext4 /dev/vgsystem/root
	mkswap /dev/vgsystem/swap
	mkfs.fat -F 32 "${boot_part}"

	#mount logical volumes and start swap
	mount /dev/vgsystem/root /mnt
	mount --mkdir "${boot_part}" /mnt/boot
	swapon /dev/vgsystem/swap

}

function installation() {

	pacstrap -K /mnt base linux linux-firmware \
		util-linux mkinitcpio lvm2 dhcpcd \
		wpa_supplicant networkmanager dracut \
		efibootmgr git

	genfstab -U /mnt >>/mnt/etc/fstab
	cp "$0" /mnt/"$0"
	cp packages.txt /mnt/
	arch-chroot /mnt ./install.sh "setup"

}

#TODO set time sync
function locale_and_time() {
	#New York Time Zone
	ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
	hwclock --systohc

	#set language
	echo "LANG=${language}" >/etc/locale.conf
	sed -i "/${language}/s/^#//" /etc/locale.gen
	locale-gen

	#set hostname
	echo "${hostname}" >/etc/hostname

	#enable time syncing
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

	#create bootloader entry
	cat <<EOF >/boot/loader/entries/arch.conf
title   Arch
linux   /vmlinuz-linux $([[ -n $ucode ]] && printf "\n%s\n" "initrd  /${ucode}.img")
initrd  /initramfs-linux.img
options cryptdevice=UUID=$(blkid -s UUID -o value "${root_part}"):cryptlvm root=/dev/vgsystem/root rw
EOF

	#configuration information
	cat <<EOF >/boot/loader/loader.conf
default arch
timeout 3
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

function base() {

	#create initial user
	useradd -m -U $username
	passwd $username

	#read user defined packages and install them
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

function user_specific_configurations() {

	#fetch dotfiles from github
	git clone "$dot_files" ~/.dotfiles

	#setup bash environment
	ln -sf ~/.dotfiles/.bashrc ~/.bashrc
	ln -sf ~/.dotfiles/.bash_profile ~/.bash_profile && source ~/.bash_profile

	#basic XDG defined in .bash_profile. create directories if needed
	mkdir -p "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"

	#link config files dotfiles
	for file in ~/.dotfiles/config/*; do
		ln -s "$file" "$XDG_CONFIG_HOME/$(basename "$file")"
	done

	#shoft link user defined scripts
	ln -s ~/.dotfiles/scripts ~/scripts

	#create preview directory for ncmpcpp
	mkdir ~/.dotfiles/config/ncmpcpp/previews

	#code taken from vim-plug github repo, install vim-plug
	sh -c 'curl -fLo "${XDG_DATA_HOME:-$HOME/.local/share}"/nvim/site/autoload/plug.vim --create-dirs \
       https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'

	#install plugins
	nvim +PlugInstall +qall

	#enable mpd for music
	systemctl --user enable mpd.service

	#set firefox for default browser
	xdg-settings set default-web-browser firefox.desktop

	#create base xdg directories
	xdg-user-dirs-update --force
}

function configure() {

	#need to directory to enable systemctl functionaity for user
	mkdir /run/user/"$(id -u "$username")"

	#set defaults for user
	export -f user_specific_configurations
	su $username -c "user_specific_configurations"

	#disable trackpad from custom udev rule
	cp /home/$username/.dotfiles/99-myfavoritetrackpoint.rules /etc/udev/rules.d/
}

function cleanup() {
	rm /mnt/install.sh /mnt/packages.txt
	umount /mnt/boot
	umount /mnt
	swapoff /dev/mapper/vgsystem-swap
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
