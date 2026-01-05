# Runbook: Solr Replica Down Simulation (CDP Secure)

## 1. Objective
To validate the High Availability (HA) and self-healing capabilities of a Cloudera CDP Solr service (Secured/Kerberized). This runbook simulates the abrupt failure of a data-bearing node to verify that the cluster continues serving traffic and that the failed node recovers automatically.

* **Note:** This scenario assumes your cluster is kerberized and TLS secured.

## 2. Prerequisites
* **Environment:** Cloudera CDP 7.1.9 SP1.
* **Access:** Root/Sudo on Solr nodes.
* **Auth:** Kerberos ticket (`kinit`) required.
* **Network:** Port **8985** (Standard CDP TLS port).
* **Tools:** `solrctl`, `curl`, `python3`, `jq` (optional).
* **Cloudera Manager:** Access to the UI for restarting services.

---

## 3. Preparation & Setup

### Step 3.1: Generate Configuration Template
Instead of creating directories manually, we use `solrctl` to generate a valid skeleton structure.

```bash
# 1. Authenticate
kinit <your_user>@<REALM>

# 2. Generate default config structure in a local directory named 'runbook_local'
# This creates the necessary folder structure including the 'conf' directory.
solrctl instancedir --generate runbook_local
```

### Step 3.2: Customize Configuration Files
Overwrite the generated files with our specific runbook configurations to ensure specific commit behaviors (soft commits, etc.).

**Action:**
1.  Navigate to the generated directory: `cd runbook_local/conf`
2.  Replace `managed-schema` (or `managed-schema.xml`) and `solrconfig.xml` with the content provided in **Appendix A**.
3.  Ensure the schema file is named `managed-schema`.

### Step 3.3: Upload Config & Create Collection
Upload the `conf` directory to Zookeeper.

```bash
# 1. Upload the 'conf' folder
# usage: solrctl --jaas /path/to/jaas.conf config --upload <SOLR_CONFIG_NAME> <LOCAL_DIR>
# Note: We upload the 'conf' subdirectory specifically.
cd ../..
solrctl --jaas /var/run/cloudera-scm-agent/process/<SOLR_PROCESS_DIR>/jaas.conf config --upload runbook_conf runbook_local/conf

# 2. Create Collection (2 Shards, 2 Replicas)
solrctl collection --create runbook_test -s 2 -r 2 -c runbook_conf
```

---

## 4. Execution

### Step 4.1: Start Load Generation
Use this script to generate continuous write traffic.

**Script: `load_gen.sh`**
```bash
#!/bin/bash
SOLR_HOST=$(hostname -f)
PORT="8985" # Standard CDP TLS Port, change it to 8983 if TLS is not enabled in your cluster.
COLLECTION="runbook_test"
SOLR_URL="https://$SOLR_HOST:$PORT/solr/$COLLECTION"

echo "Load Gen Target: $SOLR_URL"
echo "Press [Ctrl+C] to stop."

for i in {1..10000}; do
   DOC_ID="doc_$i"
   # Capture HTTP status. -k for SSL, --negotiate for Kerberos
   HTTP_CODE=$(curl -k -s --negotiate -u : -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' \
   "$SOLR_URL/update?commit=true" \
   -d "[{\"id\": \"$DOC_ID\", \"description\": \"load_test_data_$i\"}]")

   if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 000 ]; then
       echo "Indexed $DOC_ID (Status: $HTTP_CODE)"
   else
       echo "ERROR: Failed to index $DOC_ID. Status: $HTTP_CODE"
   fi
   sleep 0.5
done
```

**Action:**
```bash
chmod +x load_gen.sh
./load_gen.sh
```

### Step 4.2: Simulate Failure
1.  **Identify Target:** Find a non-leader replica.
    ```bash
    # Using dynamic hostname to prevent typing
    curl -k -s --negotiate -u : "https://$(hostname -f):8985/solr/admin/collections?action=CLUSTERSTATUS&collection=runbook_test"
    ```
2.  **Kill Node:** Log in to that host and kill the process (Simulation of crash).
    ```bash
    # SSH to the target
    ssh <TARGET_HOST>
    
    # Find and Kill
    ps aux | grep solr
    kill -9 <PID>
    ```

---

## 5. Verification

### Step 5.1: Verify Cluster State
Use this script to parse the cluster state safely.

