for i in 1 2; do false; done; echo $?
for i in 1 2; do true; done; echo $?
