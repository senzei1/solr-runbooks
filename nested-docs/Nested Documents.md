# Runbook: Solr Nested Objects on CDP

## 1. Overview
Nested Objects (Nested Documents) in Solr allow for the indexing of a document hierarchy where "child" documents are embedded within a "parent" document. This architecture maintains the relationship between entities within the same index block.

### Reasons for Usage
One primary reason to use nested objects is to ensure data integrity during searches by preventing "false matches." In a traditional flat schema, attributes are often flattened into arrays (e.g., a shirt with `colors=[Red, Blue]` and `sizes=[M, L]`). A search for "Red AND M" would return this document even if the actual inventory is "Red L" and "Blue M," because the relationship between the specific color and size is lost. Nesting preserves this correlation.

Another reason is performance efficiency. Solr stores the child documents physically adjacent to the parent document on the disk. This locality allows Solr to perform "Block Joins" at query time with significantly lower latency and memory overhead compared to joining documents across separate collections or cores.

### Use Case Options
* **eCommerce Inventories:** Modeling a generic Product (Parent) with specific SKUs (Children) to filter by specific attribute combinations.
* **Content Hierarchies:** Indexing a Book (Parent) with individual Chapters or Reviews (Children).
* **Event Logging:** Grouping a User Session (Parent) with multiple distinct Activity Events (Children).

## 2. Environment Setup (Secure CDP)
This section assumes a production-grade CDP environment where **Kerberos** authentication and **TLS/SSL** encryption are strictly enforced. All commands use the Fully Qualified Domain Name (FQDN) via `$(hostname -f)` and target port **8985**.

### Prerequisites
* **Kerberos Ticket:** You must have a valid Kerberos ticket for a user with Solr permissions.
* **Root CA Certificate:** You need the path to the internal CA certificate (often found at `/var/lib/cloudera-scm-agent/agent-cert/cm-auto-global_cacerts.pem` in CDP) to verify SSL connections.

### Configuration Steps
1.  **Authenticate via Kerberos:**
    Ensure you have a valid ticket before running any commands.
    ```bash
    kinit <your_principal>
    ```

2.  **Generate a Default Configuration:**
    Create a local configuration directory using the default templates provided by the CDP distribution.
    ```bash
    solrctl instancedir --generate $HOME/nested_demo_conf
    ```

3.  **Upload Configuration to Zookeeper:**
    Upload the generated configuration to the Solr Zookeeper ensemble. `solrctl` handles the secure connection automatically if `kinit` is active.
    ```bash
    solrctl instancedir --create nested_demo_conf $HOME/nested_demo_conf
    ```

4.  **Create the Collection:**
    Initialize the collection using the uploaded configuration.
    ```bash
    solrctl collection --create nested_demo -s 1 -r 1 -c nested_demo_conf
    ```

## 3. Indexing Nested Data
In a secure CDP environment, indexing requires `curl` to handle SPNEGO (Kerberos) negotiation and TLS verification on port 8985.

### Concept
You must structure your JSON payload so that child documents are contained within a special field key named `_childDocuments_`. Solr will automatically flatten this into a block structure on the disk.

### Execution
Run the following command. Note the use of `https`, `$(hostname -f)`, port `8985`, and authentication flags.

**Parameters:**
* `--negotiate -u :`: Initiates Kerberos SPNEGO authentication.
* `--cacert ...`: Verifies the SSL certificate using the CDP Truststore.

```bash
curl --negotiate -u : --cacert /var/lib/cloudera-scm-agent/agent-cert/cm-auto-global_cacerts.pem \
-X POST -H 'Content-Type: application/json' \
"https://$(hostname -f):8985/solr/nested_demo/update?commitWithin=1000" --data-binary '
[
  {
    "id": "book1",
    "type_s": "book",
    "title_t": "The Way of Kings",
    "author_s": "Brandon Sanderson",
    "cat_s": "fantasy",
    "_childDocuments_": [
      { "id": "book1_c1", "type_s": "review", "stars_i": 5, "author_s": "yonik", "comment_t": "Great start!" },
      { "id": "book1_c2", "type_s": "review", "stars_i": 3, "author_s": "dan", "comment_t": "Too long." }
    ]
  },
  {
    "id": "book2",
    "type_s": "book",
    "title_t": "Snow Crash",
    "author_s": "Neal Stephenson",
    "cat_s": "sci-fi",
    "_childDocuments_": [
      { "id": "book2_c1", "type_s": "review", "stars_i": 5, "author_s": "yonik", "comment_t": "Ahead of its time." },
      { "id": "book2_c2", "type_s": "review", "stars_i": 2, "author_s": "dan", "comment_t": "Not my style." }
    ]
  }
]'
```

## 4. Querying and Retrieval
Standard queries only return the specific documents that match (parents or children). To retrieve a hierarchy, you must use the `[child]` doc transformer.

### Concept
With the modern default schema in CDP, Solr automatically detects the nested structure. You **do not** need to provide a `parentFilter`. Providing one may result in a `400 Bad Request` error.

### Execution
Retrieve all "Fantasy" or "Sci-Fi" books and include their child reviews in the response.

```bash
curl --negotiate -u : --cacert /var/lib/cloudera-scm-agent/agent-cert/cm-auto-global_cacerts.pem \
-g "https://$(hostname -f):8985/solr/nested_demo/query" -d '
  q=cat_s:(fantasy OR sci-fi)&
  fl=id,title_t,[child]'
```

### Options
* `limit`: Restricts the number of children returned per parent (default is usually 10).
    * *Example:* `fl=id,title_t,[child limit=5]`

## 5. Analytics (Faceting)
The JSON Facet API in Solr allows for "domain switching," enabling you to switch the context of the aggregation from parents to children (or vice versa) during execution.

### Scenario A: Facet on Parents based on Child Data
**Goal:** Find reviews by author "yonik" (Child), but count the associated Books by Genre (Parent).

```bash
curl --negotiate -u : --cacert /var/lib/cloudera-scm-agent/agent-cert/cm-auto-global_cacerts.pem \
-g "https://$(hostname -f):8985/solr/nested_demo/query" -d '
  q=author_s:yonik&
  fl=id&
  json.facet={
    genres: {
      type: terms,
      field: cat_s,
      domain: { blockParent : "type_s:book" }
    }
  }'
```

### Scenario B: Facet on Children based on Parent Data
**Goal:** Find "Sci-Fi" Books (Parent), but count the top Review Authors (Child).

```bash
curl --negotiate -u : --cacert /var/lib/cloudera-scm-agent/agent-cert/cm-auto-global_cacerts.pem \
-g "https://$(hostname -f):8985/solr/nested_demo/query" -d '
  q=cat_s:sci-fi&
  fl=id&
  json.facet={
    top_reviewers: {
      type: terms,
      field: author_s,
      domain: { blockChildren : "type_s:book" }
    }
  }'
```
