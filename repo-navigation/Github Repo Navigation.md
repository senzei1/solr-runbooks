# How-to: Navigate Source Code and Verify Fixes using Git/GitHub

**Objective**
This guide outlines the steps to locate error messages in the source code, identify the specific commit or ticket responsible for a change, and verify if a fix is present in a specific product release.

**Prerequisites**
* Access to the source code repository (e.g., GitHub).
* (Optional) `git` command-line tool installed locally for advanced verification.

---

### **Step 1: Locate Specific Files or Errors (Web UI)**
Use these keyboard shortcuts to quickly find what you need without manually clicking through folders.

**Option A: If you know the filename**
1.  Navigate to the repository main page.
2.  Press **`t`** on your keyboard to activate the **File Finder**.
3.  Type the name of the file (e.g., `SolrConfig.java`) and select it from the list.

**Option B: If you have an error string**
1.  Press **`/`** (forward slash) to jump to the **Global Search** bar.
2.  Type the unique part of the error message or variable name (e.g., `maxStartOffset`).
    * *Note:* Do not include dynamic values (IDs, timestamps) in your search.
3.  Select **"In this repository"**.
4.  Click the result to view the code file.

---

### **Step 2: Identify the Root Cause (Blame View)**
Once you have located the line of code triggering an error or behavior, use the "Blame" view to understand its history.

1.  Open the relevant file in the GitHub interface.
2.  Click the **Blame** button (usually located at the top-right of the code viewer).
3.  Scroll to the line in question and inspect the **Left Sidebar**:
    * **Ticket ID (e.g., SOLR-15337):** This links the code to a Jira ticket. Search this ID to find the reasoning, design docs, and discussions.
    * **Date:** This helps distinguish between a new regression (recent date) and intended legacy behavior (old date).

---

### **Step 3: Compare Product Versions**
Use this method to answer the customer question: *"What changed between version X and version Y?"*

1.  Construct a **Compare URL** using the following pattern:
    `https://github.com/{org}/{repo}/compare/{old_tag}...{new_tag}`
2.  **Example:** To see changes between Solr 9.6.0 and 9.7.0:
    * `.../compare/releases/solr/9.6.0...releases/solr/9.7.0`
3.  Review the "Files Changed" tab to see a complete diff. Use `Ctrl+F` to search for specific features or configuration parameters.

---

### **Step 4: Verify Fixes in Specific Releases (Command Line)**
For precise verification (e.g., "Is this fix in version 8.11.1?"), use the Git command line.

**Preparation:**
Clone the repository locally:
```bash
git clone [https://github.com/apache/solr.git](https://github.com/apache/solr.git)
cd solr
```

**Method 1: Check by Jira Ticket ID (The "Safe" Method)**
Use this to confirm if a bug fix is in a release, even if it was "cherry-picked" (backported) with a different hash.
```bash
# Syntax: git log <tag_name> --grep="<TICKET_ID>" --oneline

# Example: Is SOLR-12730 in Release 7.6.0?
git log releases/solr/9.9.0 --grep="SOLR-12730" --oneline
```
* **Output:** If the command returns a line, the fix **IS** present. If it returns nothing, the fix is missing.

**Method 2: Check by Commit Hash (The "Fast" Method)**
Use this if you have a Commit Hash (e.g., `8f4a2b`) and want to see every tag that contains it.
* *Warning:* This often fails for older releases if the commit was backported (which changes the hash).
```bash
# Syntax: git tag --contains <COMMIT_HASH>
git tag --contains 6e745bd2500
```

**Method 3: Find when a feature was deleted (The Pickaxe)**
Use this to find a configuration or variable that has been removed and no longer appears in the current code.
```bash
# Syntax: git log -S "<SEARCH_STRING>"
git log -S "maxBooleanClauses" --oneline
```

---

### **Troubleshooting: "Malformed Object Name"**
If `git tag --contains` gives an error like `malformed object name solr-12730`, it means you passed a Ticket ID instead of a Hash.

**Fix:** Use this one-liner to find the hash and check the tag automatically:
```bash
git tag --contains $(git log --grep="SOLR-12730" -n 1 --format=%H)
```

---

### **Cheat Sheet**

| Task | Tool/Command | Shortcut |
| :--- | :--- | :--- |
| **Find a file by name** | GitHub Web UI | Press **`t`** |
| **Search code text** | GitHub Web UI | Press **`/`** |
| **View history per line** | GitHub Web UI | Click **Blame** |
| **Is Fix X in Release Y?** | Git CLI | `git log <tag> --grep="ID"` |
| **Who has Commit X?** | Git CLI | `git tag --contains <hash>` |
| **Find deleted text** | Git CLI | `git log -S "text"` |
