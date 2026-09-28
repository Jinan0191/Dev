CREATE OR REPLACE PROCEDURE fims.sr_tdo201_main (
    P_GIJUN_YMD   IN  VARCHAR2,
    P_PRD_CD      IN  VARCHAR2 default '%',
    P_IP_USER     IN  VARCHAR2,
    P_MSG         OUT VARCHAR2
)
IS

    XCON_GIJUN_AMT    NUMBER := 10000000;
    WA_BF_YMD         VARCHAR2(8);
    W_PRD_GB          VARCHAR2(1);
    W_PYUNGA_AEK      NUMBER(20);
    W_BF_PYUNGA_AEK   NUMBER(20);
    W_SEOLJ_AEK       NUMBER(20);
    W_DAILY_RT        NUMBER(20,12);
    W_FIX_MAT_RT      NUMBER(20,12);
    W_T36_YMD         VARCHAR2(8);   -- 추가: TSS003 T/36 기준 FUND_TO_YMD
    W_T36_JY_YMD      VARCHAR2(8);   -- 추가: 만기 이자 적용일
    W_T36_GB          VARCHAR2(1);
    W_UY_YMD          VARCHAR2(8);

BEGIN
    WA_BF_YMD := FIMS.F_BF_YONG_YMD(P_GIJUN_YMD);

    FOR D1 IN (
        SELECT YMD, BF_YONG_YMD
             , (SELECT Count(*) FROM TSS002 WHERE YMD > WA_BF_YMD AND YMD <= P_GIJUN_YMD) DAY_CNT
          FROM  FIMS.TSS002
         WHERE  YMD = P_GIJUN_YMD
           AND HUIL_GB ='0'
           ) LOOP

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
                                    AND NOT EXISTS (SELECT 1 FROM TDO001R R                -- FROM_YMD가 실제 재구성 승인일이 아니면
                                                      WHERE R.PRD_CD   = A.PRD_CD           --  (PRD_CD + APRV_YMD만 매칭, FUND_CD 무관)
                                                        AND R.APRV_YMD = A.FROM_YMD) THEN
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
--DBMS_OUTPUT.PUT_LINE(D1.YMD|| ' | ' || F1.PRD_CD );
        /* 리밸런싱 미적용시 예금 */
        IF F1.FUND_TYPE_GB IN ('A', 'B', 'C')  THEN

            BEGIN
                SELECT Decode(F_HUIL_GB(FUND_TO_YMD), 1, FIMS.F_AF_YONG_YMD(FUND_TO_YMD), FUND_TO_YMD)
                  INTO W_T36_YMD
                  FROM NNN.TSS003
                WHERE CHURI_YMD BETWEEN WA_BF_YMD AND D1.YMD
                  AND FUND_FROM_YMD = F1.UY_YMD
                  AND GUBUN     = 'T'
                  AND TERM      = '36';

            EXCEPTION
                WHEN NO_DATA_FOUND THEN W_T36_YMD := NULL;   -- 미존재 시 기존 동작 유지
            END;

            W_T36_GB := CASE WHEN W_T36_YMD = D1.YMD THEN 'Y' ELSE 'N' END; -- 36개월 만기 구분
            W_T36_JY_YMD := FIMS.F_AF_YONG_YMD(W_T36_YMD); -- 만기후 이자 적용일

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

            BEGIN
            SELECT PRD_GB, SUM(DAILY_RT)+1, Decode(Max(Nvl(FIX_MAT_RT,'0')), '0', Max(LNK_RT))
              INTO W_PRD_GB, W_DAILY_RT, W_FIX_MAT_RT
              FROM (
                    SELECT B.FUND_CD, B.PRD_GB
                        , CASE WHEN PRD_GB IN ('A','B','E') THEN (DAILY_RT-1) * COUNT(*) /* 단리 */
                                ELSE POWER(DAILY_RT, COUNT(*))-1 END AS DAILY_RT /* 복리 */
                        , Max(FIX_MAT_RT) FIX_MAT_RT
                        , Max(LNK_RT) LNK_RT
                    FROM TSS002 A, TDO101N1 B
                    WHERE A.YMD > Decode(D1.YMD, (CASE WHEN W_T36_JY_YMD <= D1.YMD THEN W_T36_JY_YMD ELSE F1.UY_YMD END), NNN.F_BF_YONG_YMD((CASE WHEN W_T36_JY_YMD <= D1.YMD THEN W_T36_JY_YMD ELSE F1.UY_YMD END)), WA_BF_YMD)
                    AND  A.YMD <= D1.YMD
                    AND  B.FUND_CD = F1.FUND_CD
                    AND  B.USE_YN = 'Y'
                    AND  B.GIJUN_YM = Nvl((SELECT MAX(GIJUN_YM) FROM TDO101N1 WHERE FUND_CD = F1.FUND_CD AND GIJUN_YM <= (CASE WHEN W_T36_JY_YMD <= D1.YMD THEN W_T36_JY_YMD ELSE F1.UY_YMD END) AND USE_YN ='Y' AND (NVL(FIX_MAT_RT, 0) > 0 OR NVL(LNK_RT, 0) > 0)), (SELECT MIN(GIJUN_YM) FROM TDO101N1 WHERE FUND_CD= F1.FUND_CD AND USE_YN ='Y' AND (NVL(FIX_MAT_RT, 0) > 0 OR NVL(LNK_RT, 0) > 0)))
                    GROUP BY FUND_CD, DAILY_RT, PRD_GB
                    )
            GROUP BY FUND_CD, PRD_GB;
            EXCEPTION WHEN  NO_DATA_FOUND  THEN
                W_DAILY_RT := 0;
            END;



              IF W_PRD_GB IN ('A','B','E') /* 단리 */ AND W_T36_JY_YMD <> D1.YMD THEN
                 W_PYUNGA_AEK := W_SEOLJ_AEK * (W_DAILY_RT-1) + W_BF_PYUNGA_AEK;
              ELSIF W_PRD_GB IN ('A','B','E') /* 단리 */ AND W_T36_JY_YMD = D1.YMD THEN
                 W_PYUNGA_AEK := W_BF_PYUNGA_AEK * (W_DAILY_RT-1) + W_BF_PYUNGA_AEK;
              ELSE
                 W_PYUNGA_AEK := W_BF_PYUNGA_AEK * W_DAILY_RT; /* 복리 */
              END IF;
              W_BF_PYUNGA_AEK := W_PYUNGA_AEK;
  --DBMS_OUTPUT.PUT_LINE(D1.YMD|| ' | ' || F1.fund_CD || ' | ' ||W_SEOLJ_AEK );
                IF F1.UY_YMD = D1.YMD AND F1.FST_SEOLJ_YN = 'Y' THEN  -- 최초 운용 개시일 (운용지시일 익영업일)

                    DELETE  TDO201
                     WHERE GIJUN_YMD = D1.YMD
                       AND PRD_CD = F1.PRD_CD
                       AND PRVD_CD = F1.PRVD_CD
                       AND RISK_GB = F1.RISK_GB
                       AND FUND_CD = F1.FUND_CD;

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

                ELSIF W_T36_JY_YMD = D1.YMD THEN  -- 3년 만기 금리 적용일 . 만기 익영업일로 요청하여 수정

                    DELETE  TDO201
                     WHERE GIJUN_YMD = D1.YMD
                       AND PRD_CD = F1.PRD_CD
                       AND PRVD_CD = F1.PRVD_CD
                       AND RISK_GB = F1.RISK_GB
                       AND FUND_CD = F1.FUND_CD;

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

                    UPDATE TDO001 A  -- 기본정보 REM 3년 만기 (재처리 시 최신값으로 갱신, 멱등)
                      SET REM = TRIM(
                                  REGEXP_REPLACE(
                                      NVL(A.REM, ' '),
                                      ' 3년 만기\(' || D1.YMD || '\)[^/]*/',   -- 같은 날짜 기존 문구 제거
                                      ''
                                  )
                                ) || ' 3년 만기(' || D1.YMD || ') : ' || W_FIX_MAT_RT || '% /'
                    WHERE A.FUND_CD = F1.FUND_CD
                      AND A.END_YMD = (SELECT /*+ INDEX(TDO001 TDO001_SK) */ MIN(END_YMD)
                                          FROM TDO001 WHERE PRD_CD = A.PRD_CD AND END_YMD >= D1.YMD);


                ELSIF F1.RBC_YMD = D1.YMD THEN  -- 리밸런싱 매도 적용일

                    DELETE  TDO201
                     WHERE GIJUN_YMD = D1.YMD
                       AND PRD_CD = F1.PRD_CD
                       AND PRVD_CD = F1.PRVD_CD
                       AND RISK_GB = F1.RISK_GB
                       AND FUND_CD = F1.FUND_CD;

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

                ELSE

                    DELETE  TDO201
                     WHERE GIJUN_YMD = D1.YMD
                       AND PRD_CD = F1.PRD_CD
                       AND PRVD_CD = F1.PRVD_CD
                       AND RISK_GB = F1.RISK_GB
                       AND FUND_CD = F1.FUND_CD;

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
                         , Decode(W_T36_GB, 'Y', W_T36_GB, NULL) DEPOSIT_3Y
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
        /* 리밸런싱 미적용시 보험펀드 */
        ELSIF F1.FUND_TYPE_GB = 'I'  THEN

            FOR T2 IN (
                        /* 보험펀드가 영업일에 수집되지 않는 경우가 있어 보완 */
                       SELECT D1.YMD
                            , F1.FUND_CD
                            , Max(A.GIJUN_GA) AS GIJUN_GA
                            , Nvl(Max(A.GIJUN_GA) / Max(B.GIJUN_GA), 1) AS DAILY_RT
                        FROM TDO101N2 A
                        LEFT JOIN TDO101N2 B
                          ON A.FUND_CD = B.FUND_CD
                        AND B.GIJUN_YMD = WA_BF_YMD
                        WHERE A.FUND_CD = F1.FUND_CD
                          AND A.GIJUN_YMD = D1.YMD

                        UNION ALL

                        SELECT D1.YMD
                            , F1.FUND_CD
                            , B.GIJUN_GA
                            , 1 AS DAILY_RT
                        FROM TDO101N2 B
                        WHERE B.FUND_CD = F1.FUND_CD
                          AND B.GIJUN_YMD = WA_BF_YMD
                          AND NOT EXISTS (SELECT 1 FROM TDO101N2 A WHERE A.FUND_CD = B.FUND_CD AND A.GIJUN_YMD = D1.YMD)
                        ) LOOP


                IF D1.YMD < F1.UY_YMD AND F1.FST_SEOLJ_YN ='Y' THEN  -- 최초 운용 개시일
