#!/bin/bash
if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi

if [ -f ~/.bash_profile ]; then
    . ~/.bash_profile
fi

if [ -n "$1" ]
then
	export YMD=${1};
	# export YMD=$(date -d "${1}" +'%Y%m%d')
	# export YMD=$(date -d "$YMD -1 days" +'%Y%m%d')
else	
	export YMD=$(date +"%Y%m%d");
	export BF_YMD=$(date +"%Y%m%d" -d '-1days');
fi


# ./home/rdev/R/ETL_u/bin/TBOmain.sh 

export RSRC_PATH='/home/rdev/R/ETL_u/src'
export LOG_PATH='/home/rdev/R/ETL_u/log'
export LOG_FILE="/TBOLOG."$(date +"%Y%m")
export PROC_ID='TBOmain.sh'
YYYYMM=$(date +"%Y%m");

/bin/date "+[%Y%m%d][%H:%M:%S] [${PROC_ID}] [${YMD}]---------------------------------------------" >> $LOG_PATH$LOG_FILE
/bin/date "+[%Y%m%d][%H:%M:%S] TBO316_make [${YMD}] start. --------------------------------------" >> $LOG_PATH$LOG_FILE

###############################################################
# 20.TBO316_make.R
# Rscript /home/rdev/R/ETL_u/src/20.TBO316_make.R 20240701 20240717 1016

# Rscript $RSRC_PATH/20.TBO316_make.R $YMD $YMD 1012 >> $LOG_PATH$LOG_FILE
Rscript $RSRC_PATH/20.TBO316_make.R $YMD $YMD 1016 >> $LOG_PATH$LOG_FILE

/bin/date "+[%Y%m%d][%H:%M:%S] TBO316_make [${YMD}] end. ----------------------------------------" >> $LOG_PATH$LOG_FILE

############################################################### 
tbo_chk=`cat $LOG_PATH$LOG_FILE |grep $YMD |grep SHFUND |wc -l`
send_chk=`cat $LOG_PATH$LOG_FILE |grep $YMD |grep SHFUND |grep FTP |grep END |wc -l`
if [ ${tbo_chk} -eq "0" ]; then
        /bin/echo "[${YMD}] SHFUND NPS FILES ARE NOT READY ------------------------------------" >> $LOG_PATH$LOG_FILE
	exit;
elif [ ${send_chk} -gt "0" ]; then
	/bin/echo "[${YMD}] SHFUND NPS FTP ALREADY SENT ---------------------------------------" >> $LOG_PATH$LOG_FILE
	exit;	
else
	# /bin/ssh fundftp@210.92.202.230 "/home/fundftp/bin/ftp_kebis_send.sh ${YMD}"; # 2026.01.02 하나펀드서비스 중단
	/bin/ssh fundftp@210.92.202.230 "/home/fundftp/bin/ftp_shinhan_send.sh ${YMD}"; # 2026.01.02 신한펀드파트너스 추가

	send_success_cnt=`/bin/ssh fundftp@210.92.202.230 "cat /home/fundftp/log/feed_log.$YYYYMM |grep $YMD |grep complete |wc -l"`
	if [ ${send_success_cnt} -gt "0" ]; then
			/bin/echo "[${YMD}] SHFUND NPS FTP SEND END (COUNT:${send_success_cnt})---------------------------"  >> $LOG_PATH$LOG_FILE
	fi
fi

/bin/date "+[%Y%m%d][%H:%M:%S] TBO NPS FTP Send [${YMD}] end. -----------------------------------------" >> $LOG_PATH$LOG_FILE


exit;
