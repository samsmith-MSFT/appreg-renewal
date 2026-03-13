# App Registration Secret Rotation Logic App

A Logic App (Consumption) workflow that automatically discovers app registration client secrets, rotates expiring ones, syncs new secrets to Azure Key Vault, and optionally sends an email summary report.

## How It Works

1. **Daily scan** — Runs at 06:00 UTC, pages through all app registrations in the tenant via Microsoft Graph API.
2. **Configuration via secret description** — Secrets with a JSON snippet in their `displayName` (description) field are managed:
   ```json
   {"keyVaultName": "kv-contoso-prod", "secretName": "my-app-client-secret"}
   ```
3. **Duplicate detection** — Only the newest credential per configuration is processed. Older credentials with the same `displayName` are skipped to prevent duplicate secret creation.
4. **Expiry rotation** — If a configured secret expires within 30 days (configurable), a new credential is created and pushed to Key Vault. The old secret is kept for zero-downtime rotation.
5. **Email report** *(optional)* — If an Office 365 API connection is configured, an HTML email is sent showing rotated secrets, errors, and unconfigured app registrations.

## Prerequisites

- Azure subscription
- Microsoft Entra ID tenant access
- One or more Azure Key Vaults for secret storage
- *(Optional)* An Office 365 mailbox for sending notification emails

## Deployment Steps

### 1. Create the Logic App (Consumption) in the Azure portal

1. In the Azure portal, search for **Logic App** and click **Add**.
2. Select **Consumption** as the plan type.
3. Choose your subscription, resource group, region, and give it a name.
4. Click **Review + create** > **Create**.

### 2. Enable system-assigned managed identity

1. Open the Logic App resource.
2. Go to **Settings** > **Identity**.
3. On the **System assigned** tab, set **Status** to **On**.
4. Click **Save** and note the **Object (principal) ID**.

### 3. Grant permissions to the managed identity

The managed identity needs **Application.ReadWrite.All** on Microsoft Graph and **Key Vault Secrets Officer** on each target Key Vault.

Run the included setup script:

```powershell
.\Grant-ManagedIdentityPermissions.ps1 -ManagedIdentityObjectId "<MANAGED-IDENTITY-OBJECT-ID>"
```

See [Grant-ManagedIdentityPermissions.ps1](Grant-ManagedIdentityPermissions.ps1) for details. The script:
- Assigns the **Application.ReadWrite.All** app role on Microsoft Graph.
- Prompts for Key Vault names and assigns the **Key Vault Secrets Officer** role on each.

### 4. Paste the workflow definition

1. Open the Logic App resource.
2. Go to **Development Tools** > **Logic App Code View**.
3. Open `secret-rotation/workflow.json` from this repo and copy the entire contents.
4. Paste it into the Code View editor, replacing everything.
5. Update the `parameters` section at the bottom with your actual values:

| Parameter | What to set |
|-----------|-------------|
| `expiryThresholdDays.value` | Days before expiry to trigger rotation (default: `30`) |
| `secretValidityYears.value` | Validity period for new secrets in years (default: `1`) |

6. Click **Save**.

### 5. Verify

1. Go to **Overview** and click **Run Trigger** > **Run** to test.
2. Check the **Runs history** to confirm the workflow completes successfully.

## Configuring an App Registration

To enroll an app registration's secret for automatic rotation:

1. Go to **Entra ID** > **App registrations** > select your app > **Certificates & secrets**.
2. Add a new client secret (or edit an existing one).
3. Set the **Description** field to:
   ```json
   {"keyVaultName": "your-keyvault-name", "secretName": "desired-secret-name"}
   ```
4. The Logic App will discover this secret on its next run and sync the value to the specified Key Vault.

> **Note:** The `secretName` in Key Vault does not need to match the app registration name. Use any naming convention that suits your environment.

## Adding Email Notifications (Optional)

The workflow JSON ships without email support. To receive an HTML report after each run:

### 1. Create the Office 365 Outlook API connection

1. In the Azure portal, search for **API Connections** and click **Add**.
2. Search for **Office 365 Outlook** and select it.
3. Give it the name `office365`, place it in the same resource group as the Logic App.
4. Click **Create**, then open the connection and click **Authorize** to sign in with the mailbox account.

### 2. Add parameters to the workflow JSON

In the **definition** > **parameters** section, add:

```json
"$connections": {
  "defaultValue": {},
  "type": "Object"
},
"notificationEmail": {
  "defaultValue": "",
  "type": "String"
}
```

In the outer **parameters** section (at the bottom of the file), add:

```json
"$connections": {
  "value": {
    "office365": {
      "connectionId": "/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Web/connections/office365",
      "connectionName": "office365",
      "id": "/subscriptions/{SUB}/providers/Microsoft.Web/locations/{REGION}/managedApis/office365"
    }
  }
},
"notificationEmail": {
  "value": "your-email@contoso.com"
}
```

### 3. Add the email action to the workflow

Inside `Check_If_Notification_Needed` > `actions`, after `Compose_Final_Email`, add:

```json
"Send_Email_Notification": {
  "type": "ApiConnection",
  "inputs": {
    "host": {
      "connection": {
        "name": "@parameters('$connections')['office365']['connectionId']"
      }
    },
    "method": "post",
    "path": "/v2/Mail",
    "body": {
      "To": "@parameters('notificationEmail')",
      "Subject": "Secret Rotation Report - @{length(variables('rotatedSecrets'))} rotated, @{length(variables('newSecrets'))} new, @{length(variables('errors'))} errors",
      "Body": "@{outputs('Compose_Final_Email')}",
      "Importance": "@{if(greater(length(variables('errors')), 0), 'High', 'Normal')}"
    }
  },
  "runAfter": {
    "Compose_Final_Email": ["Succeeded"]
  }
}
```

## Architecture

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   Recurrence │────>│  Graph API   │────>│  Key Vault   │
│   Trigger    │     │  (List Apps) │     │  (PUT Secret)│
│   Daily 6AM  │     │  (addPassword│     │              │
└──────────────┘     └──────────────┘     └──────────────┘
                            │
                            v
                     ┌──────────────┐
                     │   O365 Email │
                     │  (Optional)  │
                     └──────────────┘
```

## Security Considerations

- The managed identity has **Application.ReadWrite.All**, which is a high-privilege permission. Scope access through Conditional Access policies or administrative units where possible.
- Secret values are only transiently available in the Logic App run history. Consider enabling **Secure Inputs/Outputs** on the HTTP actions that handle secret values to prevent them from appearing in run history.
- Ensure Key Vaults use **Azure RBAC** authorization (not access policies) for role assignments to work.
