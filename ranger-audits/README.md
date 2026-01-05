# 📘 Runbook: Managing Ranger Audits in Infra Solr

## 1. Architecture & Collection Overview
Ranger writes audit logs to "Infra Solr" (a dedicated Solr instance for internal Hadoop components like Ranger and Atlas). The primary collection for Ranger is usually named `ranger_audits`.

* **Audit Destinations:** Ranger can write to multiple destinations simultaneously (HDFS, Solr, Amazon S3, etc.). Solr is preferred for real-time indexing and searchability via the Ranger UI.
* **Collection Name:** `ranger_audits`
* **Config Set:** Usually named `ranger_audits` or similar, stored in Zookeeper (e.g., `/infra-solr/configs/ranger_audits`).

### Sharding Strategy
Proper sharding is critical for write throughput and search performance.
* **`ranger.audit.solr.no.shards`:** Defines the number of shards for the audit collection.
* **`ranger.audit.solr.max.shards.per.node`:** Defines the maximum replicas/shards a single Solr node can host.
* **SME Tip:** If you expand the Solr cluster, you must manually trigger a SPLITSHARD or create a new collection with more shards to utilize the new nodes; Solr does not automatically re-balance existing shards to new nodes for write scalability.

---

## 2. Data Retention & Purging (Critical)
One of the most common issues in Infra Solr is disk exhaustion due to audit logs growing indefinitely.

### The Retention Mechanism
Ranger uses a **Time-To-Live (TTL)** mechanism or a **Max Audit Age** setting to auto-purge old data. This is often handled by the `SolrAutoPurge` feature or internal Solr `UpdateProcessor`.

### Configuration Methods
1.  **Ranger Admin UI:**
    * Navigate to **Audit > Solr Configurations**.
    * Look for `ranger.audit.solr.config.ttl`.
2.  **Solr Config (`solrconfig.xml`):**
    * The `UpdateRequestProcessorChain` specifically handles the expiration.
    * Key parameter: `<int name="autoDelete">1</int>` (Enables auto-deletion).
    * Key parameter: `<str name="ttl">90DAYS</str>` (Sets the retention period).

> **⚠️ Important SME Note:** Simply changing the retention days in the Ranger UI **will not** immediately update the underlying `solrconfig.xml` in Zookeeper. You often need to:
> 1.  Update the configuration in the UI.
> 2.  Verify the config in Zookeeper (`/infra-solr/configs/ranger_audits/solrconfig.xml`).
> 3.  **Reload the Collection** via the Solr API for changes to take effect.
> 
> Also, only new documents will be affected by this change, older documents will keep the previous value.
---

## 3. Automation Script: TTL Validator
Use this script to verify if the retention policy stored in Zookeeper matches your expectations without manually digging through XML files.

### Script: `check_solr_ttl.sh`
This script connects to Zookeeper, retrieves the `solrconfig.xml` for the Ranger collection, and parses it to find the TTL settings.

**Prerequisites:**
* Access to a node with the `zookeeper-client` installed.
* Kerberos ticket (if the cluster is secured).