--DBMS_OUTPUT.PUT_LINE(D1.YMD|| ' | ' || F1.PRD_CD );
                    DELETE  TDO201
                     WHERE GIJUN_YMD = D1.YMD
                       AND PRD_CD = F1.PRD_CD
                       AND RISK_GB = F1.RISK_GB
                       AND PRVD_CD = F1.PRVD_CD
                       AND FUND_CD = T2.FUND_CD;

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
                      , T2.GIJUN_GA
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
--DBMS_OUTPUT.PUT_LINE(D1.YMD|| ' | ' || F1.PRD_CD );
                    DELETE  TDO201
                     WHERE GIJUN_YMD = D1.YMD
                       AND PRD_CD = F1.PRD_CD
                       AND RISK_GB = F1.RISK_GB
                       AND PRVD_CD = F1.PRVD_CD
                       AND FUND_CD = T2.FUND_CD;

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
                      , T2.GIJUN_GA
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

                    DELETE  TDO201
                     WHERE GIJUN_YMD = D1.YMD
                       AND PRD_CD = F1.PRD_CD
                       AND RISK_GB = F1.RISK_GB
                       AND PRVD_CD = F1.PRVD_CD
                       AND FUND_CD = T2.FUND_CD;

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
                      , IP_USER, IP_DATE
                      )
                     SELECT D1.YMD
                      , F1.RISK_GB
                      , F1.PRVD_CD
                      , F1.PRD_CD
                      , F1.FUND_CD
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

                    DELETE  TDO201
                     WHERE GIJUN_YMD = D1.YMD
                       AND PRD_CD = F1.PRD_CD
                       AND RISK_GB = F1.RISK_GB
                       AND PRVD_CD = F1.PRVD_CD
                       AND FUND_CD = F1.FUND_CD;

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
                         , T2.GIJUN_GA
                         , NULL AS SUJ_GIJUN_GA
                         , T2.DAILY_RT
                         , F1.FUND_WT
                         , TOT_PYUNGA_AEK * T2.DAILY_RT AS TOT_PYUNGA_AEK
                         , SILJ_PYUNGA_AEK * T2.DAILY_RT AS SILJ_PYUNGA_AEK
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
            END LOOP;  -- T2

        ELSIF F1.FUND_TYPE_GB = 'F' THEN --펀드

                IF F1.UY_YMD > D1.YMD AND F1.FST_SEOLJ_YN = 'Y'  THEN  -- 운용시작일실제평가액편입 (설정이전)
