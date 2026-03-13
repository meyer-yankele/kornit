# PROMPT DE RECHERCHE — Kornit OBO + Azure AI Foundry + Semantic Kernel

> Copier-coller ce prompt tel quel dans Claude, ChatGPT, Gemini, Perplexity, ou tout agent IA de recherche.

---

```
# MISSION CRITIQUE — RECHERCHE APPROFONDIE

Tu es un ingénieur senior Azure spécialisé en sécurité d'identité et en orchestration d'agents IA.
Je te confie une mission de recherche en profondeur. Je ne veux PAS de réponse théorique.
Je veux du code qui COMPILE, qui TOURNE, et qui FONCTIONNE — avec les PREUVES.

## RÈGLES STRICTES

1. **INTERDICTION de deviner.** Si tu n'es pas sûr d'une API, d'un nom de méthode ou d'un paramètre,
   DIS-LE. Je préfère "je ne suis pas sûr" plutôt qu'un code inventé qui fait perdre 3 heures.

2. **CITE TES SOURCES.** Pour chaque affirmation technique, donne :
   - Le lien vers la doc Microsoft officielle, OU
   - Le lien vers le repo GitHub (issue, sample, PR), OU
   - Le lien vers un article/blog Microsoft confirmé
   Si tu ne peux pas citer de source, marque [NON VÉRIFIÉ] à côté.

3. **VERSIONS EXACTES.** Mon stack est verrouillé. Ne me propose PAS de code pour d'autres versions :
   - Microsoft.SemanticKernel 1.73.0
   - Microsoft.SemanticKernel.Agents.OpenAI 1.73.0-preview
   - Azure.AI.OpenAI 2.8.0-beta.1
   - Azure.Identity 1.18.0
   - Microsoft.Identity.Web 4.5.0
   - .NET 8.0

4. **PAS DE RÉPONSE OPENAI VANILLA.** Mon endpoint est Azure AI Foundry (Azure AI Services),
   PAS api.openai.com. Les APIs sont différentes. Ne me donne pas d'exemples OpenAI standard.

---

## MON ARCHITECTURE

```
Postman (simule Teams)
    │ Token A (JWT Entra ID)
    ▼
AIRouter (.NET 8, Azure App Service)
    │ 1. Valide Token A
    │ 2. OBO exchange → Token B (stocké EN RAM uniquement via MSAL InMemoryTokenCaches)
    │ 3. Crée un Semantic Kernel + BobDataPlugin
    │ 4. Connecte un Azure AI Foundry Agent (GPT-4o-mini)
    │ 5. Envoie le TEXTE SEUL à l'agent (aucun token)
    │ 6. L'agent retourne requires_action: get_hr_profile
    │ 7. Semantic Kernel exécute le plugin LOCALEMENT avec Token B depuis la RAM
    │ 8. Le plugin appelle FakeBobData avec Token B
    │ 9. Les données reviennent → l'agent formule la réponse
    ▼
FakeBobData (.NET 8, Azure App Service)
    Valide Token B → retourne les données RH de l'employé identifié
```

**Endpoint Azure AI Foundry** : `https://westeurope.api.cognitive.microsoft.com/`
**Agent ID** : `asst_uD0EGtv0YGYi5tKuD3Cp09WF`
**Authentification** : API Key (pas DefaultAzureCredential)
**Modèle** : gpt-4o-mini

---

## MON CODE ACTUEL (qui ne fonctionne pas de bout en bout)

### ChatController.cs — Le flux principal

```csharp
// STEP 2: Create Kernel + Plugin
var kernel = Kernel.CreateBuilder().Build();
var bobDataPlugin = new BobDataPlugin(_httpClientFactory);
kernel.ImportPluginFromObject(bobDataPlugin, "bobdata");

// STEP 3: Connect to Azure AI Foundry Agent
var apiKey = _config["AzureAIFoundry:ApiKey"]!;
var openAIClient = OpenAIAssistantAgent.CreateAzureOpenAIClient(
    new ApiKeyCredential(apiKey), new Uri(endpoint));
var assistantClient = openAIClient.GetAssistantClient();
var assistantDef = await assistantClient.GetAssistantAsync(agentId);

var agent = new OpenAIAssistantAgent(assistantDef.Value, assistantClient)
{
    Kernel = kernel
};

// STEP 4: Send prompt — requires_action should be handled by SK
var thread = new OpenAIAssistantAgentThread(assistantClient);
var userMessage = new ChatMessageContent(AuthorRole.User, request.Question ?? "Who am I?");
var arguments = new KernelArguments { ["obo_token"] = oboToken };

var options = new AgentInvokeOptions
{
    KernelArguments = arguments,
    OnIntermediateMessage = (msg) =>
    {
        foreach (var item in msg.Items)
        {
            if (item is FunctionCallContent fc)
                _logger.LogInformation("Agent requires_action: {Function}", fc.FunctionName);
            else if (item is FunctionResultContent frc)
                _logger.LogInformation("Plugin result: {Result}", frc.Result?.ToString());
        }
        return Task.CompletedTask;
    }
};

var responseBuilder = new StringBuilder();
await foreach (var item in agent.InvokeStreamingAsync(userMessage, thread, options))
{
    responseBuilder.Append(item.Message.Content);
}
```

