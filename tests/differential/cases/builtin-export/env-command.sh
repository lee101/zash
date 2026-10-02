env V=1 bash -c 'echo $V'
env -i V=2 /usr/bin/env | head -1
