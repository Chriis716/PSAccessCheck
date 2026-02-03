<#
.SYNOPSIS
  Tests access to UNC paths using multiple service accounts from a list.

.INPUTS
  accounts.txt  (one account per line, e.g. VA\OITXXXIA)
  shares.txt    (one UNC path per line, e.g. \\server\share or \\server\share\subfolder)

.OUTPUTS
  Console table and optional CSV

.NOTES
  - Uses 'net use' to map the ROOT share (\\server\share) with each credential.
  - Then attempts to list the requested path (share root or subfolder).
  - Cleans up mappings after each test.
#>

param(
  [string]$AccountsFile = "$PSScriptRoot\accounts.txt",
  [string]$SharesFile   = "$PSScriptRoot\shares.txt",
  [switch]$ExportCsv,
  [string]$CsvPath      = "$PSScriptRoot\ShareAccessResults.csv"
)

function Get-FreeDriveLetter {
  $used = (Get-PSDrive -PSProvider FileSystem).Name
  foreach ($letter in 'Z','Y','X','W','V','U','T','S','R','Q','P','O','N','M','L','K') {
    if ($used -notcontains $letter) { return $letter }
  }
  throw "No free drive letters available."
}

function Get-RootShareFromUnc {
  param([Parameter(Mandatory)][string]$UncPath)

  if ($UncPath -notmatch '^[\\]{2}[^\\]+\\[^\\]+') { return $null }
  $parts = ($UncPath -split '\\' | Where-Object { $_ -ne '' })
  if ($parts.Count -lt 2) { return $null }
  return "\\$($parts[0])\$($parts[1])"
}

function Test-ShareAccess {
  param(
    [Parameter(Mandatory)][string]$UncPath,
    [Parameter(Mandatory)][pscredential]$Credential
  )

  $user = $Credential.UserName
  $pass = $Credential.GetNetworkCredential().Password

  $rootShare = Get-RootShareFromUnc -UncPath $UncPath
  if (-not $rootShare) {
    return [pscustomobject]@{
      User      = $user
      SharePath = $UncPath
      RootShare = $null
      CanMap    = $false
      CanList   = $false
      Error     = "Invalid UNC path."
    }
  }

  $drive = Get-FreeDriveLetter
  $drivePath = "$drive`:"
  $mapped = $false
  $canList = $false
  $errMsg = $null

  try {
    # Remove any stale mapping just in case
    cmd /c "net use $drivePath /delete /y" | Out-Null

    # Map root share using provided credentials
    $mapOut  = cmd /c "net use $drivePath `"$rootShare`" /user:`"$user`" `"$pass`""
    $mapExit = $LASTEXITCODE

    if ($mapExit -eq 0) {
      $mapped = $true

      # Convert requested UNC to mapped path, preserving subfolder
      $relative = $UncPath.Substring($rootShare.Length) # "" or "\sub\path"
      $testPath = Join-Path $drivePath ($relative.TrimStart('\'))

      try {
        Get-ChildItem -LiteralPath $testPath -ErrorAction Stop | Out-Null
        $canList = $true
      }
      catch {
        $canList = $false
        $errMsg = $_.Exception.Message
      }
    }
    else {
      $mapped = $false
      $errMsg = ($mapOut | Out-String).Trim()
      if (-not $errMsg) { $errMsg = "net use failed with exit code $mapExit" }
    }
  }
  catch {
    $errMsg = $_.Exception.Message
  }
  finally {
    cmd /c "net use $drivePath /delete /y" | Out-Null
  }

  [pscustomobject]@{
    User      = $user
    SharePath = $UncPath
    RootShare = $rootShare
    CanMap    = $mapped
    CanList   = $canList
    Error     = $errMsg
  }
}

# --- Validate input files ---
if (-not (Test-Path -LiteralPath $AccountsFile)) { throw "Accounts file not found: $AccountsFile" }
if (-not (Test-Path -LiteralPath $SharesFile))   { throw "Shares file not found:   $SharesFile" }

$accounts = Get-Content -LiteralPath $AccountsFile |
  ForEach-Object { $_.Trim() } |
  Where-Object { $_ -and $_ -notmatch '^\s*#' } |
  Select-Object -Unique

$shares = Get-Content -LiteralPath $SharesFile |
  ForEach-Object { $_.Trim() } |
  Where-Object { $_ -and $_ -notmatch '^\s*#' } |
  Select-Object -Unique

if ($accounts.Count -lt 1) { throw "No accounts found in $AccountsFile" }
if ($shares.Count -lt 1)   { throw "No shares found in $SharesFile" }

# --- Collect credentials (password prompt per account) ---
$creds = foreach ($acct in $accounts) {
  Get-Credential -UserName $acct -Message "Enter password for $acct"
}

# --- Run tests ---
$results = foreach ($cred in $creds) {
  foreach ($share in $shares) {
    Test-ShareAccess -UncPath $share -Credential $cred
  }
}

# --- Output ---
$results |
  Sort-Object User, SharePath |
  Format-Table User, SharePath, CanMap, CanList, Error -AutoSize

if ($ExportCsv) {
  $results | Export-Csv -NoTypeInformation -Path $CsvPath
  Write-Host "Exported results to: $CsvPath" -ForegroundColor Green
}
