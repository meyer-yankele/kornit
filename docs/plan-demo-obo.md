# Plan : Demo Kornit OBO — Deploiement Azure

## Le probleme de Kornit

Kornit a une architecture multi-agent IA sur Azure :
- **AI Router (Supervisor)** : App Service C# avec Semantic Kernel — recoit les requetes Teams, gere l'identite
- **Foundry Agents (Workers)** : Agents IA (HR, ERP, CRM) construits dans Azure AI Agent Service (async, Threads/Messages/Runs)
- **Bases de donnees** : BobData (HR), SAP (ERP), Oracle (CRM) — protegees par RBAC utilisateur

**Le blocage** : Le Azure AI Agent Service est **asynchrone** et **strippe les custom HTTP headers**. Impossible de passer un token OBO a travers le Foundry Agent. L'agent ne peut pas appeler les bases de donnees au nom de l'employe.

**Tentatives echouees** :
1. Redis cache pour tokens → Honeypot de securite (rejete)
2. Custom headers / injection JSON → Headers strippees par l'infra async (echoue)

**Solution actuelle** : `requires_action` (client-side function calling) — fragile mais fonctionnel
**Solution proposee (Yonah)** : Entra Agent ID (OBO natif server-side) — GA prevue mai 2026

## Ce que la demo prouve

```
Postman (Teams)
    │ Token A (David)
    ▼
kornit-airouter.azurewebsites.net  ← Azure App Service + Semantic Kernel + MSAL
    │ OBO → Token B pour BobData (garde en RAM du App Service)
    │ Envoie UNIQUEMENT le texte au Foundry Agent (pas de token)
    ▼
Foundry Agent (HR) ← Azure AI Agent Service (cloud)
    │ Analyse le prompt
    │ Retourne requires_action: get_hr_profile(employee="david")
    ▼
Semantic Kernel intercepte automatiquement (dans le App Service)
    │ Appelle le plugin local BobDataPlugin
    │ Le plugin utilise Token B (en RAM) pour appeler FakeBobData
    ▼
kornit-fakebobdata.azurewebsites.net  ← Azure App Service protege par Entra ID
    │ Valide Token B → identifie David
    │ Retourne UNIQUEMENT les donnees de David
    ▼
Semantic Kernel soumet les donnees au Foundry Agent
    │ L'agent formule la reponse en langage naturel
    ▼
AI Router retourne la reponse a l'employe
```

**Tout tourne dans Azure** — sauf Postman qui simule Teams.

## Ordre d'execution optimise

| Etape | Phase | Qui | Bloquant ? |
|-------|-------|-----|------------|
| 1 | Phase 0 — Structure .NET + NuGet | Claude Code | Non |
| 2 | Phase 1 — Coder FakeBobData | Claude Code | Non (placeholders) |
| 3 | Phase 2 — Coder AIRouter + Plugin + Foundry Agent | Claude Code | Non (placeholders) |
| 4 | Phase 3 — Configurer Azure (Entra ID, Foundry, users) | **Toi** (portail Azure) | **Oui** |
| 5 | Phase 4 — Remplacer les placeholders | Ensemble | Depend de l'etape 4 |
| 6 | Phase 5 — Deployer sur Azure App Service | Claude Code + Azure CLI | Depend de l'etape 4 |
| 7 | Phase 6 — Tests Postman (David + Sarah) sur Azure | Ensemble | Depend de tout |
| 8 | Phase 7 — Presentation Entra Agent ID | Reference | Non |

> **Logique** : On code tout avec des placeholders (etapes 1-3). Tu configures Azure dans le portail (etape 4). On injecte les vraies valeurs (etape 5), on deploie sur App Service (etape 6), et on teste sur Azure (etape 7).

---

## PHASE 0 : Structure du projet .NET (FAIT)

### 0.1 Prerequis
```bash
dotnet --version  # 8.x ✓
az --version      # 2.84.0 ✓
```

### 0.2 Structure creee
```
kornit/
├── KornitOboDemo.sln
├── src/
│   ├── AIRouter/           # → kornit-airouter.azurewebsites.net
│   │   ├── Program.cs
│   │   ├── Controllers/ChatController.cs
│   │   ├── Plugins/BobDataPlugin.cs
│   │   └── appsettings.json
│   └── FakeBobData/        # → kornit-fakebobdata.azurewebsites.net
│       ├── Program.cs
│       ├── Controllers/HrDataController.cs
│       └── appsettings.json
├── docs/
│   ├── plan-demo-obo.md
│   ├── SOLUTION_OVERVIEW.md
│   └── kornit_new_hld.png
└── references/
```

