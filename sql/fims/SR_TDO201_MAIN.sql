CREATE OR REPLACE PROCEDURE fims.sr_tdo201_main (
    P_GIJUN_YMD   IN  VARCHAR2,
    P_PRD_CD      IN  VARCHAR2 default '%',
    P_IP_USER     IN  VARCHAR2,
    P_MSG         OUT VARCHAR2
)
IS
    XCON_GIJUN_AMT    NUMBER := 10000000;
    WA_BF_YMD         VARCHAR2(8);   -- 전영업일
    W_BF2_YMD         VARCHAR2(8);   -- 전전영업일
    W_CNT             NUMBER;
    W_CUR_PRD_CD      VARCHAR2(100); -- 오류 위치 추적용
    W_CUR_FUND_CD     VARCHAR2(100);

    /* 전영업일 평가값 */
    TYPE T_PREV IS RECORD (
        FOUND           BOOLEAN,
        TOT_AEK         NUMBER,
        SILJ_AEK        NUMBER,
        NON_AEK         NUMBER,
        SEOLJ_AEK       NUMBER,
        GIJUN_GA        NUMBER,
        SUJ_GIJUN_GA    NUMBER
    );

    /* 당일 평가 결과 */
    TYPE T_VAL IS RECORD (
        GIJUN_GA        NUMBER,
        SUJ_GIJUN_GA    NUMBER,
        SILH_SUIK_RT    NUMBER,
        TOT_AEK         NUMBER,
        SILJ_AEK        NUMBER,
        NON_AEK         NUMBER,
        SEOLJ_AEK       NUMBER,
        DEPOSIT_3Y      VARCHAR2(1),   -- 예금 3년 만기일 표시
        T36_JY_YN       VARCHAR2(1),   -- 예금 3년 만기 익영업일 (설정액 재설정, 신규 이율 적용 시작)
        MAT_YMD         VARCHAR2(8),   -- 가장 최근 도래 만기일
        FIX_MAT_RT      NUMBER         -- 적용 이율 (비고 기록용)
    );

    /* 상품 구성 조회
       P_YMD      : 평가 기준일
       P_COMP_YMD : 구성 조회 기준일 (당일 구성 = P_YMD, 리밸런싱일의 기존 구성 = 전영업일)
       RBC_YMD    : 당일이 리밸런싱(변경승인)일이면 P_YMD  - 전영업일 익일 ~ 당일 사이 승인 존재
       RBC_BF_YN  : 전영업일이 리밸런싱일이면 'Y'        - 당일이 변경 포트폴리오 재투자일 */
    CURSOR C_COMP (P_YMD VARCHAR2, P_COMP_YMD VARCHAR2, P_PRD VARCHAR2) IS
                SELECT SEOLJ_YMD, FROM_YMD
                  , CASE WHEN A.FUND_TYPE_GB = 'I'                                        -- ★① TDO101N2 재조회 제거: 인라인뷰 FROM_YMD 재사용
                          THEN DECODE(F_HUIL_GB(A.FROM_YMD), 1, FIMS.F_AF_YONG_YMD(A.FROM_YMD), A.FROM_YMD)
                          ELSE A.UY_YMD
                    END AS UY_YMD
                  , END_YMD, PRD_CD, PRVD_CD
                  , RISK_GB , FUND_CD, FUND_NM, FUND_TYPE_GB, FUND_WT
                  , FST_SEOLJ_YN, RBC_YMD, RBC_BF_YN
              FROM (
                    SELECT Nvl(A.SEOLJ_YMD, A.APRV_YMD) AS SEOLJ_YMD
                        , CASE WHEN A.FUND_TYPE_GB = 'F' AND A.FROM_YMD < FIMS.F_BF_YONG_YMD(A.FUND_SEOLJ_YMD) THEN A.FUND_SEOLJ_YMD
                                WHEN A.FUND_TYPE_GB = 'I' THEN (SELECT MIN(GIJUN_YMD) FROM TDO101N2 WHERE FUND_CD = A.FUND_CD AND GIJUN_YMD >= A.FROM_YMD)
                                ELSE A.FROM_YMD END AS FROM_YMD
                        , CASE WHEN A.FUND_TYPE_GB = 'F' AND A.FROM_YMD <  A.FUND_SEOLJ_YMD THEN A.FUND_SEOLJ_YMD
                                WHEN A.FUND_TYPE_GB = 'F' AND A.FROM_YMD >= A.FUND_SEOLJ_YMD THEN A.FROM_YMD
                                WHEN A.FUND_TYPE_GB = 'I' THEN CAST(NULL AS VARCHAR2(8))  -- ★① 외곽에서 FROM_YMD 기반으로 휴일보정
                                WHEN A.FUND_TYPE_GB IN ('A','B','C') THEN
                                    /* 예금 이율·만기 기준일 : 가장 최근 변경승인일(영업일 보정), 승인 이력이 없으면 최초 설정 이력의 FROM_YMD
                                       - 리밸런싱 시 기존 예금도 매도 후 재투자되므로 승인일 기준 이율로 새로 시작 */
                                    NVL( (SELECT DECODE(F_HUIL_GB(MAX(R.APRV_YMD)), '0', MAX(R.APRV_YMD), FIMS.F_AF_YONG_YMD(MAX(R.APRV_YMD)))
                                            FROM TDO001R R
                                           WHERE R.PRD_CD    = A.PRD_CD
                                             AND R.APRV_YMD <= A.FROM_YMD
                                             AND R.APRV_YMD >  (SELECT MIN(P.FROM_YMD) FROM TDO001 P
                                                                 WHERE P.PRD_CD = A.PRD_CD AND P.SEOLJ_YMD = A.SEOLJ_YMD)),
                                         (SELECT MIN(P.FROM_YMD) FROM TDO001 P
                                           WHERE P.PRD_CD = A.PRD_CD AND P.SEOLJ_YMD = A.SEOLJ_YMD) )
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
                        , CASE WHEN EXISTS (SELECT 1 FROM TDO001R R
                                             WHERE R.PRD_CD = A.PRD_CD
                                               AND R.APRV_YMD >  WA_BF_YMD
                                               AND R.APRV_YMD <= P_YMD) THEN P_YMD
                               ELSE '99999999' END AS RBC_YMD
                        , CASE WHEN EXISTS (SELECT 1 FROM TDO001R R
                                             WHERE R.PRD_CD = A.PRD_CD
                                               AND R.APRV_YMD >  W_BF2_YMD
                                               AND R.APRV_YMD <= WA_BF_YMD) THEN 'Y'
                               ELSE 'N' END AS RBC_BF_YN
                      FROM TDO001 A
                    WHERE A.SEOLJ_YMD = (SELECT MAX(SEOLJ_YMD) FROM TDO001 WHERE PRD_CD = A.PRD_CD AND SEOLJ_YMD <= P_YMD)
                      AND Nvl(A.PYUNGA_GB, 'Y') = 'Y'
                      AND Nvl(A.HAEJI_YMD, '99999999') >= P_YMD
                      AND A.PRD_CD LIKE P_PRD
                    ) A
              WHERE A.END_YMD = (SELECT /*+ INDEX(TDO001 TDO001_SK) */ MIN(END_YMD) FROM TDO001 WHERE PRD_CD= A.PRD_CD AND END_YMD >= P_COMP_YMD);

    /* 전영업일 행 조회 */
    PROCEDURE LOAD_PREV (R IN C_COMP%ROWTYPE, P OUT T_PREV) IS
    BEGIN
        P.FOUND := FALSE;
        SELECT TOT_PYUNGA_AEK, SILJ_PYUNGA_AEK, NVL(NON_PYUNGA_AEK, 0), SEOLJ_AEK, GIJUN_GA, SUJ_GIJUN_GA
          INTO P.TOT_AEK, P.SILJ_AEK, P.NON_AEK, P.SEOLJ_AEK, P.GIJUN_GA, P.SUJ_GIJUN_GA
          FROM TDO201
         WHERE GIJUN_YMD = WA_BF_YMD
           AND PRD_CD  = R.PRD_CD
           AND RISK_GB = R.RISK_GB
           AND PRVD_CD = R.PRVD_CD
           AND FUND_CD = R.FUND_CD;
        P.FOUND := TRUE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        P.FOUND := FALSE;
    END LOAD_PREV;

    /* 예금 3년 만기일 : TSS003 에서 FUND_FROM_YMD 가 주기 시작일과 같은 행의 최대 FUND_TO_YMD
       (시작일이 TSS003 에 없으면 시작일 이후 가장 가까운 FUND_FROM_YMD 의 만기일) */
    FUNCTION GET_MAT_YMD (P_FROM_YMD IN VARCHAR2) RETURN VARCHAR2 IS
        L_MAT  VARCHAR2(8);
    BEGIN
        SELECT MAX(FUND_TO_YMD)
          INTO L_MAT
          FROM NNN.TSS003
         WHERE FUND_FROM_YMD = P_FROM_YMD
           AND GUBUN = 'T'
           AND TERM  = '36';

        IF L_MAT IS NULL THEN
            SELECT MIN(FUND_TO_YMD)
              INTO L_MAT
              FROM NNN.TSS003
             WHERE FUND_FROM_YMD >  P_FROM_YMD
               AND FUND_FROM_YMD <= TO_CHAR(TO_DATE(P_FROM_YMD, 'YYYYMMDD') + 15, 'YYYYMMDD')
               AND GUBUN = 'T'
               AND TERM  = '36';
        END IF;

        IF L_MAT IS NOT NULL AND F_HUIL_GB(L_MAT) = 1 THEN
            L_MAT := FIMS.F_AF_YONG_YMD(L_MAT);
        END IF;
        RETURN L_MAT;
    END GET_MAT_YMD;

    /* 전영업일 값(P) 기준 당일 평가 */
    PROCEDURE CALC_VAL (R IN C_COMP%ROWTYPE, P_YMD IN VARCHAR2, P IN T_PREV, V OUT T_VAL) IS
        L_BF_GA        NUMBER := P.GIJUN_GA;
        L_PRD_GB       VARCHAR2(1);
        L_DAILY_RT     NUMBER(20,12);
        L_FIX_MAT_RT   NUMBER(20,12);
        L_PYUNGA_AEK   NUMBER(20);
        L_SEOLJ_AEK    NUMBER(20);
        L_CYC_FROM     VARCHAR2(8);
        L_MAT_YMD      VARCHAR2(8);
        L_JY_YMD       VARCHAR2(8);
        L_RATE_YMD     VARCHAR2(8);
        L_DAY_FROM     VARCHAR2(8);
        L_A_GA         NUMBER;
        L_A_SILH       NUMBER;
        L_A_JISU       NUMBER;
        L_FST_GA       NUMBER;
        L_A_SUJ        NUMBER;
        L_GA_TODAY     NUMBER;
        L_RT           NUMBER;
    BEGIN
        V.DEPOSIT_3Y := NULL;
        V.T36_JY_YN  := 'N';
        V.MAT_YMD    := NULL;
        V.FIX_MAT_RT := NULL;

        /* 예금 */
        IF R.FUND_TYPE_GB IN ('A', 'B', 'C') THEN

            L_DAILY_RT := 1;
            L_RATE_YMD := R.UY_YMD;
            L_CYC_FROM := R.UY_YMD;

            /* 3년 만기 주기 추적 : UY_YMD → 만기일 → 만기 익영업일(새 주기 시작) → 만기일 ...
               - 만기일(휴일이면 익영업일)까지 기존 이율 (초일불산입, 말일산입)
               - 만기 익영업일부터 해당 시점 이율 적용, 만기일 평가액을 설정액으로 재설정 */
            FOR N IN 1 .. 30 LOOP
                EXIT WHEN L_CYC_FROM IS NULL;

                L_MAT_YMD := GET_MAT_YMD(L_CYC_FROM);

                EXIT WHEN L_MAT_YMD IS NULL OR L_MAT_YMD > P_YMD;

                IF L_MAT_YMD = P_YMD THEN          -- 오늘이 만기일
                    V.DEPOSIT_3Y := 'Y';
                    EXIT;
                END IF;

                L_JY_YMD   := FIMS.F_AF_YONG_YMD(L_MAT_YMD);   -- 만기 익영업일 (<= P_YMD)
                V.MAT_YMD  := L_MAT_YMD;
                L_RATE_YMD := L_JY_YMD;
                L_CYC_FROM := L_JY_YMD;                        -- 새 주기 시작일 = 만기 익영업일
            END LOOP;

            -- 이자 일수는 전영업일 익일 ~ 당일 (휴일 포함). 운용개시일 당일만 당일 1일
            L_DAY_FROM := CASE WHEN P_YMD = R.UY_YMD THEN NNN.F_BF_YONG_YMD(R.UY_YMD) ELSE WA_BF_YMD END;

            BEGIN
            SELECT PRD_GB, SUM(DAILY_RT)+1, Decode(Max(Nvl(FIX_MAT_RT, 0)), 0, Max(LNK_RT), Max(FIX_MAT_RT))
              INTO L_PRD_GB, L_DAILY_RT, L_FIX_MAT_RT
              FROM (
                    SELECT B.FUND_CD, B.PRD_GB
                        , CASE WHEN PRD_GB IN ('A','B','E') THEN (DAILY_RT-1) * COUNT(*) /* 단리 */
                                ELSE POWER(DAILY_RT, COUNT(*))-1 END AS DAILY_RT /* 복리 */
                        , Max(FIX_MAT_RT) FIX_MAT_RT
                        , Max(LNK_RT) LNK_RT
                    FROM TSS002 A, TDO101N1 B
                    WHERE A.YMD >  L_DAY_FROM
                    AND  A.YMD <= P_YMD
                    AND  B.FUND_CD = R.FUND_CD
                    AND  B.USE_YN = 'Y'
                    AND  B.GIJUN_YM = Nvl((SELECT MAX(GIJUN_YM) FROM TDO101N1 WHERE FUND_CD = R.FUND_CD AND GIJUN_YM <= L_RATE_YMD AND USE_YN ='Y' AND (NVL(FIX_MAT_RT, 0) > 0 OR NVL(LNK_RT, 0) > 0)), (SELECT MIN(GIJUN_YM) FROM TDO101N1 WHERE FUND_CD= R.FUND_CD AND USE_YN ='Y' AND (NVL(FIX_MAT_RT, 0) > 0 OR NVL(LNK_RT, 0) > 0)))
                    GROUP BY FUND_CD, DAILY_RT, PRD_GB
                    )
            GROUP BY FUND_CD, PRD_GB;
            EXCEPTION WHEN NO_DATA_FOUND THEN
                L_PRD_GB     := NULL;
                L_DAILY_RT   := 1;          -- 이율 미존재 시 평가액 유지
                L_FIX_MAT_RT := NULL;
            END;

            IF L_JY_YMD = P_YMD THEN
                L_SEOLJ_AEK := P.TOT_AEK;   -- 3년 만기 익영업일 : 만기일까지 이자가 반영된 평가액을 설정액으로 재설정
                V.T36_JY_YN := 'Y';
            ELSE
                L_SEOLJ_AEK := P.SEOLJ_AEK;
            END IF;

            IF L_PRD_GB IN ('A','B','E') THEN
                L_PYUNGA_AEK := L_SEOLJ_AEK * (L_DAILY_RT-1) + P.TOT_AEK;   /* 단리 */
            ELSE
                L_PYUNGA_AEK := P.TOT_AEK * L_DAILY_RT;                      /* 복리 */
            END IF;

            V.GIJUN_GA     := NULL;
            V.SUJ_GIJUN_GA := NULL;
            V.SILH_SUIK_RT := L_DAILY_RT;
            V.TOT_AEK      := L_PYUNGA_AEK;
            V.SILJ_AEK     := L_PYUNGA_AEK;
            V.NON_AEK      := 0;
            V.SEOLJ_AEK    := L_SEOLJ_AEK;
            V.FIX_MAT_RT   := L_FIX_MAT_RT;

        /* 보험펀드 : 미수집일은 직전 기준가 이월, 수익률 분모는 전일 TDO201 이월 기준가 */
        ELSIF R.FUND_TYPE_GB = 'I' THEN

            SELECT MAX(GIJUN_GA)
              INTO L_GA_TODAY
              FROM TDO101N2
             WHERE FUND_CD = R.FUND_CD
               AND GIJUN_YMD = P_YMD;

            IF L_BF_GA IS NULL THEN
                SELECT MAX(GIJUN_GA) KEEP (DENSE_RANK LAST ORDER BY GIJUN_YMD)
                  INTO L_BF_GA
                  FROM TDO101N2
                 WHERE FUND_CD = R.FUND_CD
                   AND GIJUN_YMD < P_YMD;
            END IF;

            L_RT := CASE WHEN L_GA_TODAY IS NOT NULL AND L_BF_GA > 0 THEN L_GA_TODAY / L_BF_GA ELSE 1 END;

            V.GIJUN_GA     := NVL(L_GA_TODAY, L_BF_GA);
            V.SUJ_GIJUN_GA := NULL;
            V.SILH_SUIK_RT := L_RT;
            V.TOT_AEK      := P.TOT_AEK  * L_RT;
            V.SILJ_AEK     := P.SILJ_AEK * L_RT;
            V.NON_AEK      := 0;
            V.SEOLJ_AEK    := P.SEOLJ_AEK;

        /* 공모펀드 : 미입수일은 비평가액으로 이월, 이후 수정기준가 비율로 공백 구간 수익률 반영 */
        ELSE

            SELECT MAX(GIJUN_GA), MAX(SILH_SUIK_RT), MAX(SUIK_JISU)
              INTO L_A_GA, L_A_SILH, L_A_JISU
              FROM TFN201
             WHERE ZEROIN_TYPE_GB = 'A2'
               AND GIJUN_YMD = P_YMD
               AND FUND_CD = R.FUND_CD;

            SELECT MAX(FST_GIJUN_GA)
              INTO L_FST_GA
              FROM TFN001
             WHERE ZEROIN_TYPE_GB = 'A2'
               AND END_YMD = '99999999'
               AND FUND_CD = R.FUND_CD;

            L_A_SUJ := L_A_JISU * L_FST_GA;

            L_RT := CASE WHEN L_A_GA IS NULL THEN 1
                         WHEN P.NON_AEK > 0 AND P.SUJ_GIJUN_GA > 0 AND L_A_SUJ > 0 THEN L_A_SUJ / P.SUJ_GIJUN_GA
                         ELSE NVL(L_A_SILH, 1) END;

            V.GIJUN_GA     := NVL(L_A_GA, P.GIJUN_GA);
            V.SUJ_GIJUN_GA := NVL(L_A_SUJ, P.SUJ_GIJUN_GA);
            V.SILH_SUIK_RT := L_RT;
            V.TOT_AEK      := P.TOT_AEK * L_RT;
            V.SILJ_AEK     := CASE WHEN L_A_GA IS NULL THEN 0 ELSE P.TOT_AEK * L_RT END;
            V.NON_AEK      := CASE WHEN L_A_GA IS NULL THEN P.TOT_AEK ELSE 0 END;
            V.SEOLJ_AEK    := P.SEOLJ_AEK;
        END IF;
    END CALC_VAL;

    PROCEDURE INS_VAL (R IN C_COMP%ROWTYPE, P_YMD IN VARCHAR2, V IN T_VAL) IS
    BEGIN
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
          , DEPOSIT_3Y
          , IL_BOSU
          , NUJ_BOSU
          , IP_USER, IP_DATE)
        VALUES (
            P_YMD
          , R.RISK_GB
          , R.PRVD_CD
          , R.PRD_CD
          , R.FUND_CD
          , V.GIJUN_GA
          , V.SUJ_GIJUN_GA
          , V.SILH_SUIK_RT
          , R.FUND_WT
          , V.TOT_AEK
          , V.SILJ_AEK
          , V.NON_AEK
          , 0
          , 0
          , V.SEOLJ_AEK
          , V.DEPOSIT_3Y
          , 0
          , 0
          , P_IP_USER, SYSDATE);
    END INS_VAL;

    /* 개별자산 1건 평가 및 저장 */
    PROCEDURE PROCESS_FUND (R IN C_COMP%ROWTYPE, P_YMD IN VARCHAR2) IS
        L_PREV      T_PREV;
        L_VAL       T_VAL;
        L_000_TOT   NUMBER;
        L_AMT       NUMBER;
        L_GA        NUMBER;
    BEGIN
        W_CUR_PRD_CD  := R.PRD_CD;
        W_CUR_FUND_CD := R.FUND_CD;

        DELETE  TDO201
         WHERE GIJUN_YMD = P_YMD
           AND PRD_CD = R.PRD_CD
           AND PRVD_CD = R.PRVD_CD
           AND RISK_GB = R.RISK_GB
           AND FUND_CD = R.FUND_CD;

        /* 1. 최초 설정 이력의 운용 개시 전 / 개시일 */
        IF R.FST_SEOLJ_YN = 'Y' THEN

            IF R.FUND_TYPE_GB IN ('A', 'B', 'C') AND R.UY_YMD = P_YMD THEN  -- 예금 최초 운용 개시일 (운용지시일 익영업일)

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
                    P_YMD
                  , R.RISK_GB
                  , R.PRVD_CD
                  , R.PRD_CD
                  , R.FUND_CD
                  , 1
                  , R.FUND_WT
                  , XCON_GIJUN_AMT * R.FUND_WT
                  , XCON_GIJUN_AMT * R.FUND_WT
                  , 0
                  , 0
                  , 0
                  , XCON_GIJUN_AMT * R.FUND_WT
                  , 0
                  , 0
                  , P_IP_USER, SYSDATE
                );
                RETURN;

            ELSIF R.FUND_TYPE_GB = 'I' AND P_YMD <= R.UY_YMD THEN  -- 보험펀드 운용 개시 전(예수금) / 개시일

                SELECT MAX(GIJUN_GA) INTO L_GA
                  FROM TDO101N2
                 WHERE FUND_CD = R.FUND_CD
                   AND GIJUN_YMD = P_YMD;

                IF L_GA IS NULL THEN
                    SELECT MAX(GIJUN_GA) KEEP (DENSE_RANK LAST ORDER BY GIJUN_YMD)
                      INTO L_GA
                      FROM TDO101N2
                     WHERE FUND_CD = R.FUND_CD
                       AND GIJUN_YMD < P_YMD;
                END IF;

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
                    P_YMD
                  , R.RISK_GB
                  , R.PRVD_CD
                  , R.PRD_CD
                  , R.FUND_CD
                  , L_GA
                  , 1
                  , R.FUND_WT
                  , XCON_GIJUN_AMT * R.FUND_WT
                  , CASE WHEN P_YMD = R.UY_YMD THEN XCON_GIJUN_AMT * R.FUND_WT ELSE 0 END
                  , 0
                  , CASE WHEN P_YMD = R.UY_YMD THEN 0 ELSE XCON_GIJUN_AMT * R.FUND_WT END
                  , 0
                  , XCON_GIJUN_AMT * R.FUND_WT
                  , 0
                  , 0
                  , P_IP_USER, SYSDATE
                );
                RETURN;

            ELSIF R.FUND_TYPE_GB = 'F' AND R.UY_YMD > P_YMD THEN  -- 공모펀드 운용시작 전 (예수금)

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
                SELECT P_YMD
                  , R.RISK_GB
                  , R.PRVD_CD
                  , R.PRD_CD
                  , R.FUND_CD
                  , (SELECT FST_GIJUN_GA FROM TFN001 WHERE ZEROIN_TYPE_GB ='A2' AND END_YMD ='99999999' AND FUND_CD = R.FUND_CD) AS GIJUN_GA
                  , (SELECT FST_GIJUN_GA FROM TFN001 WHERE ZEROIN_TYPE_GB ='A2' AND END_YMD ='99999999' AND FUND_CD = R.FUND_CD) AS SUJ_GIJUN_GA
                  , NULL
                  , R.FUND_WT
                  , XCON_GIJUN_AMT * R.FUND_WT AS TOT_PYUNGA_AEK
                  , 0 AS SILH_PYUNGA_AEK
                  , 0 AS NON_PYUNGA_AEK
                  , XCON_GIJUN_AMT * R.FUND_WT AS YESU_AEK
                  , 0 AS ADJ_PYUNGA_AEK
                  , XCON_GIJUN_AMT * R.FUND_WT AS SEOLJ_AEK
                  , 0
                  , 0
                  , P_IP_USER, SYSDATE
                  FROM DUAL;
                RETURN;

            ELSIF R.FUND_TYPE_GB = 'F' AND R.UY_YMD = P_YMD THEN  -- 공모펀드 운용시작일 실제평가액 편입 (기준가 미입수 시 비평가액)

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
                SELECT P_YMD
                  , R.RISK_GB
                  , R.PRVD_CD
                  , R.PRD_CD
                  , R.FUND_CD
                  , A.GIJUN_GA
                  , A.SUIK_JISU * (SELECT FST_GIJUN_GA FROM TFN001 WHERE ZEROIN_TYPE_GB ='A2' AND END_YMD ='99999999' AND FUND_CD = R.FUND_CD) AS SUJ_GIJUN_GA
                  , A.SILH_SUIK_RT
                  , R.FUND_WT
                  , XCON_GIJUN_AMT * R.FUND_WT AS TOT_PYUNGA_AEK
                  , CASE WHEN A.GIJUN_GA IS NULL THEN 0 ELSE XCON_GIJUN_AMT * R.FUND_WT END AS SILJ_PYUNGA_AEK
                  , CASE WHEN A.GIJUN_GA IS NULL THEN XCON_GIJUN_AMT * R.FUND_WT ELSE 0 END AS NON_PYUNGA_AEK
                  , 0 AS YESU_AEK
                  , 0 AS ADJ_PYUNGA_AEK
                  , XCON_GIJUN_AMT * R.FUND_WT AS SEOLJ_AEK
                  , 0
                  , 0
                  , P_IP_USER, SYSDATE
                  FROM DUAL
                  LEFT OUTER JOIN TFN201 A
                    ON A.ZEROIN_TYPE_GB = 'A2'
                   AND A.GIJUN_YMD = P_YMD
                   AND A.FUND_CD = R.FUND_CD;
                RETURN;
            END IF;
        END IF;

        /* 2. 평가 기준값 */
        LOAD_PREV(R, L_PREV);

        IF R.RBC_BF_YN = 'Y' THEN
            /* 리밸런싱일 익영업일 : 리밸런싱일 000 평가액을 변경 비중으로 재투자한 금액을 기준으로 당일 수익률 적용
               (예금은 승인일 기준 이율, 초일불산입·말일산입) */
            SELECT MAX(TOT_PYUNGA_AEK)
              INTO L_000_TOT
              FROM TDO201
             WHERE GIJUN_YMD = WA_BF_YMD
               AND PRD_CD = R.PRD_CD
               AND FUND_CD = '000';

            L_AMT := ROUND(L_000_TOT * R.FUND_WT);
            IF L_AMT IS NULL THEN
                RETURN;
            END IF;

            L_PREV.FOUND     := TRUE;          -- 기준가(GIJUN_GA, SUJ_GIJUN_GA)는 기존 보유분이 있으면 그대로 사용
            L_PREV.TOT_AEK   := L_AMT;
            L_PREV.SILJ_AEK  := L_AMT;
            L_PREV.NON_AEK   := 0;
            L_PREV.SEOLJ_AEK := L_AMT;
        END IF;

        IF NOT L_PREV.FOUND THEN
            RETURN;                            -- 전일 행 없음 : 평가 불가
        END IF;

        /* 3. 당일 평가 및 저장 */
        CALC_VAL(R, P_YMD, L_PREV, L_VAL);
        INS_VAL(R, P_YMD, L_VAL);

        IF L_VAL.T36_JY_YN = 'Y' THEN
            UPDATE TDO001 A  -- 기본정보 비고 : 만기 도래일과 변경 이율 기록 (재처리 시 같은 만기일 문구는 교체하여 중복 방지)
              SET REM = TRIM(
                          TRIM(REGEXP_REPLACE(A.REM, '/ ?3년 만기\(' || L_VAL.MAT_YMD || '\)[^/]*', ''))
                          || ' / 3년 만기(' || L_VAL.MAT_YMD || ') : '
                          || TO_CHAR(L_VAL.FIX_MAT_RT, 'FM9990.00') || '%'
                        )
            WHERE A.PRD_CD  = R.PRD_CD
              AND A.FUND_CD = R.FUND_CD
              AND A.END_YMD = (SELECT /*+ INDEX(TDO001 TDO001_SK) */ MIN(END_YMD)
                                  FROM TDO001 WHERE PRD_CD = A.PRD_CD AND END_YMD >= P_YMD);
        END IF;
    END PROCESS_FUND;

