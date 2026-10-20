#!/bin/sh
# ILM-политики и шаблоны индексов для логов.
# nginx и mysql хранятся 30 дней, php-fpm - 14 дней.
set -e

ES="${ES_URL:-http://elasticsearch:9200}"

put() {
  curl -sS -f -X PUT "$ES$1" -H 'Content-Type: application/json' -d "$2"
  echo
}

put /_ilm/policy/logs-30d '{"policy":{"phases":{"delete":{"min_age":"30d","actions":{"delete":{}}}}}}'
put /_ilm/policy/logs-14d '{"policy":{"phases":{"delete":{"min_age":"14d","actions":{"delete":{}}}}}}'

for pair in nginx:logs-30d mysql:logs-30d phpfpm:logs-14d; do
  name="${pair%%:*}"
  policy="${pair##*:}"
  put "/_index_template/lab-logs-$name" \
    "{\"index_patterns\":[\"lab-logs-$name-*\"],\"priority\":200,\"template\":{\"settings\":{\"index.lifecycle.name\":\"$policy\",\"index.number_of_shards\":1,\"index.number_of_replicas\":0}}}"
done

# чаще проверять ILM, чтобы изменения были видны быстрее
put /_cluster/settings '{"persistent":{"indices.lifecycle.poll_interval":"1m"}}'

echo "setup done"
