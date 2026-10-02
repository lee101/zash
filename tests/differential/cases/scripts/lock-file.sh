lock=run.lock
if ( set -C; echo $$ > $lock ) 2>/dev/null; then echo acquired; else echo busy; fi
if ( set -C; echo $$ > $lock ) 2>/dev/null; then echo acquired; else echo busy; fi
rm -f $lock
