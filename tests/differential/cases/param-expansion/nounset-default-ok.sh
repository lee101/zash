set -u
echo ${undefined_var:-ok} ${undefined_var-ok} ${undefined_var:+x}
