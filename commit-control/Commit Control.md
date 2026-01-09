### **Runbook: Dynamic Search & Commit Controls**

**Environment Profile**:
* **Platform**: CDP / Solr 8+
* **Security**: Kerberos Authentication + TLS (Port 8985)
* **Topology**: 1 Shard, 1 Replica

---

### **Phase 1: Configuration & Deployment**

In this phase, we modify `solrconfig.xml` to support dynamic switching (Scenario 1) and strictly block client commits (Scenario 2).

#### **Step 1: Workspace Initialization**
Create a clean local workspace and clone the default configuration templates.

```bash
# Create workspace structure
mkdir -p $HOME/solr_configs/master_conf/conf

# Copy default configset
cp -r /opt/cloudera/parcels/CDH/lib/solr/server/solr/configsets/_default/conf/* $HOME/solr_configs/master_conf/conf/
```

#### **Step 2: Modify `solrconfig.xml`**
Edit `$HOME/solr_configs/master_conf/conf/solrconfig.xml`.

**Action A: Enable Dynamic Parameters (Scenario 1)**
Insert this block inside the `<config>` tag (e.g., near other RequestHandlers).

```xml
<requestHandler name="/marketing" class="solr.SearchHandler" useParams="global_defaults">
  <lst name="defaults">
    <str name="echoParams">explicit</str>
    <int name="rows">10</int>
    <str name="df">text</str>
  </lst>
</requestHandler>
```

**Action B: Configure Commit Blocking (Scenario 2)**
Add the `ignore-commit-from-client` chain.
* **Note**: We include `DistributedUpdateProcessorFactory` which is mandatory for SolrCloud.
* **Note**: We set `default="true"` so it applies to all updates automatically.

```xml
<updateRequestProcessorChain name="ignore-commit-from-client" default="true">
  <processor class="solr.IgnoreCommitOptimizeUpdateProcessorFactory">
    <int name="statusCode">403</int>
    <str name="responseMessage">Thou shall not issue a commit!</str>
  </processor>
  <processor class="solr.LogUpdateProcessorFactory" />
  <processor class="solr.DistributedUpdateProcessorFactory" />
  <processor class="solr.RunUpdateProcessorFactory" />
</updateRequestProcessorChain>
```

**Action C: Ensure Visibility (Scenario 2)**
Locate the `<updateHandler>` block. Ensure `<autoSoftCommit>` is uncommented and set to 1000ms. Since we are blocking client commits, this is the **only** way data will become visible.

```xml
<autoSoftCommit>
  <maxTime>${solr.autoSoftCommit.maxTime:1000}</maxTime>
</autoSoftCommit>
```

#### **Step 3: Upload and Provision**
Clean up any old state and create the new collection.

```bash
# 1. Upload configuration
solrctl config --upload master_product_conf $HOME/solr_configs/master_conf/conf

# 2. Create collection
solrctl collection --create products -s 1 -r 1 -c master_product_conf
```

---

### **Phase 2: Schema & Data Ingestion**

#### **Step 4: Define Schema**
Since we disabled default field guessing by changing the update chain, we must explicitly define our fields.

```bash
SOLR_URL="https://$(hostname -f):8985/solr"

curl -k --negotiate -u : -X POST -H 'Content-type:application/json' \
  "$SOLR_URL/products/schema" -d '{
  "add-field": [
    {"name": "name", "type": "text_general", "stored": true, "indexed": true},
    {"name": "description", "type": "text_general", "stored": true, "indexed": true},
    {"name": "discount_rate", "type": "pfloat", "stored": true, "indexed": true},
    {"name": "release_date", "type": "pdate", "stored": true, "indexed": true},
    {"name": "in_stock", "type": "boolean", "stored": true, "indexed": true}
  ]
}'
```

#### **Step 5: Index Data**
We ingest the data without `?commit=true`.

