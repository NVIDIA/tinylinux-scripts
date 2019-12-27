export EDITOR="/bin/nano"
export PS1="\n\[\033[1;32m\][\t] \[\033[1;33m\]\w\[\033[0m\]\n\\$ "
export TZ=UTC
echo "$PATH" | grep -q "/sbin" || export PATH="$PATH:/usr/sbin:/sbin"
export PYTHONUSERBASE="$HOME/python"
