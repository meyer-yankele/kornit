# Kornit OBO Demo — Secure Multi-Agent Identity Propagation

> **TL;DR:** AI agents on Azure cannot pass user tokens through Azure AI Agent Service (it strips HTTP headers). This demo proves a secure alternative: keep the OBO token in App Service RAM and execute data calls locally via Semantic Kernel plugins.

---

## The Problem

Kornit's multi-agent AI platform runs on Azure. When an employee asks an AI agent a question (e.g. *"What's my leave balance?"*), the agent needs to call downstream APIs **as that specific employee** — not as a shared service account.

**The blocker:** Azure AI Agent Service is asynchronous and **strips custom HTTP headers**. You cannot pass an OBO token through the agent. Every attempt — custom headers, JSON injection, metadata fields — fails silently.

**The bad workaround:** Store tokens in Redis. This creates a honeypot — if an attacker reaches Redis, they steal every employee's token at once.

```
CURRENT (insecure):

Employee → AI Router → Redis (stores Token B) → Foundry Agent → BobData
                          ↑
                    HONEYPOT: all tokens
                    sitting in one place
```

## The Solution

**Keep the token in RAM. Never send it to the AI agent. Let the agent request data — but execute the call locally.**

```
SOLUTION (secure):

Employee → AIRouter (App Service)
               │
               ├─ 1. Validate Token A (JWT from Entra ID)
               ├─ 2. OBO exchange → Token B (RAM only, via MSAL InMemoryTokenCaches)
               ├─ 3. Send TEXT prompt to AI Agent (no token, no secrets)
               │       ↓
               │   Azure AI Agent Service (GPT-4o-mini)
               │       ↓
               │   "I need get_hr_profile" (requires_action)
               │       ↓
               ├─ 4. Semantic Kernel intercepts → executes plugin LOCALLY
               │      Plugin uses Token B FROM RAM to call FakeBobData
               │       ↓
               │   FakeBobData validates Token B → returns David's data only
               │       ↓
               └─ 5. Data submitted to agent → natural language response → employee
```

**The OBO token never leaves the App Service process memory.**

---

## Architecture

| Component | Technology | Deployed on |
|-----------|-----------|-------------|
| **AIRouter** (Supervisor) | .NET 8 · Semantic Kernel 1.73 · MSAL OBO | Azure App Service |
| **AI Agent** (HR Worker) | Azure AI Agent Service · GPT-4o-mini | Azure AI Agent Service |
| **FakeBobData** (HR API) | .NET 8 · Microsoft.Identity.Web | Azure App Service |
| **Identity** | Microsoft Entra ID (OBO flow) | Azure Entra ID |
| **Token cache** | In-memory (`AddInMemoryTokenCaches`) | App Service RAM |
| **Client** | Postman (simulates Microsoft Teams) | Local |

### Flow in 5 Steps

| Step | What happens | Where | Token B location |
|------|-------------|-------|-----------------|
| 1 | Employee sends request with Token A | → App Service | Token A in header |
| 2 | AIRouter performs OBO: Token A → Token B | App Service | **RAM only** |
| 3 | AIRouter sends **text only** to AI Agent | AI Agent Service | **Not sent** |
| 4 | Agent returns `requires_action: get_hr_profile` | AI Agent Service | Agent never had it |
| 5 | Plugin calls FakeBobData with Token B from RAM | App Service → App Service | **Used, then GC'd** |

---

## Project Structure

```
kornit/
├── KornitOboDemo.sln
├── src/
│   ├── AIRouter/                          # Supervisor service
│   │   ├── Controllers/
│   │   │   └── ChatController.cs          # Main flow: OBO → Agent → Plugin → Response
│   │   ├── Plugins/
│   │   │   └── BobDataPlugin.cs           # SK plugin — calls BobData with Token B from RAM
│   │   ├── Program.cs                     # Auth + DI setup
│   │   ├── AIRouter.csproj
│   │   └── appsettings.json.template      # Config template (no secrets)
│   │
│   └── FakeBobData/                       # Mock HR API (simulates BobHR)
│       ├── Controllers/
│       │   └── HrDataController.cs        # Returns employee-specific HR data
│       ├── Program.cs
│       ├── FakeBobData.csproj
│       └── appsettings.json.template
│
├── docs/                                  # Architecture diagrams & design docs
├── test-demo.ps1                          # PowerShell test harness (auth + API calls)
└── .gitignore
```

---

## Prerequisites

- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- An Azure subscription with:
  - **Microsoft Entra ID** (Azure AD) tenant
  - **Azure AI Agent Service** (Azure AI Foundry) with a deployed agent
  - Two **App Service** instances (AIRouter + FakeBobData)

## Setup

### 1. Clone the repo

```bash
git clone https://github.com/meyer-yankele/kornit.git
cd kornit
```

### 2. Configure secrets

Copy the template files and fill in your Azure values:

```bash
cp src/AIRouter/appsettings.json.template src/AIRouter/appsettings.json
cp src/FakeBobData/appsettings.json.template src/FakeBobData/appsettings.json
```

