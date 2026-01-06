# Runbook: End-to-End Solr Collection Lifecycle (Create, Load, Migrate to HDFS)

## 1. Scenario
You are launching a new product catalog. Initially, you deploy it on the default **Local Filesystem** storage for simplicity. However, immediately after loading the initial dataset, you decide to move it to **HDFS** to ensure it can scale to petabytes without needing to resize the physical disks on your Solr nodes.

**The Workflow:**
1.  **Create:** Deploy `products_catalog` using the standard defaults (Local Disk).
2.  **Load:** Index sample product data.
3.  **Migrate:** Move the live collection to HDFS storage using Backup/Restore.

## 2. Objective
To demonstrate the full lifecycle of a Solr collection: starting from a default local deployment and migrating it to distributed HDFS storage without data loss.

## 3. Prerequisites
* **Environment:** Cloudera CDP 7.1.9 SP1.
* **Access:** Root/Sudo on Solr nodes; HDFS Superuser.
* **Auth:** Kerberos ticket (`kinit`) required.
* **Tools:** `solrctl`, `curl`.

---

## 4. Preparation

### Step 4.1: Prepare HDFS Backup Directory
Create the secure staging area in HDFS.

```bash
# 1. Authenticate as HDFS superuser
kinit hdfs@<REALM>

# 2. Create directory and set permissions
hdfs dfs -mkdir /solr-backups
hdfs dfs -chown solr:solr /solr-backups
```

### Step 4.2: Prepare Solr Environment
Set up the `solrctl` environment variables.

```bash
# 1. Authenticate as Solr user
kinit -kt /var/run/cloudera-scm-agent/process/*-solr-SOLR_SERVER/solr.keytab solr/$(hostname -f)

# 2. Set Process Directory Variable
export SOLR_PROCESS_DIR=$(ls -1dtr /var/run/cloudera-scm-agent/process/*-solr-SOLR_SERVER | tail -1)
```

---

## 5. Phase 1: Create & Load (Local FS)

### Step 5.1: Upload Default Config
We will start by uploading the default configuration templates provided by Cloudera.

```bash
# Upload the default configset to Zookeeper as 'products_conf'
solrctl config --upload products_conf /opt/cloudera/parcels/CDH/lib/solr/server/solr/configsets/_default/conf
```

### Step 5.2: Create Collection
Create the collection. By default, this uses `NRTCachingDirectoryFactory`, which stores data on the local disk (`/var/lib/solr`).

```bash
# Create collection with 1 Shard and 1 Replica
solrctl collection --create products_catalog -s 1 -r 1 -c products_conf
```

### Step 5.3: Index Data
Load sample data to simulate a "live" environment.

```bash
SOLR_HOST=$(hostname -f)

# Index 3 sample documents
curl -k --negotiate -u : -X POST -H 'Content-Type: application/json' \
"https://$SOLR_HOST:8985/solr/products_catalog/update?commit=true" \
-d '[
  {"id": "prod_001", "name_t": "Gaming Laptop 16GB", "price_d": 1200.50},
  {"id": "prod_002", "name_t": "Wireless Mouse", "price_d": 25.99},
  {"id": "prod_003", "name_t": "Mechanical Keyboard", "price_d": 89.00}
]'
```

**Verify Data on Local Disk:**
```bash
# Query to confirm data is there
curl -k --negotiate -u : "https://$SOLR_HOST:8985/solr/products_catalog/select?q=*:*"
```

---

## 6. Phase 2: Migrate to HDFS

### Step 6.1: Download Configuration
Retrieve the configuration we just used.

```bash
solrctl instancedir --get products_conf /tmp/products_catalog
```

### Step 6.2: Modify `solrconfig.xml`
We must switch the storage engine. Edit `/tmp/products_catalog/conf/solrconfig.xml`.

**Find this (Local Configuration):**
```xml
<directoryFactory name="DirectoryFactory" class="${solr.directoryFactory:solr.NRTCachingDirectoryFactory}"/>
<lockType>${solr.lock.type:native}</lockType>
```

