-- 1. Преобразование отчетных периодов в формат даты
WITH 
results_with_date AS (
    SELECT *,
           printf('%04d-%02d-%02d', 2026, 
                  CAST(SUBSTR(Month, INSTR(Month, ' ') + 1) AS INTEGER), 1) AS month_date
    FROM results
),
targets_with_date AS (
    SELECT *,
           printf('%04d-%02d-%02d', 2026, 
                  CAST(SUBSTR(Month, INSTR(Month, ' ') + 1) AS INTEGER), 1) AS month_date
    FROM targets
),

-- 2. Нумерация результатов каждого сотрудника по хронологии
ordered_results AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY operator_name ORDER BY month_date ASC) AS seq
    FROM results_with_date
),

-- 3. Формирование/определение отчетных периодов, для которых доступно четырехмесячное окно
report_dates AS (
    SELECT operator_name, month_date AS report_date
    FROM ordered_results
    WHERE seq >= 4
),

-- 4. Формирование скользящего четырехмесячного окна для каждого сотрудника и отчетного периода
ranked_months AS (
    SELECT 
        rd.report_date,
        r.*,
        ROW_NUMBER() OVER (
            PARTITION BY r.operator_name, rd.report_date 
            ORDER BY r.month_date DESC
        ) AS month_rank_desc   -- 1ый самый свежий, 4ый самый старый в окне
    FROM results_with_date r
    JOIN report_dates rd 
        ON r.operator_name = rd.operator_name AND r.month_date <= rd.report_date
),

-- 5. Преобразование нормативов KPI из длинного формата в широкий для сравнения с результатами сотрудников
targets_pivot AS (
    SELECT 
        month_date,
        Call_Center,
        MAX(CASE WHEN KPI = 'контакты в час' THEN target END) AS target_kch,
        MAX(CASE WHEN KPI = 'csat, %' THEN target END) AS target_csat,
        MAX(CASE WHEN KPI = 'fcr, %' THEN target END) AS target_fcr,
        MAX(CASE WHEN KPI = 'qc' THEN target END) AS target_qc
    FROM targets_with_date
    GROUP BY month_date, Call_Center
),

-- 6. Расчет выполнения KPI, средних значений и четырехмесячной истории показателей для каждого сотрудника и отчетного периода 
aggregated AS (
    SELECT 
        fr.report_date,
        fr.operator_name,
        -- Количество выполнений за 4 месяца
        COUNT(CASE WHEN fr.contacts_per_hou >= t.target_kch THEN 1 END) AS cnt_done_cph,
        COUNT(CASE WHEN fr.csat_percent >= t.target_csat THEN 1 END) AS cnt_done_rr,
        COUNT(CASE WHEN fr.fcr_percent >= t.target_fcr THEN 1 END) AS cnt_done_fcr,
        COUNT(CASE WHEN fr.qc_score >= t.target_qc THEN 1 END) AS cnt_done_qc,

        -- Средние за два старых месяца (ранги 3 и 4)
        ROUND(AVG(CASE WHEN fr.month_rank_desc IN (3,4) THEN fr.contacts_per_hou END), 1) AS avg_cph_1_2,
        ROUND(AVG(CASE WHEN fr.month_rank_desc IN (3,4) THEN fr.csat_percent END), 1) AS avg_csat_1_2,
        ROUND(AVG(CASE WHEN fr.month_rank_desc IN (3,4) THEN fr.fcr_percent END), 1) AS avg_fcr_1_2,
        ROUND(AVG(CASE WHEN fr.month_rank_desc IN (3,4) THEN fr.qc_score END), 1) AS avg_score_1_2,

        -- Значения за каждый из 4 месяцев (по отдельности)
        MAX(CASE WHEN fr.month_rank_desc = 4 THEN fr.contacts_per_hou END) AS cph_1m,
        MAX(CASE WHEN fr.month_rank_desc = 3 THEN fr.contacts_per_hou END) AS cph_2m,
        MAX(CASE WHEN fr.month_rank_desc = 2 THEN fr.contacts_per_hou END) AS cph_3m,
        MAX(CASE WHEN fr.month_rank_desc = 1 THEN fr.contacts_per_hou END) AS cph_4m,

        MAX(CASE WHEN fr.month_rank_desc = 4 THEN fr.csat_percent END) AS csat_1m,
        MAX(CASE WHEN fr.month_rank_desc = 3 THEN fr.csat_percent END) AS csat_2m,
        MAX(CASE WHEN fr.month_rank_desc = 2 THEN fr.csat_percent END) AS csat_3m,
        MAX(CASE WHEN fr.month_rank_desc = 1 THEN fr.csat_percent END) AS csat_4m,

        MAX(CASE WHEN fr.month_rank_desc = 4 THEN fr.fcr_percent END) AS fcr_1m,
        MAX(CASE WHEN fr.month_rank_desc = 3 THEN fr.fcr_percent END) AS fcr_2m,
        MAX(CASE WHEN fr.month_rank_desc = 2 THEN fr.fcr_percent END) AS fcr_3m,
        MAX(CASE WHEN fr.month_rank_desc = 1 THEN fr.fcr_percent END) AS fcr_4m,

        MAX(CASE WHEN fr.month_rank_desc = 4 THEN fr.qc_score END) AS qc_1m,
        MAX(CASE WHEN fr.month_rank_desc = 3 THEN fr.qc_score END) AS qc_2m,
        MAX(CASE WHEN fr.month_rank_desc = 2 THEN fr.qc_score END) AS qc_3m,
        MAX(CASE WHEN fr.month_rank_desc = 1 THEN fr.qc_score END) AS qc_4m,

        MAX(r.call_center) AS call_center,
        MAX(r.col_2) AS col_2

    FROM ranked_months fr
    LEFT JOIN targets_pivot t 
        ON fr.Call_Center = t.Call_Center AND fr.month_date = t.month_date
    LEFT JOIN (SELECT DISTINCT operator_name, call_center, col_2 FROM results) r 
        ON fr.operator_name = r.operator_name
    WHERE fr.month_rank_desc <= 4 
    GROUP BY fr.report_date, fr.operator_name
    HAVING COUNT(*) >= 4
),

