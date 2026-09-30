# SHFUND NPS FTP 전송 (신한펀드파트너스)

| 파일 | 서버 | 경로 |
|---|---|---|
| TBOmain.sh | R ETL 서버 (rdev) | /home/rdev/R/ETL_u/bin/ |
| ftp_shinhan_send.sh | FTP 중계 서버 (fundftp@210.92.202.230) | /home/fundftp/bin/ |

## 배포 전 준비 (FTP 중계 서버)
FTP 접속정보는 `ftp_shinhan_send.sh` 상단 `FTP_HOST / FTP_USER / FTP_PASS` 변수에 직접 넣어 사용한다.
저장소에는 비밀번호를 `'********'` 로 마스킹해 두었으므로 서버 배포본에는 실제 비밀번호를 넣는다.
서버 파일은 `chmod 700` 으로 fundftp 계정만 읽을 수 있게 한다.
- 저장소 파일은 UTF-8 / LF 이다. 서버 로케일이 EUC-KR이면 `iconv -f UTF-8 -t EUC-KR` 로 변환해서 올린다 (한글은 주석뿐이라 동작에는 영향 없음).
- `flock`, `timeout`, `md5sum` (util-linux / coreutils), bash 4 이상 필요.

## 동작
1. TBOmain.sh : flock 으로 중복 실행 방지 → R 파일 생성 → 준비 확인 → ssh 로 전송 스크립트 호출
   → **ssh 종료코드 0 일 때만** `[YMD] SHFUND NPS FTP SEND END` 기록 (실패 시 `SEND FAIL (RC:n)`).
   → 전송완료 여부는 체크하지 않음 (다시 실행하면 재전송). 동시 실행만 flock 으로 차단.
2. ftp_shinhan_send.sh : flock → 로컬 6개 파일 존재/크기/MD5 확인 → FTP 전송
   → CrushFTP `226 Transfer complete. MD5=... ("/파일" 크기)` 응답을 파일별로 로컬 크기·MD5와 비교
   → 불일치 파일만 1회 재전송 → 6/6 일치 시 `SHFUND FTP complete OK 6/6`, exit 0.

## 종료코드 (ftp_shinhan_send.sh)
| RC | 의미 |
|---|---|
| 0 | 6개 전송·검증 완료 |
| 1 | 재전송 후에도 크기/MD5 불일치 (서버 파일 0 byte 등) |
| 2 | 로컬 파일 없음 또는 0 byte |
| 3 | 다른 전송이 실행 중 (중복 실행 차단) |
| 4 | 인자 오류 / 데이터 경로 오류 |
| 255 | (TBOmain 측) ssh 접속 실패 |
