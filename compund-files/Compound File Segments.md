### Runbook:  Compound File Segments Scenario

This run-book demonstrates the complete lifecycle of the Compound File Segment (CFS) strategy, tailored for Cloudera CDP environments using `solrctl`. We will create a collection, fragment the index to simulate "file handle exhaustion," and then remediate the issue by enabling CFS.

**Prerequisites:**
* A running SolrCloud environment (Cloudera CDP).
* Kerberos credentials initialized (`kinit`).
* `solrctl` configured and available in the path.

---

### Phase 1: Environment Setup & Load Simulation

We will create a collection with a configuration that allows high density (up to 6 replicas per node) and fragment the index.

#### Step 1: Create the Collection
Use `solrctl` to create the collection `load_simulation` with 3 shards and 1 replica. We typically use a standard configset (like `schemaless` or `_default`) as the base.

```bash
# 1. Generate the local configuration from a template (if needed) or use an existing one
# (Assuming '_default' or similar config exists in ZK. If not, replace with 'schemaless')
solrctl collection --create load_simulation -s 3 -r 1 -m 6 -c _default
```

#### Step 2: Simulate Load (Fragment the Index)
To demonstrate the "Too Many Open Files" risk, we run a loop that inserts a small batch of documents and performs a **hard commit** immediately. This forces Solr to create a new segment on disk for every batch.

*Run this script in your terminal:*

```bash
#!/bin/bash
# Adjust protocol/port if necessary
SOLR_HOST="https://$(hostname -f):8985"
COLLECTION="load_simulation"

echo "Starting Load Simulation..."

# Loop 20 times to create 20 distinct segments (approx 200+ files)
for i in {1..20}; do
   echo "Batch $i: Indexing and Committing..."
   
   # Insert 5 documents
   curl -k --negotiate -u : -X POST -H 'Content-Type: application/json' \
     "$SOLR_HOST/solr/$COLLECTION/update?commit=true" \
     -d "[
       {\"id\": \"batch_${i}_1\", \"title\": \"Fragmenting Index\"},
       {\"id\": \"batch_${i}_2\", \"title\": \"Fragmenting Index\"},
       {\"id\": \"batch_${i}_3\", \"title\": \"Fragmenting Index\"},
       {\"id\": \"batch_${i}_4\", \"title\": \"Fragmenting Index\"},
       {\"id\": \"batch_${i}_5\", \"title\": \"Fragmenting Index\"}
     ]" > /dev/null 2>&1
     
   # Sleep briefly to ensure unique segment timestamps
   sleep 1
done

echo "Simulation Complete. Index is now fragmented."
```

#### Step 3: Establish Baseline (File Count)
Check the file count. With ~20 segments, and standard Solr indexing (~10 files per segment), you should see roughly **200+ files**.

```bash
# 1. Find the PID
PID=$(ps -ef | grep "solr-SOLR_SERVER" | grep -v grep | awk '{print $2}')

# 2. Find the index path
INDEX_PATH=$(lsof -p $PID | grep "/load_simulation_" | grep "/index/" | head -n 1 | awk '{print $9}' | xargs dirname)

# 3. Count the files
echo "Current File Count:"
ls -1 $INDEX_PATH | wc -l

# 4. View extensions (You will see many .fdt, .fdx, .tim files)
ls -F $INDEX_PATH | head -n 10
```

---

### Phase 2: Configuration Remediation

We will modify the configuration to enforce Compound File Segments and merge the existing segments.

#### Step 4: Prepare the Configuration
Use `solrctl` to download the instance directory (configset) currently used by the collection.

```bash
# Download config from Zookeeper using solrctl
# Usage: solrctl instancedir --get <config_name> <local_path>
solrctl instancedir --get _default /tmp/solr_configs/load_simulation_conf
```

#### Step 5: Stop Solr
Stop the service from Cloudera Manager to ensure a clean state before applying major config changes.

#### Step 6: Modify `solrconfig.xml`
Edit the downloaded file: `/tmp/solr_configs/load_simulation_conf/conf/solrconfig.xml`.
*(Note: `solrctl` downloads the `conf` folder inside the target directory)*

**Find `<indexConfig>`, remove the comments and replace it with:**

```xml
<indexConfig>
  <useCompoundFile>true</useCompoundFile>

  <mergePolicyFactory class="org.apache.solr.index.TieredMergePolicyFactory">
    <int name="maxMergeAtOnce">10</int>
    <int name="segmentsPerTier">10</int>
    <double name="noCFSRatio">1.0</double>
    <double name="maxCFSSegmentSizeMB">51200.0</double>
  </mergePolicyFactory>

  <ramBufferSizeMB>100</ramBufferSizeMB>
  <maxBufferedDocs>1000</maxBufferedDocs>
</indexConfig>
```

#### Step 7: Upload Configuration to Zookeeper
Upload the modified configuration as a **new** configset named `cfs_config`.

```bash
# Note: Zookeeper must be accessible. If ZK is stopped, start it.
# Usage: solrctl instancedir --create <new_config_name> <local_path>
solrctl instancedir --create cfs_config /tmp/solr_configs/load_simulation_conf
```

#### Step 8: Start Solr
Bring the service back online.

```bash
sudo systemctl start solr
```

---

### Phase 3: Validation & Optimization

The collection is still using the old `_default` config. We must link it to `cfs_config` and force a merge.

#### Step 9: Link Config and Reload
Use the Solr API to switch the collection's config. `solrctl` is primarily for ZK management; `curl` is safer for live collection modification.

```bash
SOLR_HOST="https://$(hostname -f):8985"

# 1. Verify the new config exists in ZK
solrctl instancedir --list

# 2. Update the collection to use the new 'cfs_config'
curl -k --negotiate -u : "$SOLR_HOST/solr/admin/collections?action=MODIFYCOLLECTION&collection=load_simulation&collection.configName=cfs_config"

# 3. Reload the collection to apply changes
curl -k --negotiate -u : "$SOLR_HOST/solr/admin/collections?action=RELOAD&name=load_simulation"
```

#### Step 10: Trigger Merge (Optimize)
The new configuration applies to *new* merges. To convert the *existing* 200+ loose files into Compound Files immediately, trigger an "optimize".

```bash
curl -k --negotiate -u : "$SOLR_HOST/solr/load_simulation/update?optimize=true&maxSegments=1&waitSearcher=true"
```

#### Step 11: Final Validation
Check the file count again. It should have dropped drastically (likely to < 10 files total).

```bash
# 1. Re-acquire PID (it changed after restart)
NEW_PID=$(ps -ef | grep "solr-SOLR_SERVER" | grep -v grep | awk '{print $2}')

# 2. Find index path
NEW_INDEX_PATH=$(lsof -p $NEW_PID | grep "/load_simulation_" | grep "/index/" | head -n 1 | awk '{print $9}' | xargs dirname)

# 3. Check Count
echo "New File Count:"
ls -1 $NEW_INDEX_PATH | wc -l

# 4. Verify Extensions (Should see .cfs)
ls -F $NEW_INDEX_PATH
```