-- 7. Определение динамики по каждому KPI
dynamics AS (
    SELECT 
        report_date,
        operator_name,
        call_center,
        col_2,
        cnt_done_cph, cnt_done_rr, cnt_done_fcr, cnt_done_qc,
        avg_cph_1_2, avg_csat_1_2, avg_fcr_1_2, avg_score_1_2,
        cph_1m, cph_2m, cph_3m, cph_4m,
        csat_1m, csat_2m, csat_3m, csat_4m,
        fcr_1m, fcr_2m, fcr_3m, fcr_4m,
        qc_1m, qc_2m, qc_3m, qc_4m,

        CASE 
            WHEN cnt_done_cph >= 3 THEN 'достижение стабильно'
            WHEN cnt_done_cph < 3 AND cph_3m > avg_cph_1_2 AND cph_4m > avg_cph_1_2 THEN 'положительная динамика'
            ELSE 'отрицательная динамика'
        END AS cph_dynamics,

        CASE 
            WHEN cnt_done_rr >= 3 THEN 'достижение стабильно'
            WHEN cnt_done_rr < 3 AND csat_3m > avg_csat_1_2 AND csat_4m > avg_csat_1_2 THEN 'положительная динамика'
            ELSE 'отрицательная динамика'
        END AS csat_dynamics,

        CASE 
            WHEN cnt_done_fcr >= 3 THEN 'достижение стабильно'
            WHEN cnt_done_fcr < 3 AND fcr_3m > avg_fcr_1_2 AND fcr_4m > avg_fcr_1_2 THEN 'положительная динамика'
            ELSE 'отрицательная динамика'
        END AS fcr_dynamics,

        CASE 
            WHEN cnt_done_qc >= 3 THEN 'достижение стабильно'
            WHEN cnt_done_qc < 3 AND qc_3m > avg_score_1_2 AND qc_4m > avg_score_1_2 THEN 'положительная динамика'
            ELSE 'отрицательная динамика'
        END AS qc_dynamics

    FROM aggregated
),

