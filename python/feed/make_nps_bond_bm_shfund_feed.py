#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
신한아이타스 data feed(국민연금 채권 BM) 파일 생성

R 원본: zeroin_memb_daily_func.R
  - make_NPS_BOND_BM_SHFUND_FEED(s_date, e_date, p_memb_cd)
  - fnFEED_FG22(df_date_list, "ALL")

처리 흐름 (R 과 동일)
  1. FIMS.TSS002 에서 s_date ~ e_date 영업일(HUIL_GB='0') 목록(처리일) 조회
  2. 처리일마다 [처리일 ~ 익영업일-1] 일자 목록 조회 (금요일/연휴 전일은 휴일분 포함)
  3. 일자 목록 각각에 대해 TBO316 6개 쿼리 SELECT 후 합침
  4. NA -> "" 치환, '|' 구분 / 헤더 없음 / EUC-KR 로 6개 파일 저장
       kbp290.YYYYMMDD, kbp290_ej.YYYYMMDD, kbp300.YYYYMMDD,
       kbp300_ej.YYYYMMDD, nps_credit.YYYYMMDD, nps_comp.YYYYMMDD

DB 로그(TSS012 / MANDATE 로그), 그룹웨어 메시지 전송은 소급 생성 용도라 제외.

사용 예
  export FIMS_DB_USER=fims FIMS_DB_PASSWORD=*** FIMS_DB_DSN=host:1521/SID
  python3 make_nps_bond_bm_shfund_feed.py 20240801 20260929 \
      --memb-cd 1016 --out-dir /home/rdev/FEED/ZD01/DATA/memb/shaitas_backfill
"""

import argparse
import math
import os
import sys
import time

# ---------------------------------------------------------------------------
# SQL (R 원본 그대로, 바인드 변수만 이름 바인딩)
# ---------------------------------------------------------------------------
SQL_CHURI_YMD = """
    SELECT YMD, TO_CHAR(TO_DATE(YMD, 'YYYYMMDD') -1, 'YYYYMMDD') as BF_YMD
    FROM FIMS.TSS002
    WHERE YMD >= :s_date AND YMD <= :e_date
    AND HUIL_GB='0'
    order by YMD
"""

SQL_DATE_LIST = """
    SELECT YMD, TO_CHAR(TO_DATE(YMD, 'YYYYMMDD') -1, 'YYYYMMDD') as BF_YMD
    FROM FIMS.TSS002
    WHERE YMD >= :s_date
      AND YMD <= To_Char(To_Date(F_AF_YONG_YMD(:e_date), 'yyyymmdd')-1, 'yyyymmdd')
    order by YMD
"""

_SQL_KBP = """
    SELECT GIJUN_YMD, SECTOR_CD, MAT_CD, AVG_CPN, AVG_MAT/365
         , AVG_DUR, AVG_CONV, AVG_CURR_YLD*100
         , AVG_YTM, AVG_CPRICE_IDX, AVG_TOT_IDX, AVG_CALL_IDX
         , AVG_CPRICE_WT/100, AVG_TOT_WT/100, AVG_CALL_WT/100, AVG_SIGAP_WT/100
    FROM TBO316
    WHERE MEMB_CD = :p_memb_cd
    AND GIJUN_YMD = :p_date
    AND IDX_CD = '{idx_cd}'
    AND OFFICE_GB ='Z3'
    AND DATA_GB ='1'
    AND MAT_CD IN (SELECT MAT_CD FROM TBO300M WHERE END_YMD ='99999999' AND TYPE ='{mat_type}')
"""

# --05. NTRI 평균지수 (크레딧)
SQL_NPS_CREDIT = """
    SELECT GIJUN_YMD, IDX_CD AS BM_CD, 'NPSCredit' BM_NM, SECTOR_CD, MAT_CD
         , (SELECT NM FROM ZRN.ZRN002 WHERE G_CD LIKE 'TBO316.1016.SECTOR_CD%' AND CD = A.SECTOR_CD AND ROWNUM=1) AS SECTOR_NM
         , (SELECT MAT_TYPE FROM TBO300M WHERE END_YMD ='99999999' AND TYPE ='3' AND MAT_CD = A.MAT_CD) MAT_NM
         , AVG_TOT_IDX, AVG_CPRICE_IDX, AVG_INT_IDX, AVG_TOT_RT, CNT
         , AVG_SIGAP_AEK, AVG_CPN, AVG_DUEDAY, '0' AS PRICE, AVG_YTM, AVG_DUR, AVG_CONV, AVG_TOT_WT, AVG_SIGAP_WT
    FROM TBO316 A
    WHERE MEMB_CD = :p_memb_cd
    AND GIJUN_YMD = :p_date
    AND IDX_CD = 'C5000'
    AND OFFICE_GB ='Z3'
    AND DATA_GB ='4'
    AND (SECTOR_CD = '0000' OR SECTOR_CD IN (SELECT CD FROM ZRN.ZRN002 WHERE G_CD LIKE 'TBO316.1016.SECTOR_CD%'))
