ls nonexistent_zz 2>/dev/null | cat
echo ${PIPESTATUS[0]}
