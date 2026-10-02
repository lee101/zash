# cat: fs-listing
ls -l | awk '{print $NF}' | head -5
