alias hi='echo aliased'
hi 2>&1 | sed 's/^[^:]*: //'
