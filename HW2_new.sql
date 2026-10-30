-- ============================================================
-- Домашнее задание к лекции «Продвинутый SQL»
-- Школа Аналитиков · учебная база hh_school
-- Автор: Казимиров Егор Денисович
-- ============================================================

SET search_path = hh_school, public;

-- ============================================================
-- БЛОК А. Качество и подготовка данных
-- ============================================================

-- ЗАДАНИЕ 1. Аудит качества данных

-- проверяю, можно ли связать событие с откликом
SELECT count(*) AS broken_calls
FROM calls c
LEFT JOIN responses r 
	ON c.response_id = r.response_id
WHERE r.response_id IS NULL;
-- В результате получилось 8 звонков, которые не привязаны к реальным откликам, а это значит,
-- что их придется отфильтровать, так как невозможно вычислить для них время отклика

SELECT count(*) AS broken_messages
FROM messages m
LEFT JOIN responses r 
	ON m.response_id = r.response_id
WHERE r.response_id IS NULL;
-- 0 строк, с сообщениями все в порядке

-- проверяю, согласуются ли ID работодателей в связанных таблицах
SELECT count(*) AS mismatched_calls
FROM calls c
JOIN responses r 
	ON c.response_id = r.response_id
JOIN vacancies v 
	ON r.vacancy_id = v.vacancy_id
WHERE c.employer_id != v.employer_id;

SELECT count(*) AS mismatched_messages
FROM messages m
JOIN responses r 
	ON m.response_id = r.response_id
JOIN vacancies v 
	ON r.vacancy_id = v.vacancy_id
WHERE m.employer_id != v.employer_id;
--  оба запроса - 0, значит, ID работодателей нигде не перепутаны

-- проверяю, нет ли событий, которые произошли до отклика
SELECT count(*) AS calls_before_response
FROM calls c
JOIN responses r 
	ON c.response_id = r.response_id
WHERE c.call_at < r.created_at;

SELECT count(*) AS messages_before_response
FROM messages m
JOIN responses r 
	ON m.response_id = r.response_id
WHERE m.sent_at < r.created_at;
-- Звонков или сообщений из прошлого нет, отрицательных значений не будет

-- проверяю, согласуются ли значения внутри одной строки
SELECT count(*) AS invalid_duration_calls
FROM calls
WHERE (status = 'successful' AND (call_duration IS NULL OR call_duration <= 0))
   OR (status != 'successful' AND call_duration IS NOT NULL);
-- 0 строк выведено, значит, логика не нарушена и у успешных есть длительность, у остальных нет.

-- проверяю, есть ли пропуски в данных, которые понадобятся дальше
SELECT count(*) AS messages_without_meta
FROM messages 
WHERE message_meta IS NULL;

SELECT count(*) AS calls_without_tags
FROM calls 
WHERE call_tags IS NULL;
-- Пропусков нет и все метаданные и теги на месте

-- ДОРАБОТКА: 
-- проверяю, нет ли пустых массивов тегов
SELECT count(*) AS empty_call_tags
FROM calls
WHERE call_tags = '{}';
 -- пустых массивов тегов нет

-- ДОРАБОТКА: 
-- проверяю, нет ли пустых JSON
SELECT count(*) AS empty_message_meta
FROM messages
WHERE message_meta = '{}'; 
-- Пустых JSON тоже нет

-- ДОРАБОТКА: 
-- проверяю, нет ли пропусков (NULL) в response_id
SELECT count(*) AS null_response_id_calls
FROM calls
WHERE response_id IS NULL; 
-- 8 пропусков - это те же самые звонки, которые не привязаны к откликам.

SELECT count(*) AS null_response_id_messages
FROM messages
WHERE response_id IS NULL; 
-- с сообщениями все ок

-- ДОРАБОТКА: 
-- проверяю, нет ли полностью дублирующихся звонков
SELECT 
	count(*) AS duplicate_calls
FROM (
    SELECT 
    	response_id, 
    	employer_id, 
    	call_at, 
    	call_duration, 
    	status, 
    	count(*)
    FROM calls
    GROUP BY 
    	response_id, 
    	employer_id, 
    	call_at, 
    	call_duration, 
    	status
    HAVING count(*) > 1
) AS dups; 
-- дубликатов нет

