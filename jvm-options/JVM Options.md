# Runbook: Optimizing Solr Memory ("The 35GB Trap")

## 1. Scenario: The "Bigger is Not Better" Paradox
You manage a critical SolrCloud cluster for Big Data Analytics. As data volume grew, you recently increased the Solr Heap size from **24GB** to **34GB**, expecting a performance boost.

**The Problem:**
Instead of improving, performance has **degraded**.
* **Latency Spikes:** You are seeing frequent, long pauses in search requests.
* **Higher Memory Usage:** Despite adding 10GB of RAM, Solr seems to run out of memory *faster* than before.

**The Cause:**
You have fallen into the "Compressed Oops" trap. By crossing the 32GB threshold, the JVM forced all memory pointers to double in size (from 32-bit to 64-bit), effectively consuming the extra memory you just added and making the CPU work harder.

## 2. Objective
To optimize the Solr JVM by **reducing** the allocated memory to enter the "Sweet Spot" and switching to a modern Garbage Collector (G1GC) to stabilize pause times.

## 3. Concepts (Simplified)

### 🧱 Compressed Oops (Ordinary Object Pointers)
Think of your JVM memory like a library.
* **Below 32GB (Compressed):** The JVM uses "short codes" (32-bit) to locate books. These codes are small and fast to read.
* **Above 32GB (Uncompressed):** The library is too big for short codes. The JVM switches to "long codes" (64-bit).
* **The Trap:** If you size your library at **34GB**, the overhead of using "long codes" for *every single book* consumes about 40% more space. A 34GB library actually holds *fewer* books than a 31GB library!

### 🧹 G1GC (Garbage First Garbage Collector)
Think of Garbage Collection (GC) as cleaning the library.
* **CMS (Old Default):** Waits until the library is messy, then stops everyone from reading while it does a massive cleanup. This causes long "pauses."
* **G1GC (Recommended):** Cleans small sections of the library constantly in the background. It predicts how long cleaning will take and pauses only for very short, predictable bursts.

## 4. Prerequisites
* **Environment:** Cloudera CDP 7.1.9 SP1.
* **Access:** Cloudera Manager (Admin) or `solrctl` access.
* **Current State:** Solr Heap set to > 32GB (e.g., 34GB, 40GB).

---

## 5. Execution Steps

### Step 5.1: Verify Current "Bad" State
Check your JVM flags to confirm you are using 64-bit pointers (Compressed Oops disabled) and the legacy GC.

**Command:**
```bash
# Get the Process ID of Solr
SOLR_PID=$(pgrep -f "solr-SOLR_SERVER")

# 1. Check for Compressed Oops (Looking for "false" or missing "true")
jinfo -flag UseCompressedOops $SOLR_PID

# 2. Check Heap Size (Looking for -XX:MaxHeapSize=36507222016 or similar large number)
jinfo -flag MaxHeapSize $SOLR_PID
```

### Step 5.2: The Fix - Resize Heap to the "Sweet Spot"
We will **reduce** the Heap size to **31GB**. This is slightly below the 32GB physical limit, ensuring Compressed Oops are enabled. This effectively gives us *more* usable space than 34GB.

**Action (Cloudera Manager):**
1.  Go to **Clusters** > **Solr** > **Configuration**.
2.  Search for **Java Heap Size of Solr Server in Bytes**.
3.  Change value from `34 GB` to `31 GB`.

### Step 5.3: Enable G1GC
For Heaps larger than 4-8GB, Cloudera recommends G1GC over CMS to prevent long pauses.

**Action (Cloudera Manager):**
1.  Search for **Java Configuration Options for Solr Server** (often `solr_java_opts`).
2.  **Remove** legacy flags if present:
    * `-XX:+UseConcMarkSweepGC`
    * `-XX:+UseParNewGC`
3.  **Add** the G1GC flag:
    * `-XX:+UseG1GC`
4.  *(Optional but Recommended)* Add G1GC tuning targets:
    * `-XX:MaxGCPauseMillis=200` (Tells JVM to try and keep pauses under 200ms)

### Step 5.4: Restart and Verify
Restart the Solr service to apply changes. Once up, verify the optimization is active.

**Command:**
```bash
SOLR_PID=$(pgrep -f "solr-SOLR_SERVER")

# 1. Verify G1GC is active
jinfo -flag UseG1GC $SOLR_PID
# Output should be: -XX:+UseG1GC

# 2. Verify Compressed Oops are ENABLED
jinfo -flag UseCompressedOops $SOLR_PID
# Output should be: -XX:+UseCompressedOops
```

## 6. Summary of Results
By **decreasing** the memory allocation from 34GB to 31GB:
* **Capacity Increased:** You can now store *more* documents because pointers are 50% smaller.
* **Latency Decreased:** CPU cache usage is more efficient, and G1GC prevents massive "stop-the-world" freezes.