```bash
# Create data file
cat <<EOF > products_large.json
[
  { "id": "1", "name": "Enterprise Workstation Laptop", "description": "Reliable heavy workloads, premium build", "discount_rate": 5, "release_date": "2023-06-01T00:00:00Z", "in_stock": true },
  { "id": "2", "name": "Gaming Beast Laptop", "description": "RGB lighting performance, heavy graphics", "discount_rate": 15, "release_date": "2024-01-01T00:00:00Z", "in_stock": false },
  { "id": "3", "name": "Budget Daily Laptop", "description": "Affordable everyday use for students", "discount_rate": 50, "release_date": "2025-01-01T00:00:00Z", "in_stock": true },
  { "id": "4", "name": "Pro Creator Tablet", "description": "High resolution screen for artists", "discount_rate": 10, "release_date": "2024-03-01T00:00:00Z", "in_stock": true },
  { "id": "5", "name": "Legacy Laptop Model", "description": "Old reliable model, clearance sale", "discount_rate": 70, "release_date": "2020-01-01T00:00:00Z", "in_stock": true },
  { "id": "6", "name": "Ultra-Thin Laptop", "description": "Lightweight and portable for travel", "discount_rate": 20, "release_date": "2024-06-01T00:00:00Z", "in_stock": true }
]
EOF

# Index data (Expect Success)
curl -k --negotiate -u : -X POST -H 'Content-Type: application/json' \
"$SOLR_URL/products/update" --data-binary @products_large.json
```

---

### **Phase 3: Scenario Execution**

#### **Scenario 1: Dynamic Search Contexts**

**1. Define ParamSets (API)**
We define the rules via the Config API.

```bash
# Standard Mode (Relevance)
curl -k --negotiate -u : "$SOLR_URL/products/config/params" -H 'Content-type:application/json' -d '{
  "set": {
    "global_defaults": {
      "defType": "edismax",
      "qf": "name^2.0 description^1.0",
      "sort": "score desc"
    }
  }
}'

# Flash Sale Mode (Campaign)
curl -k --negotiate -u : "$SOLR_URL/products/config/params" -H 'Content-type:application/json' -d '{
  "set": {
    "flash_sale": {
      "defType": "edismax",
      "qf": "name^1.0 description^3.0",
      "sort": "discount_rate desc, release_date desc",
      "fq": "in_stock:true"
    }
  }
}'
```

**2. Verify Standard Behavior**
```bash
curl -k --negotiate -u : "$SOLR_URL/products/marketing?q=laptop&fl=name,score,discount_rate"
```
* **Expectation**: "Enterprise Workstation" is top.

**3. Verify Flash Sale Behavior**
```bash
curl -k --negotiate -u : "$SOLR_URL/products/marketing?q=laptop&useParams=flash_sale&fl=name,discount_rate"
```
* **Expectation**: "Legacy Laptop Model" (70% discount) is top.

---

#### **Scenario 2: Stability (Commit Blocking)**

**Goal**: Confirm that client commits are **forbidden** (HTTP 403) and that data still appears automatically.

**1. The Test (Blocked Commit)**
Attempt to force a commit.
```bash
curl -k --negotiate -u : "$SOLR_URL/products/update?commit=true" \
-H 'Content-Type: application/json' \
-d '[{"id":"test_fail","name":"Fail Item"}]'
```
* **Output**:
  ```json
  {
    "responseHeader": {
      "status": 403,
      "QTime": 1
    },
    "error": {
      "msg": "Thou shall not issue a commit!",
      "code": 403
    }
  }
  ```

**2. The Validation (Auto Visibility)**
Submit item without commit flag, wait, and search.
```bash
# Submit
curl -k --negotiate -u : "$SOLR_URL/products/update" \
-H 'Content-Type: application/json' \
-d '[{"id":"test_auto","name":"Auto Visibility Item"}]'

# Wait & Query
sleep 2
curl -k --negotiate -u : "$SOLR_URL/products/select?q=id:test_auto"
```
* **Result**: The item is found automatically.