### BobDataPlugin.cs — Le plugin Semantic Kernel

```csharp
public class BobDataPlugin
{
    private readonly IHttpClientFactory _httpClientFactory;

    public BobDataPlugin(IHttpClientFactory httpClientFactory)
    {
        _httpClientFactory = httpClientFactory;
    }

    [KernelFunction("get_hr_profile")]
    [Description("Retrieves the HR profile of the authenticated employee from BobData")]
    public async Task<string> GetHrProfileAsync(
        [Description("The employee's HR query")] string query,
        KernelArguments? args = null)
    {
        var oboToken = args?["obo_token"]?.ToString()
            ?? throw new InvalidOperationException("OBO token not available in RAM.");

        var client = _httpClientFactory.CreateClient("FakeBobData");
        var request = new HttpRequestMessage(HttpMethod.Get, "/api/HrData/my-profile");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", oboToken);

        var response = await client.SendAsync(request);
        return await response.Content.ReadAsStringAsync();
    }
}
```

### NuGet packages (AIRouter.csproj)

```xml
<PackageReference Include="Azure.AI.OpenAI" Version="2.8.0-beta.1" />
<PackageReference Include="Azure.Identity" Version="1.18.0" />
<PackageReference Include="Microsoft.Identity.Web" Version="4.5.0" />
<PackageReference Include="Microsoft.SemanticKernel" Version="1.73.0" />
<PackageReference Include="Microsoft.SemanticKernel.Agents.OpenAI" Version="1.73.0-preview" />
```

---

## LES QUESTIONS PRÉCISES — RÉPONDS À CHACUNE

### QUESTION 1 : Est-ce que `OpenAIAssistantAgent` est la bonne classe ?

Semantic Kernel a changé PLUSIEURS FOIS son API agents entre les versions 1.x.
- Dans SK 1.73.0-preview, est-ce que `OpenAIAssistantAgent` existe encore ?
- Ou est-ce que c'est devenu `AzureAIAgent`, `AssistantAgent`, ou autre chose ?
- Quel namespace exact ? `Microsoft.SemanticKernel.Agents.OpenAI` est-il correct ?

**PREUVE DEMANDÉE** : Lien vers le code source GitHub de SK 1.73.0 montrant cette classe.

### QUESTION 2 : Est-ce que `CreateAzureOpenAIClient` fonctionne avec Azure AI Foundry ?

Mon endpoint est `https://westeurope.api.cognitive.microsoft.com/` (Azure AI Services multi-service).
- Est-ce que `OpenAIAssistantAgent.CreateAzureOpenAIClient()` est compatible avec ce type d'endpoint ?
- Ou est-ce qu'il faut un endpoint de type `https://xxx.openai.azure.com/` (Azure OpenAI classique) ?
- Ou un endpoint de type `https://xxx.services.ai.azure.com/` (nouveau format AI Foundry) ?
- Azure AI Agent Service (Foundry) utilise-t-il la même API Assistants que Azure OpenAI ?

**PREUVE DEMANDÉE** : Documentation ou sample officiel montrant quel format d'endpoint utiliser.

### QUESTION 3 : Comment le plugin reçoit-il le token OBO ?

Mon BobDataPlugin a cette signature :
```csharp
public async Task<string> GetHrProfileAsync(
    [Description("The employee's HR query")] string query,
    KernelArguments? args = null)
```

- Est-ce que Semantic Kernel passe automatiquement les `KernelArguments` au plugin quand
  l'agent fait un `requires_action` ?
- Ou est-ce que le plugin ne reçoit QUE les paramètres déclarés par l'agent dans le function call ?
- Si les KernelArguments ne sont pas passés, comment injecter un token contextuel dans un plugin ?
  (Alternatives : constructeur, HttpContext, closure, DI ?)

