using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Identity.Web;
using Microsoft.SemanticKernel;
using Microsoft.SemanticKernel.Agents;
using Microsoft.SemanticKernel.Agents.OpenAI;
using Microsoft.SemanticKernel.ChatCompletion;
using AIRouter.Plugins;
using System.ClientModel;
using System.Text;

namespace AIRouter.Controllers;

/// <summary>
/// THE SUPERVISOR — Orchestrates the secure OBO + Foundry Agent flow.
/// </summary>
[ApiController]
[Route("api/[controller]")]
[Authorize]
public class ChatController : ControllerBase
{
    private readonly ITokenAcquisition _tokenAcquisition;
    private readonly IConfiguration _config;
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly ILogger<ChatController> _logger;

    public ChatController(
        ITokenAcquisition tokenAcquisition,
        IConfiguration config,
        IHttpClientFactory httpClientFactory,
        ILogger<ChatController> logger)
    {
        _tokenAcquisition = tokenAcquisition;
        _config = config;
        _httpClientFactory = httpClientFactory;
        _logger = logger;
    }

    /// <summary>
    /// POST /api/Chat/ask — Main entry point.
    /// </summary>
    [HttpPost("ask")]
    public async Task<IActionResult> Ask([FromBody] UserQuestion request)
    {
        var upn = User.FindFirst("preferred_username")?.Value
                ?? User.FindFirst("http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn")?.Value
                ?? User.FindFirst("upn")?.Value
                ?? "unknown";

        _logger.LogInformation("=== AI ROUTER (SUPERVISOR) ===");
        _logger.LogInformation("Employee identified: {Upn}", upn);
        _logger.LogInformation("Question: {Question}", request.Question);

        // ============================================================
        // STEP 1: OBO — Acquire Token B for BobData, keep in RAM
        // ============================================================
        var bobDataScopes = _config.GetSection("FakeBobData:Scopes").Get<string[]>()
            ?? throw new InvalidOperationException("FakeBobData scopes not configured");

        string oboToken;
        try
        {
            oboToken = await _tokenAcquisition.GetAccessTokenForUserAsync(bobDataScopes);
            _logger.LogInformation("STEP 1 OK: OBO Token B acquired for {Upn}", upn);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "STEP 1 FAILED: OBO exchange failed for {Upn}", upn);
            return StatusCode(500, new { error = "obo_failed", message = ex.Message });
        }

        // ============================================================
        // STEP 2: Create Semantic Kernel with local plugin
        // ============================================================
        var kernel = Kernel.CreateBuilder().Build();
        var bobDataPlugin = new BobDataPlugin(_httpClientFactory);
        bobDataPlugin.SetOboToken(oboToken);  // Token B stored in RAM only
        kernel.ImportPluginFromObject(bobDataPlugin, "bobdata");
        _logger.LogInformation("STEP 2 OK: Kernel + BobDataPlugin created (Token B in RAM)");

        // ============================================================
        // STEP 3: Connect to Azure OpenAI Assistant
        // Uses /openai/assistants/ API path (not /assistants/)
        // ============================================================
        var endpoint = _config["AzureAIFoundry:Endpoint"]!;
        var agentId = _config["AzureAIFoundry:AgentId"]!;
        _logger.LogInformation("STEP 3: Connecting to Azure OpenAI at {Endpoint}, agent {AgentId}", endpoint, agentId);

