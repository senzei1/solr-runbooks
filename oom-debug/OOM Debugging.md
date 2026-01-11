### **Solr Query OOM Reproduction Run-Book**

**Objective:** Demonstrate a `java.lang.OutOfMemoryError` caused by sorting on a field with `docValues="false"`, forcing Solr to un-invert the index into the Java Heap 

> **Note:** This was the easiest method to get an OOM/hprof.

---

#### **1. Prerequisites: System Configuration**
Before starting, Solr must be configured to have a small heap and automatic crash reporting.

**A. Lower Heap Size to 256MB**
Cloudera Manager > Solr > Configuration > Java Heap Size of Solr Server in Bytes, set the value to 256MB.

**B. Enable Automatic Heap Dumps**
Cloudera Manager > Solr > Configuration:
1. Dump Heap When Out of Memory > select "_Solr Server Default Group_"
2. Heap Dump Directory > /tmp
3. Save the changes and restart.

   
*Restart Solr after applying these changes.*

---

#### **2. Environment Initialization**
This step creates a fresh collection and applies the critical Schema vulnerability.

**Script: `setup_environment.sh`**
```bash
#!/bin/bash
SOLR_HOST="https://$(hostname -f):8985"
COLLECTION="query_oom_test"
CONFIG_NAME="query_oom_conf"

# 1. Create Configuration and Collection
solrctl instancedir --get _default /tmp/oom_config
solrctl instancedir --create $CONFIG_NAME /tmp/oom_config
sleep 2
solrctl collection --create $COLLECTION -s 1 -r 1 -c $CONFIG_NAME

# 2. CRITICAL: Apply Schema Change (Disable DocValues)
# We create a dynamic field where DocValues are explicitly FALSE.
# This forces Solr to use FieldCache (Heap) instead of Disk.
curl -k --negotiate -u : -X POST -H 'Content-type:application/json' \
  "$SOLR_HOST/solr/$COLLECTION/schema" \
  -d '{
    "add-dynamic-field":{
      "name":"*_heap_killer",
      "type":"string",
      "indexed":true,
      "stored":true,
      "docValues":false,
      "multiValued":false
    }
  }'

echo "Environment Ready."
```

---

#### **3. Data Ingestion (The Payload)**
We generate "Big" documents (high text volume) to ensure the memory usage exceeds 256MB.

**Script: `load_data.sh`**
```bash
#!/bin/bash
SOLR_HOST="https://$(hostname -f):8985"
COLLECTION="query_oom_test"

echo "--- Generating 100k 'Big' Documents (2KB text per doc) ---"
echo "id,sort_field_heap_killer" > /tmp/oom_fat.csv

# Create a 2KB string of padding
PADDING=$(printf 'X%.0s' {1..2000})

# Generate 100,000 lines. Total Memory Pressure: ~200MB+
seq 1 100000 | awk -v pad="$PADDING" '{print "doc_" $1 ",val_" $1 "_" pad}' >> /tmp/oom_fat.csv

echo "--- Split and Upload ---"
split -l 25000 -d --additional-suffix=.csv /tmp/oom_fat.csv /tmp/oom_chunk_

for file in /tmp/oom_chunk_*.csv; do
  # Add header to chunks
  sed -i '1i id,sort_field_heap_killer' "$file"
  
  echo -n "Uploading $file... "
  curl -k --negotiate -u : -s -o /dev/null -w "%{http_code}" -X POST \
    "$SOLR_HOST/solr/$COLLECTION/update?commit=true" \
    --data-binary @"$file" -H 'Content-type:application/csv'
  echo " (Done)"
done
```

---

#### **4. Monitoring & Verification**
Ensure the data is fully committed before triggering the crash.

**Command:**
```bash
export SOLR_HOST="https://$(hostname -f):8985"
export COLLECTION="query_oom_test"

curl -k --negotiate -u : -s "$SOLR_HOST/solr/$COLLECTION/select?q=*:*&rows=0" | grep numFound
```
* **Success Criteria:** Output must show `"numFound":100000` (or greater).

---

#### **5. The Trigger (Execution)**
This query forces Solr to load the `sort_field_heap_killer` values for all 100,000 documents into the Heap.

**Command:**
```bash
curl -k --negotiate -u : -X GET \
  "$SOLR_HOST/solr/$COLLECTION/select?q=*:*&sort=sort_field_heap_killer+desc&rows=1&df=_text_"
```

* **Result:** The command will likely hang or fail with a 500 error.
* **Observation:** Check `/tmp/solr_solr-SOLR_SERVER-xxxxxxxxxxxx_pid{{PID}}.hprof`. If the file exists, the OOM was successful, and the Solr server should be stopped.

### **6. Analyzing the hprof file**
Download the hprof file from the server that crashed to your local machine.

Download Eclipse Memory Analyzer Tool (MAT), and install it on your machine.

1.  Open **Eclipse MAT** > **File** > **Open Heap Dump**.
2.  Select "Leak Suspects Report" and click Finish.
3.  **Identify Memory Consumer (Histogram):**
    * Click the **Histogram** icon.
    * Sort by "Retained Heap".
    * *Look for:* **`byte[]`** or **`char[]`** arrays consuming the majority of memory (~200MB). This confirms raw data loaded into RAM.
4.  **Identify the Culprit Thread (Dominator Tree):**
    * Click the **Dominator Tree** icon.
    * *Look for:* A single **Jetty Thread** holding >90% of the Heap.
    * Expand the thread to see **`org.apache.solr.uninverting.FieldCacheImpl`**. This confirms DocValues were disabled.
5.  **Extract the Query Parameters:**
    * Inside the Dominator Tree thread, drill down into **`org.apache.solr.handler.RequestHandlerBase`** (or search for `<Java Local>`).
    * Navigate to: `params` > `map` > `table`.
    * *Look for:* The Map Entry where **Key = "sort"** and **Value = "sort_field_heap_killer desc"** (_Picture for reference_).
      
      <img width="1096" height="339" alt="Screenshot 2026-01-10 at 10 55 32 PM" src="https://github.com/user-attachments/assets/6b28797b-b055-491d-a3f9-032f5b904695" />

      Each of the lines with numbers between brackets contains a query parameter with its corresponding value.  That's how you can identify the query causing the OOM.
