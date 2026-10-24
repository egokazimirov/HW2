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
-- В результате было выведено 0 строк, а это значит,
-- что таблица messages в порядке и не имеет утерянных данных

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
-- По итогу оба запроса выдали 0 строк, а это значит, что в данных нет несостыковок и связи между таблицами
-- в этом плане корректны

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
-- Оба запроса также выдали 0, а это значит, что в базе нет звонков или сообщений, 
-- которые произошли бы раньше самого отклика, поэтому при расчете времени ответа отрицательных значений не будет

SELECT count(*) AS invalid_duration_calls
FROM calls
WHERE (status = 'successful' AND (call_duration IS NULL OR call_duration <= 0))
   OR (status != 'successful' AND call_duration IS NOT NULL);
-- В результате выведено 0 строк, а это значит, что логика статусов и длительностей звонков не нарушена

SELECT count(*) AS messages_without_meta
FROM messages 
WHERE message_meta IS NULL;

SELECT count(*) AS calls_without_tags
FROM calls 
WHERE call_tags IS NULL;
-- Пропусков нет и все метаданные и теги на месте

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
    (SELECT ROUND(p99::numeric, 1) FROM p99_calc) AS p99_duration,
    COUNT(*) FILTER (WHERE call_duration > (SELECT p99 FROM p99_calc)) AS outlier_count,
    ROUND(AVG(call_duration) FILTER (WHERE call_duration <= (SELECT p99 FROM p99_calc)), 1) AS avg_without_outliers
FROM valid_calls;
-- Всего выведено 181 валидный звонок, средняя длительность составила 467.3 секунды, 
-- а медиана - 438 секунды. 99-й перцентиль равен 890.4 секунде, а также 
-- найдено 2 выброса (звонки дольше 890 секунд) и если их убрать, то средняя упадет до 462.5 секунды

-- Общий вывод по первому блоку:
-- В ходе аудита была обнаружена одна критическая проблема, а конкретно 8 звонков в таблице calls 
-- имеют response_id, которого нет в таблице responses, то есть эти звонки невозможно 
-- привязать к конкретному отклику и поэтому из-за этой ошибки в данных, в последующих заданиях 
-- нужно отфильтровать эти 8 звонков, чтобы они не искажали статистику. Других проблем не выявлено

-- Значения выше 99-го перцентиля я считаю допустимыми выбросами, а не ошибками, потому что это могли быть 
-- действительно долгие собеседования или технические обсуждения. 
-- Однако при расчете типичной длительности звонка я бы исключил их из выборки, потому что из цифр видно,
-- что они завышают среднюю (467.3) по сравнению с медианой (438), поэтому для описания типичного звонка надежнее 
-- опираться на медиану, либо на среднюю без учета выбросов

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
    JOIN responses r 
    	ON m.response_id = r.response_id
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
    JOIN responses r 
    	ON c.response_id = r.response_id
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
    LEFT JOIN vacancies v 
    	ON r.vacancy_id = v.vacancy_id
    LEFT JOIN event_timeline e 
    	ON r.response_id = e.response_id
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
-- Всего в витрине оказалось 628 строк и из них 382 отклика имеют хотя бы одну коммуникацию, 
-- а 246 откликов остались без ответа работодателя
-- Также можно отметить, что в 314 случаях работодатель сначала 
-- писал сообщение и только в 68 случаях первым делом звонил
-- Это еще раз подтверждает вывод с прошлого блока, что переписка более популярный 
-- первый шаг для связи с кандидатом

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
        SELECT m.response_id, 
        m.message_id::text AS event_id, 
        m.sent_at AS event_at
        FROM messages m 
        JOIN responses r2 
        	ON m.response_id = r2.response_id
        WHERE m.sender_role = 'employer' 
        	AND m.sent_at >= r2.created_at 
        	AND m.sent_at < r2.created_at + INTERVAL '7 days'
        UNION ALL
        SELECT c.response_id, 
        c.call_id::text, 
        c.call_at
        FROM calls c 
        JOIN responses r2 
        	ON c.response_id = r2.response_id
        WHERE c.caller_role = 'employer' 
        	AND c.call_at >= r2.created_at 
        	AND c.call_at < r2.created_at + INTERVAL '7 days'
    ) e ON r.response_id = e.response_id
    GROUP BY r.response_id, v.employer_id, v.professional_role, r.status, r.created_at
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
        RANK() OVER (
            PARTITION BY professional_role 
            ORDER BY processed_share DESC, median_hours_first ASC
        ) AS place
    FROM filtered_employers
)
SELECT 
    professional_role, 
    place, 
    employer_id 