---

## PHASE 1 : Coder FakeBobData (FAIT)

L'API qui simule BobData — protegee par Entra ID, retourne les donnees selon l'identite du token.

### 1.1 NuGet
```bash
dotnet add package Microsoft.Identity.Web
```

### 1.2 `appsettings.json`
```json
{
  "AzureAd": {
    "Instance": "https://login.microsoftonline.com/",
    "TenantId": "__TENANT_ID__",
    "ClientId": "__FAKEBOBDATA_CLIENT_ID__",
    "Audience": "api://__FAKEBOBDATA_CLIENT_ID__"
  }
}
```
> Note : En App Service, le port est gere automatiquement par Azure. Pas de config Kestrel necessaire.

### 1.3 `Program.cs`
```csharp
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Identity.Web;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("AzureAd"));
builder.Services.AddAuthorization();
builder.Services.AddControllers();

var app = builder.Build();
app.UseHttpsRedirection();
app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();
app.Run();
```

### 1.4 `Controllers/HrDataController.cs`
- Endpoint `GET /api/HrData/my-profile` protege par `[Authorize]`
- Lit `upn` depuis les claims du Token B (OBO)
- Retourne les donnees HR de David ou Sarah selon l'identite
- **Preuve d'isolation** : David ne voit que ses donnees, Sarah les siennes

---

## PHASE 2 : Coder l'AI Router (A METTRE A JOUR)

Le coeur de la demo. C'est le **Supervisor** qui :
1. Recoit le token utilisateur (Token A) de Postman/Teams
2. Fait l'OBO pour obtenir Token B (scope BobData) — **garde en RAM**
3. Envoie uniquement le **texte** au Foundry Agent (pas de token)
4. Semantic Kernel intercepte `requires_action` et appelle le plugin local
5. Le plugin utilise Token B pour appeler FakeBobData

### 2.1 NuGet (FAIT)
```bash
dotnet add package Microsoft.Identity.Web
dotnet add package Microsoft.Identity.Web.DownstreamApi
dotnet add package Microsoft.SemanticKernel
dotnet add package Microsoft.SemanticKernel.Agents.AzureAI --prerelease
dotnet add package Azure.AI.Projects --prerelease
dotnet add package Azure.Identity
```

### 2.2 `appsettings.json`
```json
{
  "AzureAd": {
    "Instance": "https://login.microsoftonline.com/",
    "TenantId": "__TENANT_ID__",
    "ClientId": "__AIROUTER_CLIENT_ID__",
    "ClientCredentials": [{ "SourceType": "ClientSecret", "ClientSecret": "__AIROUTER_CLIENT_SECRET__" }]
  },
  "FakeBobData": {
    "BaseUrl": "https://kornit-fakebobdata.azurewebsites.net",
    "Scopes": [ "api://__FAKEBOBDATA_CLIENT_ID__/user_impersonation" ]
  },
  "AzureAIFoundry": {
    "ConnectionString": "__FOUNDRY_CONNECTION_STRING__",
    "AgentId": "__FOUNDRY_AGENT_ID__",
    "ModelDeployment": "gpt-4o-mini"
  }
}
```
> Note : `FakeBobData.BaseUrl` pointe vers l'App Service Azure, pas localhost.

### 2.3 Plugin `Plugins/BobDataPlugin.cs`
- Execute **localement** dans le process du App Service AIRouter
- Recoit Token B via `KernelArguments["obo_token"]` (en RAM)
- Appelle `https://kornit-fakebobdata.azurewebsites.net/api/HrData/my-profile` avec Token B

### 2.4 `Program.cs`
- Auth : valide Token A recu de Postman/Teams
- OBO : `EnableTokenAcquisitionToCallDownstreamApi()` + `AddInMemoryTokenCaches()`
- HttpClient : pointe vers `FakeBobData.BaseUrl` (App Service Azure)

### 2.5 `Controllers/ChatController.cs` — Le Supervisor
- `POST /api/Chat/ask` — point d'entree principal
  1. OBO : Token A → Token B (RAM)
  2. Cree le Kernel Semantic avec BobDataPlugin
  3. Connecte au Foundry Agent via `AIProjectClient`
  4. Envoie le prompt (SANS token) — `requires_action` gere automatiquement par SK
  5. Retourne la reponse avec les metadonnees de securite
