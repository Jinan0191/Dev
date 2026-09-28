CREATE OR REPLACE PROCEDURE fims.sr_tdo201_main (
    P_GIJUN_YMD   IN  VARCHAR2,
    P_PRD_CD      IN  VARCHAR2 default '%',
    P_IP_USER     IN  VARCHAR2,
    P_MSG         OUT VARCHAR2
)
IS
    TYPE T_FLAG_TAB IS TABLE OF VARCHAR2(1) INDEX BY VARCHAR2(100);

    XCON_GIJUN_AMT    NUMBER := 10000000;
    WA_BF_YMD         VARCHAR2(8);
    W_PRD_GB          VARCHAR2(1);
    W_PYUNGA_AEK      NUMBER(20);
    W_BF_PYUNGA_AEK   NUMBER(20);
    W_SEOLJ_AEK       NUMBER(20);
    W_DAILY_RT        NUMBER(20,12);
    W_FIX_MAT_RT      NUMBER(20,12);
    W_T36_JY_YMD      VARCHAR2(8);   -- 가장 최근 3년 만기 이자 적용일 (만기 익영업일, D1 이하)
    W_T36_GB          VARCHAR2(1);   -- D1 이 3년 만기일이면 'Y'
    W_CYC_FROM_YMD    VARCHAR2(8);   -- 3년 주기 시작일 (UY_YMD → 만기 익영업일 → ...)
    W_MAT_YMD         VARCHAR2(8);   -- 해당 주기의 만기일
    W_RATE_YMD        VARCHAR2(8);   -- 이율 기준일 (UY_YMD 또는 최근 만기 익영업일)
    W_DAY_FROM_YMD    VARCHAR2(8);   -- 이자 일수 산정 시작일 (미포함)
    W_GA_TODAY        NUMBER;        -- 보험펀드 당일 기준가
    W_GA_PREV         NUMBER;        -- 보험펀드 직전 기준가 (전일 TDO201 이월값)
    W_GA_CUR          NUMBER;
    W_I_RT            NUMBER;
    W_P_TOT_AEK       NUMBER;        -- 전일 000 평가액
    W_P_SEOLJ_AEK     NUMBER;        -- 전일 000 설정액
    W_P_SUIK_JISU     NUMBER;        -- 전일 000 수익지수
    W_000_SEOLJ_GB    VARCHAR2(1);   -- 000 설정액 산출구분 R:리밸런싱 T:3년만기 N:이월
    W_T36_PRD         T_FLAG_TAB;    -- 당일 3년 만기 이자 적용(설정액 재산출) 상품
    W_CUR_PRD_CD      VARCHAR2(100); -- 오류 위치 추적용
    W_CUR_FUND_CD     VARCHAR2(100);

