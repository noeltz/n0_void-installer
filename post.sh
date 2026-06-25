#!/bin/bash

userInfo() {
    separator -i
    figlet "USER"
    separator -i
    sleep 1
    read -p "Enter the username: " USERN_INPUT
    NEWUSER=$(echo "${USERN_INPUT,,}") # Lowercase
    while true; do
        read -p "Enter the password for user $NEWUSER : " -s PASS
        echo
        read -p "Enter the password again: " -s PASS2
        echo
        if [ $PASS != $PASS2 ]; then
            separator -iwi
            echo "Passwords do not match, please try again."
            separator -iwi
        else
            break
        fi
    done
    read -p "Enter the PC name (hostname): " HOSTNAME
    echo
}

getLocales() {
    separator -i
    figlet "LOCALIZATION"
    separator -i
    sleep 1
    LIBC_PWD="/etc/default/libc-locales"
    LIST_LOCALES=($(tail -n +11 "$LIBC_PWD" | awk '{sub(/^#/,""); print }' | fzf ))
    echo $LIST_LOCALES
}

getPrimaryLang() {
    separator -i
    figlet "SYSTEM LANGUAGE"
    separator -i
    sleep 1
    LANG_PRIMARY=$(awk '!/^[[:space:]]*($|#)/' $LIBC_PWD | fzf)
    LANG_P=$(echo "${LANG_PRIMARY%% *}")
}

kbdAndTimezone() {
    separator -i
    figlet "KEYBOARD"
    separator -i
    sleep 1
    LAYOUT=$(\ls /usr/share/kbd/keymaps/i386 | fzf)
    KEYBOARD=$(\ls /usr/share/kbd/keymaps/i386/$LAYOUT/ | awk '/\.gz$/' | fzf )
    KB=$(echo "${KEYBOARD%%.*}")

    separator -i
    figlet "TIMEZONE"
    separator -i
    sleep 1
    REGION=$(\ls /usr/share/zoneinfo | fzf)
    TIMEZONE=$(\ls /usr/share/zoneinfo/$REGION/ | fzf )
}

chrootFunc() {
    echo $HOSTNAME > /etc/hostname

    getLocales
    for i in "${LIST_LOCALES[@]}";do
        sed -i "s/#$i/$i/" $LIBC_PWD
    done
    xbps-reconfigure -f glibc-locales
    getPrimaryLang
    sed -Ei "s/LANG=.*/LANG=$LANG_P/" /etc/locale.conf

    sed -Ei "s/#KEYMAP=.*/KEYMAP=\"$KB\"/" /etc/rc.conf
    sed -Ei "s/#FONT=.*/FONT=\"$CF\"/" /etc/rc.conf
    ln -sf /usr/share/zoneinfo/$REGION/$TIMEZONE /etc/localtime

    useradd -m -G wheel,lp,audio,video,storage,network,input,users,kvm -s /bin/bash $NEWUSER
    passwd $NEWUSER <<EOF
${PASS}
${PASS}
EOF
    echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers.d/wheel_group
    chmod 440 /etc/sudoers.d/wheel_group
}
grubInstall () {
    xbps-install -Sy grub-x86_64-efi
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="Void"
    xbps-reconfigure -fa
}
xmirrorFunc() {
    xbps-install -Sy xmirror
    xmirror
}
chrootExit() {
    separator -iwi
    figlet "Leaving XCHROOT"
    separator -i
    echo "Continue with the command: 'reboot now'"
    separator -iwi
    exit
}
