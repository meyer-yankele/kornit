# Kornit OBO Token Security — Solution Overview

## The Problem

Kornit's AI agents need to access employee data (BobData) **on behalf of the employee**.
Today, OBO tokens are stored in **Redis** — a network-accessible database.

**If an attacker reaches Redis, they steal every employee's token at once.**

```
CURRENT (insecure):

Employee → AI Router → Redis (stores Token B) → Foundry Agent → BobData
                          ↑
                    HONEYPOT: all tokens
                    sitting in one place
```

The Foundry Agent (Azure AI Agent Service) is async and **strips HTTP headers**.
You cannot pass a token through it. Kornit tried custom headers and JSON injection — both fail.

---

## The Solution

**Keep the token in RAM. Never send it to the Foundry Agent. Deploy everything in Azure.**

```
PROPOSED (secure, deployed on Azure):

Employee → Postman(Teams) ──Token A──→ kornit-airouter.azurewebsites.net
                                              │
                                    1. Validate Token A
                                    2. OBO → Token B (RAM only)
                                    3. Send TEXT to Foundry Agent (no token)
                                              │
                          ┌───────────────────┴───────────────────┐
                          │                                       │
                          ▼                                       │
                 Azure AI Agent Service                           │
                 (kornit-hr-agent)                                │
                          │                                       │
                 "I need get_hr_profile"                          │
                 (requires_action)                                │
                          │                                       │
                          ▼                                       │
                 Semantic Kernel Plugin                           │
                 executes INSIDE the App Service                  │
                 with Token B FROM RAM                            │
                          │                                       │
                          ▼                                       │
                 kornit-fakebobdata.azurewebsites.net             │
                 Validates Token B → David's data only            │
                          │                                       │
                          └───────────────────┬───────────────────┘
                                              │
                                    Response to employee
```

### How it works in 5 steps

| Step | What happens | Where | Token location |
|------|-------------|-------|---------------|
| 1 | Employee sends request via Postman/Teams | → Azure App Service | Token A in HTTP header |
| 2 | AI Router performs OBO: Token A → Token B | Azure App Service RAM | **Token B in RAM only** |
| 3 | AI Router sends the **text** to Foundry Agent | Azure AI Agent Service | **No token sent** |
| 4 | Foundry Agent returns `requires_action: get_hr_profile` | Azure AI Agent Service | Agent never had a token |
| 5 | Plugin calls FakeBobData with Token B from RAM | Azure App Service → Azure App Service | **Token B used, then discarded** |

### The key security guarantee

> **The OBO token never leaves the AI Router App Service's memory.**
> It is never stored in Redis, never written to disk, never sent to the Foundry Agent,
> never logged, never cached in any external system.

---

## What This Proves

| Test | Result | What it proves |
|------|--------|---------------|
| David asks for his HR profile | Gets David's data only | Identity preserved end-to-end **in Azure** |
| Sarah asks for her HR profile | Gets Sarah's data only | User isolation works **in Azure** |
| Check Foundry Agent logs | No token present | Agent never touches credentials |
| Kill the App Service process | Token B disappears | RAM-only = no persistence risk |
| Remove admin consent | Instant 401 error | Security controls are active |

---

## Technology Stack

| Component | Technology | Deployed on |
|-----------|-----------|-------------|
| AI Router | .NET 8 + Semantic Kernel + MSAL | **Azure App Service** (`kornit-airouter`) |
| Foundry Agent | Azure AI Agent Service (GPT-4o-mini) | **Azure AI Agent Service** (cloud native) |
| FakeBobData | .NET 8 + Microsoft.Identity.Web | **Azure App Service** (`kornit-fakebobdata`) |
| Auth | Microsoft Entra ID (OBO flow) | **Azure Entra ID** |
| Token cache | In-memory (MSAL `AddInMemoryTokenCaches`) | App Service RAM — replaces Redis |
| Client | Postman (simulates Teams) | Local |

---

## Mapping to Kornit HLD

```
┌─────────────────────────────────────────────────────────────────────┐
│                      AZURE CLOUD                                    │
│                                                                     │
│  ┌──────────────────────────────────────────────────┐              │
│  │  Tier 3: AI Orchestrator                          │              │
│  │  kornit-airouter.azurewebsites.net               │              │
│  │  ┌────────────────────────────────────┐          │              │
│  │  │  Semantic Kernel + MSAL OBO        │          │              │
│  │  │  Token B in RAM (never persisted)  │          │              │
│  │  │  BobDataPlugin (local execution)   │          │              │
│  │  └────────────────────────────────────┘          │              │
│  └──────────┬───────────────────┬───────────────────┘              │
│             │ text only         │ Token B (RAM)                     │
│             ▼                   ▼                                   │
│  ┌──────────────────┐  ┌───────────────────────────┐              │
│  │  Tier 4: Agent   │  │  Tier 8/9: Downstream     │              │
│  │  Azure AI Agent  │  │  kornit-fakebobdata       │              │
│  │  Service         │  │  .azurewebsites.net       │              │
│  │                  │  │                           │              │
│  │  NO TOKEN HERE   │  │  Validates Token B        │              │
│  │  requires_action │  │  Returns user-specific    │              │
│  │                  │  │  HR data                  │              │
│  └──────────────────┘  └───────────────────────────┘              │
│                                                                     │
│  ┌──────────────────┐                                              │
│  │  Azure Entra ID  │  OBO Token Exchange                          │
│  │  (Identity)      │  Token A → Token B                           │
│  └──────────────────┘                                              │
└─────────────────────────────────────────────────────────────────────┘
         ▲
         │ Token A
         │
┌────────────────┐
│   Postman      │
│   (= Teams)    │
│   LOCAL        │
└────────────────┘
```

---

## Future: Entra Agent ID (GA expected May 2026)

When Microsoft Entra Agent ID reaches General Availability:

- The Foundry Agent gets its own **Agent Identity Blueprint**
- Azure performs OBO **natively on the server side**
- The AI Router no longer manages tokens — just passes Token A
- `BobDataPlugin` and `requires_action` loop are **eliminated**
- Zero token-exchange code required

**This demo is Step 1.** It proves the secure pattern today, running in Azure.
Entra Agent ID will simplify it further — same security, less code.

---

## Summary

| | Current (Redis) | This Demo (RAM + Azure) | Future (Entra Agent ID) |
|--|----------------|------------------------|------------------------|
| Token storage | Redis (network) | **App Service RAM** | Azure platform |
| Attack surface | High (honeypot) | **Minimal** | Minimal |
| Token in Foundry Agent | No | **No** | No (native OBO) |
| Identity preserved | Yes | **Yes** | Yes |
| Runs in Azure | Yes | **Yes** | Yes |
| Code complexity | Medium | Medium | **Low** |
| Available | Now | **Now** | May 2026 |