-- ищу значения, которые заметно отличаются от основной массы
-- ДОРАБОТКА: 
-- добавил расчет разницы между средней и медианой
WITH valid_calls AS (
    SELECT call_duration
    FROM calls
    WHERE status = 'successful' 
    	AND call_duration > 0
),
p99_calc AS (
    SELECT PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY call_duration) AS p99
    FROM valid_calls
)
SELECT 
    COUNT(*) AS total_calls,
    ROUND(AVG(call_duration), 1) AS avg_duration,
    ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY call_duration))::numeric, 1) AS median_duration,
    ROUND((AVG(call_duration) - (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY call_duration))::numeric)::numeric, 1) AS diff_avg_median_with_outliers,
    (SELECT ROUND(p99::numeric, 1) FROM p99_calc) AS p99_duration,
    COUNT(*) FILTER (WHERE call_duration > (SELECT p99 FROM p99_calc)) AS outlier_count,
    ROUND(AVG(call_duration) FILTER (WHERE call_duration <= (SELECT p99 FROM p99_calc)), 1) AS avg_without_outliers,
    ROUND((AVG(call_duration) FILTER (WHERE call_duration <= (SELECT p99 FROM p99_calc)) - (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY call_duration))::numeric)::numeric, 1) AS diff_avg_median_no_outliers,
    -- насколько упала средняя после удаления выбросов
    ROUND((AVG(call_duration) - AVG(call_duration) FILTER (WHERE call_duration <= (SELECT p99 FROM p99_calc)))::numeric, 1) AS avg_drop
FROM valid_calls;

-- ДОРАБОТКА: 
-- Всего 181 валидный звонок. Медиана длительности - 438 секунд.
-- 1) С выбросами: средняя = 467.3 сек. Разница между средней и медианой = 29.3 сек.
-- 2) Без выбросов (2 звонка дольше 890 сек): средняя падает до 462.5 сек,
-- а разница между средней и медианой теперь составила 24.5 сек.
-- 3) Сама средняя упала на 4.8 сек.
--
-- Общий вывод по первому блоку:
-- В ходе аудита была обнаружена одна критическая ошибка: 8 звонков в таблице calls 
-- имеют response_id = NULL, то есть их нет в таблице responses и эти звонки невозможно 
-- привязать к отклику, поэтому в последующих заданиях их нужно отфильтровать, 
-- чтобы они не искажали статистику.
-- Остальные проверки показали, что данные чистые. 
--
-- По выбросам я принял решение опираться на медиану (438 сек), так как средняя (467.3) 
-- чувствительна к двум аномально долгим звонкам. Сами эти два выброса я считаю 
-- допустимыми, а не ошибками, потому что это могли быть действительно долгими собеседования.

-- ============================================================
-- БЛОК Б. История коммуникаций
-- ============================================================

-- ЗАДАНИЕ 2. Единый слой коммуникаций

WITH message_events AS (
    SELECT 
        m.response_id,
        m.employer_id,
        m.message_id::text AS event_id, 
        m.sent_at AS event_at,
        'message' AS event_type
    FROM messages m
    JOIN responses r 
    	ON m.response_id = r.response_id
    WHERE m.sender_role = 'employer'
      AND m.sent_at >= r.created_at 
      AND m.sent_at < r.created_at + INTERVAL '7 days'
),
call_events AS (
    SELECT 
        c.response_id,
        c.employer_id,
        c.call_id::text AS event_id, 
        c.call_at AS event_at,
        'call' AS event_type
    FROM calls c
    JOIN responses r 
    	ON c.response_id = r.response_id
    WHERE c.caller_role = 'employer'
      AND c.call_at >= r.created_at 
      AND c.call_at < r.created_at + INTERVAL '7 days'
),
all_events AS (
    SELECT * FROM message_events
    UNION ALL
    SELECT * FROM call_events
)
SELECT 
    COUNT(*) AS total_events,
    COUNT(DISTINCT response_id) AS responses_with_events,
    COUNT(*) FILTER (WHERE event_type = 'call') AS total_calls,
    COUNT(*) FILTER (WHERE event_type = 'message') AS total_messages
FROM all_events;

-- Контрольные значения:
-- Общее количество событий - 1096
-- Количество различных откликов с коммуникацией - 382
-- Количество звонков - 108
-- Количество сообщений - 988

-- В первые 7 дней после отклика работодатели гораздо чаще используют переписку (988 сообщений), чем звонки (108 звонков)
-- Отдельно хочу подчеркнуть, что 8 потерянных звонков из первого блока в этот результат не попали!

