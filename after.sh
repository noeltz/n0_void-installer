#!bin/bash

installPackages() {
  sudo xbps-install -Sy $(grep -vE '^\s*(#|$)' "$1")
}
noctaliaSpecific () {
	echo "repository=https://universalrepository.pages.dev/void" | tee /etc/xbps.d/10-noctalia.conf
}
autoRunit () {
	services_runit=(
		avahi-daemon
		bluetoothd
		cronie
		cupsd
		dbus
		greetd
		chronyd
		nanoklogd
		NetworkManager
		polkitd
		socklog-unix
		sv-netmount
		zramen
		)

	for i in "${services_runit[@]}"; do
	ln -sfn "/etc/sv/$i" "/etc/runit/runsvdir/default/"
	done
}
autoHardwareServices () {			# Enables runit services chosen by detectHardware
	[ -f ./hardware-services.txt ] || return 0
	while read -r svc; do
		[ -n "$svc" ] || continue
		if [ -d "/etc/sv/$svc" ]; then
			ln -sfn "/etc/sv/$svc" "/etc/runit/runsvdir/default/"
		else
			echo "service '$svc' not found in /etc/sv, skipping"
		fi
	done < ./hardware-services.txt
}
pipewireFunc () {

	mkdir -p /etc/pipewire/pipewire.conf.d
	mkdir -p /etc/alsa/conf.d
	ln -s /usr/share/examples/wireplumber/10-wireplumber.conf /etc/pipewire/pipewire.conf.d/
	ln -s /usr/share/examples/pipewire/20-pipewire-pulse.conf /etc/pipewire/pipewire.conf.d/
	ln -s /usr/share/alsa/alsa.conf.d/50-pipewire.conf /etc/alsa/conf.d
	ln -s /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf /etc/alsa/conf.d
}
NetworkManagerFunc () {
	echo "@reboot ln -sf /run/NetworkManager/resolv.conf /etc/resolv.conf" >> /var/spool/cron/root
}
greetdSpecific () {
	usermod -aG video _greeter
	cp -rf ./specials/greetd /etc/
}
bluetoothSpecific () {
	usermod -aG bluetooth $NEWUSER
}
userdirsUpdate () {
	su $NEWUSER -c "xdg-user-dirs-update"
}
configFiles () {
    cd ./config
    install -d -o $NEWUSER -g $NEWUSER -m 755 /home/$NEWUSER/.config
    directories=($(find "$(pwd)" -mindepth 1 -maxdepth 1 -type d ))
    for i in ${directories[@]}; do
        cp -rf "$i" "/home/$NEWUSER/.config/"
        #ln -s "$i" "/home/$NEWUSER/.config/"
    done
    chown -hR $NEWUSER:$NEWUSER /home/$NEWUSER/.config/*
    cd $OLDPWD
}
