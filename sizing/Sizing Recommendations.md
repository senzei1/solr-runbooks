# Runbook: Solr Architecture & Tuning Concepts in CDP

## 1. Memory Management Strategy: JVM Heap and OS Page Cache
The documentation highlights that mismanaging RAM is a primary cause of performance issues. Solr requires memory in two distinct areas.

### The Concept
* **Java Heap:** Used for the application (live objects, caches).
* **OS Page Cache:** Solr relies on the operating system to cache the index files (which are stored on disk) in free RAM.

**The Conflict:** The documentation warns against allocating too much RAM to the Heap (`SOLR_JAVA_MEM`). If the Heap is too large, it "starves" the OS Page Cache. This forces Solr to read from the physical disk instead of RAM, causing severe performance degradation.

### How to Apply in CDP
* **Rule of Thumb:** Do not allocate all available memory to the Solr Heap. You must leave significant "free" memory for the OS to cache the index.
* **Cloudera Manager Configuration:**
    * *Setting:* `Java Heap Size of Solr Server in Bytes`.
    * *Action:* Set this to a value that balances application needs while leaving the majority of RAM free for the OS.

---

## 2. Storage Architecture: I/O Patterns and Isolation
The "Deployment Guidelines" documentation emphasizes that storage performance is critical for search workloads.

### The Concept
* **Random I/O:** Search workloads are characterized by "random I/O" (jumping to different parts of the disk to find index segments). This is fundamentally different from the "sequential I/O" patterns used by HDFS.
* **Isolation:** Because of these conflicting patterns, Solr performance suffers if it shares disk resources with HDFS DataNodes or other heavy workloads.

### How to Apply in CDP
* **Rule of Thumb:** Solr requires dedicated storage resources to ensure high IOPS (Input/Output Operations Per Second).
* **Hardware Requirement:** The guidelines explicitly recommend using **SSDs** (Solid State Drives) over spinning HDDs for the Solr data directory.
* **Cloudera Manager Configuration:**
    * *Setting:* `Solr Data Directory`.
    * *Action:* Configure this path to point to local storage, isolated from the OS and other cluster services.

---

## 3. Garbage Collection Tuning
The "Environment Specific Parameters" documentation identifies Garbage Collection (GC) as a key stability factor.

### The Concept
When Java cleans up unused memory (Garbage Collection), it can pause the application ("Stop-the-World"). If these pauses are too long, the node becomes unresponsive.
* **G1GC:** The documentation recommends using the G1 (Garbage-First) collector for large heaps, as it manages memory cleanup more efficiently than older collectors.

### How to Apply in CDP
* **Rule of Thumb:** Tuning GC arguments is necessary to prevent long pauses that disrupt the cluster.
* **Cloudera Manager Configuration:**
    * *Setting:* `Java Configuration Options for Solr Server`.
    * *Action:* Append `-XX:+UseG1GC` (optionally add `-XX:MaxGCPauseMillis=200` to target a specific pause duration).

---

## 4. Cluster Stability and Timeout Configuration
The documentation notes that environment-specific network latency or load can cause nodes to disconnect prematurely.

### The Concept
* **Zookeeper Timeouts:** Solr nodes must send "heartbeats" to ZooKeeper to prove they are alive.
* **The Risk:** Under heavy load (like massive indexing), a node might become slow to respond. If the timeout is too strict, ZooKeeper will incorrectly assume the node is dead and remove it from the cluster.

### How to Apply in CDP
* **Rule of Thumb:** The default timeout may be insufficient for high-load or slower environments.
* **Cloudera Manager Configuration:**
    * *Setting:* `ZooKeeper Client Timeout`.
    * *Action:* Increase this value (parameter: `zkClientTimeout`) to provide a larger buffer, preventing healthy (but busy) nodes from being evicted.