-- ЗАДАНИЕ 3. Таймлайн коммуникаций и витрина отклика
WITH all_events AS (
    SELECT 
        m.response_id, 
        m.employer_id, 
        m.message_id::text AS event_id, 
        m.sent_at AS event_at, 
        'message' AS event_type
    FROM messages m 
    JOIN responses r ON m.response_id = r.response_id
    WHERE m.sender_role = 'employer' 
        AND m.sent_at >= r.created_at 
        AND m.sent_at < r.created_at + INTERVAL '7 days'
    UNION ALL
    SELECT 
        c.response_id, 
        c.employer_id, 
        c.call_id::text, 
        c.call_at, 
        'call'
    FROM calls c 
    JOIN responses r ON c.response_id = r.response_id
    WHERE c.caller_role = 'employer' 
        AND c.call_at >= r.created_at 
        AND c.call_at < r.created_at + INTERVAL '7 days'
),
event_timeline AS (
    SELECT 
        response_id, 
        employer_id, 
        event_id, 
        event_at, 
        event_type,
        ROW_NUMBER() OVER (PARTITION BY response_id ORDER BY event_at, event_type, event_id) AS event_number,
        LAG(event_at) OVER (PARTITION BY response_id ORDER BY event_at, event_type, event_id) AS prev_event_at,
       
        -- ДОРАБОТКА: добавил недостающее поле "тип следующего события"
        LEAD(event_type) OVER (PARTITION BY response_id ORDER BY event_at, event_type, event_id) AS next_event_type,
        
        COUNT(*) OVER (PARTITION BY response_id ORDER BY event_at, event_type, event_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS events_so_far,
        FIRST_VALUE(event_type) OVER (PARTITION BY response_id ORDER BY event_at, event_type, event_id) AS first_event_type,
        LAST_VALUE(event_type) OVER (PARTITION BY response_id ORDER BY event_at, event_type, event_id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_event_type
    FROM all_events
),
response_stats AS (
    SELECT 
        r.response_id,
        v.employer_id,
        v.professional_role,
        r.status,
        COUNT(e.event_id) AS total_communications,
        COUNT(e.event_id) FILTER (WHERE e.event_type = 'call') AS total_calls,
        COUNT(e.event_id) FILTER (WHERE e.event_type = 'message') AS total_messages,
        MIN(e.event_at) AS first_comm_at,
        EXTRACT(EPOCH FROM (MIN(e.event_at) - r.created_at)) / 3600 AS hours_first_comm,
        MAX(EXTRACT(EPOCH FROM (e.event_at - e.prev_event_at)) / 3600) AS max_interval_hours,
        MAX(e.event_type) FILTER (WHERE e.event_number = 1) AS first_event_type,
        MAX(e.event_type) FILTER (WHERE e.event_number = 2) AS second_event_type,
        MAX(e.last_event_type) AS last_event_type
    FROM responses r
    LEFT JOIN vacancies v ON r.vacancy_id = v.vacancy_id
    LEFT JOIN event_timeline e ON r.response_id = e.response_id
    GROUP BY r.response_id, v.employer_id, v.professional_role, r.status, r.created_at
)
SELECT 
    COUNT(*) AS total_responses,
    COUNT(*) FILTER (WHERE total_communications > 0) AS responses_with_comm,
    COUNT(*) FILTER (WHERE total_communications = 0) AS responses_without_comm,
    COUNT(*) FILTER (WHERE first_event_type = 'message') AS first_was_message,
    COUNT(*) FILTER (WHERE first_event_type = 'call') AS first_was_call
FROM response_stats;

-- ВЫВОД:
-- Всего в витрине 628 строк по одной на каждый отклик.
-- И из них 382 отклика имеют хотя бы одну коммуникацию, а 246 остались без ответа.
-- В 314 случаях работодатель сначала писал сообщение и только в 68 случаях звонил.
-- Это еще раз подтверждает, что переписка более популярный первый шаг.

-- ============================================================
-- БЛОК В. Сравнение работодателей
-- ============================================================

-- ЗАДАНИЕ 4. Рейтинг работодателей внутри направления
WITH response_stats AS (
    SELECT 
        r.response_id, 
        v.employer_id, 
        v.professional_role, 
        r.status,
        COUNT(e.event_id) AS total_communications,
        EXTRACT(EPOCH FROM (MIN(e.event_at) - r.created_at)) / 3600 AS hours_first_comm
    FROM responses r
    LEFT JOIN vacancies v 
    	ON r.vacancy_id = v.vacancy_id
    LEFT JOIN (
        SELECT 
        	m.response_id, 
        	m.message_id::text AS event_id, 
        	m.sent_at AS event_at
        FROM messages m 
        JOIN responses r2 
        	ON m.response_id = r2.response_id
        WHERE m.sender_role = 'employer' 
            AND m.sent_at >= r2.created_at 
            AND m.sent_at < r2.created_at + INTERVAL '7 days'
        UNION ALL
        SELECT 
        	c.response_id, 
        	c.call_id::text, 
        	c.call_at
        FROM calls c 
        JOIN responses r2 
        	ON c.response_id = r2.response_id
        WHERE c.caller_role = 'employer' 
            AND c.call_at >= r2.created_at 
            AND c.call_at < r2.created_at + INTERVAL '7 days'
    ) e ON r.response_id = e.response_id
    GROUP BY 
    	r.response_id, 
    	v.employer_id, 
    	v.professional_role, 
    	r.status, 
    	r.created_at
),
employer_metrics AS (
    SELECT 
        professional_role,
        employer_id,
        COUNT(*) AS total_responses,
        ROUND(100.0 * COUNT(*) FILTER (WHERE total_communications > 0) / COUNT(*), 1) AS processed_share,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY hours_first_comm) 
            FILTER (WHERE total_communications > 0)::numeric, 1) AS median_hours_first,
        ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY hours_first_comm) 
            FILTER (WHERE total_communications > 0)::numeric, 1) AS p90_hours_first,
        ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'invited') / COUNT(*), 1) AS conversion_pct
    FROM response_stats
    GROUP BY professional_role, employer_id
),
filtered_employers AS (
    SELECT * FROM employer_metrics
    WHERE total_responses >= 8
),
ranked AS (
    SELECT 
        professional_role, 
        employer_id, 
        processed_share, 
        median_hours_first,
        -- ДОРАБОТКА: использую DENSE_RANK(), потому что места не должны пропускаться
        DENSE_RANK() OVER (
            PARTITION BY professional_role 
            ORDER BY 
            	processed_share DESC, 
            	median_hours_first ASC
        ) AS place
    FROM filtered_employers
)
SELECT 
    professional_role, 
    place, 
    employer_id,
    processed_share
