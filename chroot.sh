#!/bin/bash

source ./base.sh
source ./post.sh
source ./after.sh

userInfo 				# Loads user details
kbdAndTimezone			# Sets keyboard layout and timezone
chrootFunc				# Installs necessary things inside the chroot
installPackages ./repositories.txt	# Adds extra repositories
xmirrorFunc				# Sets up mirrors
grubInstall				# Sets up GRUB
noctaliaSpecific			# Adds the Noctalia repository and installs it
installPackages ./packages.txt		# Installs packages from the list
autoRunit				# Starts programs as services at OS boot
pipewireFunc				# Sets up PipeWire
NetworkManagerFunc			# Sets up network and DNS
greetdSpecific				# Sets up the login and session manager
bluetoothSpecific			# Adds the user to the Bluetooth group
userdirsUpdate				# Creates user directories
configFiles				# Copies folders from config into the configured user's .config
chrootExit				# Exits the chroot
