#!/bin/bash
if [ -f ~/.bashrc ]; then
        . ~/.bashrc
fi

if [ -f ~/.bash_profile ]; then
        . ~/.bash_profile
fi

#################################################
#       Usage : ftp_shinhan_send.sh [YYYYMMDD]
#	    2026.01.02	신한펀드파트너스(NPS) 전송
#	    2026.09.30	중복 실행 방지(flock), 파일별 전송 검증(크기/MD5), 재전송, 종료코드 추가
#
#       종료코드
#           0 : 6개 파일 전송 및 검증 완료
#           1 : 전송 후 검증 실패 (재전송 후에도 크기/MD5 불일치)
#           2 : 로컬 전송 파일 없음 또는 0 byte
#           3 : 이미 다른 전송이 실행 중 (중복 실행)
#           4 : 인자 오류 / 데이터 경로 오류
#################################################

export HOME=/home/fundftp
export PATH=$HOME/bin:$ORACLE_HOME/bin:/bin:/usr/bin:/sbin:/usr/sbin

LOG=/home/fundftp/log
DATA=/DATA/memb/shaitas

# FTP 접속정보 (신한펀드파트너스 CrushFTP)
FTP_HOST=210.122.123.52
FTP_USER=ftpzero
FTP_PASS='********'

LOCK=$LOG/.ftp_shinhan_send.lock
MAX_TRY=2                           # 검증 실패 파일 재전송 포함 최대 시도 횟수
FTP_TIMEOUT=600                     # ftp 세션 최대 대기(초)
YM=`date +%Y%m`
FEED_LOG=$LOG/feed_log.$YM

if [ $# = 0 ]; then
YMD=`date +%Y%m%d`
elif [ $# = 1 ]; then
YMD=$1
fi

FILES="kbp290 kbp290_ej kbp300 kbp300_ej nps_comp nps_credit"

# 결과 메시지는 feed_log 와 표준출력(ssh 호출 측 TBOLOG) 양쪽에 남긴다.
msg() {
        echo "[${YMD}] $*" | tee -a $FEED_LOG
}

if ! [[ "$YMD" =~ ^[0-9]{8}$ ]]; then
        YMD=${YMD:-NONE}
        msg "SHFUND FTP FAIL : invalid argument ($*)"
        exit 4
fi

# 중복 실행 방지 : 동시에 두 세션이 같은 파일을 STOR 하면 서버 파일이 0 byte 로 잘린다.
exec 9>$LOCK
if ! flock -n 9; then
        msg "SHFUND FTP FAIL : another ftp_shinhan_send.sh is running (duplicate run skipped)"
        exit 3
fi

echo "===========SHFUND START=========" >> $FEED_LOG
echo "[${YMD}] `date`" >> $FEED_LOG
echo "================================" >> $FEED_LOG

cd $DATA || { msg "SHFUND FTP FAIL : cannot cd $DATA"; exit 4; }

# 1) 로컬 파일 사전 점검 : 크기/MD5 를 기준값으로 저장
declare -A LSIZE LMD5
for f in $FILES; do
        fn=${f}.${YMD}
        if [ ! -s $fn ]; then
                msg "SHFUND FTP FAIL : local file missing or empty ($DATA/$fn)"
                exit 2
        fi
        LSIZE[$fn]=`stat -c %s $fn`
        LMD5[$fn]=`md5sum $fn | awk '{print tolower($1)}'`
done

# 2) 전송 + 검증 (검증 실패 파일만 재전송)
PENDING=""
for f in $FILES; do PENDING="$PENDING ${f}.${YMD}"; done

try=0
while [ -n "$PENDING" ] && [ $try -lt $MAX_TRY ]; do
        try=$((try + 1))
        TMP=`mktemp $LOG/.ftp_shinhan.XXXXXX`

        {
                echo "open $FTP_HOST"
                echo "user $FTP_USER $FTP_PASS"
                echo "binary"
                for fn in $PENDING; do echo "put $fn"; done
                echo "bye"
        } | timeout $FTP_TIMEOUT ftp -i -v -n > $TMP 2>&1
        cat $TMP >> $FEED_LOG

        FAILED=""
        for fn in $PENDING; do
                # CrushFTP 응답 : 226 Transfer complete.  MD5=<md5> ("/<파일명>" <서버파일크기>) STOR
                line=`grep '^226 Transfer complete' $TMP | grep -F "/${fn}\" " | tail -1`
                rmd5=`echo "$line" | sed -n 's/.*MD5=\([0-9A-Fa-f]*\).*/\1/p' | tr 'A-F' 'a-f'`
                rsize=`echo "$line" | sed -n 's/.*"[^"]*" \([0-9][0-9]*\)).*/\1/p'`

                if [ -z "$line" ]; then
                        reason="no 226 reply"
                elif [ "$rsize" != "${LSIZE[$fn]}" ]; then
                        reason="size mismatch local=${LSIZE[$fn]} server=${rsize:-?}"
                elif [ "$rmd5" != "${LMD5[$fn]}" ]; then
                        reason="md5 mismatch local=${LMD5[$fn]} server=${rmd5:-?}"
                else
                        msg "SHFUND FTP OK   $fn size=${LSIZE[$fn]} md5=${LMD5[$fn]} (try $try)"
                        continue
                fi
                msg "SHFUND FTP NG   $fn $reason (try $try)"
                FAILED="$FAILED $fn"
        done

        rm -f $TMP
        PENDING=$FAILED
done

TOTAL=`echo $FILES | wc -w`
if [ -n "$PENDING" ]; then
        NG=`echo $PENDING | wc -w`
        msg "SHFUND FTP FAIL $((TOTAL - NG))/$TOTAL :$PENDING"
        RC=1
else
        # TBOmain.sh 이전 버전의 성공 체크(grep YMD | grep complete)와 호환되도록 complete 문구 유지
        msg "SHFUND FTP complete OK $TOTAL/$TOTAL"
        RC=0
fi

echo "============ END ===============" >> $FEED_LOG
echo "[${YMD}] `date`" >> $FEED_LOG
echo "================================" >> $FEED_LOG

exit $RC
