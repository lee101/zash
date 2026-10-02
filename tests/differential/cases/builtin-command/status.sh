command true; echo $?
command false; echo $?
command nonexistent_zz 2>/dev/null; echo $?