Edit each `appsettings.json` with your:
- Entra ID tenant, client IDs, and client secret
- Azure AI Foundry endpoint, agent ID, and API key
- FakeBobData App Service URL

### 3. Entra ID app registrations

You need **3 app registrations** in Entra ID:

| App | Purpose | Key config |
|-----|---------|-----------|
| **AIRouter** | Supervisor API | Expose `access_as_user` scope · Client secret · API permission to FakeBobData |
| **FakeBobData** | HR data API | Expose `user_impersonation` scope · Validate issuer + audience |
| **Postman Client** | Simulates Teams | Public client · Redirect URI `http://localhost:5050` · Permission to AIRouter |

Grant **admin consent** for the OBO chain: Postman → AIRouter → FakeBobData.

### 4. Build and run locally

```bash
dotnet build
dotnet run --project src/FakeBobData
dotnet run --project src/AIRouter
```

### 5. Deploy to Azure

```bash
# FakeBobData
cd src/FakeBobData
dotnet publish -c Release -o ./publish
cd publish && zip -r ../../deploy-bobdata.zip .
az webapp deploy --resource-group <rg> --name kornit-fakebobdata --src-path ../../deploy-bobdata.zip

# AIRouter
cd ../../AIRouter
dotnet publish -c Release -o ./publish
cd publish && zip -r ../../deploy-airouter.zip .
az webapp deploy --resource-group <rg> --name kornit-airouter --src-path ../../deploy-airouter.zip
```

---

## Testing

### Using the test script

```powershell
# Set the required secret
$env:KORNIT_POSTMAN_SECRET = "<your-postman-client-secret>"

# Login as David (opens browser for interactive auth)
.\test-demo.ps1 login david

# Test identity
.\test-demo.ps1 whoami

# Test AI Foundry connection
.\test-demo.ps1 test-foundry

# Test the full OBO + Agent flow
.\test-demo.ps1 ask "What is my leave balance?"

# Run all tests
.\test-demo.ps1 test-all
```

### What success looks like

```json
{
  "status": "success",
  "employee": "testuser-david@365-poc.com",
  "answer": "Your annual leave balance is 18 days...",
  "securityFlow": {
    "step1": "Token A received from Postman (simulates Teams)",
    "step2": "OBO: Token A → Token B for BobData (kept in App Service RAM)",
    "step3": "Text prompt sent to Foundry Agent (NO token)",
    "step4": "Foundry Agent returned requires_action: get_hr_profile",
    "step5": "Local plugin called FakeBobData WITH Token B from RAM",
    "tokenIsolation": "Token B NEVER left the App Service RAM"
  }
}
```

---

## Security Guarantees

| Property | How it's enforced |
|----------|------------------|
| **Token never leaves RAM** | MSAL `AddInMemoryTokenCaches()` — no Redis, no disk, no DB |
| **Agent never sees the token** | Only text prompt is sent to Azure AI Agent Service |
| **User isolation** | OBO preserves original identity — David sees David's data, Sarah sees Sarah's |
| **No honeypot** | No centralized token store to attack |
| **Least privilege** | Each token is scoped to `user_impersonation` on FakeBobData only |
| **Defense in depth** | Token A validated → OBO exchange → Token B validated → RBAC check |

---

## Future: Entra Agent ID

When **Microsoft Entra Agent ID** reaches GA (expected ~2025–2026):
- The AI Agent gets its own managed identity
- Azure performs OBO **natively on the server side**
- The `requires_action` loop and `BobDataPlugin` are eliminated
- Same security guarantees, zero token-management code

**This demo is Step 1.** It proves the secure pattern today. Entra Agent ID will simplify it further.

---

## Key Files

| File | What it does |
|------|-------------|
| [`ChatController.cs`](src/AIRouter/Controllers/ChatController.cs) | Full OBO → Agent → Plugin → Response flow |
| [`BobDataPlugin.cs`](src/AIRouter/Plugins/BobDataPlugin.cs) | SK plugin that calls BobData with Token B from RAM |
| [`Program.cs`](src/AIRouter/Program.cs) | Auth middleware + DI configuration |
| [`HrDataController.cs`](src/FakeBobData/Controllers/HrDataController.cs) | HR API that validates Token B and returns user-specific data |
| [`SOLUTION_OVERVIEW.md`](docs/SOLUTION_OVERVIEW.md) | Detailed architecture documentation |
| [`test-demo.ps1`](test-demo.ps1) | PowerShell test harness with interactive auth |

---

## Tech Stack

- **Runtime:** .NET 8.0
- **AI Orchestration:** [Microsoft Semantic Kernel](https://github.com/microsoft/semantic-kernel) 1.73.0
- **AI Agent:** [Azure AI Agent Service](https://learn.microsoft.com/azure/ai-services/agents/) (OpenAI Assistants API)
- **Auth:** [Microsoft.Identity.Web](https://github.com/AzureAD/microsoft-identity-web) 4.5.0 (MSAL + OBO)
- **Identity:** Microsoft Entra ID
- **Hosting:** Azure App Service

---

## License

Internal Kornit Digital project. Not for public distribution.