BEGIN
    WA_BF_YMD := FIMS.F_BF_YONG_YMD(P_GIJUN_YMD);

    FOR D1 IN (
        SELECT YMD, BF_YONG_YMD
          FROM  FIMS.TSS002
         WHERE  YMD = P_GIJUN_YMD
           AND HUIL_GB ='0'
           ) LOOP

      W_T36_PRD.DELETE;

      FOR F1 IN (
                SELECT SEOLJ_YMD, FROM_YMD
                  , CASE WHEN A.FUND_TYPE_GB = 'I'                                        -- ★① TDO101N2 재조회 제거: 인라인뷰 FROM_YMD 재사용
                          THEN DECODE(F_HUIL_GB(A.FROM_YMD), 1, FIMS.F_AF_YONG_YMD(A.FROM_YMD), A.FROM_YMD)
                          ELSE A.UY_YMD
                    END AS UY_YMD
                  , END_YMD, PRD_CD, PRVD_CD
                  , RISK_GB , FUND_CD, FUND_NM, FUND_TYPE_GB, FUND_WT
                  , FST_SEOLJ_YN, Nvl(RBC_YMD, '99999999') AS RBC_YMD
              FROM (
                    SELECT Nvl(A.SEOLJ_YMD, A.APRV_YMD) AS SEOLJ_YMD
                        , CASE WHEN A.FUND_TYPE_GB = 'F' AND A.FROM_YMD < FIMS.F_BF_YONG_YMD(A.FUND_SEOLJ_YMD) THEN A.FUND_SEOLJ_YMD
                                WHEN A.FUND_TYPE_GB = 'I' THEN (SELECT MIN(GIJUN_YMD) FROM TDO101N2 WHERE FUND_CD = A.FUND_CD AND GIJUN_YMD >= A.FROM_YMD)
                                ELSE A.FROM_YMD END AS FROM_YMD
                        , CASE WHEN A.FUND_TYPE_GB = 'F' AND A.FROM_YMD <  A.FUND_SEOLJ_YMD THEN A.FUND_SEOLJ_YMD
                                WHEN A.FUND_TYPE_GB = 'F' AND A.FROM_YMD >= A.FUND_SEOLJ_YMD THEN A.FROM_YMD
                                WHEN A.FUND_TYPE_GB = 'I' THEN CAST(NULL AS VARCHAR2(8))  -- ★① 외곽에서 FROM_YMD 기반으로 휴일보정
                                WHEN A.FUND_TYPE_GB IN ('A','B','C')                       -- 설정 시점의 이율로 고정하여 가져오는 관계로 해당 TYPE만
                                    AND NOT EXISTS (SELECT 1 FROM TDO001R R                -- 직전 이력 FROM_YMD 이후 ~ 현 FROM_YMD 사이에 승인(리밸런싱)이 없으면
                                                      WHERE R.PRD_CD    = A.PRD_CD          --  (FROM_YMD 는 자료 미입수 등으로 APRV_YMD 보다 늦을 수 있음)
                                                        AND R.APRV_YMD <= A.FROM_YMD
                                                        AND R.APRV_YMD >  NVL((SELECT MAX(P.FROM_YMD)
                                                                                 FROM TDO001 P
                                                                                WHERE P.PRD_CD    = A.PRD_CD
                                                                                  AND P.SEOLJ_YMD = A.SEOLJ_YMD
                                                                                  AND NVL(P.PYUNGA_GB,'Y') = 'Y'
                                                                                  AND NVL(P.HAEJI_YMD,'99999999') >= D1.YMD
                                                                                  AND P.FROM_YMD  < A.FROM_YMD), '00000000')) THEN
                                    NVL( (SELECT MAX(P.FROM_YMD)
                                            FROM TDO001 P
                                            WHERE P.PRD_CD    = A.PRD_CD
                                              AND P.SEOLJ_YMD = A.SEOLJ_YMD               -- 동일 설정 스냅샷
                                              AND NVL(P.PYUNGA_GB,'Y') = 'Y'
                                              AND NVL(P.HAEJI_YMD,'99999999') >= D1.YMD
                                              AND P.FROM_YMD  < A.FROM_YMD),
                                          A.FROM_YMD )                                    -- 최초(직전 없음)면 현재 유지
                                ELSE A.FROM_YMD END AS UY_YMD
                        , A.END_YMD
                        , A.PRD_CD
                        , A.PRVD_CD
                        , A.RISK_GB
                        , A.FUND_CD
                        , A.FUND_NM
                        , A.FUND_TYPE_GB
                        , A.FUND_WT
                        , DECODE(RANK() OVER (PARTITION BY A.PRD_CD ORDER BY A.END_YMD), '1', 'Y', 'N') AS FST_SEOLJ_YN  -- 최초 설정 히스토리 여부
                        , NVL(DECODE(F_HUIL_GB(B.APRV_YMD), '0', B.APRV_YMD, FIMS.F_AF_YONG_YMD(B.APRV_YMD)), '99999999') AS RBC_YMD
                      FROM TDO001 A
                      LEFT OUTER JOIN (SELECT PRD_CD, MAX(APRV_YMD) AS APRV_YMD          -- PRD_CD당 1행으로 집계(팬아웃 제거)
                                        FROM TDO001R
                                        WHERE APRV_YMD BETWEEN WA_BF_YMD AND D1.YMD
                                        GROUP BY PRD_CD) B
                        ON A.PRD_CD = B.PRD_CD
                    WHERE A.SEOLJ_YMD = (SELECT MAX(SEOLJ_YMD) FROM TDO001 WHERE PRD_CD = A.PRD_CD AND SEOLJ_YMD <= D1.YMD)
                      AND Nvl(A.PYUNGA_GB, 'Y') = 'Y'
                      AND Nvl(A.HAEJI_YMD, '99999999') >= D1.YMD
                      AND A.PRD_CD LIKE P_PRD_CD
                    ) A
              WHERE A.END_YMD = (SELECT /*+ INDEX(TDO001 TDO001_SK) */ MIN(END_YMD) FROM TDO001 WHERE PRD_CD= A.PRD_CD AND END_YMD >= D1.YMD)
      ) LOOP
        W_CUR_PRD_CD  := F1.PRD_CD;
        W_CUR_FUND_CD := F1.FUND_CD;

        /* 모든 분기가 동일 키를 재생성하므로 1회만 삭제 */
        DELETE  TDO201
         WHERE GIJUN_YMD = D1.YMD
           AND PRD_CD = F1.PRD_CD
           AND PRVD_CD = F1.PRVD_CD
           AND RISK_GB = F1.RISK_GB
           AND FUND_CD = F1.FUND_CD;

        /* 예금 */
        IF F1.FUND_TYPE_GB IN ('A', 'B', 'C')  THEN

            -- 펀드별 변수 초기화 (이전 루프 값 잔존 방지)
            W_PRD_GB       := NULL;
            W_FIX_MAT_RT   := NULL;
            W_DAILY_RT     := 1;
            W_T36_JY_YMD   := NULL;
            W_T36_GB       := 'N';
            W_RATE_YMD     := F1.UY_YMD;
            W_CYC_FROM_YMD := F1.UY_YMD;

            /* 3년 만기 주기 추적 : UY_YMD → 만기일 → 만기 익영업일(새 주기 시작) → 만기일 ...
               D1 이전에 도래한 가장 최근 만기의 익영업일을 이율 기준일로 사용 */
            FOR N IN 1 .. 30 LOOP
                EXIT WHEN W_CYC_FROM_YMD IS NULL;

                SELECT MIN(Decode(F_HUIL_GB(FUND_TO_YMD), 1, FIMS.F_AF_YONG_YMD(FUND_TO_YMD), FUND_TO_YMD))
                  INTO W_MAT_YMD
                  FROM NNN.TSS003
                 WHERE FUND_FROM_YMD = W_CYC_FROM_YMD
                   AND GUBUN     = 'T'
                   AND TERM      = '36';

                EXIT WHEN W_MAT_YMD IS NULL OR W_MAT_YMD > D1.YMD;

                IF W_MAT_YMD = D1.YMD THEN          -- 오늘이 만기일 (이자는 익영업일부터 신규 적용)
                    W_T36_GB := 'Y';
                    EXIT;
                END IF;

                W_T36_JY_YMD   := FIMS.F_AF_YONG_YMD(W_MAT_YMD);   -- 만기 익영업일 (<= D1)
                W_RATE_YMD     := W_T36_JY_YMD;
                W_CYC_FROM_YMD := W_T36_JY_YMD;                    -- 새 주기 시작일 = 만기 익영업일
            END LOOP;

            BEGIN
              SELECT TOT_PYUNGA_AEK, SEOLJ_AEK
                INTO W_BF_PYUNGA_AEK, W_SEOLJ_AEK
                FROM TDO201
                WHERE GIJUN_YMD = WA_BF_YMD
                     AND PRD_CD = F1.PRD_CD
                     AND RISK_GB = F1.RISK_GB
                     AND PRVD_CD = F1.PRVD_CD
                     AND FUND_CD = F1.FUND_CD;
            EXCEPTION WHEN  NO_DATA_FOUND  THEN
                W_BF_PYUNGA_AEK := 0;
                W_SEOLJ_AEK := 0;
            END;

            -- 이자 일수는 항상 전영업일 익일 ~ 당일 (휴일 포함). 운용개시일 당일만 당일 1일
            W_DAY_FROM_YMD := CASE WHEN D1.YMD = F1.UY_YMD THEN NNN.F_BF_YONG_YMD(F1.UY_YMD) ELSE WA_BF_YMD END;

            BEGIN
            SELECT PRD_GB, SUM(DAILY_RT)+1, Decode(Max(Nvl(FIX_MAT_RT, 0)), 0, Max(LNK_RT), Max(FIX_MAT_RT))
              INTO W_PRD_GB, W_DAILY_RT, W_FIX_MAT_RT
              FROM (
                    SELECT B.FUND_CD, B.PRD_GB
                        , CASE WHEN PRD_GB IN ('A','B','E') THEN (DAILY_RT-1) * COUNT(*) /* 단리 */
                                ELSE POWER(DAILY_RT, COUNT(*))-1 END AS DAILY_RT /* 복리 */
                        , Max(FIX_MAT_RT) FIX_MAT_RT
                        , Max(LNK_RT) LNK_RT
                    FROM TSS002 A, TDO101N1 B
                    WHERE A.YMD >  W_DAY_FROM_YMD
                    AND  A.YMD <= D1.YMD
                    AND  B.FUND_CD = F1.FUND_CD
                    AND  B.USE_YN = 'Y'
                    AND  B.GIJUN_YM = Nvl((SELECT MAX(GIJUN_YM) FROM TDO101N1 WHERE FUND_CD = F1.FUND_CD AND GIJUN_YM <= W_RATE_YMD AND USE_YN ='Y' AND (NVL(FIX_MAT_RT, 0) > 0 OR NVL(LNK_RT, 0) > 0)), (SELECT MIN(GIJUN_YM) FROM TDO101N1 WHERE FUND_CD= F1.FUND_CD AND USE_YN ='Y' AND (NVL(FIX_MAT_RT, 0) > 0 OR NVL(LNK_RT, 0) > 0)))
                    GROUP BY FUND_CD, DAILY_RT, PRD_GB
                    )
            GROUP BY FUND_CD, PRD_GB;
            EXCEPTION WHEN  NO_DATA_FOUND  THEN
                W_PRD_GB     := NULL;
                W_DAILY_RT   := 1;        -- 이율 미존재 시 평가액 유지 (0 이면 평가액이 0 이 됨)
                W_FIX_MAT_RT := NULL;
            END;

            IF W_T36_JY_YMD = D1.YMD THEN
                W_SEOLJ_AEK := W_BF_PYUNGA_AEK;  -- 3년 만기 익영업일 : 전일 평가액을 설정액으로 재설정
            END IF;

            IF W_PRD_GB IN ('A','B','E') THEN
                W_PYUNGA_AEK := W_SEOLJ_AEK * (W_DAILY_RT-1) + W_BF_PYUNGA_AEK;   /* 단리 */
            ELSE
                W_PYUNGA_AEK := W_BF_PYUNGA_AEK * W_DAILY_RT;                       /* 복리 */
            END IF;

                IF F1.UY_YMD = D1.YMD AND F1.FST_SEOLJ_YN = 'Y' THEN  -- 최초 운용 개시일 (운용지시일 익영업일)

                    INSERT INTO TDO201 (
                        GIJUN_YMD
                      , RISK_GB
                      , PRVD_CD
                      , PRD_CD
                      , FUND_CD
                      , SILH_SUIK_RT
                      , FUND_WT
                      , TOT_PYUNGA_AEK
                      , SILJ_PYUNGA_AEK
                      , NON_PYUNGA_AEK
                      , YESU_AEK
                      , ADJ_PYUNGA_AEK
                      , SEOLJ_AEK
                      , IL_BOSU
                      , NUJ_BOSU
                      , IP_USER, IP_DATE)
                     VALUES (
                        D1.YMD
                      , F1.RISK_GB
                      , F1.PRVD_CD
                      , F1.PRD_CD
                      , F1.FUND_CD
                      , 1
                      , F1.FUND_WT
                      , XCON_GIJUN_AMT * F1.FUND_WT
                      , XCON_GIJUN_AMT * F1.FUND_WT
                      , 0
                      , 0
                      , 0
                      , XCON_GIJUN_AMT * F1.FUND_WT
                      , 0
                      , 0
                      , P_IP_USER, SYSDATE
                    );

                ELSIF F1.RBC_YMD = D1.YMD THEN  -- 리밸런싱 매도 적용일 (3년 만기와 겹치면 리밸런싱 우선)

                    INSERT INTO TDO201 (
                        GIJUN_YMD
                      , RISK_GB
                      , PRVD_CD
                      , PRD_CD
                      , FUND_CD
                      , SILH_SUIK_RT
                      , FUND_WT
                      , TOT_PYUNGA_AEK
                      , SILJ_PYUNGA_AEK
                      , NON_PYUNGA_AEK
                      , YESU_AEK
                      , ADJ_PYUNGA_AEK
                      , SEOLJ_AEK
                      , IL_BOSU
                      , NUJ_BOSU
                      , IP_USER, IP_DATE)
                    SELECT D1.YMD
                         , F1.RISK_GB
                         , F1.PRVD_CD
                         , F1.PRD_CD
                         , F1.FUND_CD
                         , 1 SILH_SUIK_RT
                         , F1.FUND_WT
                         , A.TOT_PYUNGA_AEK * F1.FUND_WT AS TOT_PYUNGA_AEK
                         , A.TOT_PYUNGA_AEK * F1.FUND_WT AS SILJ_PYUNGA_AEK
                         , 0 AS NON_PYUNGA_AEK
                         , 0 AS YESU_AEK
                         , 0 AS ADJ_PYUNGA_AEK
                         , A.TOT_PYUNGA_AEK * F1.FUND_WT
                         , 0 AS IL_BOSU
                         , 0 AS NUJ_BOSU
                         , P_IP_USER, SYSDATE
                    FROM TDO201 A
                   WHERE GIJUN_YMD = WA_BF_YMD
                     AND PRD_CD = F1.PRD_CD
                     AND PRVD_CD = F1.PRVD_CD
                     AND RISK_GB = F1.RISK_GB
                     AND FUND_CD = '000'
                    ;

                ELSIF W_T36_JY_YMD = D1.YMD THEN  -- 3년 만기 금리 적용일 (만기 익영업일) : 설정액 재산출

                    INSERT INTO TDO201 (
                        GIJUN_YMD
                      , RISK_GB
                      , PRVD_CD
                      , PRD_CD
                      , FUND_CD
                      , SILH_SUIK_RT
                      , FUND_WT
                      , TOT_PYUNGA_AEK
                      , SILJ_PYUNGA_AEK
                      , NON_PYUNGA_AEK
                      , YESU_AEK
                      , ADJ_PYUNGA_AEK
                      , SEOLJ_AEK
                      , IL_BOSU
                      , NUJ_BOSU
                      , IP_USER, IP_DATE)
                    SELECT D1.YMD
                         , F1.RISK_GB
                         , F1.PRVD_CD
                         , F1.PRD_CD
                         , F1.FUND_CD
                         , W_DAILY_RT SILH_SUIK_RT
                         , F1.FUND_WT
                         , W_PYUNGA_AEK AS TOT_PYUNGA_AEK
                         , W_PYUNGA_AEK AS SILJ_PYUNGA_AEK
                         , 0 AS NON_PYUNGA_AEK
                         , 0 AS YESU_AEK
                         , 0 AS ADJ_PYUNGA_AEK
                         , A.TOT_PYUNGA_AEK
                         , 0 AS IL_BOSU
                         , 0 AS NUJ_BOSU
                         , P_IP_USER, SYSDATE
                    FROM TDO201 A
                   WHERE GIJUN_YMD = WA_BF_YMD
                     AND PRD_CD = F1.PRD_CD
                     AND PRVD_CD = F1.PRVD_CD
                     AND RISK_GB = F1.RISK_GB
                     AND FUND_CD = F1.FUND_CD
                    ;

                    IF SQL%ROWCOUNT > 0 THEN
                        W_T36_PRD(F1.PRD_CD) := 'Y';   -- 000 설정액 재산출 대상
                    END IF;

                    UPDATE TDO001 A  -- 기본정보 REM 3년 만기 (재처리 시 최신값으로 갱신, 멱등)
                      SET REM = TRIM(
                                  REGEXP_REPLACE(
                                      NVL(A.REM, ' '),
                                      ' 3년 만기\(' || D1.YMD || '\)[^/]*/',   -- 같은 날짜 기존 문구 제거
                                      ''
                                  )
                                ) || ' 3년 만기(' || D1.YMD || ') : '
                                  || RTRIM(TO_CHAR(W_FIX_MAT_RT, 'FM99999990.999999999999'), '.') || '% /'
                    WHERE A.PRD_CD  = F1.PRD_CD
                      AND A.FUND_CD = F1.FUND_CD
                      AND A.END_YMD = (SELECT /*+ INDEX(TDO001 TDO001_SK) */ MIN(END_YMD)
                                          FROM TDO001 WHERE PRD_CD = A.PRD_CD AND END_YMD >= D1.YMD);

                ELSE

                    INSERT INTO TDO201 (
                        GIJUN_YMD
                        , RISK_GB
                        , PRVD_CD
                        , PRD_CD
                        , FUND_CD
                        , SILH_SUIK_RT
                        , FUND_WT
                        , TOT_PYUNGA_AEK
                        , SILJ_PYUNGA_AEK
                        , NON_PYUNGA_AEK
                        , YESU_AEK
                        , ADJ_PYUNGA_AEK
                        , SEOLJ_AEK
                        , DEPOSIT_3Y
                        , IL_BOSU
                        , NUJ_BOSU
                        , IP_USER, IP_DATE
                        )
                    SELECT D1.YMD
                         , F1.RISK_GB
                         , F1.PRVD_CD
                         , F1.PRD_CD
                         , F1.FUND_CD
                         , W_DAILY_RT AS DAILY_RT
                         , F1.FUND_WT
                         , W_PYUNGA_AEK AS TOT_PYUNGA_AEK
                         , W_PYUNGA_AEK AS SILJ_PYUNGA_AEK
                         , 0 AS NON_PYUNGA_AEK
                         , 0 AS YESU_AEK
                         , 0 AS ADJ_PYUNGA_AEK
                         , A.SEOLJ_AEK
                         , Decode(W_T36_GB, 'Y', W_T36_GB, NULL) DEPOSIT_3Y   -- 3년 만기일 표시
                         , 0 AS IL_BOSU
                         , 0 AS NUJ_BOSU
                         , P_IP_USER, SYSDATE
                    FROM TDO201 A
                   WHERE GIJUN_YMD = WA_BF_YMD
                     AND PRD_CD = F1.PRD_CD
                     AND RISK_GB = F1.RISK_GB
                     AND PRVD_CD = F1.PRVD_CD
                     AND FUND_CD = F1.FUND_CD
                    ;
                END IF;

        /* 보험펀드 */
        ELSIF F1.FUND_TYPE_GB = 'I'  THEN

            /* 보험펀드가 영업일에 수집되지 않는 경우가 있어 보완
               - 당일 기준가가 없으면 직전 기준가를 이월하고 수익률 1
               - 수익률 분모는 전일 TDO201 에 이월된 기준가를 사용하여 미수집 구간 수익률이 누락되지 않도록 함 */
            SELECT MAX(GIJUN_GA)
              INTO W_GA_TODAY
              FROM TDO101N2
             WHERE FUND_CD = F1.FUND_CD
               AND GIJUN_YMD = D1.YMD;

            BEGIN
                SELECT GIJUN_GA
                  INTO W_GA_PREV
                  FROM TDO201
                 WHERE GIJUN_YMD = WA_BF_YMD
                   AND PRD_CD = F1.PRD_CD
                   AND RISK_GB = F1.RISK_GB
                   AND PRVD_CD = F1.PRVD_CD
                   AND FUND_CD = F1.FUND_CD;
            EXCEPTION WHEN NO_DATA_FOUND THEN
                W_GA_PREV := NULL;
            END;

            IF W_GA_PREV IS NULL THEN
                SELECT MAX(GIJUN_GA) KEEP (DENSE_RANK LAST ORDER BY GIJUN_YMD)
                  INTO W_GA_PREV
                  FROM TDO101N2
                 WHERE FUND_CD = F1.FUND_CD
                   AND GIJUN_YMD < D1.YMD;
            END IF;

            W_GA_CUR := NVL(W_GA_TODAY, W_GA_PREV);
            W_I_RT   := CASE WHEN W_GA_TODAY IS NOT NULL AND W_GA_PREV > 0 THEN W_GA_TODAY / W_GA_PREV ELSE 1 END;

                IF D1.YMD < F1.UY_YMD AND F1.FST_SEOLJ_YN ='Y' THEN  -- 최초 운용 개시 이전

                    INSERT INTO TDO201 (
                        GIJUN_YMD
                      , RISK_GB
                      , PRVD_CD
                      , PRD_CD
                      , FUND_CD
                      , GIJUN_GA
                      , SILH_SUIK_RT
                      , FUND_WT
                      , TOT_PYUNGA_AEK
                      , SILJ_PYUNGA_AEK
                      , NON_PYUNGA_AEK
                      , YESU_AEK
                      , ADJ_PYUNGA_AEK
                      , SEOLJ_AEK
                      , IL_BOSU
                      , NUJ_BOSU
                      , IP_USER, IP_DATE
                      )
                     VALUES (
                        D1.YMD
                      , F1.RISK_GB
                      , F1.PRVD_CD
                      , F1.PRD_CD
                      , F1.FUND_CD
                      , W_GA_CUR
                      , 1
                      , F1.FUND_WT
                      , XCON_GIJUN_AMT * F1.FUND_WT
                      , 0
                      , 0
                      , XCON_GIJUN_AMT * F1.FUND_WT
                      , 0
                      , XCON_GIJUN_AMT * F1.FUND_WT
                      , 0
                      , 0
                      , P_IP_USER, SYSDATE
                    );
                ELSIF  D1.YMD = F1.UY_YMD AND F1.FST_SEOLJ_YN ='Y' THEN  -- 최초 운용 개시일

                    INSERT INTO TDO201 (
                        GIJUN_YMD
                      , RISK_GB
                      , PRVD_CD
                      , PRD_CD
                      , FUND_CD
                      , GIJUN_GA
                      , SILH_SUIK_RT
                      , FUND_WT
                      , TOT_PYUNGA_AEK
                      , SILJ_PYUNGA_AEK
                      , NON_PYUNGA_AEK
                      , YESU_AEK
                      , ADJ_PYUNGA_AEK
                      , SEOLJ_AEK
                      , IL_BOSU
                      , NUJ_BOSU
                      , IP_USER, IP_DATE
                      )
                     VALUES (
                        D1.YMD
                      , F1.RISK_GB
                      , F1.PRVD_CD
                      , F1.PRD_CD
                      , F1.FUND_CD
                      , W_GA_CUR
                      , 1
                      , F1.FUND_WT
                      , XCON_GIJUN_AMT * F1.FUND_WT
                      , XCON_GIJUN_AMT * F1.FUND_WT
                      , 0
                      , 0
                      , 0
                      , XCON_GIJUN_AMT * F1.FUND_WT
                      , 0
                      , 0
                      , P_IP_USER, SYSDATE
                    );

                ELSIF F1.RBC_YMD = D1.YMD THEN -- 리밸런싱 적용시작일

                    INSERT INTO TDO201 (
                        GIJUN_YMD
                      , RISK_GB
                      , PRVD_CD
                      , PRD_CD
                      , FUND_CD
                      , GIJUN_GA
                      , SILH_SUIK_RT
                      , FUND_WT
                      , TOT_PYUNGA_AEK
                      , SILJ_PYUNGA_AEK
                      , NON_PYUNGA_AEK
                      , YESU_AEK
                      , ADJ_PYUNGA_AEK
                      , SEOLJ_AEK
                      , IL_BOSU
                      , NUJ_BOSU
                      , IP_USER, IP_DATE
                      )
                     SELECT D1.YMD
                      , F1.RISK_GB
                      , F1.PRVD_CD
                      , F1.PRD_CD
                      , F1.FUND_CD
                      , W_GA_CUR          -- 익일 수익률 분모로 사용
                      , 1
                      , F1.FUND_WT
                      , TOT_PYUNGA_AEK * F1.FUND_WT
                      , TOT_PYUNGA_AEK * F1.FUND_WT
                      , 0
                      , 0
                      , 0
                      , TOT_PYUNGA_AEK * F1.FUND_WT
                      , 0
                      , 0
                      , P_IP_USER, SYSDATE
                    FROM TDO201
                    WHERE GIJUN_YMD = WA_BF_YMD
                     AND PRD_CD = F1.PRD_CD
                     AND RISK_GB = F1.RISK_GB
                     AND PRVD_CD = F1.PRVD_CD
                     AND FUND_CD = '000'
                    ;

                ELSE

                    INSERT INTO TDO201 (
                        GIJUN_YMD
                      , RISK_GB
                      , PRVD_CD
                      , PRD_CD
                      , FUND_CD
                      , GIJUN_GA
                      , SUJ_GIJUN_GA
                      , SILH_SUIK_RT
                      , FUND_WT
                      , TOT_PYUNGA_AEK
                      , SILJ_PYUNGA_AEK
                      , NON_PYUNGA_AEK
                      , YESU_AEK
                      , ADJ_PYUNGA_AEK
                      , SEOLJ_AEK
                      , IL_BOSU
                      , NUJ_BOSU
                      , IP_USER, IP_DATE)
                    SELECT D1.YMD
                         , F1.RISK_GB
                         , F1.PRVD_CD
                         , F1.PRD_CD
                         , F1.FUND_CD
                         , W_GA_CUR
                         , NULL AS SUJ_GIJUN_GA
                         , W_I_RT
                         , F1.FUND_WT
                         , TOT_PYUNGA_AEK * W_I_RT AS TOT_PYUNGA_AEK
                         , SILJ_PYUNGA_AEK * W_I_RT AS SILJ_PYUNGA_AEK
                         , 0 AS NON_PYUNGA_AEK
                         , 0 AS YESU_AEK
                         , 0 AS ADJ_PYUNGA_AEK
                         , A.SEOLJ_AEK
                         , 0 AS IL_BOSU
                         , 0 AS NUJ_BOSU
                         , P_IP_USER, SYSDATE
                    FROM TDO201 A
                   WHERE GIJUN_YMD = WA_BF_YMD
                     AND PRD_CD = F1.PRD_CD
                     AND RISK_GB = F1.RISK_GB
                     AND PRVD_CD = F1.PRVD_CD
                     AND FUND_CD = F1.FUND_CD
                    ;
                END IF;

        ELSIF F1.FUND_TYPE_GB = 'F' THEN --펀드

                IF F1.UY_YMD > D1.YMD AND F1.FST_SEOLJ_YN = 'Y'  THEN  -- 운용시작일실제평가액편입 (설정이전)

                    INSERT INTO TDO201 (
                        GIJUN_YMD
                      , RISK_GB
                      , PRVD_CD
                      , PRD_CD
                      , FUND_CD
                      , GIJUN_GA
                      , SUJ_GIJUN_GA
                      , SILH_SUIK_RT
                      , FUND_WT
                      , TOT_PYUNGA_AEK
                      , SILJ_PYUNGA_AEK
                      , NON_PYUNGA_AEK
                      , YESU_AEK
                      , ADJ_PYUNGA_AEK
                      , SEOLJ_AEK
                      , IL_BOSU
                      , NUJ_BOSU
                      , IP_USER, IP_DATE)
                    SELECT D1.YMD
                      , F1.RISK_GB
                      , F1.PRVD_CD
                      , F1.PRD_CD
                      , F1.FUND_CD
                      , (SELECT FST_GIJUN_GA FROM TFN001 WHERE ZEROIN_TYPE_GB ='A2' AND END_YMD ='99999999' AND FUND_CD = F1.FUND_CD) AS GIJUN_GA
                      , (SELECT FST_GIJUN_GA FROM TFN001 WHERE ZEROIN_TYPE_GB ='A2' AND END_YMD ='99999999' AND FUND_CD = F1.FUND_CD) AS SUJ_GIJUN_GA
                      , NULL
                      , F1.FUND_WT
                      , XCON_GIJUN_AMT * F1.FUND_WT AS TOT_PYUNGA_AEK
                      , 0 AS SILH_PYUNGA_AEK
                      , 0 AS NON_PYUNGA_AEK
                      , XCON_GIJUN_AMT * F1.FUND_WT AS YESU_AEK
                      , 0 AS ADJ_PYUNGA_AEK
                      , XCON_GIJUN_AMT * F1.FUND_WT AS SEOLJ_AEK
                      , 0
                      , 0
                      , P_IP_USER, SYSDATE
                      FROM DUAL
                      ;

                ELSIF F1.UY_YMD = D1.YMD  AND F1.FST_SEOLJ_YN = 'Y'  THEN  -- 운용시작일실제평가액편입 (최초)
                                                                              -- 기준가 미입수 시에도 비평가액으로 편입 (누락 방지)
                    INSERT INTO TDO201 (
                        GIJUN_YMD
                      , RISK_GB
                      , PRVD_CD
                      , PRD_CD
                      , FUND_CD
                      , GIJUN_GA
                      , SUJ_GIJUN_GA
                      , SILH_SUIK_RT
                      , FUND_WT
                      , TOT_PYUNGA_AEK
                      , SILJ_PYUNGA_AEK
                      , NON_PYUNGA_AEK
                      , YESU_AEK
                      , ADJ_PYUNGA_AEK
                      , SEOLJ_AEK
                      , IL_BOSU
                      , NUJ_BOSU
                      , IP_USER, IP_DATE)
                    SELECT D1.YMD
                      , F1.RISK_GB
                      , F1.PRVD_CD
                      , F1.PRD_CD
                      , F1.FUND_CD
                      , A.GIJUN_GA
                      , A.SUIK_JISU * (SELECT FST_GIJUN_GA FROM TFN001 WHERE ZEROIN_TYPE_GB ='A2' AND END_YMD ='99999999' AND FUND_CD = F1.FUND_CD) AS SUJ_GIJUN_GA
                      , A.SILH_SUIK_RT
                      , F1.FUND_WT
                      , XCON_GIJUN_AMT * F1.FUND_WT AS TOT_PYUNGA_AEK
                      , CASE WHEN A.GIJUN_GA IS NULL THEN 0 ELSE XCON_GIJUN_AMT * F1.FUND_WT END AS SILJ_PYUNGA_AEK
                      , CASE WHEN A.GIJUN_GA IS NULL THEN XCON_GIJUN_AMT * F1.FUND_WT ELSE 0 END AS NON_PYUNGA_AEK
                      , 0 AS YESU_AEK
                      , 0 AS ADJ_PYUNGA_AEK
                      , XCON_GIJUN_AMT * F1.FUND_WT AS SEOLJ_AEK
                      , 0
                      , 0
                      , P_IP_USER, SYSDATE
                      FROM DUAL
                      LEFT OUTER JOIN TFN201 A
                        ON A.ZEROIN_TYPE_GB = 'A2'
                       AND A.GIJUN_YMD = D1.YMD
                       AND A.FUND_CD = F1.FUND_CD;

                ELSIF D1.YMD = F1.RBC_YMD THEN  --  최초 적용일 (리밸런싱) : 기준가 미입수 시 비평가액으로 산입

                    INSERT INTO TDO201 (
                        GIJUN_YMD
                      , RISK_GB
                      , PRVD_CD
                      , PRD_CD
                      , FUND_CD
                      , GIJUN_GA
                      , SUJ_GIJUN_GA
                      , SILH_SUIK_RT
                      , FUND_WT
                      , TOT_PYUNGA_AEK
                      , SILJ_PYUNGA_AEK
                      , NON_PYUNGA_AEK
                      , YESU_AEK
                      , ADJ_PYUNGA_AEK
                      , SEOLJ_AEK
                      , IL_BOSU
                      , NUJ_BOSU
                      , IP_USER, IP_DATE)
                    SELECT D1.YMD
                      , F1.RISK_GB
                      , F1.PRVD_CD
                      , F1.PRD_CD
                      , F1.FUND_CD
                      , A.GIJUN_GA
                      , A.SUIK_JISU * (SELECT FST_GIJUN_GA FROM TFN001 WHERE ZEROIN_TYPE_GB ='A2' AND END_YMD ='99999999' AND FUND_CD = F1.FUND_CD) AS SUJ_GIJUN_GA
                      , A.SILH_SUIK_RT
                      , F1.FUND_WT
                      , B.TOT_PYUNGA_AEK * F1.FUND_WT  AS TOT_PYUNGA_AEK
                      , CASE WHEN A.GIJUN_GA IS NULL THEN 0 ELSE B.TOT_PYUNGA_AEK * F1.FUND_WT END AS SILJ_PYUNGA_AEK
                      , CASE WHEN A.GIJUN_GA IS NULL THEN B.TOT_PYUNGA_AEK * F1.FUND_WT ELSE 0 END AS NON_PYUNGA_AEK
                      , 0 AS YESU_AEK
                      , 0 AS ADJ_PYUNGA_AEK
                      , B.TOT_PYUNGA_AEK * F1.FUND_WT AS SEOLJ_AEK
                      , 0
                      , 0
                      , P_IP_USER, SYSDATE
                      FROM TDO201 B
                      LEFT OUTER JOIN TFN201 A
                        ON A.ZEROIN_TYPE_GB = 'A2'
                       AND A.GIJUN_YMD = D1.YMD
                       AND A.FUND_CD = F1.FUND_CD
                    WHERE B.PRD_CD = F1.PRD_CD
                      AND B.RISK_GB = F1.RISK_GB
                      AND B.PRVD_CD = F1.PRVD_CD
                      AND B.FUND_CD = '000'
                      AND B.GIJUN_YMD = WA_BF_YMD;       -- FROM_YMD 는 APRV_YMD 와 다를 수 있으므로 전영업일 기준

                ELSE  -- 일반 평가 (기존 '운용개시 익영업일' 분기와 동일 결과이므로 통합)

                    INSERT INTO TDO201 (
                        GIJUN_YMD
                      , RISK_GB
                      , PRVD_CD
                      , PRD_CD
                      , FUND_CD
                      , GIJUN_GA
                      , SUJ_GIJUN_GA
                      , SILH_SUIK_RT
                      , FUND_WT
                      , TOT_PYUNGA_AEK
                      , SILJ_PYUNGA_AEK
                      , NON_PYUNGA_AEK
                      , YESU_AEK
                      , ADJ_PYUNGA_AEK
                      , SEOLJ_AEK
                      , IL_BOSU
                      , NUJ_BOSU
                      , IP_USER, IP_DATE)
                 SELECT D1.YMD
                      , X.RISK_GB
                      , X.PRVD_CD
                      , X.PRD_CD
                      , F1.FUND_CD
                      , NVL(X.A_GIJUN_GA, X.B_GIJUN_GA)            -- 미입수 시 기준가 이월
                      , NVL(X.A_SUJ_GIJUN_GA, X.B_SUJ_GIJUN_GA)    -- 미입수 시 수정기준가 이월
                      , X.RT AS SILH_SUIK_RT
                      , F1.FUND_WT
                      , X.B_TOT * X.RT AS TOT_PYUNGA_AEK
                      , CASE WHEN X.A_GIJUN_GA IS NULL THEN 0 ELSE X.B_TOT * X.RT END AS SILJ_PYUNGA_AEK
                      , CASE WHEN X.A_GIJUN_GA IS NULL THEN X.B_TOT ELSE 0 END AS NON_PYUNGA_AEK
                      , 0 AS YESU_AEK
                      , 0 AS ADJ_PYUNGA_AEK
                      , X.B_SEOLJ
                      , 0 AS IL_BOSU
                      , 0 AS NUJ_BOSU
                      , P_IP_USER
                      , SYSDATE
                   FROM (
                         SELECT Y.*
                              , CASE WHEN Y.A_GIJUN_GA IS NULL THEN 1
                                     -- 전일이 미입수(이월)였다면 전일대비 수익률 대신 수정기준가 비율로 공백 구간 수익률 반영
                                     WHEN Y.B_NON_PYUNGA > 0 AND Y.B_SUJ_GIJUN_GA > 0 AND Y.A_SUJ_GIJUN_GA > 0
                                          THEN Y.A_SUJ_GIJUN_GA / Y.B_SUJ_GIJUN_GA
                                     ELSE NVL(Y.A_SILH_SUIK_RT, 1)
                                END AS RT
                           FROM (
                                 SELECT B.RISK_GB, B.PRVD_CD, B.PRD_CD
                                      , B.TOT_PYUNGA_AEK       AS B_TOT
                                      , B.SEOLJ_AEK            AS B_SEOLJ
                                      , NVL(B.NON_PYUNGA_AEK, 0) AS B_NON_PYUNGA
                                      , B.GIJUN_GA             AS B_GIJUN_GA
                                      , B.SUJ_GIJUN_GA         AS B_SUJ_GIJUN_GA
                                      , A.GIJUN_GA             AS A_GIJUN_GA
                                      , A.SILH_SUIK_RT         AS A_SILH_SUIK_RT
                                      , A.SUIK_JISU * (SELECT FST_GIJUN_GA FROM TFN001 WHERE ZEROIN_TYPE_GB ='A2' AND END_YMD ='99999999' AND FUND_CD = B.FUND_CD) AS A_SUJ_GIJUN_GA
                                   FROM TDO201 B
                                   LEFT OUTER JOIN TFN201 A
                                     ON A.FUND_CD = B.FUND_CD
                                    AND A.ZEROIN_TYPE_GB = 'A2'
                                    AND A.GIJUN_YMD = D1.YMD
                                  WHERE B.PRVD_CD = F1.PRVD_CD
                                    AND B.RISK_GB = F1.RISK_GB
                                    AND B.GIJUN_YMD = WA_BF_YMD
                                    AND B.PRD_CD = F1.PRD_CD
                                    AND B.FUND_CD = F1.FUND_CD
                                ) Y
                        ) X
                      ;

                END IF;
        END IF;
       END LOOP; -- F1

       /* 재처리 시 구성에서 빠진 개별자산의 기존 행 정리 (000 합산 오염 방지) */
       DELETE TDO201 T
        WHERE T.GIJUN_YMD = D1.YMD
          AND T.PRD_CD LIKE P_PRD_CD
          AND T.FUND_CD <> '000'
          AND NOT EXISTS (SELECT 1
                            FROM TDO001 A
                           WHERE A.PRD_CD  = T.PRD_CD
                             AND A.FUND_CD = T.FUND_CD
                             AND A.END_YMD = (SELECT MIN(END_YMD) FROM TDO001 WHERE PRD_CD = A.PRD_CD AND END_YMD >= D1.YMD));

