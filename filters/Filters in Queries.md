### **Runbook: Solr Advanced Querying & Performance Tuning**

**Context:** Optimizing Solr for CDP (Customer Data Platform) workloads using Caching, Filtering, and Post-Filtering.

---

#### **1. Theory & Best Practices**

In high-velocity CDP environments, standard caching strategies often fail because data changes too frequently (invalidating caches) or queries use unique values (polluting caches).

* **Standard Filters (`fq`):** Use for reusable segments (e.g., `Region`, `Status`). These are cached in `filterCache`.
* **Uncached Filters (`cache=false`):** Use for real-time data (`NOW`) or unique IDs. Prevents cache pollution.
* **Post-Filters (`cost=100`):** Use for expensive operations (complex math, Geo-spatial, ACLs). Forces the filter to run **last**, only on the small subset of documents that matched the cheap filters.

---

#### **2. Environment Configuration**

We configure Solr to minimize "blocking" during data ingestion by disabling specific cache warmers.

**Step 2.1: Setup Script (`setup_lab.sh`)**
This script creates a collection tailored for high-write throughput.
```bash
#!/bin/bash
SOLR_HOST="https://$(hostname -f):8985"
COLLECTION="cdp_demo"
CONFIG_NAME="cdp_demo_conf"

# 1. Prepare Config
solrctl instancedir --get _default /tmp/cdp_config
CONFIG_FILE="/tmp/cdp_config/conf/solrconfig.xml"

# TUNING: Lower filterCache warming (Default is often too high for CDP)
sed -i 's/autowarmCount="[0-9]*"/autowarmCount="16"/' "$CONFIG_FILE"

# TUNING: Disable documentCache warming (Critical for NRT)
# Internal Doc IDs change on every commit, making this cache invalid immediately.
sed -i '/name="documentCache"/,/autowarmCount/ s/autowarmCount="[0-9]*"/autowarmCount="0"/' "$CONFIG_FILE"

# 2. Create
solrctl instancedir --create $CONFIG_NAME /tmp/cdp_config
solrctl collection --create $COLLECTION -s 1 -r 1 -c $CONFIG_NAME
```

---

#### **3. Data Simulation**

We ingest mock customer events containing segments (for caching) and revenue figures (for expensive math).

**Step 3.1: Ingest Data (`load_data.sh`)**
```bash
#!/bin/bash
SOLR_HOST="https://$(hostname -f):8985"
COLLECTION="cdp_demo"
DATA_FILE="/tmp/cdp_events.json"

echo "Generating 10,000 mock events..."
echo "[" > "$DATA_FILE"
for i in {1..10000}; do
  # Segments: Gold, Silver, Bronze
  if [ $((i % 10)) -eq 0 ]; then SEG="Gold"; elif [ $((i % 3)) -eq 0 ]; then SEG="Silver"; else SEG="Bronze"; fi
  # Region: US, EU, APAC
  REGIONS=("US" "EU" "APAC"); REGION=${REGIONS[$((RANDOM % 3))]}
  # Timestamp: Current time (NRT)
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  echo "{\"id\": \"event_$i\", \"user_id_s\": \"user_$i\", \"segment_s\": \"$SEG\", \"region_s\": \"$REGION\", \"revenue_f\": $((RANDOM % 1000)), \"event_dt\": \"$TS\"}," >> "$DATA_FILE"
done
echo "{\"id\": \"dummy_end\"}]" >> "$DATA_FILE"

curl -k --negotiate -u : -X POST -H 'Content-type:application/json' \
  "$SOLR_HOST/solr/$COLLECTION/update?commit=true" --data-binary @"$DATA_FILE"
```

---

#### **4. Execution Scenarios**

Execute these commands to validate the performance behaviors.

**Scenario A: The Standard Filter (Cached)**
* **Goal:** Reusable segment filtering.
* **Behavior:** First run is standard speed. Second run is near-instant (0ms) as it hits the `filterCache`.
```bash
# Run twice. The QTime of the second run should be ~0.
curl -k --negotiate -u : -s \
  "$SOLR_HOST/solr/$COLLECTION/select?q=*:*&fq=segment_s:Gold&debug=timing" \
  | grep "QTime"
```

**Scenario B: The Uncached Filter (Real-Time)**
* **Goal:** Filter by dynamic time (`NOW`).
* **Syntax:** `{!cache=false}` + `[NOW-1DAY+TO+NOW]` (Plus signs replace spaces).
* **Behavior:** Solr re-calculates the date math on every request. QTime remains consistent (e.g., 4ms) but never drops to 0, preventing cache pollution.
```bash
curl -k --negotiate -u : -g -s \
  "$SOLR_HOST/solr/$COLLECTION/select?q=*:*&debug=timing&fq="'{!cache=false}event_dt:[NOW-1DAY+TO+NOW]' \
  | grep "QTime"
```

**Scenario C: The Post-Filter (Optimization)**
* **Goal:** Run expensive math (`log(revenue)`) only on a small subset of users.
* **Syntax:** `cost=100` defer execution to the end.
* **Behavior:** Higher QTime (e.g., 54ms) confirms the operation is expensive. The `cost` parameter ensures this expense is only paid for documents passing the cheap `region_s` filter first.
```bash
curl -k --negotiate -u : -g -s \
  "$SOLR_HOST/solr/$COLLECTION/select?q=*:*&debug=timing&fq=region_s:US&fq="'{!frange+l=2+cost=100+cache=false}log(sum(revenue_f,1))' \
  | grep "QTime"
```

---

#### **5 The "Cost" of _fq_ Parameter Explained**

Solr executes filters in two distinct phases based on the `cost` value. This "Magic Threshold" of **100** determines whether Solr runs a filter against the entire index or only against the survivors of previous filters.

| Cost Value | Phase | Mechanism | Best For |
| :--- | :--- | :--- | :--- |
| **0 - 99** | **1. Intersection** | Solr scans the index for this field, builds a "Bitset" of all matching IDs, and intersects it with other sets. | Simple terms (`region:US`), Ranges (`price:[0 TO 10]`), or any Cached filter. |
| **>= 100** | **2. Post-Filter** | Solr takes the survivors from Phase 1 and runs logic on them **one by one**. | Expensive Math (`frange`), Geo-Spatial (`geofilt`), Access Control (ACLs). |

**The Execution "Funnel" Visualization:**

1. **Top of Funnel (Phase 1):** Solr runs all `cost=0` filters in parallel.
   * *Example:* `region:US` reduces 1,000,000 docs -> 3,000 survivors.
2. **Middle of Funnel (Intersection):** Solr combines these results.
3. **Bottom of Funnel (Phase 2):** Solr runs the `cost=100` filter.
   * *Example:* Calculate `log(revenue)` **only** on the 3,000 survivors.
   * *Result:* 50 final documents.

**Why this matters:**
Without `cost=100`, Solr might attempt to calculate `log(revenue)` for all 1,000,000 documents *before* checking if they were in the US, wasting massive amounts of CPU.

### **References:**

https://solr.apache.org/guide/solr/latest/query-guide/common-query-parameters.html

https://solr.apache.org/guide/solr/latest/configuration-guide/caches-warming.html

https://lucidworks.com/post/caching-and-filters-and-post-filters/