- `GET /api/Chat/whoami` — diagnostic (claims du Token A)

---

## PHASE 3 : Configurer Azure (portail — toi)

> **Cette phase est manuelle** — tu la fais dans le portail Azure/Entra ID.
> Une fois terminee, tu me donnes les valeurs et je remplace les placeholders.

### 3.1 Creer les App Registrations (Entra ID)

Portail : https://entra.microsoft.com → App registrations

#### App 1 : `kornit-fakebobdata` (la base de donnees HR)
- Single tenant
- **Expose an API** : URI `api://<CLIENT_ID>`, scope `user_impersonation`
- Pas de secret (ne fait pas d'OBO)

#### App 2 : `kornit-ai-router` (le superviseur)
- Single tenant
- **Expose an API** : URI `api://<CLIENT_ID>`, scope `user_impersonation`
- **API Permissions** : My APIs → `kornit-fakebobdata` → Delegated → `user_impersonation` → Grant admin consent
- **Secret** : creer, noter `AI_ROUTER_CLIENT_SECRET`

#### App 3 : `kornit-postman-client` (simule Teams)
- Single tenant
- **Redirect URI** : Platform Web → `https://oauth.pstmn.io/v1/callback`
- **API Permissions** : My APIs → `kornit-ai-router` → `user_impersonation` + Microsoft Graph → `openid profile email User.Read` → Grant admin consent
- **Secret** : creer, noter `POSTMAN_CLIENT_SECRET`

**Valeurs a noter :**

| Variable | Source |
|----------|--------|
| `TENANT_ID` | Entra ID → Overview |
| `AIROUTER_CLIENT_ID` | App 2 |
| `AIROUTER_CLIENT_SECRET` | App 2 → Secrets |
| `FAKEBOBDATA_CLIENT_ID` | App 1 |
| `POSTMAN_CLIENT_ID` | App 3 |
| `POSTMAN_CLIENT_SECRET` | App 3 → Secrets |

### 3.2 Creer 2 utilisateurs test
- `testuser-david@<domaine>.onmicrosoft.com` (David Cohen)
- `testuser-sarah@<domaine>.onmicrosoft.com` (Sarah Levy)

### 3.3 Creer Azure AI Foundry (pour le Foundry Agent)

1. **Portail Azure** → Creer une ressource → "Azure AI Foundry"
2. Creer un **Hub** :
   - Nom : `kornit-ai-hub`
   - Region : West Europe (ou la plus proche)
   - Storage Account : creer automatiquement
3. Creer un **Project** dans le hub :
   - Nom : `kornit-obo-demo`
4. **Deployer un modele** :
   - Models + endpoints → Deploy base model → `gpt-4o-mini`
   - **Noter** : la connection string du projet

### 3.4 Creer le Foundry Agent (HR Agent)

Dans le portail AI Foundry (https://ai.azure.com) → votre projet → Agents :

1. Cliquer **"+ Create agent"**
2. Nom : `kornit-hr-agent`
3. Modele : `gpt-4o-mini`
4. Instructions :
   ```
   Tu es l'agent HR de Kornit Digital. Quand un employe demande ses informations RH
   (profil, salaire, conges, manager), tu utilises l'outil get_hr_profile pour recuperer
   ses donnees. Tu ne reponds JAMAIS avec des donnees inventees — tu appelles toujours
   l'outil d'abord.
   ```
5. **Ajouter le Function Tool** `get_hr_profile` (via SDK ou portail)
6. **Noter l'Agent ID** apres creation

---

## PHASE 4 : Remplacer les placeholders

Une fois la Phase 3 terminee, remplacer dans les fichiers :

| Placeholder | Fichier(s) | Valeur |
|-------------|-----------|--------|
| `__TENANT_ID__` | `AIRouter/appsettings.json` + `FakeBobData/appsettings.json` | Ton Tenant ID |
| `__AIROUTER_CLIENT_ID__` | `AIRouter/appsettings.json` | Client ID de l'App 2 |
| `__AIROUTER_CLIENT_SECRET__` | `AIRouter/appsettings.json` | Secret de l'App 2 |
| `__FAKEBOBDATA_CLIENT_ID__` | Les 2 appsettings.json | Client ID de l'App 1 |
| `__FOUNDRY_CONNECTION_STRING__` | `AIRouter/appsettings.json` | Connection string du projet Foundry |
| `__FOUNDRY_AGENT_ID__` | `AIRouter/appsettings.json` | Agent ID du Foundry Agent |

---

## PHASE 5 : Deployer sur Azure App Service

### 5.1 Creer le Resource Group
```bash
az group create --name rg-kornit-obo --location westeurope
```

### 5.2 Deployer FakeBobData
```bash
cd src/FakeBobData
az webapp up --name kornit-fakebobdata --resource-group rg-kornit-obo --runtime "DOTNETCORE:8.0" --sku B1
```

Configurer les App Settings (secrets via portail, pas dans le code) :
```bash
az webapp config appsettings set --name kornit-fakebobdata --resource-group rg-kornit-obo --settings \
  AzureAd__TenantId="<TENANT_ID>" \
  AzureAd__ClientId="<FAKEBOBDATA_CLIENT_ID>" \
  AzureAd__Audience="api://<FAKEBOBDATA_CLIENT_ID>"
```

### 5.3 Deployer AIRouter
```bash
cd src/AIRouter
az webapp up --name kornit-airouter --resource-group rg-kornit-obo --runtime "DOTNETCORE:8.0" --sku B1
```

Configurer les App Settings :
```bash
az webapp config appsettings set --name kornit-airouter --resource-group rg-kornit-obo --settings \
  AzureAd__TenantId="<TENANT_ID>" \
  AzureAd__ClientId="<AIROUTER_CLIENT_ID>" \
  "AzureAd__ClientCredentials__0__ClientSecret"="<AIROUTER_CLIENT_SECRET>" \
  FakeBobData__BaseUrl="https://kornit-fakebobdata.azurewebsites.net" \
  "FakeBobData__Scopes__0"="api://<FAKEBOBDATA_CLIENT_ID>/user_impersonation" \
  AzureAIFoundry__ConnectionString="<FOUNDRY_CONNECTION_STRING>" \
  AzureAIFoundry__AgentId="<AGENT_ID>"
```

### 5.4 Verifier le deploiement
```bash
# Verifier que les 2 App Services sont en ligne
curl -s -o /dev/null -w "%{http_code}" https://kornit-fakebobdata.azurewebsites.net/api/HrData/my-profile
# → 401 (normal, pas de token)

curl -s -o /dev/null -w "%{http_code}" https://kornit-airouter.azurewebsites.net/api/Chat/whoami
# → 401 (normal, pas de token)
```

Un 401 = l'App Service est en ligne et l'auth fonctionne. Tout ce qui n'est pas 401 = probleme de deploiement.

---

## PHASE 6 : Tests Postman sur Azure

### 6.1 Configurer Postman
- **POST** `https://kornit-airouter.azurewebsites.net/api/Chat/ask`
- **Body** (JSON) : `{ "question": "Montre moi mon profil RH" }`
- **Authorization** : OAuth 2.0, Authorization Code
  - Auth URL : `https://login.microsoftonline.com/<TENANT_ID>/oauth2/v2.0/authorize`
  - Token URL : `https://login.microsoftonline.com/<TENANT_ID>/oauth2/v2.0/token`
  - Client ID : `<POSTMAN_CLIENT_ID>`
  - Client Secret : `<POSTMAN_CLIENT_SECRET>`
  - Scope : `api://<AIROUTER_CLIENT_ID>/user_impersonation openid profile email`
  - Callback : `https://oauth.pstmn.io/v1/callback`

### 6.2 Test David
1. Get New Access Token → login `testuser-david` → Use Token
2. Envoyer la requete
3. **Verifier** :
   - Le Router identifie David
   - OBO reussi → Token B en RAM du App Service
   - Foundry Agent retourne `requires_action: get_hr_profile`
   - Plugin appelle `kornit-fakebobdata.azurewebsites.net` avec Token B
   - Reponse en langage naturel : "David Cohen, R&D Ink Chemistry..."

### 6.3 Test Sarah (isolation)
1. Nouveau token → login `testuser-sarah`
2. Meme requete
3. **Verifier** : donnees differentes (Sarah Levy, Digital Printing)
4. **PREUVE** : David ne voit JAMAIS les donnees de Sarah

### 6.4 Ce que la demo prouve visuellement

| Ce qu'on voit | Ce que ca prouve |
|---------------|-----------------|
| URLs `*.azurewebsites.net` | Les services tournent dans Azure, pas en local |
| David voit ses donnees, Sarah les siennes | L'identite est preservee bout en bout dans Azure |
| Le Foundry Agent retourne `requires_action` | L'agent ne touche JAMAIS le token |
| Token B en RAM du App Service | Zero Redis, zero cache externe |
| Reponse en langage naturel | Le Foundry Agent est utile (pas un simple proxy) |

---

## PHASE 7 : Presentation — Entra Agent ID

### Ce que la demo montre (l'etat actuel)
Le AI Router (App Service) fait le gros du travail : OBO, interception requires_action, appel securise.
Semantic Kernel automatise le polling mais le Router reste le gardien des tokens.
**Tout tourne dans Azure** — meme infrastructure que la production.

### Ce qu'Entra Agent ID changera (GA prevue mai 2026)
Quand Entra Agent ID sera GA :
- Le Foundry Agent aura sa propre **Agent Identity Blueprint**
- La plateforme Azure executera le OBO **nativement cote serveur**
- Le AI Router n'aura plus besoin de gerer les tokens
- Zero code pour l'echange de tokens

### Impact sur le code
- `BobDataPlugin` → **supprime** (le Foundry Agent appellera BobData directement)
- `requires_action` loop → **supprimee** (la plateforme fait tout)
- `ITokenAcquisition` dans le Router → **simplifie** (juste passer Token A)

---

## Mapping Demo → HLD

| Tier HLD | Composant HLD | Composant Demo | Deploye sur |
|----------|--------------|----------------|-------------|
| Tier 1 | Teams + Ingress APIM | Postman | Local (simule Teams) |
| Tier 3 | AI Orchestrator (SK) | `kornit-airouter` | **Azure App Service** |
| Tier 3 | Entra ID OBO | MSAL OBO | **Azure Entra ID** |
| Tier 4 | Foundry Agents | `kornit-hr-agent` | **Azure AI Agent Service** |
| Tier 8/9 | HR Database | `kornit-fakebobdata` | **Azure App Service** |

> Les Tiers 2 (APIM/Cosmos), 5 (Internal APIM), et 6 (Logic Apps) ne participent pas
> a la propagation d'identite — ils ne sont pas necessaires pour prouver le pattern OBO.

---

## Troubleshooting

| Erreur | Solution |
|--------|----------|
| AADSTS65001 consent | Grant admin consent dans chaque App Registration |
| AADSTS50013 audience mismatch | Verifier `Audience` = `api://<CLIENT_ID>` dans FakeBobData |
| AADSTS500011 resource not found | L'App Registration n'a pas de scope expose — verifier "Expose an API" |
| AADSTS7000215 invalid secret | Secret expire ou mauvais — verifier App Settings du App Service |
| 502 Bad Gateway sur App Service | Verifier les logs : `az webapp log tail --name kornit-airouter --resource-group rg-kornit-obo` |
| Foundry Agent timeout (10min) | Verifier que FakeBobData App Service repond rapidement |
| requires_action non intercepte | Verifier que le plugin est enregistre dans le Kernel AVANT de creer l'agent |
| Token OBO null dans le plugin | Verifier que `KernelArguments` contient `obo_token` |

---

## Checklist de securite

### Avant chaque test
- [ ] Admin consent accorde sur **toutes** les App Registrations
- [ ] Les 2 utilisateurs test existent et ont un mot de passe fonctionnel
- [ ] Les 2 App Services sont en ligne (retournent 401 sans token)

### Verifications token / identite
- [ ] Token B a bien le scope `api://<FAKEBOBDATA_CLIENT_ID>/user_impersonation`
- [ ] Token B est un **delegated token** (pas app-only) — verifier `scp` claim present
- [ ] Token A et Token B contiennent le meme `oid` (meme utilisateur bout en bout)

### Isolation des donnees (le test critique)
- [ ] David voit UNIQUEMENT ses donnees
- [ ] Sarah voit UNIQUEMENT ses donnees
- [ ] Un appel sans token retourne 401

### Securite du token (le coeur du probleme Kornit)
- [ ] Token B n'apparait JAMAIS dans les logs du Foundry Agent
- [ ] Token B n'est JAMAIS transmis via HTTP au Foundry Agent
- [ ] Token B reste exclusivement en RAM du App Service
- [ ] Aucun token dans Redis, fichier, base de donnees, ou variable d'environnement

---

## Nettoyage apres la demo

```bash
# Supprimer toutes les ressources Azure
az group delete --name rg-kornit-obo --yes --no-wait
```