--       -- 디폴트 상품 전체 그룹 수익률 생성 (000)
       FOR G1 IN (
                    WITH A_BASE AS (
                    SELECT A.PRD_CD
                            , A.RISK_GB
                            , A.PRVD_CD
                            , A.END_YMD
                            , A.FUND_TYPE_GB
                            , A.FUND_CD
                            , A.FUND_WT
                            , A.FUND_SEOLJ_YMD
                            , DECODE(RANK() OVER (PARTITION BY A.PRD_CD ORDER BY A.END_YMD), 1, 'Y', 'N') AS FST_SEOLJ_YN
                            , (SELECT MIN(YMD) FROM TSS002 WHERE YMD BETWEEN A.FROM_YMD AND FIMS.F_AF_YONG_YMD(A.FROM_YMD) AND HUIL_GB = '0') AS FROM_YMD
                            , CASE WHEN A.FUND_TYPE_GB = 'F' AND A.FROM_YMD < A.FUND_SEOLJ_YMD THEN
                                        A.FUND_SEOLJ_YMD
                                  WHEN A.FUND_TYPE_GB = 'F' AND A.FROM_YMD >= A.FUND_SEOLJ_YMD THEN
                                       A.FROM_YMD
                                  WHEN A.FUND_TYPE_GB = 'I' THEN (SELECT DECODE(F_HUIL_GB(DECODE(MIN(GIJUN_YMD), A.FROM_YMD , A.FROM_YMD, MIN(GIJUN_YMD))), 1, FIMS.F_AF_YONG_YMD(MIN(GIJUN_YMD)), MIN(GIJUN_YMD)) FROM TDO101N2 WHERE FUND_CD = A.FUND_CD AND GIJUN_YMD >= A.FROM_YMD)
                                  ELSE A.FROM_YMD
                              END AS UY_YMD
                            , (SELECT DECODE(F_HUIL_GB(MAX(APRV_YMD)), '0', MAX(APRV_YMD), FIMS.F_AF_YONG_YMD(MAX(APRV_YMD))) FROM TDO001R WHERE PRD_CD = A.PRD_CD AND APRV_YMD BETWEEN WA_BF_YMD AND D1.YMD GROUP BY PRD_CD) AS RBC_YMD -- 리밸런싱 여부
                        FROM TDO001 A
                        WHERE A.SEOLJ_YMD = (SELECT MAX(SEOLJ_YMD) FROM TDO001 WHERE PRD_CD = A.PRD_CD AND SEOLJ_YMD <= D1.YMD)
                          AND NVL(A.HAEJI_YMD,'99999999') >= D1.YMD
                          AND NVL(A.PYUNGA_GB,'Y') ='Y'
                          AND A.PRD_CD LIKE P_PRD_CD
                    )
                    , A_WT AS (
                        SELECT A.*
                            ,CASE WHEN A.UY_YMD <= D1.YMD THEN A.FUND_WT ELSE 0 END AS ADJ_FUND_WT   -- UY_YMD 반영된 실제 사용 비중
                        FROM A_BASE A
                    )
                    SELECT
                          MIN(FROM_YMD) AS FROM_YMD
                        , MIN(UY_YMD)   AS UY_YMD
                        , '000'         AS FUND_CD
                        , Max(RISK_GB) AS RISK_GB
                        , Max(PRVD_CD) AS PRVD_CD
                        , PRD_CD
                        , NVL(MAX(RBC_YMD), '99999999') AS RBC_YMD
                        , MAX(FST_SEOLJ_YN) AS FST_SEOLJ_YN
--                        , SUM(ADJ_FUND_WT)  AS FUND_WT   -- ★★ 기준일에 유효한 비중만 합산
                        , CASE WHEN MAX(FST_SEOLJ_YN) = 'Y'
                              THEN XCON_GIJUN_AMT
                              ELSE (SELECT SEOLJ_AEK FROM TDO201 WHERE PRD_CD = A.PRD_CD AND GIJUN_YMD = WA_BF_YMD AND FUND_CD = '000')
                          END AS SEOLJ_AEK
                        , CASE WHEN SUM(ADJ_FUND_WT) < 1 AND MAX(FST_SEOLJ_YN) ='Y'
                              THEN (1-SUM(ADJ_FUND_WT)) * XCON_GIJUN_AMT
                              WHEN SUM(ADJ_FUND_WT) < 1
                              THEN (1-SUM(ADJ_FUND_WT)) * (SELECT SEOLJ_AEK FROM TDO201 WHERE PRD_CD = A.PRD_CD AND GIJUN_YMD = WA_BF_YMD AND FUND_CD = '000')
                              ELSE 0
                          END AS YESU_AEK
                    FROM A_WT A
                    WHERE A.END_YMD = (SELECT MIN(END_YMD)FROM TDO001 WHERE PRD_CD = A.PRD_CD AND END_YMD >= D1.YMD)
                    GROUP BY PRD_CD
                  ) LOOP
          W_CUR_PRD_CD  := G1.PRD_CD;
          W_CUR_FUND_CD := G1.FUND_CD;

          DELETE  TDO201
            WHERE GIJUN_YMD = D1.YMD
              AND PRD_CD = G1.PRD_CD
              AND RISK_GB = G1.RISK_GB
              AND PRVD_CD = G1.PRVD_CD
              AND FUND_CD = G1.FUND_CD
              ;

          IF  D1.YMD = G1.FROM_YMD AND G1.FST_SEOLJ_YN = 'Y'  THEN --최초 운용지시

              INSERT INTO TDO201 (
                  GIJUN_YMD
                , RISK_GB
                , PRVD_CD
                , PRD_CD
                , FUND_CD
                , SILH_SUIK_RT
                , SUIK_JISU
                , FUND_WT
                , TOT_PYUNGA_AEK
                , SILJ_PYUNGA_AEK
                , NON_PYUNGA_AEK
                , YESU_AEK
                , ADJ_PYUNGA_AEK
                , SEOLJ_AEK
                , IL_BOSU
                , NUJ_BOSU
                , IP_USER, IP_DATE)
              SELECT D1.YMD AS GIJUN_YMD
                , G1.RISK_GB
                , G1.PRVD_CD
                , G1.PRD_CD
                , G1.FUND_CD AS FUND_CD
                , 1 AS SILH_SUIK_RT
                , 1 AS SUIK_JISU
                , 1 AS FUND_WT
                , G1.SEOLJ_AEK AS TOT_PYUNGA_AEK
                , G1.SEOLJ_AEK - G1.YESU_AEK AS SILJ_PYUNGA_AEK
                , 0 AS NON_PYUNGA_AEK
                , G1.YESU_AEK AS YESU_AEK
                , 0 AS ADJ_PYUNGA_AEK
                , G1.SEOLJ_AEK AS SEOLJ_AEK
                , 0 AS IL_BOSU
                , 0 AS NUJ_BOSU
                , P_IP_USER AS IP_USER
                , SYSDATE
                FROM DUAL
            ;

          ELSE
              BEGIN
                  SELECT TOT_PYUNGA_AEK, SEOLJ_AEK, SUIK_JISU
                    INTO W_P_TOT_AEK, W_P_SEOLJ_AEK, W_P_SUIK_JISU
                    FROM TDO201
                   WHERE GIJUN_YMD = WA_BF_YMD
                     AND PRD_CD = G1.PRD_CD
                     AND FUND_CD = G1.FUND_CD;
              EXCEPTION WHEN NO_DATA_FOUND THEN
                  W_P_TOT_AEK   := NULL;
                  W_P_SEOLJ_AEK := NULL;
                  W_P_SUIK_JISU := NULL;
              END;

              /* 000 설정액
                 R : 리밸런싱 시작  - 재배분된 개별자산 설정액 합계
                 T : 예금 3년 만기 이자 적용일 - 리밸런싱과 동일하게 전일 평가액으로 재설정
                 N : 그 외         - 전일 설정액 이월 (재설정값 유지) */
              W_000_SEOLJ_GB := CASE WHEN D1.YMD = G1.RBC_YMD          THEN 'R'
                                     WHEN W_T36_PRD.EXISTS(G1.PRD_CD)  THEN 'T'
                                     ELSE 'N' END;

              INSERT INTO TDO201 (
                  GIJUN_YMD
                , RISK_GB
                , PRVD_CD
                , PRD_CD
                , FUND_CD
                , SILH_SUIK_RT
                , SUIK_JISU
                , FUND_WT
                , TOT_PYUNGA_AEK
                , SILJ_PYUNGA_AEK
                , NON_PYUNGA_AEK
                , YESU_AEK
                , ADJ_PYUNGA_AEK
                , SEOLJ_AEK
                , IL_BOSU
                , NUJ_BOSU
                , IP_USER, IP_DATE)
         SELECT D1.YMD GIJUN_YMD
                , G1.RISK_GB AS RISK_GB
                , G1.PRVD_CD AS PRVD_CD
                , PRD_CD
                , G1.FUND_CD AS FUND_CD
                , ( SUM(SILJ_PYUNGA_AEK)
                  + SUM(NON_PYUNGA_AEK)
                  + Sum(YESU_AEK) ) / NULLIF(W_P_TOT_AEK, 0) AS SILH_SUIK_RT
                , ( SUM(SILJ_PYUNGA_AEK)
                  + SUM(NON_PYUNGA_AEK)
                  + Sum(YESU_AEK) ) / NULLIF(W_P_TOT_AEK, 0) * W_P_SUIK_JISU AS SUIK_JISU
                , SUM(FUND_WT) AS FUND_WT
                , ( SUM(SILJ_PYUNGA_AEK)
                  + SUM(NON_PYUNGA_AEK)
                  + Sum(YESU_AEK)) AS TOT_PYUNGA_AEK
                , SUM(SILJ_PYUNGA_AEK) AS SILJ_PYUNGA_AEK
                , SUM(NON_PYUNGA_AEK) AS NON_PYUNGA_AEK
                , Sum(YESU_AEK) AS YESU_AEK
                , SUM(ADJ_PYUNGA_AEK) AS ADJ_PYUNGA_AEK
                , CASE W_000_SEOLJ_GB
                       WHEN 'R' THEN SUM(SEOLJ_AEK)
                       WHEN 'T' THEN NVL(W_P_TOT_AEK, SUM(SEOLJ_AEK))
                       ELSE          NVL(W_P_SEOLJ_AEK, SUM(SEOLJ_AEK))
                  END AS SEOLJ_AEK
                , SUM(IL_BOSU) AS IL_BOSU
                , SUM(NUJ_BOSU) AS NUJ_BOSU
                , P_IP_USER AS IP_USER
                , SYSDATE
                FROM  TDO201
              WHERE  GIJUN_YMD = D1.YMD
                AND  PRD_CD = G1.PRD_CD
                AND RISK_GB = G1.RISK_GB
                AND PRVD_CD = G1.PRVD_CD
                AND  FUND_CD <> G1.FUND_CD
            GROUP BY  PRD_CD
            ;
          END IF;
       END LOOP;

       BEGIN -- 분산값 산출 (산식 검토 보류)
          MERGE INTO TDO201 M
          USING (
                  WITH BASE_DATA AS (
                  -- 기본 데이터 및 SUJ_NAV 계산
                  SELECT
                      PRD_CD,
                      SILH_SUIK_RT,
                      CASE WHEN NVL(SILH_SUIK_RT, 0) = 0 THEN 0
                          ELSE CEIL(TOT_PYUNGA_AEK / SILH_SUIK_RT)
                      END AS SUJ_NAV
                  FROM TDO201
                  WHERE FUND_CD = '000'
                  AND GIJUN_YMD = D1.YMD
              ),
              AVG_CALC AS (
                  -- 1. 전체 가중평균수익률(AVG_SUIK_RT) 산출
                  SELECT
                      A.*,
                      (SUM((NVL(SILH_SUIK_RT, 1) - 1) * NVL(SUJ_NAV, 0)) OVER()
                      / NULLIF(SUM(NVL(SUJ_NAV, 0)) OVER(), 0)) + 1 AS AVG_SUIK_RT
                  FROM BASE_DATA A
              )
              SELECT
                  PRD_CD,
                  SUJ_NAV,
                  SILH_SUIK_RT,
                  -- 1. 가중평균수익률 (모든 행 동일)
                  AVG_SUIK_RT,
                  -- 2. 개별 상품의 편차 제곱 가중치 (BUNJA)
                  (SUJ_NAV * POWER(SILH_SUIK_RT - AVG_SUIK_RT, 2)) AS PRD_BUNJA,
                  -- 3. 해당 상품의 비중 대비 편차 (BUNJA / SUJ_NAV)
                  CASE WHEN NVL(SUJ_NAV, 0) = 0 THEN 0
                      ELSE (SUJ_NAV * POWER(SILH_SUIK_RT - AVG_SUIK_RT, 2)) / SUJ_NAV
                  END AS BUNSN
              FROM AVG_CALC
              ORDER BY PRD_CD
              ) U
          ON (M.PRD_CD = U.PRD_CD AND M.FUND_CD = '000' AND M.GIJUN_YMD = D1.YMD)
          WHEN MATCHED THEN UPDATE
               SET M.BUNSN = U.BUNSN;
       END;
    END LOOP; -- D1

    COMMIT;   -- 기준일 단위 단일 트랜잭션

    P_MSG := 'Y';

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        P_MSG := SUBSTR('N - [' || P_GIJUN_YMD || ' / ' || W_CUR_PRD_CD || ' / ' || W_CUR_FUND_CD || '] '
                        || SQLERRM || ' ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 1000);
END;
/
