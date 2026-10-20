# Сбор логов и метрик с помощью Beats

Filebeat, Metricbeat и Heartbeat отправляют данные в Elasticsearch, просмотр - в Kibana.
Стенд разделён на два docker compose стека, каждый соответствует одной виртуальной машине из задания.

| Стек | Роль | Компоненты |
|------|------|------------|
| `vm1-cms` | ВМ с CMS | WordPress (php-fpm), nginx, MySQL, filebeat, metricbeat |
| `vm2-elk` | ВМ мониторинга | Elasticsearch, Kibana, heartbeat |

```
vm1-cms                                   vm2-elk
nginx - php-fpm - mysql                   Elasticsearch <-- Kibana
  |        |        |                          ^
  +-- logs-+--------+                          |
        filebeat ------------------------------+
        metricbeat (VM, nginx, mysql) ---------+
                                       heartbeat +-- http://nginx/, mysql:3306
```

## Структура

```
vm1-cms/
  docker-compose.yml
  .env.example
  nginx/default.conf
  php-fpm/zzz-logs.conf
  mysql/lab.cnf, mysql/init/01-metricbeat.sql
  filebeat/filebeat.yml
  metricbeat/metricbeat.yml
vm2-elk/
  docker-compose.yml
  .env.example
  heartbeat/heartbeat.yml
  scripts/setup-es.sh           # ILM-политики и шаблоны индексов
  scripts/create-data-views.sh  # data views в Kibana
screenshots/
```

## Требования

- Docker с Compose v2
- около 3 ГБ свободной памяти
- на Linux-хосте: `sudo sysctl -w vm.max_map_count=262144`

## Запуск

Общая сеть, через которую стеки видят друг друга:

```bash
docker network create lab-net
```

Сначала вторая ВМ (Elasticsearch, Kibana, ILM, heartbeat):

```bash
cd vm2-elk
cp .env.example .env
docker compose up -d
```

Затем первая ВМ:

```bash
cd ../vm1-cms
cp .env.example .env
docker compose up -d
```

Первая ВМ должна стартовать после второй: шаблоны индексов с ILM создаются при запуске
`vm2-elk` и должны существовать к моменту, когда filebeat создаст первые индексы.

WordPress доступен на http://localhost:8080 (при первом открытии - мастер установки),
Kibana - на http://localhost:5601.

## Генерация данных для проверки

```bash
# access-логи nginx и php-fpm
for i in $(seq 1 30); do curl -s -o /dev/null http://localhost:8080/; done

# ошибка 404 и запись в error-лог nginx
curl -s -o /dev/null http://localhost:8080/missing.php

# запись в slow log MySQL
docker compose -f vm1-cms/docker-compose.yml exec mysql \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT SLEEP(2);"'
```

Когда данные появились, создать data views:

```bash
./vm2-elk/scripts/create-data-views.sh
```

## Что где настроено

### 1. CMS

WordPress на php-fpm (`wordpress:php8.2-fpm`), nginx и MySQL 8.0 - `vm1-cms/docker-compose.yml`.

### 2. Filebeat и Metricbeat

Filebeat (`vm1-cms/filebeat/filebeat.yml`) читает файлы логов:

| Источник | Файл |
|----------|------|
| nginx access / error | `/var/log/lab-nginx/access.log`, `error.log` |
| php-fpm | `/var/log/php-fpm/access.log`, `error.log` |
| MySQL | `/var/log/mysql/error.log`, `slow.log` (многострочные записи собираются через multiline) |

Логи пишутся в именованные тома, которые смонтированы в контейнер filebeat на чтение.
Php-fpm и MySQL настроены на запись в файлы: `php-fpm/zzz-logs.conf`, `mysql/lab.cnf`.

Индексы: `lab-logs-nginx-*`, `lab-logs-phpfpm-*`, `lab-logs-mysql-*`.

Metricbeat (`vm1-cms/metricbeat/metricbeat.yml`):

