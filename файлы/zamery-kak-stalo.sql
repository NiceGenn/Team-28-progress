-- ===========================================================================
-- ЗАМЕРЫ «КАК СТАЛО» — одна выгрузка на все цифры справки и карточки
--
-- ЗАПУСК НА СТЕНДЕ, PowerShell. Два шага: положить файл внутрь контейнера
-- с базой и выполнить его там.
--
--   docker cp .\замеры_как_стало.sql tp2_db:/tmp/z.sql
--   docker exec tp2_db psql -U radar -d radar -f /tmp/z.sql > замеры.txt
--
-- Результат окажется в файле `замеры.txt` рядом — его и присылать.
--
-- ПОЧЕМУ ИМЕННО ТАК, а не через конвейер. В PowerShell нет перенаправления
-- ввода `< файл` — это синтаксис cmd и bash, PowerShell на нём ругается.
-- А `Get-Content файл | docker exec -i …` в Windows PowerShell 5.1 портит
-- кириллицу: `$OutputEncoding` по умолчанию ASCII, и русские комментарии
-- и заголовки колонок приезжают в контейнер знаками вопроса. `docker cp`
-- копирует файл побайтно и обе беды обходит.
--
-- Скрипт ТОЛЬКО ЧИТАЕТ: ни одного INSERT, UPDATE или DELETE. Запускать на
-- боевой базе безопасно.
--
-- ПЕРИОД. Ниже задан пилот 08.09–25.09.2026 — период внедрения мероприятий
-- по карточке проекта. Меняется в одном месте, в CTE `период`.
--
-- ЧТО ИСКЛЮЧЕНО ИЗ СЧЁТА, и почему:
--   is_test = true      — заявки, помеченные оператором как тестовые;
--                         панель их тоже не считает, иначе внутренний тест
--                         администрации 20–25.07 попал бы в результат;
--   status = 'duplicate' — склеенные дубли. Заявка-дубль не исчезает
--                         (duplicate_of_id хранит ссылку), но в показателях
--                         учитывается один раз — иначе одна яма, о которой
--                         сообщили трое, даст три «решённые проблемы».
--
-- Имена событий взяты из кода: app/core/lifecycle.py — created, assigned,
-- started, completed, confirmed, auto_confirmed, reopened, rejected.
-- ===========================================================================

\pset border 2
\pset null '—'

-- Период измерения. Правится здесь и больше нигде.
CREATE TEMP VIEW период AS
SELECT '2026-09-08'::timestamptz AS c, '2026-09-26'::timestamptz AS po;

-- Заявки периода, без тестовых и без склеенных дублей.
CREATE TEMP VIEW база AS
SELECT r.*
FROM requests r, период p
WHERE r.created_at >= p.c AND r.created_at < p.po
  AND r.is_test = false
  AND r.status <> 'duplicate';

-- Ключевые моменты жизни каждой заявки — по журналу событий.
CREATE TEMP VIEW вехи AS
SELECT b.id,
       b.status,
       b.rating,
       b.sla_deadline,
       b.created_at,
       MIN(e.created_at) FILTER (WHERE e.event_type = 'assigned')  AS взята,
       MIN(e.created_at) FILTER (WHERE e.event_type IN ('completed', 'confirmed'))
                                                                    AS закрыта
FROM база b
LEFT JOIN request_events e ON e.request_id = b.id
GROUP BY b.id, b.status, b.rating, b.sla_deadline, b.created_at;

\echo
\echo '=== 1. ОБЪЁМ ==============================================='
\echo '   Всего заявок за период; из них закрыто. Идёт в справку,'
\echo '   раздел 4, и в слайд 8 презентации.'
SELECT COUNT(*)                                                        AS "заявок всего",
       COUNT(*) FILTER (WHERE status IN ('done', 'confirmed'))         AS "закрыто",
       COUNT(*) FILTER (WHERE status = 'rejected')                     AS "отклонено",
       COUNT(*) FILTER (WHERE status IN ('new','accepted','in_progress')) AS "в работе"
FROM база;

\echo
\echo '=== 2. ВРЕМЯ ПРОТЕКАНИЯ ПРОЦЕССА, дней ====================='
\echo '   Показатель «Время протекания процесса» в карточке и справке.'
\echo '   Медиана устойчивее среднего: одна забытая заявка не портит'
\echo '   картину. Мин и макс — для диапазона «от и до», как в ВПП.'
SELECT COUNT(*)                                                          AS "закрытых заявок",
       ROUND(MIN (EXTRACT(epoch FROM закрыта - created_at)) / 86400.0, 1) AS "мин, дн",
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (
              ORDER BY EXTRACT(epoch FROM закрыта - created_at)))::numeric / 86400.0, 1)
                                                                          AS "медиана, дн",
       ROUND(MAX (EXTRACT(epoch FROM закрыта - created_at)) / 86400.0, 1) AS "макс, дн"
FROM вехи WHERE закрыта IS NOT NULL;

\echo
\echo '=== 3. РЕАКЦИЯ И РАБОТА, часов ============================='
\echo '   Реакция — от подачи до «Взять в работу». Работа — от взятия'
\echo '   до закрытия. Те же две цифры показывает панель в «Статистике».'
SELECT ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (
              ORDER BY EXTRACT(epoch FROM взята - created_at)))::numeric / 3600.0, 1)
              AS "реакция, медиана ч",
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (
              ORDER BY EXTRACT(epoch FROM закрыта - взята)))::numeric / 3600.0, 1)
              AS "работа, медиана ч"
FROM вехи WHERE взята IS NOT NULL;

