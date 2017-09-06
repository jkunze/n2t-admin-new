# Customize this shared (eg, role) account user's startup files based
# on who is actually logged into it; find that user and source anything
# that you find for that user under ~/.profile.d/<username>.

if [ -f ~/.bashrc ] ; then
	source ~/.bashrc
fi

whoami=`who -m | awk '{ print $1 }'`

if [ -f ~/.profile.d/$whoami ] ; then
	source ~/.profile.d/$whoami
fi
