p='f*'
case foo in $p) echo unquoted-var;; esac
case foo in "$p") echo quoted;; *) echo literal-mismatch;; esac