--                 DBMS_OUTPUT.PUT_LINE(D1.YMD|| ' | ' || F1.PRD_CD );
                     DELETE  TDO201
                     WHERE GIJUN_YMD = D1.YMD
                       AND PRD_CD = F1.PRD_CD
                       AND RISK_GB = F1.RISK_GB
                       AND PRVD_CD = F1.PRVD_CD
                       AND FUND_CD = F1.FUND_CD;

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

                    DELETE  TDO201
                     WHERE GIJUN_YMD = D1.YMD
                       AND PRD_CD = F1.PRD_CD
                       AND RISK_GB = F1.RISK_GB
                       AND PRVD_CD = F1.PRVD_CD
                       AND FUND_CD = F1.FUND_CD;

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
                    SELECT GIJUN_YMD
                      , F1.RISK_GB
                      , F1.PRVD_CD
                      , F1.PRD_CD
                      , F1.FUND_CD
                      , A.GIJUN_GA
                      , A.SUIK_JISU * (SELECT FST_GIJUN_GA FROM TFN001 WHERE ZEROIN_TYPE_GB ='A2' AND END_YMD ='99999999' AND FUND_CD = A.FUND_CD) AS SUJ_GIJUN_GA
                      , A.SILH_SUIK_RT
                      , F1.FUND_WT
                      , XCON_GIJUN_AMT * F1.FUND_WT AS TOT_PYUNGA_AEK
                      , XCON_GIJUN_AMT * F1.FUND_WT AS SILJ_PYUNGA_AEK
                      , 0 AS NON_PYUNGA_AEK
                      , 0 AS YESU_AEK
                      , 0 AS ADJ_PYUNGA_AEK
                      , XCON_GIJUN_AMT * F1.FUND_WT AS SEOLJ_AEK
                      , 0
                      , 0
                      , P_IP_USER, SYSDATE  FROM TFN201 A
                    WHERE ZEROIN_TYPE_GB = 'A2'
                      AND GIJUN_YMD = D1.YMD
                      AND FUND_CD = F1.FUND_CD;

                ELSIF D1.YMD = F1.RBC_YMD THEN  --  최초 적용일 비평가액으로 산입(리밸런싱)

                    DELETE  TDO201
                     WHERE GIJUN_YMD = D1.YMD
                       AND PRD_CD = F1.PRD_CD
                       AND RISK_GB = F1.RISK_GB
                       AND PRVD_CD = F1.PRVD_CD
                       AND FUND_CD = F1.FUND_CD;

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
                      , A.SUIK_JISU * (SELECT FST_GIJUN_GA FROM TFN001 WHERE ZEROIN_TYPE_GB ='A2' AND END_YMD ='99999999' AND FUND_CD = A.FUND_CD) AS SUJ_GIJUN_GA
                      , A.SILH_SUIK_RT
                      , F1.FUND_WT
                      , B.TOT_PYUNGA_AEK * F1.FUND_WT  AS TOT_PYUNGA_AEK
                      , B.TOT_PYUNGA_AEK * F1.FUND_WT AS SILJ_PYUNGA_AEK
                      , 0 AS NON_PYUNGA_AEK
                      , 0 AS YESU_AEK
                      , 0 AS ADJ_PYUNGA_AEK
                      , B.TOT_PYUNGA_AEK * F1.FUND_WT AS SEOLJ_AEK
                      , 0
                      , 0
                      , P_IP_USER, SYSDATE  FROM TFN201 A, TDO201 B
                    WHERE A.ZEROIN_TYPE_GB = 'A2'
                      AND A.GIJUN_YMD = D1.YMD
                      AND A.FUND_CD = F1.FUND_cD
                      AND B.PRD_CD = F1.PRD_CD
                      AND B.RISK_GB = F1.RISK_GB
                      AND B.PRVD_CD = F1.PRVD_CD
                      AND B.FUND_cD = '000'
                      AND B.GIJUN_YMD = FIMS.F_BF_YONG_YMD(F1.FROM_YMD);

                ELSIF D1.YMD = FIMS.F_AF_YONG_YMD(F1.UY_YMD)  THEN  --  실제 평가 시작 수익률 반영

                    DELETE  TDO201
                     WHERE GIJUN_YMD = D1.YMD
                       AND PRD_CD = F1.PRD_CD
                       AND RISK_GB = F1.RISK_GB
                       AND PRVD_CD = F1.PRVD_CD
                       AND FUND_CD = F1.FUND_CD;
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
                    SELECT
                        A.GIJUN_YMD
                      , F1.RISK_GB
                      , F1.PRVD_CD
                      , F1.PRD_CD
                      , F1.FUND_CD
                      , A.GIJUN_GA
                      , A.SUIK_JISU * (SELECT FST_GIJUN_GA FROM TFN001 WHERE ZEROIN_TYPE_GB ='A2' AND END_YMD ='99999999' AND FUND_CD = A.FUND_CD) AS SUJ_GIJUN_GA
                      , A.SILH_SUIK_RT
                      , F1.FUND_WT
                      , B.TOT_PYUNGA_AEK  * A.SILH_SUIK_RT AS TOT_PYUNGA_AEK
                      , B.SILJ_PYUNGA_AEK * A.SILH_SUIK_RT AS SILJ_PYUNGA_AEK
                      , 0 AS NON_PYUNGA_AEK
                      , 0 AS YESU_AEK
                      , 0 AS ADJ_PYUNGA_AEK
                      , B.SEOLJ_AEK  AS SEOLJ_AEK
                      , 0
                      , 0
                      , P_IP_USER, SYSDATE  FROM TFN201 A, TDO201 B
                    WHERE A.ZEROIN_TYPE_GB = 'A2'
                      AND A.GIJUN_YMD = D1.YMD
                      AND A.FUND_CD = F1.FUND_cD
                      AND B.PRD_CD = F1.PRD_CD
                      AND B.RISK_GB = F1.RISK_GB
                      AND B.PRVD_CD = F1.PRVD_CD
                      AND B.FUND_cD = F1.FUND_CD
                      AND B.GIJUN_YMD = WA_BF_YMD;

                ELSE

                    DELETE  TDO201
                     WHERE GIJUN_YMD = D1.YMD
                       AND PRD_CD = F1.PRD_CD
                       AND RISK_GB = F1.RISK_GB
                       AND PRVD_CD = F1.PRVD_CD
                       AND FUND_CD = F1.FUND_CD
                       ;

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
                      , B.RISK_GB
                      , B.PRVD_CD
                      , B.PRD_CD
                      , F1.FUND_CD
                      , A.GIJUN_GA
                      , A.SUIK_JISU * (SELECT FST_GIJUN_GA FROM TFN001 WHERE ZEROIN_TYPE_GB ='A2' AND END_YMD ='99999999' AND FUND_CD = B.FUND_CD) AS SUJ_GIJUN_GA
                      , NVL(A.SILH_SUIK_RT, 1) AS SILH_SUIK_RT
                      , F1.FUND_wT
                      , NVL(B.TOT_PYUNGA_AEK * A.SILH_SUIK_RT, B.TOT_PYUNGA_AEK) AS TOT_PYUNGA_AEK
                      , NVL(B.TOT_PYUNGA_AEK * A.SILH_SUIK_RT, 0) AS SILJ_PYUNGA_AEK
                      , DECODE(NVL(A.GIJUN_GA, 1), 1, B.TOT_PYUNGA_AEK, 0)  AS NON_PYUNGA_AEK
                      , 0 AS YESU_AEK
                      , 0 AS ADJ_PYUNGA_AEK
                      , B.SEOLJ_AEK
                      , 0 AS IL_BOSU
                      , 0 AS NUJ_BOSU
                      , P_IP_USER
                      , SYSDATE
                     FROM TDO201 B
                     -------------------------------------------------------------
                     LEFT OUTER JOIN TFN201 A
                     ON A.FUND_CD = B.FUND_CD AND A.ZEROIN_TYPE_GB (+)= 'A2' AND A.GIJUN_YMD = D1.YMD
                    WHERE B.PRVD_CD = F1.PRVD_CD
                      AND B.RISK_GB = F1.RISK_GB
                      AND B.GIJUN_YMD = WA_BF_YMD
                      AND B.PRD_CD = F1.PRD_CD
                      AND B.FUND_CD = F1.FUND_CD
                      ;

                END IF;
            COMMIT;
        END IF;
       END LOOP; -- F1

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
                            , (SELECT DEPOSIT_3Y FROM TDO201 WHERE PRD_CD = A.PRD_CD AND GIJUN_YMD = D1.YMD AND FUND_cD = A.FUND_CD) AS T36_GB
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
                        , NVL(MAX(T36_GB), 'N') AS T36_GB
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
       BEGIN
       --
          IF  D1.YMD = G1.FROM_YMD AND G1.FST_SEOLJ_YN = 'Y'  THEN --최초 운용지시

              DELETE  TDO201
                WHERE GIJUN_YMD = D1.YMD
                  AND PRD_CD = G1.PRD_CD
                  AND RISK_GB = G1.RISK_GB
                  AND PRVD_CD = G1.PRVD_CD
                  AND FUND_CD = G1.FUND_CD
                  ;
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

          ELSIF G1.T36_GB = 'Y' THEN  -- 예금 3년만기 설정액 재산출

               DELETE  TDO201
                WHERE GIJUN_YMD = D1.YMD
                  AND PRD_CD = G1.PRD_CD
                  AND RISK_GB = G1.RISK_GB
                  AND PRVD_CD = G1.PRVD_CD
                  AND FUND_CD = G1.FUND_CD
                  ;
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
                , G1.RISK_GB
                , G1.PRVD_CD
                , PRD_CD
                , G1.FUND_CD AS FUND_CD
                , ( SUM(SILJ_PYUNGA_AEK)
                  + SUM(NON_PYUNGA_AEK)
                  + Sum(YESU_AEK) ) / (SELECT TOT_PYUNGA_AEK FROM TDO201 WHERE GIJUN_YMD = WA_BF_YMD AND FUND_CD = G1.FUND_CD AND PRD_CD = G1.PRD_CD) AS SILH_SUIK_RT
                , (( SUM(SILJ_PYUNGA_AEK)
                  + SUM(NON_PYUNGA_AEK)
                  + Sum(YESU_AEK) ) / (SELECT TOT_PYUNGA_AEK FROM TDO201 WHERE GIJUN_YMD = WA_BF_YMD AND FUND_CD = G1.FUND_CD AND PRD_CD = G1.PRD_CD))
                  * (SELECT SUIK_JISU FROM TDO201 WHERE GIJUN_YMD = D1.BF_YONG_YMD AND FUND_CD = G1.FUND_CD AND PRD_CD = G1.PRD_CD) AS SUIK_JISU
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
                AND PRVD_CD = G1.PRVD_CD
                AND RISK_GB = G1.RISK_GB
                AND  FUND_CD <> G1.FUND_CD
            GROUP BY  PRD_CD;

          ELSIF D1.YMD = G1.RBC_YMD  THEN -- 리밸런싱 시작

               DELETE  TDO201
                WHERE GIJUN_YMD = D1.YMD
                  AND PRD_CD = G1.PRD_CD
                  AND RISK_GB = G1.RISK_GB
                  AND PRVD_CD = G1.PRVD_CD
                  AND FUND_CD = G1.FUND_CD
                  ;
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
                , G1.RISK_GB
                , G1.PRVD_CD
                , PRD_CD
                , G1.FUND_CD AS FUND_CD
                , ( SUM(SILJ_PYUNGA_AEK)
                  + SUM(NON_PYUNGA_AEK)
                  + Sum(YESU_AEK) ) / (SELECT TOT_PYUNGA_AEK FROM TDO201 WHERE GIJUN_YMD = WA_BF_YMD AND FUND_CD = G1.FUND_CD AND PRD_CD = G1.PRD_CD) AS SILH_SUIK_RT
                , (( SUM(SILJ_PYUNGA_AEK)
                  + SUM(NON_PYUNGA_AEK)
                  + Sum(YESU_AEK) ) / (SELECT TOT_PYUNGA_AEK FROM TDO201 WHERE GIJUN_YMD = WA_BF_YMD AND FUND_CD = G1.FUND_CD AND PRD_CD = G1.PRD_CD))
                  * (SELECT SUIK_JISU FROM TDO201 WHERE GIJUN_YMD = D1.BF_YONG_YMD AND FUND_CD = G1.FUND_CD AND PRD_CD = G1.PRD_CD) AS SUIK_JISU
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
                AND PRVD_CD = G1.PRVD_CD
                AND RISK_GB = G1.RISK_GB
                AND  FUND_CD <> G1.FUND_CD
            GROUP BY  PRD_CD
          ;

          ELSE