**Script: `verify_cluster.sh`**
```bash
#!/bin/bash
SOLR_HOST=$(hostname -f)
PORT="8985"
COLLECTION="runbook_test"

# Added &wt=json to force JSON output
URL="https://$SOLR_HOST:$PORT/solr/admin/collections?action=CLUSTERSTATUS&collection=$COLLECTION&wt=json"

echo "Checking: $URL"

# Pipe curl directly to python to avoid shell variable issues
curl -k -s --negotiate -u : "$URL" | python3 -c "
import sys, json

try:
    # Read stdin
    raw_input = sys.stdin.read()
    
    if not raw_input.strip():
        print('Error: Empty response from Solr')
        sys.exit(1)

    data = json.loads(raw_input)
    
    if 'error' in data:
        print(f'Solr Error: {data[\"error\"][\"msg\"]}')
        sys.exit(1)
        
    shards = data['cluster']['collections']['$COLLECTION']['shards']
    for s_name, s_data in shards.items():
        print(f'Shard: {s_name} ({s_data[\"state\"]})')
        for r_name, r_data in s_data['replicas'].items():
            state = r_data['state']
            node = r_data['node_name']
            role = 'Leader' if r_data.get('leader') == 'true' else 'Replica'
            print(f'  - {role}: {r_name} | Node: {node} | Status: {state}')

except Exception as e:
    print(f'Error parsing JSON: {e}')
    print('Raw output start:')
    print(raw_input[:200]) # Print first 200 chars to debug
"
```

**Action:**
```bash
chmod +x verify_cluster.sh
./verify_cluster.sh
```

### Step 5.2: Log Analysis
On a **surviving** node:
```bash
tail -f /var/log/solr/solr.log | grep -E "Connection refused|gone|down"
```

---

## 6. Recovery

1.  **Restart Service (Cloudera Manager):**
    * Log in to **Cloudera Manager**.
    * Navigate to **Clusters > Solr > Instances**.
    * Select the node that is down (it should show a "Bad Health" or "Stopped" status).
    * Click **Actions > Start**.

2.  **Verify Sync:**
    Monitor the logs on the starting node (via SSH):
    ```bash
    tail -f /var/log/solr/solr.log | grep -i "recovery"
    ```

3.  **Final Status:**
    Run `./verify_cluster.sh` to ensure all nodes return to `active`.

---

## Appendix A: Configuration Files

**File: `runbook_local/conf/managed-schema`**
```xml
<?xml version="1.0" encoding="UTF-8" ?>
<schema name="runbook-schema" version="1.6">
  <field name="_version_" type="plong" indexed="false" stored="false"/>
  <field name="id" type="string" indexed="true" stored="true" required="true" multiValued="false" />
  <uniqueKey>id</uniqueKey>
  <field name="description" type="text_general" indexed="true" stored="true"/>
  <dynamicField name="*_s"  type="string"  indexed="true"  stored="true" />
  <fieldType name="string" class="solr.StrField" sortMissingLast="true" />
  <fieldType name="plong" class="solr.LongPointField" docValues="true"/>
  <fieldType name="text_general" class="solr.TextField" positionIncrementGap="100">
    <analyzer>
      <tokenizer class="solr.StandardTokenizerFactory"/>
      <filter class="solr.LowerCaseFilterFactory"/>
    </analyzer>
  </fieldType>
</schema>
```

**File: `runbook_local/conf/solrconfig.xml`**
```xml
<?xml version="1.0" encoding="UTF-8" ?>
<config>
  <luceneMatchVersion>8.0.0</luceneMatchVersion>
  <directoryFactory name="DirectoryFactory" class="${solr.directoryFactory:solr.NRTCachingDirectoryFactory}"/>
  <codecFactory class="solr.SchemaCodecFactory"/>
  <updateHandler class="solr.DirectUpdateHandler2">
    <updateLog>
      <str name="dir">${solr.ulog.dir:}</str>
      <int name="numVersionBuckets">65535</int>
    </updateLog>
    <autoCommit>
      <maxTime>${solr.autoCommit.maxTime:15000}</maxTime>
      <openSearcher>false</openSearcher>
    </autoCommit>
    <autoSoftCommit>
      <maxTime>${solr.autoSoftCommit.maxTime:1000}</maxTime>
    </autoSoftCommit>
  </updateHandler>
  <requestHandler name="/select" class="solr.SearchHandler">
    <lst name="defaults"><str name="echoParams">explicit</str><int name="rows">10</int></lst>
  </requestHandler>
  <requestHandler name="/get" class="solr.RealTimeGetHandler">
    <lst name="defaults"><str name="omitHeader">true</str></lst>
  </requestHandler>
  <requestHandler name="/update" class="solr.UpdateRequestHandler" />
</config>
```
