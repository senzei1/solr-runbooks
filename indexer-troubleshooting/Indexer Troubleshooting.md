# Runbook: Indexer scenario (HBase NRT + MapReduce Batch)

## 1. Architecture Overview
We are building a robust Solr ingestion architecture that supports two distinct pipelines in a secure (Kerberos + Auto-TLS) CDP environment:

1.  **Real-Time (NRT):** Data written to HBase is instantly indexed via the HBase Indexer.
2.  **Batch History:** Massive JSON dumps on HDFS are indexed via the MapReduce Indexer Tool (MRIT).

**Critical Design Decision:** To allow the MapReduce "GoLive" tool to merge indexes without hitting local filesystem permission errors, the Solr collection **must** be configured to store data natively on HDFS.

---

## 2. Phase 1: Security & Environment Setup

### Step 2.1: Create JAAS Configuration
Create a JAAS file to allow the Hadoop CLI to authenticate using your active Kerberos ticket.

**File:** `/root/client-jaas.conf`
```java
Client {
  com.sun.security.auth.module.Krb5LoginModule required
  useKeyTab=false
  useTicketCache=true;
};
```

> **Note:** Please ensure you are using the proper kerberos principal, as the jaas.conf will be using the ticket cache instead of the keytab location.

### Step 2.2: Configure Client Environment Variables
You **must** export these variables before running any `hadoop jar` commands. This resolves SSL handshake errors and HTTP 401 (SPNEGO) failures.

> *Note: Verify the path to your `cm-auto-global_truststore.jks`. It is usually in `/var/lib/cloudera-scm-agent/agent-cert/`.*

```bash
export HADOOP_CLIENT_OPTS="-Djava.security.auth.login.config=/root/client-jaas.conf \
-Djavax.net.ssl.trustStore=/var/lib/cloudera-scm-agent/agent-cert/cm-auto-global_truststore.jks \
-Djavax.net.ssl.trustStorePassword=<YOUR_TRUSTSTORE_PASSWORD>"
```

---

## 3. Phase 2: Configuration Strategy (HDFS Backed)

### Step 3.1: Prepare Config Directory
Clone the default configuration to a temporary workspace.

```bash
mkdir -p /tmp/universal_configs/conf
cp -r /opt/cloudera/parcels/CDH/lib/solr/server/solr/configsets/_default/conf/* /tmp/universal_configs/conf/
```

### Step 3.2: Configure `solrconfig.xml` for HDFS
Open `/tmp/universal_configs/conf/solrconfig.xml`. You must replace the local storage definition with the HDFS factory to prevent "Access Denied" errors during merge.

**1. Find & Replace `<directoryFactory>`:**
```xml
<directoryFactory name="DirectoryFactory" class="solr.HdfsDirectoryFactory">
  <str name="solr.hdfs.home">hdfs://<YOUR_NAMENODE_HOST>:8020/user/solr/customer_hdfs</str>
  <str name="solr.hdfs.confdir">/etc/hadoop/conf</str>
  <bool name="solr.hdfs.blockcache.enabled">true</bool>
  <bool name="solr.hdfs.nrtcachingdirectory.enable">true</bool>
</directoryFactory>
```

**2. Update `<lockType>`:**
```xml
<lockType>hdfs</lockType>
```

### Step 3.3: Create the Morphline (`morphline.conf`)
Create `/tmp/universal_configs/conf/morphline.conf` containing two distinct commands.

**Critical:** Note the `sanitizeUnknownSolrFields` command in the JSON pipeline. This prevents crashes when the MapReduce tool injects metadata fields (like `file_path`) that are not in your schema.

```hocon
SOLR_LOCATOR : {
  collection : customer_hdfs
  # Hardcoded ZK Host avoids resolution issues
  zkHost : "<YOUR_ZOOKEEPER_HOST>:2181/solr"
}

morphlines : [
  {
    id : morphline_hbase
    importCommands : ["org.kitesdk.**", "org.apache.solr.**", "com.ngdata.**"]
    commands : [
      {
        extractHBaseCells {
          mappings : [
            { inputColumn : "info:first_name", outputField : "first_name_s", type : string, source : value }
            { inputColumn : "info:last_name", outputField : "last_name_s", type : string, source : value }
            { inputColumn : "info:segment", outputField : "segment_s", type : string, source : value }
          ]
        }
      }
      { sanitizeUnknownSolrFields { solrLocator : ${SOLR_LOCATOR} } }
      { loadSolr { solrLocator : ${SOLR_LOCATOR} } }
    ]
  },
  {
    id : morphline_json
    importCommands : ["org.kitesdk.**", "org.apache.solr.**"]
    commands : [
      { readJson { } }
      {
        extractJsonPaths {
          flatten : false
          paths : {
            id : /id
            first_name_s : /first_name_s
            last_name_s : /last_name_s
            segment_s : /segment_s
          }
        }
      }
      { sanitizeUnknownSolrFields { solrLocator : ${SOLR_LOCATOR} } }
      { loadSolr { solrLocator : ${SOLR_LOCATOR} } }
    ]
  }
]
```