"""

# --06. NTRI 평균지수 (전체)
SQL_NPS_COMP = """
    SELECT GIJUN_YMD, IDX_CD AS BM_CD, 'NPS전체' BM_NM, SECTOR_CD, MAT_CD
         , (SELECT NM FROM ZRN.ZRN002 WHERE G_CD LIKE 'TBO316.1016.SECTOR_CD%' AND CD = A.SECTOR_CD AND ROWNUM=1) AS SECTOR_NM
         , (SELECT MAT_TYPE FROM TBO300M WHERE END_YMD ='99999999' AND TYPE ='4' AND MAT_CD = A.MAT_CD) MAT_NM
         , AVG_TOT_IDX, AVG_CPRICE_IDX, AVG_INT_IDX, AVG_TOT_RT, CNT
         , AVG_SIGAP_AEK, AVG_CPN, SubStr(AVG_DUEDAY, 1, 8), '0' AS PRICE, AVG_YTM
         , AVG_DUR, AVG_CONV, AVG_TOT_WT, AVG_SIGAP_WT
    FROM TBO316 A
    WHERE MEMB_CD = :p_memb_cd
    AND GIJUN_YMD = :p_date
    AND IDX_CD = 'T5000'
    AND OFFICE_GB ='Z3'
    AND DATA_GB ='5'
    AND (SECTOR_CD = '0000' OR SECTOR_CD IN (SELECT CD FROM ZRN.ZRN002 WHERE G_CD LIKE 'TBO316.1016.SECTOR_CD%'))
