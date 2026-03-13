# Kornit OBO Identity Demo — Journal de Session
**Date :** 11 mars 2026
**Auteur :** Yaacov (Azure AI Platform Team, Kornit Digital)
**Objectif :** Prouver que l'identité employé est préservée bout-en-bout via le flux OBO (On-Behalf-Of) Azure, avec démonstration live sur Azure Portal.

---

## 1. Architecture déployée sur Azure

### Services Azure actifs

| Service | URL | Rôle |
|---------|-----|------|
| **AIRouter** | `kornit-airouter.azurewebsites.net` | Point d'entrée — valide Token A, fait l'OBO, orchestre l'agent |
| **FakeBobData** | `kornit-fakebobdata.azurewebsites.net` | API RH simulée — valide Token B, retourne données par employé |
| **Azure AI Foundry Agent** | `westeurope.api.cognitive.microsoft.com` | Agent GPT-4o-mini — `kornit-hr-agent` (ID: `asst_uD0EGtv0YGYi5tKuD3Cp09WF`) |
| **Entra ID** | Tenant: `28ebea5a-2667-45d2-a777-e778cfdf7509` | Authentification + échange OBO |

### App Registrations Entra ID

| App | Client ID | Rôle |
|-----|-----------|------|
| `kornit-ai-router` | `93d9ee75-62f0-4bb2-a032-cd3c40dab9e3` | Reçoit Token A, émet Token B |
| `kornit-fakebobdata` | `9a1d91b4-4dcb-461e-8095-252afb105a6c` | Cible finale OBO |
| `kornit-postman-client` | `ccc99e15-5c21-4901-b239-1fd4b44034b5` | Client Postman (simule Teams) |

---

## 2. Le Flux OBO — Explication Complète

```
Postman (Teams)
    │
    │  Token A (JWT — David Cohen)
    ▼
kornit-airouter.azurewebsites.net
    │
    ├─ 1. Valide Token A via Microsoft.Identity.Web
    ├─ 2. OBO Exchange : Token A → Token B (RAM uniquement)
    ├─ 3. Envoie TEXTE SEULEMENT à Foundry Agent (zéro token)
    │
    ├──────────────────────────────────────────────┐
    │                                              │
    ▼                                              ▼
Azure AI Foundry Agent                    BobDataPlugin (local)
(kornit-hr-agent)                         avec Token B depuis RAM
    │                                              │
    │ requires_action: get_hr_profile              ▼
    └──────────────────────────────► kornit-fakebobdata
                                     Valide Token B
                                     Retourne données David uniquement
```

### Garantie de sécurité fondamentale
> **Token B ne quitte JAMAIS la RAM de l'App Service AIRouter.**
> Il n'est pas stocké dans Redis, pas écrit sur disque, pas envoyé à l'agent IA, pas loggué, pas caché dans un système externe.

---

## 3. Stack Technique

### Technologies utilisées

| Technologie | Version | Usage |
|-------------|---------|-------|
| **.NET 8** | 8.0.23 | Runtime des deux App Services |
| **Microsoft.Identity.Web** | dernière | Validation JWT + OBO automatique |
| **MSAL.NET** | 4.82.0.0 | Bibliothèque OBO sous-jacente |
| **Semantic Kernel** | 1.73.0-preview | Orchestration agent + plugins |
| **OpenAIAssistantAgent** (SK) | preview | Connexion à Azure AI Foundry |
| **BobDataPlugin** | custom | Plugin local exécuté avec Token B |
| **Azure App Service** | Linux | Hébergement AIRouter + FakeBobData |
| **Azure AI Foundry** | westeurope | Agent GPT-4o-mini |
| **AddInMemoryTokenCaches** | MSAL | Cache RAM uniquement (remplace Redis) |

### Endpoints disponibles

| Méthode | Endpoint | Description |
|---------|----------|-------------|
| `GET` | `/api/Chat/whoami` | Diagnostic — affiche les claims du Token A |
| `GET` | `/api/Chat/test-foundry` | Diagnostic — teste la connexion à l'agent IA |
| `POST` | `/api/Chat/ask` | Principal — exécute le flux OBO complet |

