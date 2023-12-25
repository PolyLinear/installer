#!/bin/bash
#Script to create a bare minimum arch linux installation

#assuming internet is connected

#verify boot mode, assure 64-bit x64 UEFI
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

pacstrap -K /mnt base linux linux-firmware neovim

genfstab -U /mnt >> /mnt/etc/fstab


