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
# 2026.09.30 중복 실행 방지(flock), NOT READY 오판 수정, ssh 종료코드로 전송 성공 판단

export RSRC_PATH='/home/rdev/R/ETL_u/src'
export LOG_PATH='/home/rdev/R/ETL_u/log'
export LOG_FILE="/TBOLOG."$(date +"%Y%m")
export PROC_ID='TBOmain.sh'
YYYYMM=$(date +"%Y%m");

FTP_SERVER='fundftp@210.92.202.230'
SSH_OPT='-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=4'

# 중복 실행 방지 : 전송 중에 다시 실행되면 두 세션이 동시에 FTP 전송하게 된다.
exec 9>$LOG_PATH/.TBOmain.lock
if ! flock -n 9; then
	/bin/echo "[${YMD}] TBOmain.sh ALREADY RUNNING - SKIP ------------------------------------" >> $LOG_PATH$LOG_FILE
	exit;
fi

/bin/date "+[%Y%m%d][%H:%M:%S] [${PROC_ID}] [${YMD}]---------------------------------------------" >> $LOG_PATH$LOG_FILE
/bin/date "+[%Y%m%d][%H:%M:%S] TBO316_make [${YMD}] start. --------------------------------------" >> $LOG_PATH$LOG_FILE

###############################################################
# 20.TBO316_make.R
# Rscript /home/rdev/R/ETL_u/src/20.TBO316_make.R 20240701 20240717 1016

# Rscript $RSRC_PATH/20.TBO316_make.R $YMD $YMD 1012 >> $LOG_PATH$LOG_FILE
Rscript $RSRC_PATH/20.TBO316_make.R $YMD $YMD 1016 >> $LOG_PATH$LOG_FILE

/bin/date "+[%Y%m%d][%H:%M:%S] TBO316_make [${YMD}] end. ----------------------------------------" >> $LOG_PATH$LOG_FILE

###############################################################
# 이 쉘이 직접 남기는 SHFUND 메시지(NOT READY/SEND END/SEND FAIL 등)는 준비 여부 판단에서 제외
tbo_chk=`grep "$YMD" $LOG_PATH$LOG_FILE | grep SHFUND | grep -v -e "SHFUND NPS FILES ARE NOT READY" -e "SHFUND NPS FTP" -e "SHFUND FTP" | wc -l`
# 2026.09.30 전송완료(ALREADY SENT) 체크 제거 : 재전송 허용, 동시 전송은 flock 으로 차단
if [ ${tbo_chk} -eq 0 ]; then
	/bin/echo "[${YMD}] SHFUND NPS FILES ARE NOT READY ------------------------------------" >> $LOG_PATH$LOG_FILE
	exit;
else
	# /bin/ssh fundftp@210.92.202.230 "/home/fundftp/bin/ftp_kebis_send.sh ${YMD}"; # 2026.01.02 하나펀드서비스 중단
	# 2026.01.02 신한펀드파트너스 추가
	# 전송 스크립트가 파일별 크기/MD5 검증 결과를 표준출력으로 돌려주고, 전체 성공 시에만 종료코드 0
	/bin/ssh ${SSH_OPT} ${FTP_SERVER} "/home/fundftp/bin/ftp_shinhan_send.sh ${YMD}" >> $LOG_PATH$LOG_FILE 2>&1
	send_rc=$?

	if [ ${send_rc} -eq 0 ]; then
		/bin/echo "[${YMD}] SHFUND NPS FTP SEND END (6/6 VERIFIED)---------------------------" >> $LOG_PATH$LOG_FILE
	else
		# 1:검증실패 2:파일없음 3:중복실행 4:인자/경로 오류 255:ssh 접속 실패
		/bin/echo "[${YMD}] SHFUND NPS FTP SEND FAIL (RC:${send_rc})---------------------------" >> $LOG_PATH$LOG_FILE
	fi
fi

/bin/date "+[%Y%m%d][%H:%M:%S] TBO NPS FTP Send [${YMD}] end. -----------------------------------------" >> $LOG_PATH$LOG_FILE


exit;
