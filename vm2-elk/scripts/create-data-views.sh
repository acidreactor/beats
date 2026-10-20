#!/bin/sh
# Создаёт data views в Kibana. Запускать после того, как в Elasticsearch пошли данные.
KIBANA="${KIBANA_URL:-http://localhost:5601}"

create() {
  curl -sS -f -X POST "$KIBANA/api/data_views/data_view" \
    -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
    -d "{\"override\":true,\"data_view\":{\"id\":\"$1\",\"name\":\"$2\",\"title\":\"$3\",\"timeFieldName\":\"@timestamp\"}}" >/dev/null \
    && echo "ok: $2"
}

create lab-logs-all     "logs: all"     "lab-logs-*"
create lab-logs-nginx   "logs: nginx"   "lab-logs-nginx-*"
create lab-logs-phpfpm  "logs: php-fpm" "lab-logs-phpfpm-*"
create lab-logs-mysql   "logs: mysql"   "lab-logs-mysql-*"
create lab-metricbeat   "metrics"       "metricbeat-*"
create lab-heartbeat    "heartbeat"     "heartbeat-*"
