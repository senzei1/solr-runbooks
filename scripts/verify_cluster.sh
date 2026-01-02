#!/bin/bash
SOLR_HOST="localhost" # UPDATE THIS
PORT="8983" # UPDATE THIS
COLLECTION="runbook_test"

curl -s --negotiate -u : "http://$SOLR_HOST:$PORT/solr/admin/collections?action=CLUSTERSTATUS&collection=$COLLECTION" | \
python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    shards = data['cluster']['collections']['$COLLECTION']['shards']
    for s_name, s_data in shards.items():
        print(f'Shard: {s_name}')
        for r_name, r_data in s_data['replicas'].items():
            print(f'  - {r_name} | Node: {r_data[\"node_name\"]} | Status: {r_data[\"state\"]}')
except Exception as e:
    print('Error:', e)
"
