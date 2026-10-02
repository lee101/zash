command -v cd
command -v ls | grep -c '/ls$'
command -v nonexistent_zz || echo notfound
