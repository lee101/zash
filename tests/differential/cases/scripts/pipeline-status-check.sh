set -o pipefail
if grep -q alpha a.txt | head -1; then echo found; else echo missing; fi
if ! cat nonexistent_zz 2>/dev/null | sort > /dev/null; then echo failed; fi
