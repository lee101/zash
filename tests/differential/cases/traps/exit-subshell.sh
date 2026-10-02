trap 'echo parent-exit' EXIT
( trap 'echo sub-exit' EXIT; echo in-sub )
echo after-sub