FROM ranked
WHERE place <= 2
ORDER BY 
	professional_role, 
	place;

-- ДОРАБОТКА: 
-- Вывод:
-- После фильтрации и ранжирования по DENSE_RANK(), в топ-2 по каждому направлению попали:
-- 1. «Аналитик данных»: 1-е место - 109, 2-е место - 103.
-- 2. «Дата-инженер»: 1-е место - 106, 2-е место - 101.
-- 3. «Продуктовый аналитик»: 1-е место - 103, 2-е место - 102.
-- 4. «Разработчик»: 1-е место - 112, 2-е место - 104.
-- 5. «Тестировщик»: 1-е место - 107, 2-е место - 108.

-- Отдельно я решил проверить, насколько велик разброс по доле обработанных откликов. 
-- Оказалось, что он очень большой. Например, у лидера в «Аналитике данных» (109) - 89.5%, 
-- а у компании на 2-м месте в «Дата-инженере» (101) всего 45.8%. 
-- Это значит, что различия между работодателями действительно большие, 
-- просто они проявляются не в скорости ответа, а в том, 
-- обрабатывают они отклики вообще или игнорируют половину.

-- ЗАДАНИЕ 5. Скорость ответа работодателя в переписке
WITH message_pairs AS (
    SELECT 
        m.employer_id,
        m.sender_role,
        m.sent_at AS employer_msg_at,
        LAG(m.sender_role) OVER (PARTITION BY m.response_id ORDER BY m.sent_at, m.message_id) AS prev_sender,
        LAG(m.sent_at) OVER (PARTITION BY m.response_id ORDER BY m.sent_at, m.message_id) AS prev_msg_at
    FROM messages m
    JOIN responses r ON m.response_id = r.response_id
    WHERE m.sent_at >= r.created_at AND m.sent_at < r.created_at + INTERVAL '7 days'
),
response_times AS (
    SELECT 
        employer_id,
        EXTRACT(EPOCH FROM (employer_msg_at - prev_msg_at)) / 3600 AS response_hours
    FROM message_pairs
    WHERE sender_role = 'employer' AND prev_sender = 'applicant'
),
employer_speed AS (
    SELECT 
        employer_id,
        COUNT(*) AS measured_responses,
        ROUND(AVG(response_hours)::numeric, 1) AS avg_response_hours,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY response_hours)::numeric, 1) AS median_response_hours,
        ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY response_hours)::numeric, 1) AS p90_response_hours
    FROM response_times
    GROUP BY employer_id
)
SELECT * FROM employer_speed
ORDER BY median_response_hours ASC;