---

## 4. Fichiers créés/modifiés aujourd'hui

### `docs/demo-obo-proof.html`
**Page de démonstration MVP** — Interface visuelle type "Mission Control" qui :
- Anime le flux OBO step-by-step avec SVG
- Affiche les logs en temps réel (terminal style)
- Montre les 3 preuves de sécurité (Token B RAM, zéro token agent, isolation identité)
- Mode SIMULATION (données réelles capturées) + Mode LIVE (appels API réels)
- Ouvrir directement dans le navigateur — zéro installation
- Police : Orbitron + Fira Code, thème dark "Security Operations Center"

### `docs/architecture-diagram.html`
**Diagramme d'architecture** — Vue statique du flux OBO avec :
- Noeuds animés (User → AIRouter → Agent | FakeBobData)
- Security boundary visuelle
- Flow en 6 étapes
- Security badges (Zero-Trust, Isolation, Traçabilité)
- Stack technique

### `docs/SOLUTION_OVERVIEW.md`
**Vue d'ensemble de la solution** — Document technique expliquant :
- Le problème actuel (Redis = honeypot)
- La solution proposée (Token B en RAM)
- Comparaison : Redis vs RAM vs Entra Agent ID (futur)
- Mapping avec le HLD Kornit

### `docs/project1.md` (ce fichier)
Journal complet de la session du 11 mars 2026.

---

## 5. Démonstration Live Réussie — Preuves Azure

### Test effectué le 11 mars 2026 à 18:37 UTC

**Token utilisé :** Token A de `testuser-david@365-poc.com`
**Requête :** `POST /api/Chat/ask` avec question `"Quel est mon profil RH ?"`

### Logs Azure Log Stream (extraits clés)

```
18:37:22 === AI ROUTER (SUPERVISOR) ===
18:37:22 Employee identified: testuser-david@365-poc.com

18:37:22 === OnBehalfOfParameters ===
18:37:22 ApiId - AcquireTokenOnBehalfOf
18:37:23 POST login.microsoftonline.com/.../oauth2/v2.0/token
18:37:29 Response: 200 OK (6445ms)
18:37:30 Token Acquisition finished successfully
18:37:30 AT expiration: 19:25:46 — source: IdentityProvider

18:37:30 STEP 1 OK: OBO Token B acquired for testuser-david@365-poc.com
18:37:30 STEP 2 OK: Kernel + BobDataPlugin created (Token B in RAM)
18:37:30 STEP 3c OK: Assistant retrieved: kornit-hr-agent
18:37:31 STEP 4: Sending prompt to Assistant...

18:37:33 GET https://kornit-fakebobdata.azurewebsites.net/api/HrData/my-profile
18:37:35 Response: 200 OK (1380ms)
18:37:35 [BobDataPlugin] SUCCESS: authenticatedAs: testuser-david@365-poc.com

18:37:36 STEP 4a: Agent requires_action: get_hr_profile
18:37:36 STEP 4b: Plugin result (743 chars): David Cohen, KRN-2847...
18:37:39 STEP 4 OK: Response received (502 chars)
```

### Réponse API complète reçue

```json
{
  "status": "success",
  "employee": "testuser-david@365-poc.com",
  "question": "Quel est mon profil RH ?",
  "answer": "- Nom : David Cohen\n- ID : KRN-2847\n- Département : R&D — Ink Chemistry\n- Poste : Senior Ink Formulation Engineer\n- Site : Rosh Ha'Ayin, Israël\n- Manager : Dr. Yael Stern",
  "securityFlow": {
    "step1": "Token A received from Postman (simulates Teams)",
    "step2": "OBO: Token A → Token B for BobData (kept in App Service RAM)",
    "step3": "Text prompt sent to Foundry Agent (NO token)",
    "step4": "Foundry Agent returned requires_action: get_hr_profile",
    "step5": "Local plugin called FakeBobData WITH Token B from RAM",
    "step6": "Data submitted to Foundry Agent → natural language response",
    "tokenIsolation": "Token B NEVER left the App Service RAM",
    "identityPreserved": true
  }
}
```

