#!/usr/bin/env bash
#
# sftp_daily_upload.sh
#   매일 해당 날짜(YYYYMMDD) 로컬 디렉토리의 파일을
#   원격지 루트 디렉토리 아래 같은 이름의 날짜 디렉토리를 만들어 SFTP로 put 한다.
#
# 사용법:
#   ./sftp_daily_upload.sh            # 오늘 날짜 기준
#   ./sftp_daily_upload.sh 20261006   # 특정 날짜 재전송
#
# crontab 예시 (매일 06:10 실행):
#   10 6 * * * /path/to/sftp_daily_upload.sh >> /path/to/logs/cron.log 2>&1
#
set -euo pipefail

########################################
# 설정 (환경에 맞게 수정)
########################################
REMOTE_USER="mirae"                  # 원격지 계정
REMOTE_HOST="192.168.1.96"           # 원격지 호스트/IP
REMOTE_PORT=7422                     # SFTP 포트
REMOTE_ROOT="/data"                  # 원격지 루트 디렉토리
# 원격지에 public key 등록된 개인키 - 반드시 절대경로로 지정
#   ${HOME} 을 쓰면 다른 스크립트/cron/su 에서 호출될 때 다른 경로가 되어 인증 실패함
SSH_KEY="/home/계정명/.ssh/id_rsa"

LOCAL_BASE="/EXFS/fundftp/memb/mirae" # 날짜 디렉토리들의 상위 로컬 경로
DATE_FMT="+%Y%m%d"                   # 날짜 디렉토리 형식
LOG_DIR="/EXFS/fundftp/log"          # 로그 디렉토리
LOG_KEEP_DAYS=400                    # 로그 보관 일수 (월별 파일, 마지막 기록일 기준 약 13개월)
########################################

TARGET_DATE="${1:-$(date "${DATE_FMT}")}"
LOCAL_DIR="${LOCAL_BASE}/${TARGET_DATE}"
REMOTE_DIR="${REMOTE_ROOT%/}/${TARGET_DATE}"

mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/sftp_upload_${TARGET_DATE:0:6}.log"   # 월별 로그 (YYYYMM)
LOCK_FILE="/tmp/sftp_daily_upload.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }

# 중복 실행 방지
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    log "ERROR: 이미 실행 중입니다."
    exit 1
fi

log "===== SFTP 업로드 시작 (대상일자: ${TARGET_DATE}) ====="
log "실행계정: $(id -un) / HOME: ${HOME:-없음} / KEY: ${SSH_KEY}"

# 개인키 확인 (없거나 읽을 수 없으면 ssh 가 키를 건너뛰어 Permission denied 발생)
if [[ ! -r "${SSH_KEY}" ]]; then
    log "ERROR: 개인키를 읽을 수 없습니다: ${SSH_KEY} (실행계정: $(id -un))"
    exit 3
fi

# 로컬 디렉토리 / 파일 확인
if [[ ! -d "${LOCAL_DIR}" ]]; then
    log "ERROR: 로컬 디렉토리가 없습니다: ${LOCAL_DIR}"
    exit 2
fi

shopt -s nullglob
FILES=("${LOCAL_DIR}"/*)
shopt -u nullglob
FILE_CNT=0
for f in "${FILES[@]}"; do [[ -f "$f" ]] && FILE_CNT=$((FILE_CNT + 1)); done

if (( FILE_CNT == 0 )); then
    log "WARN: 전송할 파일이 없습니다: ${LOCAL_DIR}"
    exit 0
fi
log "전송 대상 파일 수: ${FILE_CNT}"

# SFTP 공통 옵션
#   구버전 OpenSSH 호환을 위해 -P(포트), -i(키) 대신 -o 옵션 사용
#   (구버전 sftp 에서 -P 는 sftp_server_path 이고 -i 는 지원하지 않음)
#   최초 1회는 수동 접속해서 호스트 키를 known_hosts 에 등록해 두어야 함
SFTP_OPTS=(
    -o "Port=${REMOTE_PORT}"
    -o "IdentityFile=${SSH_KEY}"
    -o BatchMode=yes
    -o ConnectTimeout=30
    -o ServerAliveInterval=30
)

BATCH_FILE="$(mktemp)"
trap 'rm -f "${BATCH_FILE}"' EXIT

set +e

# 1) 원격 날짜 디렉토리 생성 (이미 있으면 실패하지만 무시)
#    구버전은 배치파일의 '-' 접두사를 지원하지 않아 별도 세션으로 분리
echo "mkdir \"${REMOTE_DIR}\"" > "${BATCH_FILE}"
echo "bye" >> "${BATCH_FILE}"
sftp -b "${BATCH_FILE}" "${SFTP_OPTS[@]}" \
     "${REMOTE_USER}@${REMOTE_HOST}" >> "${LOG_FILE}" 2>&1
log "원격 디렉토리 생성 시도 완료 (이미 있으면 실패 메시지는 무시): ${REMOTE_DIR}"

# 2) 파일 전송
{
    echo "cd \"${REMOTE_DIR}\""
    echo "lcd \"${LOCAL_DIR}\""
    for f in "${FILES[@]}"; do
        [[ -f "$f" ]] && echo "put \"$(basename "$f")\""
    done
    echo "ls -l"
    echo "bye"
} > "${BATCH_FILE}"

sftp -b "${BATCH_FILE}" "${SFTP_OPTS[@]}" \
     "${REMOTE_USER}@${REMOTE_HOST}" >> "${LOG_FILE}" 2>&1
RC=$?
set -e

if (( RC == 0 )); then
    log "SUCCESS: ${FILE_CNT}개 파일 전송 완료 -> ${REMOTE_HOST}:${REMOTE_DIR}"
else
    log "ERROR: SFTP 전송 실패 (rc=${RC}). 로그 확인: ${LOG_FILE}"
fi

# 오래된 로그 정리
find "${LOG_DIR}" -name 'sftp_upload_*.log' -mtime +"${LOG_KEEP_DAYS}" -delete 2>/dev/null || true

log "===== SFTP 업로드 종료 ====="
exit "${RC}"