        try
        {
            var apiKey = _config["AzureAIFoundry:ApiKey"]!;
            _logger.LogInformation("STEP 3a: Using API Key authentication");

            // Create Azure OpenAI client with API key (required for AIServices multi-service resource)
            var openAIClient = OpenAIAssistantAgent.CreateAzureOpenAIClient(new ApiKeyCredential(apiKey), new Uri(endpoint));
            var assistantClient = openAIClient.GetAssistantClient();
            _logger.LogInformation("STEP 3b: AssistantClient created, retrieving assistant...");

            var assistantDef = await assistantClient.GetAssistantAsync(agentId);
            _logger.LogInformation("STEP 3c OK: Assistant retrieved: {Name}", assistantDef.Value.Name);

            var agent = new OpenAIAssistantAgent(assistantDef.Value, assistantClient)
            {
                Kernel = kernel
            };

            // ============================================================
            // STEP 4: Send prompt — requires_action handled by SK
            // ============================================================
            _logger.LogInformation("STEP 4: Sending prompt to Assistant...");
            var thread = new OpenAIAssistantAgentThread(assistantClient);
            var userMessage = new ChatMessageContent(AuthorRole.User, request.Question ?? "Who am I?");
            var arguments = new KernelArguments { ["obo_token"] = oboToken };

            var responseBuilder = new StringBuilder();
            string? functionCalled = null;
            string? pluginResult = null;

            var options = new AgentInvokeOptions
            {
                KernelArguments = arguments,
                OnIntermediateMessage = (msg) =>
                {
                    foreach (var item in msg.Items)
                    {
                        if (item is FunctionCallContent fc)
                        {
                            functionCalled = fc.FunctionName;
                            _logger.LogInformation("STEP 4a: Agent requires_action: {Function}", fc.FunctionName);
                        }
                        else if (item is FunctionResultContent frc)
                        {
                            pluginResult = frc.Result?.ToString() ?? "null";
                            _logger.LogInformation("STEP 4b: Plugin result ({Length} chars): {Preview}",
                                pluginResult.Length,
                                pluginResult.Length > 300 ? pluginResult.Substring(0, 300) : pluginResult);
                        }
                    }
                    return Task.CompletedTask;
                }
            };

            await foreach (var item in agent.InvokeStreamingAsync(userMessage, thread, options))
            {
                responseBuilder.Append(item.Message.Content);
            }
            _logger.LogInformation("STEP 4 OK: Response received ({Length} chars)", responseBuilder.Length);

            // ============================================================
            // STEP 5: Return the response with security metadata
            // ============================================================
            return Ok(new
            {
                status = "success",
                employee = upn,
                question = request.Question,
                answer = responseBuilder.ToString(),
                securityFlow = new
                {
                    step1 = "Token A received from Postman (simulates Teams)",
                    step2 = "OBO: Token A → Token B for BobData (kept in App Service RAM)",
                    step3 = "Text prompt sent to Foundry Agent (NO token)",
                    step4 = $"Foundry Agent returned requires_action: {functionCalled ?? "N/A"}",
                    step5 = "Local plugin called FakeBobData WITH Token B from RAM",
                    step6 = "Data submitted to Foundry Agent → natural language response",
                    tokenIsolation = "Token B NEVER left the App Service RAM",
                    identityPreserved = true,
                    pluginRawResult = pluginResult ?? "N/A"
                }
            });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "STEP 3/4 FAILED: Azure OpenAI error");
            return StatusCode(500, new
            {
                error = "foundry_failed",
                step = "Azure OpenAI connection or agent invocation",
                message = ex.Message,
                innerError = ex.InnerException?.Message,
                type = ex.GetType().Name
            });
        }
    }

    /// <summary>
    /// GET /api/Chat/test-foundry — Diagnostic: test Azure OpenAI connection only
    /// </summary>
    [HttpGet("test-foundry")]
    public async Task<IActionResult> TestFoundry()
    {
        var endpoint = _config["AzureAIFoundry:Endpoint"]!;
        var agentId = _config["AzureAIFoundry:AgentId"]!;

        _logger.LogInformation("TEST-FOUNDRY: endpoint={Endpoint}, agentId={AgentId}", endpoint, agentId);

        try
        {
            var apiKey = _config["AzureAIFoundry:ApiKey"]!;
            _logger.LogInformation("TEST-FOUNDRY: Using API Key authentication");

            var openAIClient = OpenAIAssistantAgent.CreateAzureOpenAIClient(new ApiKeyCredential(apiKey), new Uri(endpoint));
            var assistantClient = openAIClient.GetAssistantClient();
            _logger.LogInformation("TEST-FOUNDRY: Client created, retrieving assistant...");

            var assistantDef = await assistantClient.GetAssistantAsync(agentId);
            _logger.LogInformation("TEST-FOUNDRY: Assistant retrieved OK: {Name}", assistantDef.Value.Name);

            return Ok(new
            {
                status = "foundry_connected",
                agentName = assistantDef.Value.Name,
                agentId = assistantDef.Value.Id,
                model = assistantDef.Value.Model,
                authMethod = "ApiKey",
                endpoint = endpoint
            });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "TEST-FOUNDRY FAILED");
            return StatusCode(500, new
            {
                error = "foundry_connection_failed",
                message = ex.Message,
                innerError = ex.InnerException?.Message,
                type = ex.GetType().Name
            });
        }
    }

    /// <summary>
    /// GET /api/Chat/whoami — Diagnostic endpoint showing Token A claims
    /// </summary>
    [HttpGet("whoami")]
    public IActionResult WhoAmI()
    {
        return Ok(new
        {
            endpoint = "AIRouter /api/Chat/whoami (Azure App Service)",
            upn = User.FindFirst("preferred_username")?.Value
                ?? User.FindFirst("http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn")?.Value
                ?? User.FindFirst("upn")?.Value,
            objectId = User.FindFirst("http://schemas.microsoft.com/identity/claims/objectidentifier")?.Value
                ?? User.FindFirst("oid")?.Value,
            name = User.FindFirst("name")?.Value,
            claims = User.Claims.Select(c => new { c.Type, c.Value }).ToList()
        });
    }
}

public record UserQuestion(string Question);
