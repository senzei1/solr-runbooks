# Runbook Addendum: Advanced JVM Tuning for Solr

## 1. Objective
To harden the Solr JVM configuration beyond basic memory sizing. These settings improve how Solr handles heavy indexing, unexpected crashes, and network instability.

## 2. Recommended Options Checklist

### 🚀 Performance Flags

* **`-XX:+ParallelRefProcEnabled`**
    * **What it does:** Uses multiple CPU threads to clean up "weak" references (temporary objects) during Garbage Collection.
    * **Why for Solr:** Solr caches (Filter Cache, Query Result Cache) rely heavily on these weak references. Without this flag, GC pauses can spike because a single thread is stuck cleaning up millions of cache entries.

* **`-XX:+UseStringDeduplication`**
    * **What it does:** The JVM identifies duplicate text strings in memory and makes them point to the same location, saving space.
    * **Why for Solr:** Solr stores massive amounts of text (IDs, field names, tokens). This flag can reduce Heap usage by 10-20% with minimal CPU overhead, effectively giving you "free" memory.

### 🛡️ Stability & Debugging Flags

* **`-XX:+HeapDumpOnOutOfMemoryError`**
    * **What it does:** Automatically saves a snapshot of memory (Heap Dump) to disk the moment Solr crashes due to "Out of Memory" (OOM).
    * **Why for Solr:** Without this, an OOM crash leaves no evidence. You will restart the server and have *no idea* why it crashed (e.g., a massive query? a huge document?).

* **`-XX:HeapDumpPath=/var/log/solr`**
    * **What it does:** Tells the JVM *where* to write the Heap Dump.
    * **Why for Solr:** By default, it might write to a random directory or fail if disk space is low. Pointing it to a large partition ensures you actually capture the evidence.

* **`-XX:-OmitStackTraceInFastThrow`**
    * **What it does:** Forces the JVM to *always* print the full error trace, even if the error happens thousands of times.
    * **Why for Solr:** By default, after an error (like `NullPointerException`) happens frequently, the JVM optimizes performance by suppressing the error message. This makes debugging impossible because you just see "NullPointerException" with no context.

### 📝 GC Logging (JDK 11 / CDP 7)

In older versions (JDK 8), you used `-PrintGCDetails`. In **CDP 7.1.9 (JDK 11)**, the syntax has changed completely to the Unified Logging framework (`-Xlog`).

* **The Command:**
    `-Xlog:gc*:file=/var/log/solr/solr_gc.log:time,uptime:filecount=10,filesize=100M`
* **Why for Solr:** "Stop-the-world" pauses are the #1 enemy of Solr performance. These logs are the *only* way to prove if a slow search was caused by Solr code or a JVM freeze.

---

## 3. Implementation Steps

### Step 3.1: Locate the Configuration Safety Valve
In Cloudera Manager, you cannot always find a checkbox for these specific advanced flags. You must use the "Safety Valve".

1.  Go to **Clusters** > **Solr** > **Configuration**.
2.  Search for **Java Configuration Options for Solr Server**.

### Step 3.2: Add the Flags
Paste the following flags directly into the Safety Valve text box (ensure they are space-separated):

```text
-XX:+ParallelRefProcEnabled -XX:+UseStringDeduplication -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/var/log/solr -XX:-OmitStackTraceInFastThrow -Xlog:gc*:file=/var/log/solr/solr_gc.log:time,uptime:filecount=10,filesize=100M
```

### Step 3.3: Restart
Restart the Solr service.

---

## 4. Verification

To confirm these flags are actually running, check the process arguments:

```bash
# 1. Get Solr PID
SOLR_PID=$(pgrep -f "solr-SOLR_SERVER")

# 2. Check for a specific flag (e.g., ParallelRefProcEnabled)
jinfo -flag ParallelRefProcEnabled $SOLR_PID
# Output should be: -XX:+ParallelRefProcEnabled
```
