# Runbook: Diagnosing and Resolving Class Loading Conflicts

## 1. Overview
In distributed systems like CDP, "Class Loading Hell" (or Dependency Hell) occurs when a runtime environment forces an application to load an incompatible version of a library (JAR) instead of the version it was compiled against. This typically happens when third-party parcels, custom applications, or "fat JARs" introduce conflicting versions of common libraries (e.g., Lucene, Jackson, Guava, Protobuf) into the global classpath.

---

## 2. Symptoms and Error Signatures
Class loading issues rarely say "Classpath Conflict." Instead, they manifest as runtime crashes with specific Java exceptions.

### A. The "Wrong Version" Symptoms
These occur when a class is found, but it is an older or newer version than expected.
* **`java.lang.NoSuchMethodError`**: The most common signal. The JVM loaded a class (e.g., `com.google.common.base.Preconditions`), but the specific method called implies the loaded JAR is a different version than the code expects.
* **`java.lang.IncompatibleClassChangeError`**: The binary structure of the loaded class definition does not match what the calling code expects (e.g., a static field became non-static).
* **`java.lang.VerifyError`**: Often seen with `Cannot inherit from final class`. This indicates the loaded class has been modified in a way that violates Java bytecode verification rules relative to the parent class.

### B. The "Missing Class" Symptoms
* **`java.lang.ClassNotFoundException`**: The class is physically missing from the runtime classpath.
* **`java.lang.NoClassDefFoundError`**: The class was present during compilation but missing (or failed to initialize) at runtime.

### C. Operational Signals
* **"It works in Dev but fails in Prod":** Often indicates a Production-only Parcel (like a monitoring agent or security tool) is polluting the global classpath.
* **"It fails after a Cluster Upgrade":** Indicates a system JAR version changed, causing a conflict with a static user JAR.

---

## 3. Troubleshooting Methodology



### Step 3.1: Locate the Source (The "Verbose" Probe)
When a job fails with a version conflict, the standard stack trace is insufficient because it doesn't tell you *where* the bad class came from. You must enable verbose class loading.

**For MapReduce / Oozie / Hive:**
Add the following to your JVM options:
```bash
-Dmapreduce.map.java.opts="-verbose:class -XX:+PrintClassHistogram"
-Dmapreduce.reduce.java.opts="-verbose:class"
```

**For Spark:**
Add to `spark-submit` or `spark-defaults.conf`:
```bash
--conf "spark.driver.extraJavaOptions=-verbose:class"
--conf "spark.executor.extraJavaOptions=-verbose:class"
```

### Step 3.2: Analyze the Logs for "Shadowing"
Run the job until failure, then capture the `stderr` logs. Search for the class mentioned in the stack trace.

**Example Trace Analysis:**
> *Error:* `NoSuchMethodError: org.apache.lucene.index.IndexWriter`
>
> *Verbose Log Entry:*
> `[Loaded org.apache.lucene.index.IndexWriter from file:/opt/cloudera/parcels/CUSTOM_APP/lib/lucene-core-4.10.3.jar]`

**Diagnosis:** The JVM loaded Lucene 4.10 from a Custom Parcel instead of the expected Lucene 7.x/8.x from CDH. The Custom Parcel is "shadowing" the system libraries.

### Step 3.3: Inspect the Global Environment
Determine how the conflicting path entered the classpath. Check the environment variables generated on the gateway/client nodes.

```bash
# Check standard Hadoop variables
grep -E "CLASSPATH|MR2_CLASSPATH" /etc/hadoop/conf/hadoop-env.sh

# Check if a custom script is modifying the shell environment
env | grep CLASSPATH
```

---

## 4. Classpath Configuration Tips & Solutions



### A. The "User-First" Strategy (Configuration)
If your job brings its own libraries (e.g., inside a fat jar) that conflict with Hadoop's internal libraries, you can instruct YARN to prioritize your JARs over the system JARs.

**Configuration:** `mapreduce.job.user.classpath.first`
* **Set to `true`**: The framework adds the user's lib directory to the *beginning* of the classpath.
* **Use Case:** Your app needs a newer version of Jackson or Guava than what CDP ships with.
* *Warning:* This can break Hadoop functionality if you accidentally override core Hadoop classes. Use with caution.

### B. The "Client Isolation" Strategy (Environment)
If a global environment variable (like `MR2_CLASSPATH`) is "polluted" by a "rogue" parcel, you can isolate your job by using a sanitized configuration directory.

**Mechanism:**
1.  Copy the `/etc/hadoop/conf` directory to a local workspace.
2.  Edit `mapred-site.xml` to explicitly define `mapreduce.application.classpath` *without* the variable referencing the bad parcel.
3.  Run your job with `export HADOOP_CONF_DIR=/path/to/clean/conf`.

### C. The "Shading" Strategy (Build Time)
The most robust fix for Java developers is to avoid the conflict entirely by "Shading" (renaming) dependencies during the build process.

**Mechanism (Maven Shade Plugin):**
* **Concept:** Rename `com.google.common.*` to `my.app.shaded.google.common.*` inside your JAR.
* **Result:** Your application uses its own private copy of the library, and the Hadoop system uses its own copy. They never collide because the package names are technically different.

### D. The "Custom Service Descriptor" (CSD) Audit
If you manage the cluster, verify how third-party services inject themselves.
* **Audit Path:** `/opt/cloudera/csd/` or `/var/lib/cloudera-scm-server/`
* **Check:** Look for `service.sdl` files that modify `HADOOP_CLASSPATH`. Ensure these modifications are scoped to specific roles, not applied globally to the Gateway configuration.

---

## 5. Summary Checklist for Resolution

| Step | Action | Command/Tool |
| :--- | :--- | :--- |
| **1. Identify** | Confirm it is a class conflict (not a logic bug). | Look for `NoSuchMethod`, `VerifyError`. |
| **2. Trace** | Find the physical JAR file causing the issue. | `-verbose:class` |
| **3. Isolate** | Determine if the JAR is User-provided or System-provided. | Check log paths (`/opt/cloudera/...`). |
| **4. Resolve** | Apply the appropriate fix. | `user.classpath.first=true` (if User jar is right) <br> OR <br> `HADOOP_CONF_DIR` isolation (if System env is polluted). |
