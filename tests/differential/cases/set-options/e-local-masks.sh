set -e
f() { local x=$(false); echo masked; }
f