**Replace with (HDFS Configuration):**
```xml
<directoryFactory name="DirectoryFactory" class="${solr.directoryFactory:org.apache.solr.core.HdfsDirectoryFactory}">
    <str name="solr.hdfs.home">${solr.hdfs.home:}</str>
    <str name="solr.hdfs.confdir">${solr.hdfs.confdir:}</str>
    <str name="solr.hdfs.security.kerberos.enabled">${solr.hdfs.security.kerberos.enabled:false}</str>
    <str name="solr.hdfs.security.kerberos.keytabfile">${solr.hdfs.security.kerberos.keytabfile:}</str>
    <str name="solr.hdfs.security.kerberos.principal">${solr.hdfs.security.kerberos.principal:}</str>
    <bool name="solr.hdfs.blockcache.enabled">${solr.hdfs.blockcache.enabled:true}</bool>
    <str name="solr.hdfs.blockcache.global">${solr.hdfs.blockcache.global:true}</str>
    <int name="solr.hdfs.blockcache.slab.count">${solr.hdfs.blockcache.slab.count:1}</int>
    <bool name="solr.hdfs.blockcache.direct.memory.allocation">${solr.hdfs.blockcache.direct.memory.allocation:true}</bool>
    <int name="solr.hdfs.blockcache.blocksperbank">${solr.hdfs.blockcache.blocksperbank:16384}</int>
    <bool name="solr.hdfs.blockcache.read.enabled">${solr.hdfs.blockcache.read.enabled:true}</bool>
    <bool name="solr.hdfs.blockcache.write.enabled">${solr.hdfs.blockcache.write.enabled:false}</bool>
    <bool name="solr.hdfs.nrtcachingdirectory.enable">${solr.hdfs.nrtcachingdirectory.enable:true}</bool>
    <int name="solr.hdfs.nrtcachingdirectory.maxmergesizemb">${solr.hdfs.nrtcachingdirectory.maxmergesizemb:100}</int>
    <int name="solr.hdfs.nrtcachingdirectory.maxcachedmb">${solr.hdfs.nrtcachingdirectory.maxcachedmb:192}</int>
    <bool name="solr.hdfs.locality.metrics.enabled">${solr.hdfs.locality.metrics.enabled:false}</bool>
</directoryFactory>
<lockType>${solr.lock.type:hdfs}</lockType>
```

### Step 6.3: Update Zookeeper
Upload the modified config. This changes the definition for *future* instances of the collection.

```bash
solrctl --jaas $SOLR_PROCESS_DIR/jaas.conf instancedir --update products_conf /tmp/products_catalog/conf
```

### Step 6.4: Backup Data
Snapshot the existing local data to HDFS.

```bash
# Backup name: prod_backup_v1
curl -k --negotiate -u : "https://$SOLR_HOST:8985/solr/admin/collections?action=BACKUP&name=prod_backup_v1&collection=products_catalog&location=/solr-backups"
```

### Step 6.5: Delete Old Collection
Remove the collection. This unbinds it from the "Local FS" definition.

```bash
solrctl collection --delete products_catalog

# Verify deletion
solrctl collection --list
```

### Step 6.6: Restore to HDFS
Restore the collection. Solr will read the updated Zookeeper config (from Step 6.3) and automatically provision the shards in HDFS.

```bash
# Restore from /solr-backups/prod_backup_v1
curl -k --negotiate -u : "https://$SOLR_HOST:8985/solr/admin/collections?action=RESTORE&name=prod_backup_v1&collection=products_catalog&location=/solr-backups&requestId=restore_prod_1"
```

**Check Status:**
```bash
solrctl collection --request-status restore_prod_1
```

---

## 7. Verification

### Step 7.1: Verify HDFS Storage
Confirm the new directory exists in HDFS. It should not be in `/var/lib/solr` anymore.

```bash
hdfs dfs -ls /solr/products_catalog
```

### Step 7.2: Verify Data Integrity
Query the collection to ensure our 3 products (`prod_001`, etc.) are still there.

```bash
curl -k --negotiate -u : "https://$SOLR_HOST:8985/solr/products_catalog/select?q=*:*"
```