**PREUVE DEMANDÉE** : Code source SK ou sample officiel montrant comment un plugin accède
à des données contextuelles (pas les arguments de la function call de l'agent).

### QUESTION 4 : Le flux `InvokeStreamingAsync` gère-t-il `requires_action` automatiquement ?

Quand l'agent GPT-4o-mini retourne `requires_action` avec `get_hr_profile` :
- Est-ce que `OpenAIAssistantAgent.InvokeStreamingAsync()` intercepte automatiquement
  le `requires_action`, exécute le plugin Semantic Kernel localement, soumet le résultat
  à l'agent, et continue le streaming ?
- Ou est-ce qu'il faut intercepter manuellement avec une boucle polling + submit_tool_outputs ?
- `InvokeAsync` (non-streaming) se comporte-t-il différemment ?

**PREUVE DEMANDÉE** : Code source SK `OpenAIAssistantAgent.cs` ou test unitaire montrant
le comportement avec requires_action.

### QUESTION 5 : La définition de la function tool côté Foundry Agent

Mon agent Azure AI Foundry doit avoir un tool `get_hr_profile` défini.
- Quel format JSON exact pour la tool definition ?
- Les paramètres doivent-ils matcher EXACTEMENT les `[KernelFunction]` parameters du plugin ?
- Si oui, est-ce que `query` est le seul paramètre attendu ?
- Ou est-ce que SK peut synchroniser automatiquement les tools depuis le Kernel vers l'agent ?

**PREUVE DEMANDÉE** : Exemple de tool definition JSON qui fonctionne avec SK.

---

## CE QUE JE VEUX EN SORTIE

### LIVRABLE 1 : Diagnostic

Un tableau clair :
| Élément de mon code | Statut | Problème identifié | Source/Preuve |
|---|---|---|---|

### LIVRABLE 2 : Code corrigé COMPLET

Pas des fragments. Le fichier `ChatController.cs` COMPLET et le fichier `BobDataPlugin.cs` COMPLET,
corrigés et fonctionnels. Avec commentaires expliquant chaque correction.

### LIVRABLE 3 : Alternatives si SK Agent ne marche pas

Si `OpenAIAssistantAgent` ne fonctionne pas correctement avec Azure AI Foundry en SK 1.73.0 :
- **Plan B** : Utiliser directement `AssistantsClient` de `Azure.AI.OpenAI` (low-level API)
  avec une boucle manuelle requires_action → submit_tool_outputs
- **Plan C** : Utiliser `Azure.AI.Projects` SDK (si plus stable pour Foundry)
- **Plan D** : Downgrade ou upgrade de Semantic Kernel vers une version où ça fonctionne

Pour CHAQUE alternative, donne le code COMPLET et les preuves que ça marche.

### LIVRABLE 4 : Commande de test

Une commande curl ou PowerShell que je peux exécuter immédiatement pour vérifier que le flux
fonctionne de bout en bout une fois le code déployé.

---

## ANTI-BULLSHIT CHECKLIST

Avant de me répondre, vérifie toi-même :

- [ ] Chaque nom de classe que j'utilise EXISTE dans les versions de packages listées
- [ ] Chaque méthode que j'appelle A LA BONNE SIGNATURE pour ces versions
- [ ] Le code que tu me donnes COMPILERAIT si je le copie-colle (pas d'imports manquants,
      pas de types inventés)
- [ ] Tu as vérifié que l'endpoint Azure AI Foundry (cognitive.microsoft.com) est compatible
      avec l'API Assistants
- [ ] Tu n'as PAS confondu Azure OpenAI (openai.azure.com) avec Azure AI Services
      (cognitive.microsoft.com) avec Azure AI Foundry (ai.azure.com)
- [ ] Tu as cité au moins UNE source vérifiable pour chaque réponse technique

Si tu ne peux pas cocher tous ces points, DIS-LE EXPLICITEMENT et indique ce que tu n'as
pas pu vérifier. C'est 100x plus utile qu'une réponse qui a l'air confiante mais qui est fausse.

---

## CONTEXTE ADDITIONNEL POUR TA RECHERCHE

- Le Azure AI Agent Service (anciennement "Foundry Agents") est en Preview depuis fin 2024
- L'API path est probablement `/openai/assistants/` (pas `/assistants/`)
- Il y a eu des BREAKING CHANGES majeurs dans SK Agents entre 1.60 et 1.73
- L'ancien pattern `OpenAIAssistantAgent.CreateAsync()` a été remplacé (quand ? par quoi ?)
- Microsoft a fusionné Azure OpenAI avec Azure AI Services sous "Azure AI Foundry" en 2025
- Les endpoints `cognitive.microsoft.com` et `openai.azure.com` coexistent mais ont des
  comportements différents
- `AzureAIAgent` (namespace `Microsoft.SemanticKernel.Agents.AzureAI`) est une classe
  différente de `OpenAIAssistantAgent` — laquelle utiliser pour Foundry ?

Recherche les GitHub Issues du repo `microsoft/semantic-kernel` liées à :
- "AzureAIAgent" vs "OpenAIAssistantAgent"
- "Azure AI Foundry" + "assistant"
- "requires_action" + "function calling"
- "KernelArguments" + "plugin"
- Breaking changes dans Agents entre versions 1.60-1.73

---

FIN DU PROMPT. Maintenant fais ta recherche, prends le temps qu'il faut, et donne-moi
une réponse qui me fait GAGNER du temps, pas en PERDRE.
```

---
