<#
.SYNOPSIS
    Grants the required permissions to a Logic App system-assigned managed identity
    for the App Registration Secret Rotation workflow.

.DESCRIPTION
    This script assigns:
      1. Microsoft Graph "Application.ReadWrite.All" app role to the managed identity.
      2. "Key Vault Secrets Officer" role on one or more Key Vaults.

    Prerequisites:
      - Microsoft.Graph PowerShell module (Install-Module Microsoft.Graph)
      - Az PowerShell module (Install-Module Az) for Key Vault role assignments
      - Sufficient privileges: Global Admin or Privileged Role Administrator for Graph
        app-role assignment, and Owner/User Access Administrator on Key Vault scope.

.PARAMETER ManagedIdentityObjectId
    The Object (principal) ID of the Logic App's system-assigned managed identity.
    Found under the Logic App > Settings > Identity > System assigned.

.PARAMETER KeyVaultResourceIds
    Optional. One or more fully qualified Key Vault resource IDs to grant
    "Key Vault Secrets Officer" on. If omitted, the script prompts interactively.

.EXAMPLE
    .\Grant-ManagedIdentityPermissions.ps1 -ManagedIdentityObjectId "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

.EXAMPLE
    .\Grant-ManagedIdentityPermissions.ps1 `
        -ManagedIdentityObjectId "aaaaaaaaaaa-bbbb-cccc-eeee-ddddddddddd" `
        -KeyVaultResourceIds @(
            "/subscriptions/<your-sub-id/resourceGroups/<your-rg-group/providers/Microsoft.KeyVault/vaults/your-kv-01",
            "/subscriptions/<your-sub-id/resourceGroups/<your-rg-group/providers/Microsoft.KeyVault/vaults/your-kv-02"
        )
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ManagedIdentityObjectId,

    [Parameter()]
    [string[]]$KeyVaultResourceIds
)

$ErrorActionPreference = 'Stop'

# -------------------------------------------------------------------
# 1. Assign Microsoft Graph Application.ReadWrite.All app role
# -------------------------------------------------------------------
Write-Host "`n=== Step 1: Assign Microsoft Graph Application.ReadWrite.All ===" -ForegroundColor Cyan

Connect-MgGraph -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All" -NoWelcome

$graphSP = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
if (-not $graphSP) {
    throw "Could not find the Microsoft Graph service principal in the tenant."
}

$appRole = $graphSP.AppRoles | Where-Object { $_.Value -eq "Application.ReadWrite.All" }
if (-not $appRole) {
    throw "Could not find the Application.ReadWrite.All app role on Microsoft Graph."
}

# Check if the assignment already exists
$existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityObjectId |
    Where-Object { $_.AppRoleId -eq $appRole.Id -and $_.ResourceId -eq $graphSP.Id }

if ($existing) {
    Write-Host "  Application.ReadWrite.All is already assigned. Skipping." -ForegroundColor Yellow
} else {
    New-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $ManagedIdentityObjectId `
        -PrincipalId $ManagedIdentityObjectId `
        -ResourceId $graphSP.Id `
        -AppRoleId $appRole.Id | Out-Null

    Write-Host "  Application.ReadWrite.All assigned successfully." -ForegroundColor Green
}

# -------------------------------------------------------------------
# 2. Assign Key Vault Secrets Officer on each Key Vault
# -------------------------------------------------------------------
Write-Host "`n=== Step 2: Assign Key Vault Secrets Officer role ===" -ForegroundColor Cyan

if (-not $KeyVaultResourceIds) {
    Write-Host "  No Key Vault resource IDs supplied via parameter." -ForegroundColor Yellow
    Write-Host "  Enter fully qualified Key Vault resource IDs one per line."
    Write-Host "  Format: /subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.KeyVault/vaults/{NAME}"
    Write-Host "  Press Enter on an empty line when done.`n"

    $KeyVaultResourceIds = @()
    while ($true) {
        $input = Read-Host "  Key Vault resource ID"
        if ([string]::IsNullOrWhiteSpace($input)) { break }
        $KeyVaultResourceIds += $input
    }
}

if ($KeyVaultResourceIds.Count -eq 0) {
    Write-Host "  No Key Vaults specified. Skipping role assignment." -ForegroundColor Yellow
} else {
    Connect-AzAccount -UseDeviceAuthentication -ErrorAction SilentlyContinue | Out-Null

    foreach ($kvId in $KeyVaultResourceIds) {
        Write-Host "  Assigning on: $kvId"

        $existingRole = Get-AzRoleAssignment `
            -ObjectId $ManagedIdentityObjectId `
            -RoleDefinitionName "Key Vault Secrets Officer" `
            -Scope $kvId `
            -ErrorAction SilentlyContinue

        if ($existingRole) {
            Write-Host "    Already assigned. Skipping." -ForegroundColor Yellow
        } else {
            New-AzRoleAssignment `
                -ObjectId $ManagedIdentityObjectId `
                -RoleDefinitionName "Key Vault Secrets Officer" `
                -Scope $kvId | Out-Null

            Write-Host "    Key Vault Secrets Officer assigned." -ForegroundColor Green
        }
    }
}

Write-Host "`n=== Done ===" -ForegroundColor Cyan
Write-Host "The managed identity ($ManagedIdentityObjectId) now has the required permissions."
Write-Host "You can verify in the Azure portal under the Logic App's Identity blade > Azure role assignments.`n"
