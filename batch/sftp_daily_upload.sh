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
REMOTE_USER="remote_user"            # 원격지 계정
REMOTE_HOST="remote.example.com"     # 원격지 호스트/IP
REMOTE_PORT=6622                     # SFTP 포트
REMOTE_ROOT="/"                      # 원격지 루트 디렉토리 (예: /upload)
SSH_KEY="${HOME}/.ssh/id_rsa"        # 원격지에 public key 등록된 개인키

LOCAL_BASE="/data/send"              # 날짜 디렉토리들의 상위 로컬 경로
DATE_FMT="+%Y%m%d"                   # 날짜 디렉토리 형식
LOG_DIR="/data/logs/sftp"            # 로그 디렉토리
LOG_KEEP_DAYS=30                     # 로그 보관 일수
########################################

TARGET_DATE="${1:-$(date "${DATE_FMT}")}"
LOCAL_DIR="${LOCAL_BASE}/${TARGET_DATE}"
REMOTE_DIR="${REMOTE_ROOT%/}/${TARGET_DATE}"

mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/sftp_upload_${TARGET_DATE}.log"
LOCK_FILE="/tmp/sftp_daily_upload.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }

# 중복 실행 방지
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    log "ERROR: 이미 실행 중입니다."
    exit 1
fi

log "===== SFTP 업로드 시작 (대상일자: ${TARGET_DATE}) ====="

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

# SFTP 배치 명령 작성
#   '-' 접두사: 해당 명령 실패해도 계속 진행 (디렉토리가 이미 있을 때 mkdir 실패 무시)
BATCH_FILE="$(mktemp)"
trap 'rm -f "${BATCH_FILE}"' EXIT

{
    echo "-mkdir \"${REMOTE_DIR}\""
    echo "cd \"${REMOTE_DIR}\""
    echo "lcd \"${LOCAL_DIR}\""
    for f in "${FILES[@]}"; do
        [[ -f "$f" ]] && echo "put \"$(basename "$f")\""
    done
    echo "ls -l"
    echo "bye"
} > "${BATCH_FILE}"

# 실행
set +e
sftp -b "${BATCH_FILE}" \
     -P "${REMOTE_PORT}" \
     -i "${SSH_KEY}" \
     -o BatchMode=yes \
     -o ConnectTimeout=30 \
     -o ServerAliveInterval=30 \
     -o StrictHostKeyChecking=accept-new \
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
