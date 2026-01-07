# Runbook: Kerberos Troubleshooting

## 1. Hostname and Network Configuration

**Concept & Use Case**
The Kerberos library depends heavily on accurate hostname configuration to function correctly. It requires that every host has a Fully Qualified Domain Name (FQDN) configured. Furthermore, the system must be able to perform both forward lookups (hostname to IP) and reverse lookups (IP to hostname) to verify the identity of the machines communicating within the cluster. This ensures that a service running on "node1" is actually who it claims to be.

**Actionable Steps**
* **Verify FQDN:** Run `hostname -f` to ensure the FQDN is set (e.g., `node1.example.com`).
* **Set FQDN:** Use the systemd command to set the hostname permanently:
    `sudo hostnamectl set-hostname <new-FQDN>`
* **Check DNS Forward Lookup:** Run `dig +noall +answer <host-FQDN>`.
* **Check DNS Reverse Lookup:** Run `dig +noall +answer +x <IP-address>`.
* **Check Local Lookup (/etc/hosts):** Run `ping -c 2 <host-FQDN>` and verify the IP matches the entry in `/etc/hosts`.

---

## 2. Time Synchronization (NTP/Chrony)

**Concept & Use Case**
Kerberos is time-sensitive to prevent replay attacks. The library assumes all nodes in the network are synchronized within a 5-minute window. If the time difference between a client and the KDC (Key Distribution Center) exceeds this limit, the Kerberos library will reject the authentication requests. Modern Linux systems often use `chronyd` or `systemd-timesyncd` instead of the legacy `ntp` daemon.

**Actionable Steps**
* **Check Synchronization Status:**
    * **RHEL 8/9 / CentOS Stream:** Run `chronyc tracking`. Look for "Leap status : Normal" and small "System time" offset.
    * **Ubuntu/Debian:** Run `timedatectl status` and ensure "System clock synchronized: yes".
* **Verify Time:** Run `date -u` on all nodes and KDC servers to ensure they are manually within 5 minutes of each other if automated sync is failing.

---

## 3. Central Configuration (`krb5.conf`)

**Concept & Use Case**
The `/etc/krb5.conf` is the central configuration file used by both KDC and client hosts. It defines the `default_realm`, how the system locates the KDC (via config or DNS), and how domains map to specific realms. Correct configuration here is vital for multi-realm setups and cross-realm trust.

**Actionable Steps**
* **Set Default Realm:** Ensure `default_realm = REALM` points to the correct default environment.
* **Configure DNS Lookup:** Set `dns_lookup_realm` and `dns_lookup_kdc` to `false` unless you have explicitly configured DNS SRV records for Kerberos.
* **Define KDCs:** In the `[realms]` section, list the KDC and admin server hosts.
* **Map Domains:** In the `[domain_realm]` section, map each host or domain to its correct realm.
* **Set Cache Location:** Define `default_ccache_name = /tmp/krb5cc_%{uid}` to ensure credentials are stored in the local filesystem, which is required for many Hadoop Java libraries.

> **Note:** CDP platform doesn't support _keyring_ cache for kerberos.

---

## 4. User and Service Principals

**Concept & Use Case**
Principals are the unique identities in Kerberos. They can be user principals (e.g., `jane@REALM`) or service principals (e.g., `nn/host1.hwx.com@REALM`). Before accessing any secure service, a valid ticket must be acquired for the correct principal. For services, ensuring the "ServiceName" (sname) is correct in the configuration is critical.

**Actionable Steps**
* **Check Current Ticket:** Run `klist`.
* **Destroy Ticket:** Run `kdestroy` to clear the cache.
* **Get User Ticket:** Run `kinit <user-principal-name>`.
* **Verify Service Principal:** Check the service configuration (e.g., `dfs.namenode.kerberos.principal` in Hadoop/HDFS files) if authentication fails.

---

## 5. Keytab Maintenance & Key Version Numbers (KVNO)

**Concept & Use Case**
Services use keytab files to authenticate automatically. Keytabs can become "stale" if the password or key changes on the KDC but not in the local keytab file. The Key Version Number (KVNO) in the keytab must match the KVNO on the KDC.
* **Note:** If using Microsoft Active Directory (AD), the KVNO is often ignored or set to zero, so mismatches may be false alarms in AD environments.

**Actionable Steps**
* **Inspect Keytab:** Run `klist -kt <keytab-file>` to see the principal and KVNO inside the file.
* **Check KDC KVNO:**
    * Authenticate as a user: `kinit <user-principal>`.
    * Query the service principal version: `kvno <service-principal-name>`.
* **Compare:** Ensure the number returned by `kvno` matches the output of `klist` (unless using AD).

---

## 6. Java Security & Encryption (JCE)

**Concept & Use Case**
To support strong encryption types like AES256, the Java Virtual Machine (JVM) must have the "unlimited key JCE" policy enabled.
* **Update:** In modern Java versions (JDK 8u161+, JDK 11, JDK 17, JDK 21), the unlimited policy is **enabled by default**. You typically do not need to install policy JARs manually anymore.

**Actionable Steps**
* **Test Policy:** Run the policy check tool (if available in your cluster distribution) or a simple Java command to print `Cipher.getMaxAllowedKeyLength("AES")`.
* **Verify Result:** The output must indicate "Unlimited" or `2147483647` (max integer).

---

## 7. Debugging and Logging

**Concept & Use Case**
When authentication fails, standard error messages are often insufficient. Enabling `KRB5_TRACE` allows administrators to see the detailed packet flow, including hostname resolution and KDC connection attempts. For Java applications, JVM-level debugging flags trace the JAAS and SPNEGO layers.

**Actionable Steps**
* **Enable Client Trace:**
    * `export KRB5_TRACE=/tmp/kinit.log`
    * Run the command (e.g., `kinit`)
    * Review `/tmp/kinit.log` for errors like "Response was not from master KDC" or "Preauth failed".
* **Enable JVM Debug:** Add the following flags to the application's environment variables (e.g., `CATALINA_OPTS` or `HADOOP_OPTS`):
    `-Dsun.security.krb5.debug=true -Dsun.security.jgss.debug=true -Dsun.security.spnego.debug=true`
* **Check KDC Logs:**
    * **MIT KDC:** Check `/var/log/kerberos/krb5kdc.log`.
    * **Microsoft AD:** Check the Windows System Event log.

---

## 8. Web Authentication (SPNEGO)

**Concept & Use Case**
SPNEGO allows HTTP clients (browsers) to authenticate with web services using Kerberos credentials. This restricts web console access to only those users with valid tickets.

**Actionable Steps**
* **Configure Browser:** Browsers (Chrome, Edge, Firefox) must be explicitly configured to whitelist the domain for SPNEGO negotiation.
* **Negotiation Check:** If access fails, check if the browser is prompting for a password (basic auth) instead of negotiating silently; this usually indicates a browser configuration or trusted zone issue.
