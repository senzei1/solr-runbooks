# Runbook: Solr Replica Down Simulation (CDP)

## Objective
The objective of this runbook is to validate the High Availability (HA) and self-healing capabilities of an Apache SolrCloud cluster within a Cloudera CDP environment. By simulating the abrupt failure of a data-bearing node, we aim to confirm that the cluster can continue serving read and write traffic without interruption and that the failed node can recover its consistency automatically upon restart.

## Prerequisites
* **Environment:** Cloudera CDP (Solr 7.x / 8.x)
* **Access:** Root or sudo access to Solr nodes.
* **Authentication:** Kerberos ticket (`kinit`) required for `solrctl` and `curl`.
* **Tools:** `solrctl` (standard for CDP), `curl`, `systemctl`, `ps`, `kill`, `grep`.
* **Zookeeper:** Access to the Zookeeper ensemble (Port 2181).

---

## Phase 1: Configuration & Setup

We must explicitly define the cluster configuration to ensure consistent behavior regarding commit timings and transaction logging.

* **Prepare Configuration Directory:**
    Create a local directory named `configs` and populate it with the `solrconfig.xml` and `managed-schema.xml` files (See **Appendix A** for file contents).

* **Upload ConfigSet via solrctl:**
    Push the configuration to Zookeeper using the CDP standard tool.
    ```bash
    # 1. Authenticate
    kinit <your_user>@<REALM>

    # 2. Upload Configuration (runbook_conf is the name in ZK)
    solrctl config --upload runbook_conf ./configs/
    ```

* **Create the Collection:**
    Create `runbook_test` with 2 shards and replication factor 2.
    ```bash
    solrctl collection --create runbook_test -s 2 -r 2 -c runbook_conf
    ```

---

## Phase 2: Load Generation

Simulating failure on an idle cluster often hides concurrency issues. We generate synthetic read and write load to observe how the application behaves during the failure.

* **Start the Load Generator:**
    Create and run the `load_gen.sh` script (See **Appendix B** for content).
    ```bash
    chmod +x load_gen.sh
    ./load_gen.sh
    ```

* **Monitor Read Traffic (Optional):**
    In a third terminal, monitor read availability.
    ```bash
    # Replace <SOLR_HOST> with a valid hostname
    watch -n 1 "curl -s --negotiate -u : 'http://<SOLR_HOST>:8983/solr/runbook_test/select?q=*:*&rows=0'"
    ```

---

## Phase 3: Simulate Failure

In this phase, we identify a specific target component and forcefully terminate it.

* **Identify a Target Replica:**
    Query the cluster status to find a host running a replica.
    ```bash
    curl -s --negotiate -u : "http://<SOLR_HOST>:8983/solr/admin/collections?action=CLUSTERSTATUS&collection=runbook_test"
    ```

* **Kill the Node:**
    SSH into the target host, identify the Solr PID, and force-kill it.
    ```bash
    # SSH into the node
    ssh <TARGET_NODE>

    # Find the PID (User is typically 'solr')
    ps aux | grep solr

    # Kill the process forcefully
    kill -9 <PID>
    ```

---

## Phase 4: Verification & Analysis

Once the node is down, the cluster state must reflect the change.

* **Check Cluster State:**
    Run the `verify_cluster.sh` script (See **Appendix B** for content) to confirm Solr has marked the node as `gone` or `down`.
    ```bash
    chmod +x verify_cluster.sh
    ./verify_cluster.sh
    ```

* **Analyze Logs:**
    Check the logs of the *surviving* nodes to confirm they detected the failure.
    ```bash
    # Standard CDP log path
    tail -f /var/log/solr/solr.log | grep -E "Connection refused|gone|down"
    ```

---

## Phase 5: Recovery

The final phase tests the "self-healing" logic.

* **Restart the Node:**
    Use `systemctl` to bring the service back up on the node you killed.
    ```bash
    sudo systemctl start solr
    ```

* **Validate Recovery:**
    Watch the logs on the recovering node for sync messages.
    ```bash
    tail -f /var/log/solr/solr.log | grep -i "recovery"
    ```

* **Final Consistency Check:**
    Run the verify script one last time to ensure all nodes are `active`.
    ```bash
    ./verify_cluster.sh
    ```

---