-- ВЫВОД:
-- Всего было найдено 749 ситуаций, когда кандидат писал сообщение и ему отвечал работодатель
-- Быстрее всех отвечает компания с ID 107 - в среднем по медиане она тратит на ответ 3.9 часа,
-- а компания с ID 102 оказалась самой медленной, ее медиана всего 4.9 часа
-- 90-й перцентиль показывает, что в 90% случаев все компании 
-- отвечают максимум за 13-20 часов, то есть даже самые медленные в основном укладываются 
-- в один рабочий день

-- ============================================================
-- БЛОК Г. Сложные типы данных
-- ============================================================

-- ЗАДАНИЕ 6.1. Теги звонков
WITH valid_calls AS (
    SELECT 
        c.call_id, 
        c.call_tags
    FROM calls c
    JOIN responses r ON c.response_id = r.response_id
    WHERE c.caller_role = 'employer' 
      AND c.call_at >= r.created_at 
      AND c.call_at < r.created_at + INTERVAL '7 days'
      AND NOT (c.status = 'unsuccessful' AND 'connected' = ANY(c.call_tags))
)
SELECT 
    COUNT(*) FILTER (WHERE 'screening' = ANY(call_tags)) AS screening_cnt,
    COUNT(*) FILTER (WHERE 'interview' = ANY(call_tags)) AS interview_cnt,
    COUNT(*) FILTER (WHERE 'follow_up' = ANY(call_tags)) AS follow_up_cnt,
    COUNT(*) FILTER (WHERE 'details' = ANY(call_tags)) AS details_cnt,
    COUNT(*) FILTER (WHERE 'screening' = ANY(call_tags) 
    	OR 'interview' = ANY(call_tags)
    	OR 'follow_up' = ANY(call_tags) 
    	OR 'details' = ANY(call_tags)) AS calls_with_any_biz_tag,
    ROUND(AVG(CARDINALITY(call_tags))::numeric, 1) AS avg_tags_per_call
FROM valid_calls;

-- ДОРАБОТКА: 
-- Вывод:
-- Всего нашлось 108 звонков, у которых есть хотя бы один бизнес-тег.
-- Самым частым оказался "interview" - 31 раз, то есть чаще всего фиксируется 
-- именно приглашение на собеседование. Следом идут "follow_up" - 29 раз
-- и "screening" - 25 раз, а реже всего ставится "details" - 23 раза.
-- Если сложить все эти бизнес-теги, то получится ровно 108. 
-- Получается, что на каждый звонок приходится ровно один бизнес-тег. 
-- То есть работодатель не ставит сразу несколько смысловых тегов, 
-- он выбирает один, чтобы отметить этап

-- ЗАДАНИЕ 6.2. Метаданные сообщений
WITH msg_meta AS (
    SELECT 
        COALESCE(m.message_meta ->> 'channel', 'unknown') AS channel,
        m.message_meta ->> 'is_read' AS is_read_str,
        COALESCE(jsonb_array_length(m.message_meta -> 'attachments'), 0) AS attachments_cnt
    FROM messages m
    JOIN responses r 
    	ON m.response_id = r.response_id
    WHERE m.sender_role = 'employer' 
    	AND m.sent_at >= r.created_at 
    	AND m.sent_at < r.created_at + INTERVAL '7 days'
)
SELECT 
    channel,
    COUNT(*) AS total_msgs,
    COUNT(*) FILTER (WHERE is_read_str IS NOT NULL) AS known_read_status,
    COUNT(*) FILTER (WHERE is_read_str = 'false') AS unread_msgs,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_read_str = 'false') / NULLIF(COUNT(*) FILTER (WHERE is_read_str IS NOT NULL), 0), 1) AS unread_share,
    COUNT(*) FILTER (WHERE attachments_cnt > 0) AS msgs_with_attach,
    ROUND(100.0 * COUNT(*) FILTER (WHERE attachments_cnt > 0) / COUNT(*), 1) AS attach_share