-- 8. Расчет количества KPI со стабильной, положительной и отрицательной динамикой
final_calc AS (
    SELECT 
        *,
        (CASE WHEN cph_dynamics = 'достижение стабильно' THEN 1 ELSE 0 END +
         CASE WHEN csat_dynamics = 'достижение стабильно' THEN 1 ELSE 0 END +
         CASE WHEN fcr_dynamics = 'достижение стабильно' THEN 1 ELSE 0 END +
         CASE WHEN qc_dynamics = 'достижение стабильно' THEN 1 ELSE 0 END) AS cnt_done_target_total,

        (CASE WHEN cph_dynamics = 'положительная динамика' THEN 1 ELSE 0 END +
         CASE WHEN csat_dynamics = 'положительная динамика' THEN 1 ELSE 0 END +
         CASE WHEN fcr_dynamics = 'положительная динамика' THEN 1 ELSE 0 END +
         CASE WHEN qc_dynamics = 'положительная динамика' THEN 1 ELSE 0 END) AS cnt_positive_dynamics_total,

        (CASE WHEN cph_dynamics = 'отрицательная динамика' THEN 1 ELSE 0 END +
         CASE WHEN csat_dynamics = 'отрицательная динамика' THEN 1 ELSE 0 END +
         CASE WHEN fcr_dynamics = 'отрицательная динамика' THEN 1 ELSE 0 END +
         CASE WHEN qc_dynamics = 'отрицательная динамика' THEN 1 ELSE 0 END) AS cnt_negative_dynamics_total
    FROM dynamics
)

-- 9. Формирование итоговой аналитической витрины с применением правил классификации
SELECT 
    report_date AS 'Период отчёта',
    call_center AS 'КЦ',
    col_2 AS 'Группа',
    operator_name AS 'Сотрудник',
    cnt_done_target_total AS 'кол. kpi вып-х стаб.',
    cnt_positive_dynamics_total AS 'кол. kpi положит. дин.',
    cnt_negative_dynamics_total AS 'кол. kpi отриц.',
    CASE 
        WHEN cnt_done_target_total = 4 THEN 'высокая эффект.'
        WHEN cnt_done_target_total = 3 AND cnt_positive_dynamics_total = 1 THEN 'высокая эффект.'
        WHEN cnt_done_target_total = 3 AND cnt_positive_dynamics_total = 0 THEN 'средняя эффект.'
        WHEN cnt_done_target_total = 2 AND cnt_positive_dynamics_total = 2 THEN 'средняя эффект.'
        WHEN cnt_done_target_total = 1 AND cnt_positive_dynamics_total >= 2 THEN 'средняя эффект.'
        WHEN cnt_done_target_total = 0 AND cnt_positive_dynamics_total >= 2 THEN 'средняя эффект.'
        WHEN cnt_done_target_total = 2 AND (cnt_positive_dynamics_total = 1 OR cnt_positive_dynamics_total = 0) THEN 'низкая эффект.'
        WHEN cnt_done_target_total = 1 AND (cnt_positive_dynamics_total = 1 OR cnt_positive_dynamics_total = 0) THEN 'низкая эффект.'
        WHEN cnt_done_target_total = 0 AND (cnt_positive_dynamics_total = 1 OR cnt_positive_dynamics_total = 0) THEN 'низкая эффект.'
    END AS 'Текущ. эффект. сотр.',

    -- Показатели за 4 месяца (1м – самый старый, 4м – самый свежий)
    cph_1m AS 'К/ч 1 мес.',
    cph_2m AS 'К/ч 2 мес.',
    cph_3m AS 'К/ч 3 мес.',
    cph_4m AS 'К/ч 4 мес',
    cph_dynamics AS 'К/ч дин.',

    ROUND(csat_1m / 100, 3) AS 'Кл.оц 1 мес.',
    ROUND(csat_2m / 100, 3) AS 'Кл.оц 2 мес.',
    ROUND(csat_3m / 100, 3) AS 'Кл.оц 3 мес.',
    ROUND(csat_4m / 100, 3) AS 'Кл.оц 4 мес.',
    csat_dynamics AS 'Кл.оц дин.',

    ROUND(fcr_1m / 100, 3) AS 'Реш с 1 раза 1 мес.',
    ROUND(fcr_2m / 100, 3) AS 'Реш с 1 раза 2 мес.',
    ROUND(fcr_3m / 100, 3) AS 'Реш с 1 раза 3 мес.',
    ROUND(fcr_4m / 100, 3) AS 'Реш с 1 раза 4 мес.',
    fcr_dynamics AS 'Реш. с 1 раза дин.',

    qc_1m AS 'Контр. кач. 1 мес.',
    qc_2m AS 'Контр. кач. 2 мес.',
    qc_3m AS 'Контр. кач. 3 мес.',
    qc_4m AS 'Контр. кач. 4 мес',
    qc_dynamics AS 'Контр. кач. дин.'

FROM final_calc
ORDER BY report_date DESC, operator_name;
