#!/bin/bash
SOLR_HOST="localhost" # UPDATE THIS
PORT="8983" #UPDATE THIS
COLLECTION="runbook_test"
SOLR_URL="http://$SOLR_HOST:$PORT/solr/$COLLECTION"

echo "Starting load gen on $SOLR_URL..."
for i in {1..10000}; do
   DOC_ID="doc_$i"
   # Using --negotiate for Kerberos
   curl -s --negotiate -u : -X POST -H 'Content-Type: application/json' \
   "$SOLR_URL/update?commit=true" \
   -d "[{\"id\": \"$DOC_ID\", \"description\": \"load_test_$i\"}]" > /dev/null
   sleep 0.5
done