\echo
\echo '=== 4. ДОЛЯ ИСПОЛНЕННЫХ В СРОК, % =========================='
\echo '   Показатель карточки и справки. Считаются только заявки,'
\echo '   у которых срок вообще был установлен (sla_hours > 0).'
SELECT COUNT(*)                                                    AS "со сроком, закрытых",
       COUNT(*) FILTER (WHERE закрыта <= sla_deadline)             AS "в срок",
       ROUND(100.0 * COUNT(*) FILTER (WHERE закрыта <= sla_deadline)
             / NULLIF(COUNT(*), 0), 1)                             AS "доля, %"
FROM вехи WHERE закрыта IS NOT NULL AND sla_deadline IS NOT NULL;

\echo
\echo '=== 5. ДОЛЯ ЗАЯВОК С УСТАНОВЛЕННЫМ СРОКОМ, % ==============='
\echo '   В карточке заявлено 100 %. Проверяем фактом.'
SELECT COUNT(*)                                                  AS "заявок",
       COUNT(*) FILTER (WHERE sla_deadline IS NOT NULL)          AS "со сроком",
       ROUND(100.0 * COUNT(*) FILTER (WHERE sla_deadline IS NOT NULL)
             / NULLIF(COUNT(*), 0), 1)                           AS "доля, %"
FROM база;

\echo
\echo '=== 6. ДОЛЯ ЗАЯВОК С ФОТОФИКСАЦИЕЙ УСТРАНЕНИЯ, % ==========='
\echo '   Показатель заменил «документальное подтверждение» 17.09.'
\echo '   Фото отчёта — снимок, добавленный ПОСЛЕ взятия в работу.'
SELECT COUNT(*)                                            AS "закрытых заявок",
       COUNT(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM request_photos p
           WHERE p.request_id = в.id AND p.created_at >= в.взята))
                                                           AS "с фото устранения",
       ROUND(100.0 * COUNT(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM request_photos p
           WHERE p.request_id = в.id AND p.created_at >= в.взята))
             / NULLIF(COUNT(*), 0), 1)                     AS "доля, %"
FROM вехи в WHERE закрыта IS NOT NULL AND взята IS NOT NULL;

\echo
\echo '=== 7. ОЦЕНКА ЖИТЕЛЕМ РЕЗУЛЬТАТА, балл ====================='
\echo '   Цель — не менее 4,0. Заодно видно, сколько человек вообще'
\echo '   ответили: молчание автора закрывает заявку автоматически.'
SELECT COUNT(rating)                       AS "оценок получено",
       ROUND(AVG(rating)::numeric, 2)      AS "средняя",
       COUNT(*) FILTER (WHERE rating <= 2) AS "оценок 1–2 (возврат в работу)"
FROM база;

\echo
\echo '=== 8. ДОЛЯ ПРОБЛЕМ, ВЫЯВЛЕННЫХ ДО ОБРАЩЕНИЯ ЖИТЕЛЯ, % ====='
\echo '   ЯДРО ПРОЕКТА. Заявка считается плановым выявлением, если её'
\echo '   подал участник инициативной группы — роль staff в сервисе.'
\echo '   ЕСЛИ ЗДЕСЬ НОЛЬ — инициативные группы не заведены в панели,'
\echo '   и показатель нечем закрыть. Это первая задача недели.'
SELECT COUNT(*)                                                   AS "заявок",
       COUNT(*) FILTER (WHERE u.role = 'staff')                   AS "от инициативных групп",
       ROUND(100.0 * COUNT(*) FILTER (WHERE u.role = 'staff')
             / NULLIF(COUNT(*), 0), 1)                            AS "доля, %"
FROM база b JOIN users u ON u.id = b.author_id;

\echo
\echo '=== 9. ДЕДУПЛИКАЦИЯ: сколько повторов склеено =============='
\echo '   Подтверждает потерю 1 (перепроизводство): столько выездов'
\echo '   по одному объекту процесс раньше выполнял бы отдельно.'
SELECT COUNT(*) AS "склеено дублей за период"
FROM requests r, период p
WHERE r.duplicate_of_id IS NOT NULL
  AND r.is_test = false
  AND r.created_at >= p.c AND r.created_at < p.po;

\echo
\echo '=== 10. ОХВАТ: населённые пункты и категории ==============='
\echo '   Для слайда «Как стало» и блока масштаба в карточке.'
SELECT COUNT(DISTINCT c.name)                       AS "категорий в работе",
       COUNT(DISTINCT b.address_text)               AS "различных адресов",
       COUNT(*) FILTER (WHERE b.location IS NOT NULL) AS "заявок с координатами"
FROM база b LEFT JOIN categories c ON c.id = b.category_id;

\echo
\echo '=== 11. ТОП АДРЕСОВ — распределение по объектам ============'
\echo '   Закрывает пункт карточки «нет распределения проблем по'
\echo '   объектам возникновения»: раньше этой таблицы не существовало.'
SELECT address_text AS "адрес", COUNT(*) AS "заявок"
FROM база
WHERE address_text IS NOT NULL
GROUP BY address_text
HAVING COUNT(*) > 1
ORDER BY COUNT(*) DESC
LIMIT 10;

\echo
\echo '=== 12. ОЧЕРЕДЬ НА РАЗБОР ================================='
\echo '   Показатель «очередь необработанных сообщений»: было 2–8.'
\echo '   Это снимок на сейчас, а не за период.'
SELECT COUNT(*) FILTER (WHERE status = 'new')                AS "не разобрано",
       COUNT(*) FILTER (WHERE needs_manual_review)           AS "в ручной сортировке"
FROM requests WHERE is_test = false AND status <> 'duplicate';

\echo
\echo '=== ГОТОВО ================================================='
\echo 'Каждое число ложится в свою строку справки и карточки —'
\echo 'соответствие расписано в README.md этой папки.'
