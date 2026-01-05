# Runbook: Solr Mixed-Replica Architecture

## 1. Objective
To deploy a SolrCloud collection optimized for a "High Read / Moderate Write" workload. We will use a mixed-replica strategy to isolate indexing overhead from search traffic and provide cost-effective scalability.

**The Strategy:**
* **NRT (Leader):** Handles the heavy lifting of indexing and soft-commits.
* **TLOG (Failover):** Provides a "Standby" node that stores data but doesn't waste CPU indexing it unless it becomes the leader.
* **PULL (Read Scalability):** Lightweight copies that only serve search queries, consuming minimal CPU.

## 2. Prerequisites
* **Environment:** Cloudera CDP 7.1.9 SP1.
* **Nodes:** Minimum 3 Solr nodes (to spread the replica types).
* **Auth:** Kerberos ticket (`kinit`) required.
* **Tools:** `solrctl` or `curl`.

---

## 3. Replica Definitions & Use Cases

Before executing, it is critical to understand *why* we are mixing these types.

### 🟢 NRT (Near Real Time)
* **What it is:** The "Classic" Solr replica. It maintains a Transaction Log and **indexes documents locally**.
* **Behavior:** It performs all analysis and indexing work. It is always eligible to become the Leader.
* **Pros:** Data is searchable immediately (Near Real Time).
* **Cons:** High CPU and Disk I/O usage (because it does the heavy lifting of indexing).
* **Use Case:** Use for **Leaders** and clusters where every millisecond of data freshness counts.

### 🟡 TLOG (Transaction Log)
* **What it is:** A "Standby" replica. It maintains a Transaction Log (for safety) but **does NOT index locally**.
* **Behavior:** It copies built index segments from the Leader. If the Leader dies, the TLOG replica "wakes up," replays its log, and becomes the new Leader.
* **Pros:** Much lower CPU usage than NRT (since it doesn't index). Faster indexing throughput for the cluster.
* **Cons:** Not strictly "Real Time" (updates appear after segment replication).
* **Use Case:** Use for **Data Redundancy/Failover**. It keeps your data safe without burning CPU on indexing.

### 🔵 PULL
* **What it is:** A "Read-Only" replica. It has **NO Transaction Log** and **does NOT index**.
* **Behavior:** It strictly pulls index segments from the Leader. It **cannot** become a Leader.
* **Pros:** Extremely low resource usage. You can pack many PULL replicas on a single node to scale search traffic.
* **Cons:** If the Leader dies, PULL replicas stop getting updates until a new Leader is elected.
* **Use Case:** Use for **Scaling Search Traffic**. Perfect for serving website queries to end-users.

---

## 4. Execution

### Step 4.1: Upload Configuration
We will use a standard configuration for this test.

```bash
# 1. Authenticate
kinit <your_user>@<REALM>

# 2. Upload default config
solrctl config --upload ecom_conf /opt/cloudera/parcels/CDH/lib/solr/server/solr/configsets/_default/conf
```

### Step 4.2: Create the Collection
We will create a collection named `products_catalog` with:
* **1 Shard** (Partition).
* **1 NRT Replica** (The Leader).
* **1 TLOG Replica** (The Backup).
* **2 PULL Replicas** (The Search Servants).

**Command:**
```bash
# Using curl to specify exact replica counts
SOLR_HOST=$(hostname -f)
PORT="8985"

curl -k --negotiate -u : "https://$SOLR_HOST:$PORT/solr/admin/collections?action=CREATE&name=products_catalog&numShards=1&nrtReplicas=1&tlogReplicas=1&pullReplicas=2&collection.configName=ecom_conf&wt=json"
```

---

## 5. Verification

### Step 5.1: Verify Replica Types
We need to confirm that Solr actually created the different types. We will parse the `CLUSTERSTATUS` output.
Save the following script in a file, assign the execute permission and run it.

**Script:**
```bash
#!/bin/bash
SOLR_HOST=$(hostname -f)
PORT="8985"
COLLECTION="products_catalog"

# Fetch Status
curl -k -s --negotiate -u : "https://$SOLR_HOST:$PORT/solr/admin/collections?action=CLUSTERSTATUS&collection=$COLLECTION&wt=json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
replicas = data['cluster']['collections']['$COLLECTION']['shards']['shard1']['replicas']

print(f'{ \"NODE\":<50} | { \"ROLE\":<10} | { \"TYPE\":<5} | { \"STATE\"}')
print('-' * 85)

for r in replicas.values():
    node = r['node_name']
    rtype = r.get('type', 'NRT') # Default is NRT if missing
    state = r['state']
    role = 'LEADER' if r.get('leader') == 'true' else 'Replica'
    
    print(f'{node:<50} | {role:<10} | {rtype:<5} | {state}')
"
```

### Step 5.2: Expected Output
You should see output similar to this, showing one Leader (NRT) and the other specialized types:

```text
NODE                                               | ROLE       | TYPE  | STATE
-------------------------------------------------------------------------------------
node1.example.com:8985_solr                        | LEADER     | NRT   | active
node2.example.com:8985_solr                        | Replica    | TLOG  | active
node3.example.com:8985_solr                        | Replica    | PULL  | active
node4.example.com:8985_solr                        | Replica    | PULL  | active
```

---

## 6. Summary of Benefits
By using this architecture for the `products_catalog`:
1.  **Writes are fast:** Only the NRT node burns CPU analyzing text.
2.  **Reads are cheap:** The PULL nodes serve customer searches without slowing down the indexing process.
3.  **Failover is safe:** If Node 1 (NRT) crashes, Node 2 (TLOG) will immediately promote itself to Leader and start indexing, ensuring no data is lost.
