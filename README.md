# VA Share Access Validation (PowerShell)

This repository contains a PowerShell utility designed to **validate shared folder access** for multiple VA service or user accounts across one or more UNC paths.

It is primarily intended for scenarios where:
- A **new account** has been added to security groups
- Access is expected but needs to be **verified**
- Multiple service accounts must be checked consistently
- Documentation or evidence of access is required (CSV output)

---

## 🔍 What This Script Does

For each account and each shared folder, the script:

1. Authenticates using the supplied credentials
2. Maps the **root share** using `net use`
3. Attempts to **list directory contents**
4. Records whether the account:
   - Successfully authenticated to the share
   - Can read/list the requested path
5. Cleans up all temporary drive mappings

The result is a clear matrix of **Account × Share × Access Status**.

---

## 📁 Repository Structure
├── Test-VAShareAccess.ps1
├── accounts.txt
├── shares.txt
└── README.md


---

## 📄 Input Files

### `accounts.txt`
List one account per line.

Example:



---

### `shares.txt`
List one UNC path per line.  
Paths may be either a share root or a subfolder.

Example:
\\server2\shareB\SubFolder \\server3\shareC ``` Blank lines and lines starting with `#` are ignored. --- ## ▶️ How to Run Open PowerShell and navigate to the script directory: ```powershell cd path\to\repo ``` Run the script: ```powershell .\Test-VAShareAccess.ps1 ``` You will be prompted **once per account** to enter the password securely. --- ## 📤 Export Results to CSV To export the results for documentation or ticket attachments: ```powershell .\Test-VAShareAccess.ps1 -ExportCsv ``` The CSV will be created as: ``` ShareAccessResults.csv ``` --- ## 📊 Output Fields | Field | Description | |-----------|-------------| | User | Account being tested | | SharePath| UNC path requested | | RootShare| Root share mapped | | CanMap | Account authenticated to the share | | CanList | Account can list/read the folder | | Error | Failure reason (if any) | > **Note:** `CanMap = True` but `CanList = False` usually indicates the account can authenticate but lacks read/list permissions. --- ## ⚠️ Notes & Limitations - Uses `net use`, which may behave differently in environments enforcing strict Kerberos-only authentication - Read/list access is tested by directory enumeration - Script does **not** modify data on the share - Temporary drive mappings are always cleaned up --- ## 🔐 Security Considerations - Passwords are never stored - Credentials are collected using `Get-Credential` - Plaintext passwords are used **only in-memory** for `net use` - No logging of sensitive data --- ## 🛠️ Common Use Cases - Validate new service account access - Confirm group membership propagation - Troubleshoot "access denied" issues - Provide evidence for access requests or incidents --- ## 🚀 Possible Enhancements - Write / Modify permission testing (create + delete temp file) - Kerberos-only authentication mode - Parallel execution for large share lists - HTML or Excel reporting --- ## 📌 Disclaimer This script is provided as-is for administrative validation purposes. Always ensure you have proper authorization before testing credentials or accessing network resources. --- ## 📬 Questions or Improvements Feel free to open an issue or submit a pull request if you have enhancements or fixes.
