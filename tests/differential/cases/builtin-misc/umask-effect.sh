umask 077
touch um.txt
stat -c %a um.txt
umask 022
touch um2.txt
stat -c %a um2.txt
