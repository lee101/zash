command -V cd
command -V nonexistent_zz 2>&1 | sed 's/^[^:]*: //'