```bash
#!/bin/bash
# =============================================================================
# Script: check_solr_ttl.sh
# Purpose: Validates Ranger Audit TTL settings in Infra Solr Zookeeper Config
# Usage: ./check_solr_ttl.sh [ZK_HOST:PORT] [ZNODE_PATH]
# Example: ./check_solr_ttl.sh node1.example.com:2181 /infra-solr
# =============================================================================

ZK_CONNECTION_STRING=${1:-"localhost:2181"}
SOLR_ZNODE=${2:-"/infra-solr"}
CONFIG_NAME="ranger_audits"
TEMP_CONFIG_FILE="/tmp/solrconfig_check.xml"

echo "---------------------------------------------------------"
echo "🔍 Checking Ranger Audit TTL Configuration in Zookeeper"
echo "   ZK Host: $ZK_CONNECTION_STRING"
echo "   ZNode:   $SOLR_ZNODE"
echo "---------------------------------------------------------"

# 1. Download solrconfig.xml from Zookeeper
# Note: Adjust the path below if your config name differs from 'ranger_audits'
ZK_CONFIG_PATH="$SOLR_ZNODE/configs/$CONFIG_NAME/solrconfig.xml"

echo ">> Downloading config from: $ZK_CONFIG_PATH..."

# Using zookeeper-client to get the file. 
# Attempting to use 'hdfs dfs -get' style or zookeeper-client depending on availability.
# For standard CDP/HDP environments, we use zookeeper-client command line.

if command -v zookeeper-client &> /dev/null; then
    # Create a batch script for zookeeper-client
    echo "get $ZK_CONFIG_PATH" > /tmp/zk_cmd.txt
    zookeeper-client -server $ZK_CONNECTION_STRING < /tmp/zk_cmd.txt > /tmp/zk_output.txt 2>&1
    
    # Extract the XML content (removing ZK shell junk)
    # This is a rough extraction; manual verification might be needed if output is messy
    sed -n '/<?xml/,$p' /tmp/zk_output.txt | sed '$d' > $TEMP_CONFIG_FILE
else
    echo "❌ Error: 'zookeeper-client' not found. Please run on a node with ZK clients installed."
    exit 1
fi

# 2. Parse and Validate Settings
if [ -s "$TEMP_CONFIG_FILE" ]; then
    echo ">> Config downloaded. Parsing settings..."
    
    # Check for autoDelete
    AUTO_DELETE=$(grep -oP '(?<=<int name="autoDelete">).*?(?=</int>)' $TEMP_CONFIG_FILE)
    
    # Check for TTL value
    TTL_VAL=$(grep -oP '(?<=<str name="ttl">).*?(?=</str>)' $TEMP_CONFIG_FILE)
    
    echo "---------------------------------------------------------"
    echo "📊 RESULTS:"
    
    if [ "$AUTO_DELETE" == "1" ]; then
        echo "   ✅ Auto-Delete is ENABLED (value=1)"
    else
        echo "   ❌ Auto-Delete is DISABLED (value=$AUTO_DELETE) or not found!"
    fi
    
    if [ -n "$TTL_VAL" ]; then
        echo "   ✅ TTL Value found: $TTL_VAL"
    else
        echo "   ❌ TTL Value NOT found in configuration!"
    fi
    echo "---------------------------------------------------------"
    
    # Cleanup
    rm $TEMP_CONFIG_FILE /tmp/zk_cmd.txt /tmp/zk_output.txt
else
    echo "❌ Failed to retrieve solrconfig.xml from Zookeeper. Check your ZNode path and permissions."
fi
```

---

## 4. Performance Tuning
Infra Solr is write-heavy. Tuning must prioritize indexing throughput over search latency.

### JVM & Memory
* **Heap Size:** Infra Solr is memory hungry. Ensure the heap is sized to prevent OOM errors, but leave 50% of system RAM for the OS (file system cache).
* **Garbage Collection:** G1GC is generally recommended for larger heaps (>4GB).

### Commit Strategy (`solrconfig.xml`)
Frequent commits kill performance.
* **AutoSoftCommit:** Controls visibility of documents.
    * *Recommendation:* Set to `60000` (1 minute) or higher. You rarely need "near real-time" visibility for audit logs.
* **AutoCommit (Hard):** Flushes data to disk and clears the transaction log.
    * *Recommendation:* Set to `15000` (15 seconds) with `openSearcher=false`. This protects data durability without triggering expensive searcher warm-ups.

### Indexing Parameters
* **`ramBufferSizeMB`:** Increase this (e.g., to 256MB or 512MB) to allow larger batches of documents to buffer in memory before flushing to a segment.
* **`mergePolicy`:** TieredMergePolicy is standard. Watch for "too many segments" warnings in logs.

---

## 5. Troubleshooting & Maintenance

### Common Failure Scenarios
| Issue | Cause | Fix |
| :--- | :--- | :--- |
| **Ranger UI shows no audits** | Solr is down or Ranger plugin can't connect. | Check `ranger-admin` logs for connection timeouts. Verify Solr is reachable via curl. |
| **Disk Full / Solr Crashes** | Retention policy not working or volume too high. | Verify TTL settings using the script above. Check if `autoDelete` is true. |
| **Write Performance degradation** | Too many small segments or frequent commits. | Tune `autoSoftCommit` (increase interval) and `ramBufferSizeMB`. |
| **"Replica Down"** | Zookeeper session timeout or OOM. | Check Solr GC logs. Increase ZK session timeout if network is jittery. |

### Essential Commands (API)
**Reload Collection (Apply Config Changes):**
```bash
curl -i -k --negotiate -u : "https://<SOLR_HOST>:8985/solr/admin/collections?action=RELOAD&name=ranger_audits"
```

**Check Cluster Status:**
```bash
curl -i -k --negotiate -u : "https://<SOLR_HOST>:8985/solr/admin/collections?action=CLUSTERSTATUS"
```

**Force Merge (Use carefully during off-peak):**
```bash
curl -i -k --negotiate -u : "https://<SOLR_HOST>:8985/solr/ranger_audits/update?optimize=true&maxSegments=1"
```

---

## 6. Summary of Key Parameters

* **Solr Heap:** `INFRA_SOLR_HEAP_SIZE` (Tune based on node capacity).
* **Zookeeper Znode:** `/infra-solr` (Default namespace).
* **Collection:** `ranger_audits`.
* **Retention Config:** `ranger.audit.solr.config.ttl` (UI) / `ttl` (XML).
* **Commit Config:** `autoSoftCommit` (Visibility), `autoCommit` (Durability).
