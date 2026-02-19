# VA Share Access Test (PowerShell)

This guide explains how to run the **Test-VAShareAccess.ps1** script to validate:

- ✔ Account access to shared folders  
- ✔ Folder-level permissions (reach/list)  
- ✔ Optional write access (create/delete test file)  
- ✔ Export results for documentation (CSV)

---

## 📁 Requirements

Place the following files in the **same folder**:

- Test-VAShareAccess.ps1
- accounts.txt
- shares.txt


---

## 👤 Configure Accounts (`accounts.txt`)

Add one account per line using VA domain format:

- VA\OITXXXIA
- VA\OITXXXIU
- VA\OITXXXIU2


> ⚠️ Use the exact account names assigned by your site or team.

---

## 📂 Configure Shares (`shares.txt`)

Add one UNC path per line.

⚠️ These must reflect your **site’s SMB shared paths**.

### Example:
\\server01\DICOM\Scratch \\server02\Imaging\Imports  

### Notes: 
- ✔ Use real server/share paths from your environment
- ✔ Subfolders are supported
- ❌ Do NOT use local paths (e.g., `C:\`)

--- 

## 💻 Open PowerShell 

1. Click **Start**
2. Search for **PowerShell**
3. Open it (no admin required)
  
--- 

## 📁 Navigate to Script Folder 
```powershell 
cd "C:\Path\To\Your\Script"
``` 

### Example: 
```powershell 
cd "C:\Temp\ShareAccessTest"
``` 

--- 

## ▶️ Run the Script (Safe Mode – No Changes) 
```powershell 
.\Test-VAShareAccess.ps1
```
### What this does: 
- Prompts for each account password
- Tests access to each share
- Does **NOT modify anything**

--- 
## ✍️ Run with Write Test (Optional) 

```powershell 
.\Test-VAShareAccess.ps1 -EnableWriteTest
```
### What this adds: 
- Creates a temporary file
- Deletes it immediately
- Confirms write/modify access
> ⚠️ Only use if permitted to create/delete files in those folders. 

--- ## 📊 Export Results to CSV 

```powershell 
.\Test-VAShareAccess.ps1 -EnableWriteTest -ExportCsv
```
### Output: 
``` 
.\ShareAccessResults.csv
```
--- 
## 🔍 Understanding Results 
| Field 
| Description | 
|------|-------------| 
| CanMap 
| Account authenticated to share | 
| CanReach 
| Folder path is accessible | 
| CanList 
| Can browse contents | 
| CanWrite 
| Can create files | 
| CanDelete 
| Can delete files | 
| PermissionSummary | Final access level | 

--- 

### ✅ Example Interpretations | Result | Meaning | |--------|--------| | Modify (Write/Delete) | Full access | | Write Only | Can create but not delete | | Read/List Access | Read-only access | | Traverse Only | Limited (no listing) | | No Access | Blocked (auth/share/ACL issue) | 

--- 

## ⚠️ Common Issues ### Error 1219 ``` Multiple connections to a server using different credentials ``` #### Fix: ```cmd net use * /delete ``` Then rerun the script. --- ### Access Denied - Account not added to NTFS permissions - Share permissions missing - Incorrect folder path 

--- 

### System Error 53 
``` 
The network path was not found 
``` - Server unreachable - DNS issue - Invalid UNC path

---
## 🧠 Best Practices
- Run in a **clean session** (clear `net use` if needed)
- Ensure accounts are added to:
- ✔ NTFS Security tab
- ✔ Share permissions (if restricted)
- Use CSV export for ticketing and documentation

---
## 🚀 Recommended Command
```powershell
.\Test-VAShareAccess.ps1 -EnableWriteTest -ExportCsv ```
--- 

## 📌 Summary
1. Add accounts to `accounts.txt`
2. Add site SMB paths to `shares.txt`
3. Run script in PowerShell
4. Review output or export CSV