--             DBMS_OUTPUT.PUT_LINE(D1.YMD|| ' | ' || G1.PRD_CD );
              DELETE  TDO201
                WHERE GIJUN_YMD = D1.YMD
                  AND PRD_CD = G1.PRD_CD
                  AND RISK_GB = G1.RISK_GB
                  AND PRVD_CD = G1.PRVD_CD
                  AND FUND_CD = G1.FUND_CD
                  ;
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
                  + Sum(YESU_AEK) ) / (SELECT TOT_PYUNGA_AEK FROM TDO201 WHERE GIJUN_YMD = WA_BF_YMD AND FUND_CD = G1.FUND_CD AND PRD_CD = G1.PRD_CD) AS SILH_SUIK_RT
                , (SUM(SILJ_PYUNGA_AEK)
                  + SUM(NON_PYUNGA_AEK)
                  + Sum(YESU_AEK) ) / (SELECT TOT_PYUNGA_AEK FROM TDO201 WHERE GIJUN_YMD = WA_BF_YMD AND FUND_CD = G1.FUND_CD AND PRD_CD = G1.PRD_CD)
                  * (SELECT SUIK_JISU FROM TDO201 WHERE GIJUN_YMD = WA_BF_YMD AND FUND_CD = G1.FUND_CD AND PRD_CD = G1.PRD_CD) AS SUIK_JISU
                , SUM(FUND_WT) AS FUND_WT
                , ( SUM(SILJ_PYUNGA_AEK)
                  + SUM(NON_PYUNGA_AEK)
                  + Sum(YESU_AEK)) AS TOT_PYUNGA_AEK
                , SUM(SILJ_PYUNGA_AEK) AS SILJ_PYUNGA_AEK
                , SUM(NON_PYUNGA_AEK) AS NON_PYUNGA_AEK
                , Sum(YESU_AEK) AS YESU_AEK
                , SUM(ADJ_PYUNGA_AEK) AS ADJ_PYUNGA_AEK
                --, (SELECT SEOLJ_AEK FROM TDO201 WHERE GIJUN_YMD = WA_BF_YMD AND FUND_CD = G1.FUND_CD AND PRD_CD = G1.PRD_CD)  AS SEOLJ_AEK
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

       COMMIT;
       END;
       END LOOP;

       BEGIN -- 분산값 산출
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
    COMMIT;

    P_MSG := 'Y';

EXCEPTION
    WHEN OTHERS THEN
        P_MSG := 'N - ' || SQLERRM;
END;
/