"""

# (파일명 prefix, SQL) - R fnFEED_FG22 의 01~06 순서
FEEDS = [
    ("kbp290", _SQL_KBP.format(idx_cd="B5000", mat_type="1")),     # --01. 상대가치형 3사평균지수(기본)
    ("kbp290_ej", _SQL_KBP.format(idx_cd="B5000", mat_type="2")),  # --02. 상대가치형 3사평균지수(세분화)
    ("kbp300", _SQL_KBP.format(idx_cd="G5000", mat_type="1")),     # --03. 일반채권형 3사평균지수(기본)
    ("kbp300_ej", _SQL_KBP.format(idx_cd="G5000", mat_type="2")),  # --04. 일반채권형 3사평균지수(세분화)
    ("nps_credit", SQL_NPS_CREDIT),                                # --05. NTRI 평균지수 (크레딧)
    ("nps_comp", SQL_NPS_COMP),                                    # --06. NTRI 평균지수 (전체)
]


# ---------------------------------------------------------------------------
# R write.table 과 동일한 숫자 표기
#   - 유효숫자 최대 15자리 (R_print.digits = DBL_DIG)
#   - 고정소수점 폭 <= 지수표기 폭 이면 고정소수점, 아니면 지수표기 (scipen = 0)
#     예) 100000 -> 1e+05, 0.0001 -> 1e-04, 0.00012 -> 0.00012
# ---------------------------------------------------------------------------
R_DIGITS = 15


def format_r_number(x, plain=False):
    if x is None:
        return ""
    x = float(x)
    if math.isnan(x):
        return ""
    if math.isinf(x):
        return "Inf" if x > 0 else "-Inf"
    if x == 0:
        return "0"

    mant, exp = f"{x:.{R_DIGITS - 1}e}".split("e")
    kp = int(exp)
    digits = mant.lstrip("-").replace(".", "").rstrip("0")
    nsig = max(len(digits), 1)
    neg = 1 if x < 0 else 0

    rgt = max(0, nsig - kp - 1)
    fixed_width = neg + (kp + 1 if kp >= 0 else 1) + (rgt + 1 if rgt > 0 else 0)
    sci_width = neg + (nsig + 1 if nsig > 1 else 1) + (5 if abs(kp) >= 100 else 4)

    if plain or fixed_width <= sci_width:
        return f"{x:.{rgt}f}"

    m = digits[0] + ("." + digits[1:] if nsig > 1 else "")
    return f"{'-' if neg else ''}{m}e{'-' if kp < 0 else '+'}{abs(kp):02d}"


def format_value(v, plain=False):
    if v is None:
        return ""  # R: a.FG22$...[is.na(...)] <- ""
    if isinstance(v, str):
        return v
    if isinstance(v, (int, float)) or type(v).__name__ == "Decimal":
        return format_r_number(v, plain)
    return str(v)


# ---------------------------------------------------------------------------
# DB
# ---------------------------------------------------------------------------
def connect(args):
    import oracledb

    if args.thick:
        oracledb.init_oracle_client(lib_dir=args.oracle_lib_dir or None)
    user = args.user or os.environ.get("FIMS_DB_USER")
    password = args.password or os.environ.get("FIMS_DB_PASSWORD")
    dsn = args.dsn or os.environ.get("FIMS_DB_DSN")
    if not (user and password and dsn):
        sys.exit("DB 접속정보 필요: --user/--password/--dsn 또는 FIMS_DB_USER/FIMS_DB_PASSWORD/FIMS_DB_DSN")
    return oracledb.connect(user=user, password=password, dsn=dsn)


def select(conn, sql, **binds):
    with conn.cursor() as cur:
        cur.execute(sql, binds)
        return cur.fetchall()


def write_feed(path, rows, encoding, plain):
    # mfm.file.save3_enc(df, path, file, "|", F, "EUC-KR") : 헤더/따옴표/행번호 없음
    with open(path, "w", encoding=encoding, newline="\n") as f:
        for row in rows:
            f.write("|".join(format_value(v, plain) for v in row))
            f.write("\n")


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def make_nps_bond_bm_shfund_feed(conn, s_date, e_date, p_memb_cd, out_dir, encoding, plain):
    os.makedirs(out_dir, exist_ok=True)

    churi_ymd = select(conn, SQL_CHURI_YMD, s_date=s_date, e_date=e_date)
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} 처리일 {len(churi_ymd)}건 ({s_date} ~ {e_date}), memb_cd={p_memb_cd}")

    summary = []
    for p_churi_ymd, _ in churi_ymd:
        date_list = select(conn, SQL_DATE_LIST, s_date=p_churi_ymd, e_date=p_churi_ymd)

        counts = []
        for prefix, sql in FEEDS:
            rows = []
            for p_date, _ in date_list:
                rows.extend(select(conn, sql, p_memb_cd=p_memb_cd, p_date=p_date))
            write_feed(os.path.join(out_dir, f"{prefix}.{p_churi_ymd}"), rows, encoding, plain)
            counts.append(len(rows))

        ymds = ",".join(d for d, _ in date_list)
        print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} [{p_churi_ymd}] GIJUN_YMD={ymds} "
              + " ".join(f"{p}={c}" for (p, _), c in zip(FEEDS, counts)))
        summary.append((p_churi_ymd, ymds, counts))

    empty = [s for s in summary if 0 in s[2]]
    if empty:
        print(f"\n[WARN] 0건 파일이 있는 처리일 {len(empty)}건:")
        for churi, ymds, counts in empty:
            print(f"  {churi} ({ymds}) " + " ".join(f"{p}={c}" for (p, _), c in zip(FEEDS, counts)))
    print(f"\n완료: 처리일 {len(summary)}건, 파일 {len(summary) * len(FEEDS)}개 -> {out_dir}")


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="신한아이타스 data feed(국민연금 채권 BM) 파일 생성")
    ap.add_argument("s_date", help="시작일 YYYYMMDD")
    ap.add_argument("e_date", help="종료일 YYYYMMDD")
    ap.add_argument("--memb-cd", default="1016", help="MEMB_CD (기본 1016)")
    ap.add_argument("--out-dir", default="./shaitas", help="출력 디렉토리 (운영: /home/rdev/FEED/ZD01/DATA/memb/shaitas)")
    ap.add_argument("--encoding", default="euc-kr", help="파일 인코딩 (기본 euc-kr)")
    ap.add_argument("--plain-numbers", action="store_true",
                    help="R 식 지수표기(1e+05 등) 대신 항상 고정소수점으로 기록")
    ap.add_argument("--user")
    ap.add_argument("--password")
    ap.add_argument("--dsn", help="host:port/service_name")
    ap.add_argument("--thick", action="store_true", help="oracledb thick 모드 (Oracle 11g 이하)")
    ap.add_argument("--oracle-lib-dir", help="thick 모드 Instant Client 경로")
    return ap.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    conn = connect(args)
    try:
        make_nps_bond_bm_shfund_feed(conn, args.s_date, args.e_date, args.memb_cd,
                                     args.out_dir, args.encoding, args.plain_numbers)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
