trap 'echo cleanup' EXIT
nonexistent_command_zz 2>/dev/null
echo continuing
