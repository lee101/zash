set -a
v=exported
bash -c 'echo ${v:-not}'
set +a
w=local
bash -c 'echo ${w:-not}'
