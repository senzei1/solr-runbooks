# Runbook: Manual Modification of state.json (Direct ZK Edit)

## 1. Objective
To manually retrieve, edit, and restore the `state.json` file for a specific Solr collection directly from Zookeeper. This is a "break-glass" procedure used to remove ghost replicas or correct corrupted shard states that persist despite standard API remediation attempts.

## 2. Prerequisites
* **Environment:** Cloudera CDP.
* **Access:** Root access to a Solr node.
* **Auth:** Kerberos ticket (`kinit`) required.
* **Tools:** `zkcli.sh` (provided by Solr package), text editor (`vi` or `nano`).

---

## 3. Preparation & Authentication

### Step 3.1: Locate JAAS Configuration
The `zkcli.sh` tool requires explicit JVM flags to handle Kerberos SASL authentication and ACLs. The path to `jaas.conf` in CDP is dynamic (inside a process directory).

**Action:** Find the current running Solr process's JAAS config.
```bash
# 1. Find the process ID of Solr
SOLR_PID=$(pgrep -f "solr-SOLR_SERVER")

# 2. Locate the jaas.conf for that specific process
JAAS_PATH=$(ls /var/run/cloudera-scm-agent/process/*-solr-SOLR_SERVER/jaas.conf | head -n 1)

echo "Using JAAS Config: $JAAS_PATH"
```

### Step 3.2: Export JVM Flags
Set the environment variable `ZKCLI_JVM_FLAGS` so `zkcli.sh` can authenticate with Zookeeper.

```bash
export ZKCLI_JVM_FLAGS="-Djava.security.auth.login.config=$JAAS_PATH \
-DzkACLProvider=org.apache.solr.common.cloud.SaslZkACLProvider \
-Djava.security.krb5.conf=/etc/krb5.conf"
```

---

## 4. Execution

### Step 4.1: Retrieve state.json
Download the current state file from Zookeeper to your local machine.

*Note: Replace `<COLLECTION_NAME>` with your target collection.*

```bash
# Define Variables
ZK_HOST=$(hostname -f):2181
COLLECTION="runbook_test"  # <--- UPDATE THIS
ZK_PATH="/solr/collections/$COLLECTION/state.json"

# Run zkcli.sh to GET the file
/opt/cloudera/parcels/CDH/lib/solr/bin/zkcli.sh -zkhost $ZK_HOST \
-cmd getfile $ZK_PATH state.json.orig

# Create a working copy
cp state.json.orig state.json
```

### Step 4.2: Edit the State
Modify the JSON file to remove the offending replica or correct the state.

```bash
vi state.json
```

> **Editing Tips:**
> * Look for the specific `"core_nodeX"` that is causing issues.
> * Ensure you do not break the JSON syntax (matching brackets/commas).
> * Use `jq` to validate syntax before uploading: `cat state.json.new | jq .`

### Step 4.3: Upload the New State
Push the modified file back to Zookeeper.

```bash
/opt/cloudera/parcels/CDH/lib/solr/bin/zkcli.sh -zkhost $ZK_HOST \
-cmd putfile $ZK_PATH state.json
```

---

## 5. Verification

### Step 5.1: Verify Zookeeper Update
Ensure the file in Zookeeper matches your new file.

```bash
/opt/cloudera/parcels/CDH/lib/solr/bin/zkcli.sh -zkhost $ZK_HOST \
-cmd getfile $ZK_PATH state.json.check

# Compare check file with new file (Should be empty output)
diff state.json.new state.json.check
```

### Step 5.2: Reload Collection
For the changes to take effect immediately, force the cluster to recognize the state change.

```bash
# Get Solr Hostname
SOLR_HOST=$(hostname -f)

# Reload Collection via API
curl -k --negotiate -u : "https://$SOLR_HOST:8985/solr/admin/collections?action=RELOAD&name=$COLLECTION"
```

### Step 5.3: Final Status Check
Query the cluster status to confirm the bad replica/state is resolved.

```bash
curl -k -s --negotiate -u : \
"https://$SOLR_HOST:8985/solr/admin/collections?action=CLUSTERSTATUS&collection=$COLLECTION&wt=json" | python3 -m json.tool
```

---

## 6. Rollback (If needed)

If the cluster becomes unstable or the JSON was invalid, restore the original file immediately.

```bash
mv state.json.orig state.json
/opt/cloudera/parcels/CDH/lib/solr/bin/zkcli.sh -zkhost $ZK_HOST \
-cmd putfile $ZK_PATH state.json
```
