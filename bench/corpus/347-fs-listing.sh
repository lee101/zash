# cat: fs-listing
ln -sf $PWD/README.md $SCRATCH/lnk && readlink $SCRATCH/lnk | wc -c
