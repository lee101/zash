case $UID in ''|*[!0-9]*) echo bad;; *) echo numeric;; esac
[ "$EUID" = "$UID" ] && echo same