---

## 6. Table de Preuves de Sécurité

| Preuve | Evidence dans les logs | Signification |
|--------|------------------------|---------------|
| Identité préservée | `testuser-david` présent à chaque étape | Pas un compte service générique |
| OBO réel | `AcquireTokenOnBehalfOf → 200 OK` | Entra ID a fait l'échange réel |
| Token en RAM | `Only in-memory caching is used` | Jamais Redis, jamais disque |
| Agent sans token | `requires_action: get_hr_profile` | L'IA demande — ne stocke pas |
| Isolation utilisateur | `authenticatedAs: testuser-david` | Sarah verrait SES données uniquement |

---

## 7. Comment faire la Démo sur Azure Portal

### Étapes (2 minutes devant le patron)

1. **Azure Portal → App Services → `kornit-airouter`**
2. **Support + troubleshooting → Log stream** (fenêtre noire "Connected!")
3. **Postman → Get New Access Token** → login `testuser-david@365-poc.com`
4. **POST** `https://kornit-airouter.azurewebsites.net/api/Chat/ask`
   ```json
   { "question": "Quel est mon profil RH ?" }
   ```
5. **Regarder le Log Stream Azure** s'animer en temps réel

### Points à montrer au patron
- `Employee identified: testuser-david` — identité capturée
- `OBO Token B acquired` — échange sécurisé
- `Only in-memory caching` — pas Redis
- `GET kornit-fakebobdata... 200 OK` — données récupérées avec Token B
- `requires_action` → `Plugin result` — l'agent n'a jamais eu le token

---

## 8. Utilisateurs de Test

| Utilisateur | UPN | Object ID | Données RH |
|-------------|-----|-----------|-----------|
| David Cohen | `testuser-david@365-poc.com` | `c6b708e1-72a7-4fbf-8f61-9e87ebe86d88` | R&D Ink Chemistry, KRN-2847 |
| Sarah Levy | `testuser-sarah@365-poc.com` | — | Digital Printing (à tester) |

---

## 9. Problèmes rencontrés et résolus

| Problème | Cause | Solution |
|----------|-------|----------|
| `401 — signature invalid` (18:16-18:22) | Token expiré (durée 68 min) | Obtenir nouveau token via Postman |
| CLI Azure `AADSTS7000215` | Secret SP expiré ou fichier manquant | Utiliser Postman directement |
| `test-foundry` réussi mais `ask` pas encore | Token expiré entre les deux appels | Obtenir token frais avant chaque série |

---

## 10. Prochaines Étapes

- [ ] **Tester avec Sarah** — obtenir token `testuser-sarah@365-poc.com` et appeler `/ask` → prouver que Sarah voit SES données uniquement
- [ ] **Ajouter CORS** à `Program.cs` pour permettre les appels depuis `demo-obo-proof.html` en live
- [ ] **Régénérer le secret du Service Principal** (`cb6b3ec4-52f3-4482-90a0-f0012edf9a3e`) pour réautomatiser les déploiements CLI
- [ ] **Présenter à Yonah / direction** avec le Log Stream + la réponse JSON comme preuve

---

## 11. Futur — Entra Agent ID (GA prévu mai 2026)

Quand Microsoft Entra Agent ID atteindra la GA :
- L'agent IA aura sa propre **Agent Identity Blueprint**
- Azure fera l'OBO **nativement côté serveur**
- `BobDataPlugin` et la boucle `requires_action` seront **supprimés**
- Zero code d'échange de token requis

**Cette demo est l'Étape 1.** Elle prouve le pattern sécurisé aujourd'hui sur Azure.
Entra Agent ID simplifiera le code — même sécurité, moins de code.

---

*Fichier généré le 11 mars 2026 — Session Claude Code (Sonnet 4.6)*