FROM msg_meta
GROUP BY channel
ORDER BY total_msgs DESC;

-- ВЫВОД:
-- В базе оказалось всего два канала связи - это веб-версия и мобильное приложение
-- Больше всего сообщений отправлено через веб 628 штук, а через приложение 360 и статус прочтения известен у всех сообщений
-- В веб-версии непрочитанными остаются 52 сообщения (8.3%), а в приложении 36 (10%)
-- Вложения встречаются достаточно редко: 4% сообщений в вебе (25 штук) и 3.9% в приложении (14 штук). 
-- Получается, можно сказать, что веб-версия используется чаще, чем мобильное приложение

-- ============================================================
-- БЛОК Д. Самостоятельное исследование
-- ============================================================

-- ЗАДАНИЕ 7. Что связано с приглашением?

-- В своей первой гипотезе я решил проверить, влияет ли скорость ответа и инициатива работодателя на то, 
-- получит кандидат приглашение или нет, потому что мне показалось логичным, что если компания отвечает быстро 
-- и сама звонит первой, то она более заинтересована в кандидате 
-- Гипотеза 1
WITH all_events AS (
    SELECT 
        m.response_id, 
        m.message_id::text AS event_id, 
        m.sent_at AS event_at, 
        'message' AS event_type
    FROM messages m 
    JOIN responses r 
    	ON m.response_id = r.response_id
    WHERE m.sender_role = 'employer' 
        AND m.sent_at >= r.created_at 
        AND m.sent_at < r.created_at + INTERVAL '7 days'
    UNION ALL
    SELECT 
        c.response_id, 
        c.call_id::text, 
        c.call_at, 
        'call'
    FROM calls c 
    JOIN responses r 
    	ON c.response_id = r.response_id
    WHERE c.caller_role = 'employer' 
        AND c.call_at >= r.created_at 
        AND c.call_at < r.created_at + INTERVAL '7 days'
),
event_timeline AS (
    SELECT 
        response_id, 
        event_at, 
        event_type,
        ROW_NUMBER() OVER (PARTITION BY response_id ORDER BY event_at, event_type, event_id) AS event_number
    FROM all_events
),
response_stats AS (
    SELECT 
        r.response_id, 
        CASE 
            WHEN r.status = 'invited' 
            THEN 'Приглашенные' 
            ELSE 'Без приглашения' 
            END AS group_name,
        EXTRACT(EPOCH FROM (MIN(e.event_at) - r.created_at)) / 3600 AS hours_first_comm,
        MAX(e.event_type) FILTER (WHERE e.event_number = 1) AS first_event_type
    FROM responses r
    LEFT JOIN event_timeline e 
    	ON r.response_id = e.response_id
    GROUP BY 
    	r.response_id, 
    	r.status, 
    	r.created_at
)
SELECT 
    group_name,
    COUNT(*) AS responses_count,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY hours_first_comm)::numeric, 1) AS median_hours_to_first,
    -- ДОРАБОТКА: считаю долю звонков первыми только от тех, где была коммуникация 
    COUNT(*) FILTER (WHERE first_event_type IS NOT NULL) AS responses_with_comm_for_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE first_event_type = 'call') 
          / NULLIF(COUNT(*) FILTER (WHERE first_event_type IS NOT NULL), 0), 1) AS pct_first_call_from_comm
FROM response_stats
GROUP BY group_name;

-- ДОРАБОТКА: 
-- Вывод по гипотезе 1:
-- Гипотеза не подтверждается, потому что медиана времени до первого ответа у приглашенных (51.1 ч) 
-- и у остальных (54.7 ч) отличается незначительно. 
-- Я пересчитал долю звонков первыми, до этого я делил на все отклики в группе, включая те, 
-- где вообще не было коммуникации и поэтому процент был занижен. 
-- Теперь я делю только на те отклики, где коммуникация была.
-- У приглашенных таких откликов 54 из 92, а у остальных 328 из 536.
-- В итоге доля звонков первыми составила 20.4% у приглашенных и 17.4% у остальных.
-- Это значит, что в данных нет заметной связи между скоростью ответа, инициативой и приглашением.

