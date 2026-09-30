#!/bin/bash
if [ -f ~/.bashrc ]; then
        . ~/.bashrc
fi

if [ -f ~/.bash_profile ]; then
        . ~/.bash_profile
fi

#################################################
#       Usage
#	    2026.01.02	신한펀드파트너스(NPS) 전송
#################################################

export HOME=/home/fundftp
export PATH=$HOME/bin:$ORACLE_HOME/bin:/bin:/usr/bin:/sbin:/usr/sbin

LOG=/home/fundftp/log
DATA=/DATA/memb/shaitas
YM=`date +%Y%m`

if [ $# = 0 ]; then
YMD=`date +%Y%m%d`
elif [ $# = 1 ]; then
YMD=$1
fi

echo "===========SHFUND START=========" >> $LOG/feed_log.$YM
echo `date` >> $LOG/feed_log.$YM
echo "================================" >> $LOG/feed_log.$YM

cd $DATA

ftp -i -v -n << EOF >> $LOG/feed_log.$YM
open 210.122.123.52
user ftpzero ********

mput kbp290.${YMD}
mput kbp290_ej.${YMD}
mput kbp300.${YMD}
mput kbp300_ej.${YMD}
mput nps_comp.${YMD}
mput nps_credit.${YMD}

bye
EOF

echo "============ END ===============" >> $LOG/feed_log.$YM
echo `date` >> $LOG/feed_log.$YM
echo "================================" >> $LOG/feed_log.$YM

exit 0;

