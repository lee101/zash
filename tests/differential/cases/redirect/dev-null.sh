echo hidden > /dev/null
echo shown
ls nonexistent_xyz 2>/dev/null
echo $?
