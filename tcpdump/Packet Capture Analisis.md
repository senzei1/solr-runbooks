# Lab: TCPDump Analysis

**Context:**
A common, confusing support scenario occurs when a client reports a "Timeout" or "Connection Reset," but the Server Logs show the operation succeeded (e.g., `status: 0`, `QTime: 7`).

This lab reproduces this scenario by creating a **Network Partition** exactly when the server tries to send the response.

> **Note:** We used _tc_ to induce some lag to replicate this scenario: _point out if a live merge (MERGEINDEXES) operation succeeds on the solr server, but a firewall cuts the connections before the result could be returned to the indexer client._

### **1. The Theory**
We use Linux Traffic Control (`tc`) to decouple **Processing Time** from **Delivery Time**.
1.  **Lag Phase:** We force the OS to hold every packet for 3 seconds.
2.  **Execution:** Solr processes the request instantly (~10ms) and hands the "Success" packet to the OS.
3.  **Trap:** The OS holds the packet in the "Lag Buffer" for 3 seconds.
4.  **Sabotage:** We sever the connection (Firewall) before the 3 seconds are up.

**Result:** The operation succeeds on disk, but the reporting fails on the wire.

---

### **2. Reproduction Script (`ghost_lab.sh`)**
Save this script on the Solr node. It handles tool installation and executes the sabotage automatically.

**Note:** You will need **Wireshark** installed on your local workstation (Mac/Windows) to analyze the resulting `.pcap` file. Download it from [wireshark.org](https://www.wireshark.org/).

```bash
#!/bin/bash
# Usage: ./ghost_lab.sh

SOLR_PORT=8985
COLLECTION="cdp_demo"
SOLR_HOST="https://$(hostname -f):$SOLR_PORT"
PCAP_FILE="/tmp/solr_ghost_traffic.pcap"

# --- 1. Prerequisite Check & Installation ---
echo "--- Checking Dependencies ---"
NEEDS_INSTALL=0
if ! command -v tc &> /dev/null; then NEEDS_INSTALL=1; fi
if ! command -v tcpdump &> /dev/null; then NEEDS_INSTALL=1; fi
if ! command -v firewall-cmd &> /dev/null; then NEEDS_INSTALL=1; fi

if [ $NEEDS_INSTALL -eq 1 ]; then
  echo "Installing required tools (firewalld, tc, tcpdump)..."
  # CentOS/RHEL 8+
  dnf install -y firewalld iproute-tc tcpdump
fi

# Ensure Firewall is running (Required for the sabotage step)
if ! systemctl is-active --quiet firewalld; then
  echo "Starting Firewalld Service..."
  systemctl enable --now firewalld
  sleep 3 # Wait for service to initialize
fi

# --- 2. Setup: Clean Slate & Add Lag ---
echo "--- Setup: Configuring 3s Latency on Loopback ---"
# Clean up old artifacts
rm -f $PCAP_FILE
tc qdisc del dev lo root > /dev/null 2>&1
firewall-cmd --direct --remove-rule ipv4 filter OUTPUT 0 -p tcp --sport $SOLR_PORT -j DROP > /dev/null 2>&1

# Add 3000ms delay to loopback interface
# This creates the "Time Warp" allowing us to trap the packet
tc qdisc add dev lo root netem delay 3000ms

# --- 3. Start Capture ---
echo "--- Starting Packet Capture ---"
# Run as root (-Z root) to avoid permission errors when writing to /tmp
nohup tcpdump -Z root -i lo port $SOLR_PORT -w $PCAP_FILE > /dev/null 2>&1 &
TCPDUMP_PID=$!
sleep 1

# --- 4. Trigger Request ---
echo "--- Triggering Solr Request (Handshake will take ~12s) ---"
# High timeout needed because the handshake is now very slow (3s per packet)
curl -k --negotiate -u : -v --connect-timeout 30 \
  "$SOLR_HOST/solr/$COLLECTION/update?optimize=true&maxSegments=1&waitSearcher=true" &

# --- 5. The Wait & Sabotage ---
echo "--- Waiting 14s for Request to Land... ---"
# Timeline:
# T+0s: Curl starts
# T+12s: Handshake complete, Request Sent. Solr finishes instantly.
# T+12.1s: Response (200 OK) enters the 3s Lag Buffer.
sleep 14

echo "--- CUTTING CONNECTION (Firewall Active) ---"
# We kill the connection while the response is stuck in the buffer
firewall-cmd --direct --add-rule ipv4 filter OUTPUT 0 -p tcp --sport $SOLR_PORT -j DROP

# --- 6. Cleanup ---
sleep 5
echo "--- Restoring Network ---"
kill $TCPDUMP_PID
firewall-cmd --direct --remove-rule ipv4 filter OUTPUT 0 -p tcp --sport $SOLR_PORT -j DROP
tc qdisc del dev lo root

echo "--- Lab Complete. Artifact: $PCAP_FILE ---"
```

---

### **3. Wireshark Forensics**
Once you have the `.pcap` file, transfer it to your desktop and open it in Wireshark.
Since Solr uses HTTPS, you cannot read the text "HTTP 200 OK". You must identify the traffic flow in the **Packet List** (Top Pane).

#### **Step 3.1: Verify the Lag (The "Time Warp")**
* **Filter:** `tcp.port == 8985`
* **Check:** The time between `SYN` (Frame 1) and `SYN, ACK` (Frame 2) should be exactly **3.0 seconds**. This proves the network was artificially slowed.

<img width="1024" height="414" alt="image" src="https://github.com/user-attachments/assets/2e14f1d7-e335-4dc2-ad26-3dfb6ffe8e02" />

This confirms that the operating system was holding packets back, creating the conditions for the "Ghost" scenario.

#### **Step 3.2: Verify the "Ghost" Response**
Remove the filter and look at the very end of the packet list (around Time = 14s). You will see a packet similar to **Frame 24**:
* **Source:** Port 8985 (Server)
* **Flag:** `[PSH, ACK]`
* **Length:** `Len=764` (or similar size > 0)
* **Interpretation:** The `PSH` flag and non-zero length prove that Solr **generated a response payload** (The encrypted "Success" message). If Solr had failed, this packet would not exist.

#### **Step 3.3: Verify the Failure**
Immediately after Frame 24, you will NOT see an `ACK` from the client acknowledging receipt. Instead, the conversation stops or you see retransmissions. This proves the client never got the message.

---

### **4. Summary for the Customer**
When you encounter this in production, use this template:

> "I have analyzed the packet capture. The evidence shows that **Solr successfully processed the request** (see `HTTP 200 OK` in the capture stream).
>
> However, the TCP connection was severed immediately after the response was generated (see `TCP RST` at the end of the stream). This indicates the operation completed on the application side, but a network device (Firewall, Load Balancer, or congested Link) prevented the success confirmation from reaching the client."