### Step 3.4: Upload & Create Collection
Because we modified `solrconfig.xml` manually, the collection will be natively HDFS-backed from the moment of creation.

```bash
# 1. Prepare HDFS Directory
hdfs dfs -mkdir -p /user/solr/customer_hdfs
hdfs dfs -chown solr:solr /user/solr/customer_hdfs
hdfs dfs -chmod 775 /user/solr/customer_hdfs

# 2. Upload Config
solrctl config --upload universal_conf /tmp/universal_configs/conf

# 3. Create Collection
solrctl collection --create customer_hdfs -s 2 -r 1 -c universal_conf
```

---

## 4. Phase 3: Real-Time Pipeline (HBase Indexer)

### Step 4.1: Service Configuration (Cloudera Manager)
The background service requires SSL trust to communicate with Solr.
1.  Go to **Key-Value Store Indexer > Configuration**.
2.  Search for **Java Configuration Options**.
3.  Append: `-Djavax.net.ssl.trustStore=/var/lib/cloudera-scm-agent/agent-cert/cm-auto-global_truststore.jks -Djavax.net.ssl.trustStorePassword=<YOUR_TRUSTSTORE_PASSWORD>`
4.  Restart the service.

### Step 4.2: Register the Indexer
Create `hbase-indexer.xml`:
```xml
<indexer table="customers" mapper="com.ngdata.hbaseindexer.morphline.MorphlineResultToSolrMapper">
  <param name="morphlineFile" value="morphline.conf"/>
  <param name="morphlineId" value="morphline_hbase"/>
</indexer>
```

Register it using the CLI:
```bash
export HBASE_INDEXER_OPTS="-Djavax.net.ssl.trustStore=/var/lib/cloudera-scm-agent/agent-cert/cm-auto-global_truststore.jks -Djavax.net.ssl.trustStorePassword=<YOUR_TRUSTSTORE_PASSWORD>"

hbase-indexer add-indexer \
  --name customer_indexer \
  --indexer-conf hbase-indexer.xml \
  --connection-param solr.zk=<YOUR_ZOOKEEPER_HOST>:2181/solr \
  --connection-param solr.collection=customer_hdfs \
  --zookeeper <YOUR_ZOOKEEPER_HOST>:2181
```

---

## 5. Phase 4: Batch Pipeline (MapReduce)

### Step 5.1: Run MapReduce Indexer Tool (MRIT)
This tool performs the heavy lifting: it reads JSON from HDFS, converts it to Lucene index shards using MapReduce, and merges them live into Solr.

**Key Flags:**
* `--go-live`: Merges the resulting index directly into the running Solr cluster.
* `--morphline-id`: Selects the JSON specific pipeline from our config.

```bash
# 1. Variables
ZK_HOST="<YOUR_ZOOKEEPER_HOST>:2181/solr"
COLLECTION="customer_hdfs"
NAMENODE_URI="hdfs://<YOUR_NAMENODE_HOST>:8020"
OUT_DIR="${NAMENODE_URI}/user/solr/mrit_out_$(date +%s)"
INPUT_DATA="${NAMENODE_URI}/data/historical/batch_data.json"

# 2. Run Job
hadoop jar /opt/cloudera/parcels/CDH/lib/solr/contrib/mr/search-mr-*-job.jar \
  org.apache.solr.hadoop.MapReduceIndexerTool \
  -D 'mapreduce.job.user.classpath.first=true' \
  --morphline-file /tmp/universal_configs/conf/morphline.conf \
  --morphline-id morphline_json \
  --output-dir $OUT_DIR \
  --zk-host $ZK_HOST \
  --collection $COLLECTION \
  --go-live \
  $INPUT_DATA
```

---

## 6. Retrospective: Issues Faced & Solved

| Issue | Symptom | Root Cause | Solution |
| :--- | :--- | :--- | :--- |
| **1. Silent Failure** | HBase updates happened, but Solr showed 0 docs. | Background Indexer Service lacked SSL TrustStore. | Added `-Djavax.net.ssl.trustStore...` to CM configuration. |
| **2. Auth Required** | `HTTP 401 Authentication required` during `GoLive`. | Hadoop Client had Kerberos ticket but no JAAS config for HTTP (SPNEGO). | Added `-Djava.security.auth.login.config` to `HADOOP_CLIENT_OPTS`. |
| **3. Access Denied** | `AccessDeniedException: .../lib/solr/server/hdfs` during Merge. | Solr was using Local Filesystem storage. `GoLive` tried to merge HDFS blocks into local read-only folders. | **Pivotal Fix:** Configured `solrconfig.xml` to use `HdfsDirectoryFactory`, ensuring the entire lifecycle stays on HDFS. |
| **4. Schema Errors** | `SolrException: unknown field 'file_path'`. | MRIT automatically injects file metadata fields. | Added `sanitizeUnknownSolrFields` to Morphline to drop unmapped fields safely. |
