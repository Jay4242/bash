#!/bin/bash

# Function to create blank iso files
create_iso_files() {
  local num_disks=$1
  local iso_size=23300  #Can get size with dvd+rw-mediainfo /dev/sr0  #This probably isn't perfect, decreased size for formatted reserved space on a 25GB BD-R.

  for (( i=1; i<=num_disks; i++ ))
  do
    dd if=/dev/zero of="${temp_dir}/zfs_${i}.iso" bs=4k count=$(( $(echo "${iso_size}*1024/4" | bc) ))
  done
  }

# Function to attach iso files as loopback devices and create device list
attach_loopback_devices() {
  local num_disks=$1
  local devices=""
  
  for (( i=1; i<=num_disks; i++ ))
  do
    loop=$(sudo losetup -f)
    sudo losetup "${loop}" "${temp_dir}/zfs_${i}.iso"
    devices+="${loop} "
  done
  
  echo "$devices"
  }

# Function to create ZFS pool and mount it
create_zfs_pool() {
  local pool_type=$1
  local devices=$2
  
  if [[ "${pool_type}" == "mirror" ]]; then
    sudo zpool create -m /tmp/bdr_pool -O encryption=on -O keylocation=prompt -O keyformat=passphrase bdr_zfs mirror ${devices}
  elif [[ "${pool_type}" == "raidz" ]]; then
    sudo zpool create -m /tmp/bdr_pool -O encryption=on -O keylocation=prompt -O keyformat=passphrase bdr_zfs raidz ${devices}
  elif [[ "${pool_type}" == "raidz2" ]]; then
    sudo zpool create -m /tmp/bdr_pool -O encryption=on -O keylocation=prompt -O keyformat=passphrase bdr_zfs raidz2 ${devices}
  elif [[ "${pool_type}" == "raidz3" ]]; then
    sudo zpool create -m /tmp/bdr_pool -O encryption=on -O keylocation=prompt -O keyformat=passphrase bdr_zfs raidz3 ${devices}
  else
    echo "Invalid pool type specified. Exiting."
    exit 1
  fi
  sudo zfs set compression=on bdr_zfs
  sudo chown "$(whoami):$(whoami)" /tmp/bdr_pool
  }

# Function to test usable space of ZFS pool
test_usable_space() {
  local usable_size=$(echo "$(zfs get -p -o value available bdr_zfs | tail -n 1) / 1024 / 1024" | bc)
  echo "Usable space of ZFS pool: ${usable_size} Megabytes"
  }

# Function to split directory into vol_* files
split_directory() {
  local usable_size=$1
  directory_to_backup=$2
  dirsplit -s ${usable_size} "${directory_to_backup}"
  }

copy_files() {
  vol_file=$1
  zfs_root=$2

  while read line; do
    dest=$(echo "$line" | cut -d'=' -f1)
    src=$(echo "$line" | cut -d'=' -f2)
    dest_path="$zfs_root$dest"
    mkdir -p "$(dirname "$dest_path")"
    cp -v "$src" "$dest_path"
  done < "$vol_file"
  }

export_zfs_pool() {
  sudo zpool export "$1"
  #sudo umount /tmp/bdr_pool
  mapfile -t loops < <(sudo losetup -l | grep -i zfs.*.iso | awk -F' ' '{print $1}')
  for loop in "${loops[@]}" ; do
    sudo losetup -d "${loop}"
  done
  }


# Function to burn iso files to BD-R
burn_to_bdr() {
  local num_disks=$1
  
  for (( i=1; i<=num_disks; i++ ))
  do
    dvd+rw-format /dev/sr0
    growisofs -dvd-compat -Z /dev/sr0="${temp_dir}/zfs_${i}.iso"
    eject /dev/sr0
    read -p "Just burned zfs_${i}.iso of ${num_disks} for the set."
  done
  }

# Function to cleanup temp directory
cleanup_temp_dir() {
  rm -rf "${temp_dir}"
  }

# Main script
temp_dir=$(mktemp -d)
cd "${temp_dir}"
read -p "Enter the number of disks to use: " num_disks
read -p "Is the zfs pool a mirror or raid-z? (Enter 'mirror' or 'raidz'/'raidz2'/'raidz3'): " pool_type

if ! create_iso_files $num_disks ; then
  echo "Failed to create blank iso files."
  cleanup_temp_dir
  exit 1
  fi
if ! devices=$(attach_loopback_devices $num_disks) ; then
  echo "Failed to attach iso files as loopback devices."
  cleanup_temp_dir
  exit 1
  fi
if ! create_zfs_pool $pool_type "$devices" ; then
  echo "Failed to create ZFS Pool on iso files."
  cleanup_temp_dir
  exit 1
  fi
if ! test_usable_space ; then
  echo "Failed to test usable space."
  export_zfs_pool bdr_zfs "$num_disks"
  cleanup_temp_dir
  exit 1
  fi
read -p "Copy files to /tmp/bdr_pool"
if ! export_zfs_pool bdr_zfs "$num_disks" ; then
  echo "Failed to export ZFS Pool."
  cleanup_temp_dir
  exit 1
  fi
if ! burn_to_bdr $num_disks ; then
  echo "Failed to burn BD-Rs."
  fi
if ! cleanup_temp_dir ; then
  echo "Failed to clean up temp directory at $temp_dir"
  fi