FROM ranked
WHERE place <= 2
ORDER BY professional_role, place;

-- ВЫВОД:
-- После фильтрации компаний в топ-2 попали следующие работодатели:
-- В направлении «Аналитик данных»: 1-е место компания 109, 2-е место компания 103
-- В направлении «Дата-инженер»: 1-е место компания 106, 2-е место компания 101
-- В направлении «Продуктовый аналитик»: 1-е место компания 103, 2-е место компания 102.

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

-- Вывод:
-- Всего нашлось 108 звонков, у которых есть хотя бы один бизнес-тег.
-- Самым частым оказался "interview" (31 раз), то есть чаще всего 
-- фиксируется именно приглашение на собеседование, следом идут "follow_up" (29) 
-- и "screening" (25), а реже всего ставится "details" (23), но при этом в среднем на каждый звонок 
-- приходится по 4 тега, а это значит, что работодатели не ограничиваются одним тегом, 
-- чтобы точнее понимать, на каком этапе находится кандидат.

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
    SELECT c.response_id, 
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
    GROUP BY r.response_id, r.status, r.created_at
)
SELECT 
    group_name,
    COUNT(*) AS responses_count,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY hours_first_comm)::numeric, 1) AS median_hours_to_first,
    ROUND(100.0 * COUNT(*) FILTER (WHERE first_event_type = 'call') / COUNT(*), 1) AS pct_first_call
FROM response_stats
GROUP BY group_name;

-- Вывод по гипотезе 1:
-- Гипотеза не подтверждается, потому что медиана времени до первого ответа у приглашенных составила 51.1 час, 
-- а у откликов без приглашения 54.7 часа (разница в 3.6 часа),то есть работодатели не отвечают быстрее тем, 
-- кого в итоге приглашают
-- Также гипотеза не подтверждается, потому что доля звонков, где работодатель сам звонит первым, у приглашенных (12%),
-- а без приглашения (10.6%), значит, что инициативность работодателя тоже не влияет на успех

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

-- Вывод для продакт-менеджера:
-- В ходе работы был проведен аудит коммуникаций между работодателями и кандидатами в первые 7 дней после отклика. 
-- В самом начале я обнаружил 8 звонков, которые не привязаны ни к одному отклику и я их исключил, чтобы они не искажали статистику. 
-- Выяснилось, что работодатели гораздо чаще предпочитают переписку (988 сообщений), чем звонки (108 звонков),
-- но при этом 246 откликов из 628 остаются без какого-либо ответа от компании.
-- Компании сильно различаются по скорости, например, если смотреть на скорость ответа в переписке, то
-- самая быстрая отвечает в среднем за 3.9 часа, а самая медленная за 4.9 часа.
-- Также я выяснил, что в направлении "Аналитик данных" лучшие компании по обработке откликов - это ID 109 и ID 103.
-- Оказалось, что вообще неважно, как быстро компания ответила, кто начал общение первым 
-- и сколько раз они переписывались и получается, что те, кого в итоге пригласили, по всем 
-- этим параметрам ничем не отличаются от тех, кому отказали.
-- Ограничение анализа: нет данных о содержании резюме кандидатов и требованиях компаний, 
-- поэтому можно увидеть только факт общения, но не реальные причины выбора кандидата и чтобы лучше понять
-- почему одних приглашают, а других нет, я бы добавил данные о соответствии навыков кандидата требованиям вакансии.