-- Во второй гипотезе я решил проверить, не влияет ли на приглашение длительность звонка между соискателем и работодателем.
-- Возможно, приглашение чаще получают те, с кем дольше вели диалог и у кого были длительные разговоры.
WITH all_events AS (
    SELECT 
        m.response_id, 
        m.message_id::text AS event_id, 
        m.sent_at AS event_at, 
        'message' AS event_type, 
        NULL::integer AS call_duration
    FROM messages m 
    JOIN responses r 
    	ON m.response_id = r.response_id
    WHERE m.sender_role = 'employer' 
    	AND m.sent_at >= r.created_at 
   		AND m.sent_at < r.created_at + INTERVAL '7 days'
    UNION ALL
    SELECT 
        c.response_id, 
        c.call_id::text, 
        c.call_at, 
        'call', 
        CASE 
	        WHEN c.status = 'successful' 
	        THEN c.call_duration 
	        ELSE NULL 
	        END
    FROM calls c 
    JOIN responses r 
    	ON c.response_id = r.response_id
    WHERE c.caller_role = 'employer' 
    	AND c.call_at >= r.created_at 
    	AND c.call_at < r.created_at + INTERVAL '7 days'
),
event_timeline AS (
    SELECT 
        response_id, 
        event_at, 
        event_type, 
        call_duration,
        ROW_NUMBER() OVER (PARTITION BY response_id ORDER BY event_at, event_type, event_id) AS event_number
    FROM all_events
),
response_stats AS (
    SELECT 
        r.response_id, 
        CASE 
	        WHEN r.status = 'invited' 
	        THEN 'Приглашенные' 
	        ELSE 'Без приглашения' 
	        END AS group_name,
        COUNT(e.event_at) AS total_comm,
        EXTRACT(EPOCH FROM (MAX(e.event_at) - r.created_at)) / 3600 AS hours_last_comm,
        ROUND(AVG(e.call_duration)::numeric, 1) AS avg_call_duration_sec
    FROM responses r
    LEFT JOIN event_timeline e 
    	ON r.response_id = e.response_id
    GROUP BY r.response_id, r.status, r.created_at
)
SELECT 
    group_name,
    COUNT(*) AS responses_count,
    ROUND(AVG(total_comm)::numeric, 1) AS avg_comm,
    ROUND(AVG(hours_last_comm)::numeric, 1) AS avg_hours_last_comm,
    ROUND(AVG(avg_call_duration_sec)::numeric, 1) AS avg_call_duration_sec
FROM response_stats
GROUP BY group_name;

-- Вывод по гипотезе 2:
-- Гипотеза также не подтверждается, потому что среднее число коммуникаций в успешных откликах (1.6) 
-- даже чуть меньше, чем в неуспешных (1.8)
-- Время до последнего контакта (90.2 ч против 92.3 ч) и средняя длительность 
-- звонков (437.2 сек против 462.6 сек) также практически не отличаются, а это значит, 
-- что объем переписки и длительность диалога сами по себе не гарантируют приглашение

-- ============================================================
-- ЗАДАНИЕ 8. Итог исследования
-- ============================================================
-- ДОРАБОТКА: 
-- Вывод для продакт-менеджера:
-- В ходе работы был проведен аудит коммуникаций между работодателями и кандидатами в первые 7 дней после отклика. 
-- В самом начале я обнаружил 8 звонков, которые не привязаны ни к одному отклику и исключил их из анализа.
-- Выяснилось, что работодатели гораздо чаще предпочитают переписку (988 сообщений), 
-- чем звонки (108 звонков), но при этом 246 откликов из 628 остаются вообще без ответа.
-- Разница между работодателями большая, но не в скорости ответа, так как медиана у всех компаний примерно 4-5 часов, 
-- а в доле обработанных откликов. В задании 4 видно, что у лидера в «Аналитике данных» (компания 109) обработано 89.5% откликов, 
-- а у компании на 2-м месте в «Дата-инженере» (101) всего 45.8%, то есть одни компании отвечают почти на все отклики, 
-- а другие обрабатывают меньше половины. 
-- Мои гипотезы не подтвердились. Я не нашел явной связи между скоростью ответа, инициативой работодателя 
-- или количеством сообщений и фактом приглашения на собеседование. Отклики, которые закончились приглашением (status = 'invited'), 
-- по этим параметрам практически не отличаются от всех остальных (отказы, просмотры, новые отклики) 
-- Ограничение анализа: нет данных о содержании резюме кандидатов и требованиях компаний, 
-- поэтому видно только факт общения, но не реальные причины выбора кандидата. Чтобы лучше понять, 
-- почему одних приглашают, а других нет, я бы добавил данные о соответствии навыков кандидата требованиям вакансии.