BEGIN
    WA_BF_YMD := FIMS.F_BF_YONG_YMD(P_GIJUN_YMD);
    W_BF2_YMD := FIMS.F_BF_YONG_YMD(WA_BF_YMD);

    FOR D1 IN (
        SELECT YMD, BF_YONG_YMD
          FROM  FIMS.TSS002
         WHERE  YMD = P_GIJUN_YMD
           AND HUIL_GB ='0'
           ) LOOP

      /* 1. 리밸런싱(변경승인)일 상품 : 승인일까지는 기존 포트폴리오의 수익률·평가액·설정액 유지
            (변경 포트폴리오는 승인일 익영업일부터 재투자) */
      SELECT COUNT(*)
        INTO W_CNT
        FROM TDO001R
       WHERE PRD_CD LIKE P_PRD_CD
         AND APRV_YMD >  WA_BF_YMD
         AND APRV_YMD <= D1.YMD;

      IF W_CNT > 0 THEN
          FOR R0 IN C_COMP(D1.YMD, WA_BF_YMD, P_PRD_CD) LOOP
              IF R0.RBC_YMD = D1.YMD THEN
                  PROCESS_FUND(R0, D1.YMD);
              END IF;
          END LOOP;
      END IF;

      /* 2. 그 외 상품 : 당일 구성으로 평가 (리밸런싱 익영업일이면 변경 포트폴리오 재투자) */
      FOR F1 IN C_COMP(D1.YMD, D1.YMD, P_PRD_CD) LOOP
          IF F1.RBC_YMD <> D1.YMD THEN
              PROCESS_FUND(F1, D1.YMD);
          END IF;
      END LOOP;

       /* 재처리 시 구성에서 빠진 개별자산의 기존 행 정리 (000 합산 오염 방지)
          리밸런싱일은 기존 구성(전영업일 기준)으로 저장하므로 두 구성 모두 유효 */
       DELETE TDO201 T
        WHERE T.GIJUN_YMD = D1.YMD
          AND T.PRD_CD LIKE P_PRD_CD
          AND T.FUND_CD <> '000'
          AND NOT EXISTS (SELECT 1
                            FROM TDO001 A
                           WHERE A.PRD_CD  = T.PRD_CD
                             AND A.FUND_CD = T.FUND_CD
                             AND (   A.END_YMD = (SELECT MIN(END_YMD) FROM TDO001 WHERE PRD_CD = A.PRD_CD AND END_YMD >= D1.YMD)
                                  OR A.END_YMD = (SELECT MIN(END_YMD) FROM TDO001 WHERE PRD_CD = A.PRD_CD AND END_YMD >= WA_BF_YMD)));

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

          ELSE  -- 일반 / 리밸런싱 / 예금 3년 만기 : 개별자산 합산 (설정액 = 개별자산 설정액 합계)

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
                  + Sum(YESU_AEK) ) / NULLIF((SELECT TOT_PYUNGA_AEK FROM TDO201 WHERE GIJUN_YMD = WA_BF_YMD AND FUND_CD = G1.FUND_CD AND PRD_CD = G1.PRD_CD), 0) AS SILH_SUIK_RT
                , (SUM(SILJ_PYUNGA_AEK)
                  + SUM(NON_PYUNGA_AEK)
                  + Sum(YESU_AEK) ) / NULLIF((SELECT TOT_PYUNGA_AEK FROM TDO201 WHERE GIJUN_YMD = WA_BF_YMD AND FUND_CD = G1.FUND_CD AND PRD_CD = G1.PRD_CD), 0)
                  * (SELECT SUIK_JISU FROM TDO201 WHERE GIJUN_YMD = WA_BF_YMD AND FUND_CD = G1.FUND_CD AND PRD_CD = G1.PRD_CD) AS SUIK_JISU
                , SUM(FUND_WT) AS FUND_WT
                , ( SUM(SILJ_PYUNGA_AEK)
                  + SUM(NON_PYUNGA_AEK)
                  + Sum(YESU_AEK)) AS TOT_PYUNGA_AEK
                , SUM(SILJ_PYUNGA_AEK) AS SILJ_PYUNGA_AEK
                , SUM(NON_PYUNGA_AEK) AS NON_PYUNGA_AEK
                , Sum(YESU_AEK) AS YESU_AEK
                , SUM(ADJ_PYUNGA_AEK) AS ADJ_PYUNGA_AEK
                , Sum(SEOLJ_AEK)  AS SEOLJ_AEK
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