- модуль `system` - cpu, load, memory, network, process, process_summary, uptime, filesystem, fsstat (данные хоста читаются через `/hostfs`);
- модуль `nginx` - метрики `stubstatus` (эндпоинт `/server-status`, доступен только из внутренних сетей);
- модуль `mysql` - метрики `status`, отдельный пользователь `metricbeat` с правами `PROCESS, REPLICATION CLIENT` создаётся скриптом `mysql/init/01-metricbeat.sql`.

### 3. Elasticsearch, Kibana, Heartbeat

Запускаются в `vm2-elk/docker-compose.yml`. Heartbeat (`vm2-elk/heartbeat/heartbeat.yml`) проверяет:

- HTTP-доступность адреса CMS (`CMS_URL`);
- TCP-доступность порта базы данных (`DB_ADDR`).

Адреса задаются в `vm2-elk/.env`.

### 4. ILM (доп. задание)

`vm2-elk/scripts/setup-es.sh` создаёт две политики с фазой delete и шаблоны индексов,
которые привязывают их к индексам логов:

| Индексы | Политика | Хранение |
|---------|----------|----------|
| `lab-logs-nginx-*` | `logs-30d` | 30 дней |
| `lab-logs-mysql-*` | `logs-30d` | 30 дней |
| `lab-logs-phpfpm-*` | `logs-14d` | 14 дней |

Индексы создаются по дням, поэтому rollover не нужен, отсчёт `min_age` идёт от создания индекса.
Проверка:

```bash
curl -s 'localhost:9200/lab-logs-*/_ilm/explain?pretty' | grep -E '"index"|"policy"'
curl -s 'localhost:9200/_ilm/policy/logs-30d?pretty'
curl -s 'localhost:9200/_ilm/policy/logs-14d?pretty'
```

### 5. Dissect для nginx (доп. задание)

Для access-лога nginx в `filebeat.yml` используется процессор `dissect`. Строка в формате combined
разбирается на поля (`client.ip`, `http.request.method`, `url.original`,
`http.response.status_code`, `user_agent.original` и т.д.), после чего `convert` приводит статус и размер
к числам, а `timestamp` берёт `@timestamp` из времени запроса. В Elasticsearch документ сохраняется
в виде структурированного JSON. Строки, не подходящие под шаблон (например, битые запросы),
сохраняются как есть, в поле `message`.

Проверка:

```bash
curl -s 'localhost:9200/lab-logs-nginx-*/_search?size=1&q=log_type:access&pretty'
```

## Проверка в Kibana

1. Discover, data view `logs: nginx` / `logs: php-fpm` / `logs: mysql` - логи.
2. Discover, data view `metrics` - метрики `system.*`, `nginx.stubstatus.*`, `mysql.status.*`.
3. Discover, data view `heartbeat` - поле `monitor.status` (`up` / `down`) для `CMS web` и `CMS database port`.
   Остановка `docker compose -f vm1-cms/docker-compose.yml stop mysql` переводит проверку порта в `down`.

Скриншоты лежат в каталоге `screenshots/`.

## Запуск на отдельных ВМ

Если стеки разворачиваются на разных машинах, общая сеть `lab-net` не нужна:

- в `vm1-cms/.env` указать `ES_HOST=http://<IP второй ВМ>:9200`;
- в `vm2-elk/.env` указать `CMS_URL=http://<IP первой ВМ>:8080/` и `DB_ADDR=<IP первой ВМ>:3306`;
- опубликовать порт 3306 у сервиса `mysql` в `vm1-cms/docker-compose.yml` (`ports: ["3306:3306"]`);
- убрать секцию `networks` из compose-файлов.

## Примечания

- Для упрощения стенда в Elasticsearch отключена аутентификация (`xpack.security.enabled=false`). В рабочей среде её необходимо включать и передавать учётные данные в `output.elasticsearch` каждого Beat.
- Пароли в `.env.example` и пользователь `metricbeat` учебные.
