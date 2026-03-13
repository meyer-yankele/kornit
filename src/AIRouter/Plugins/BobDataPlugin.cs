using System.ComponentModel;
using System.Net.Http.Headers;
using Microsoft.SemanticKernel;

namespace AIRouter.Plugins;

/// <summary>
/// Semantic Kernel plugin that calls FakeBobData LOCALLY with OBO token from RAM.
///
/// KEY SECURITY PATTERN:
/// - The Foundry Agent NEVER sees this token (the "wall")
/// - The Agent returns requires_action → this plugin executes locally
/// - Token B lives only in RAM, never in Redis/DB/cache
/// </summary>
public class BobDataPlugin
{
    private readonly IHttpClientFactory _httpClientFactory;
    private string? _oboToken;

    public BobDataPlugin(IHttpClientFactory httpClientFactory)
    {
        _httpClientFactory = httpClientFactory;
    }

    /// <summary>
    /// Sets the OBO token in RAM before the agent invocation.
    /// Token B lives ONLY in this object's memory — never sent to the AI agent.
    /// </summary>
    public void SetOboToken(string token) => _oboToken = token;

    [KernelFunction("get_hr_profile")]
    [Description("Retrieves the HR profile of the authenticated employee from BobData")]
    public async Task<string> GetHrProfileAsync(
        [Description("The employee's HR query")] string query)
    {
        // Token B is stored in RAM via SetOboToken() — never leaves the App Service
        var oboToken = _oboToken
            ?? throw new InvalidOperationException(
                "OBO token not available in RAM. The Supervisor must call SetOboToken() before invoking the agent.");

        var client = _httpClientFactory.CreateClient("FakeBobData");
        var request = new HttpRequestMessage(HttpMethod.Get, "/api/HrData/my-profile");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", oboToken);

        var response = await client.SendAsync(request);
        var body = await response.Content.ReadAsStringAsync();

        if (!response.IsSuccessStatusCode)
        {
            Console.WriteLine($"[BobDataPlugin] ERROR: {response.StatusCode} — {body}");
            return $"Error calling BobData: {response.StatusCode} — {body}";
        }

        Console.WriteLine($"[BobDataPlugin] SUCCESS: {body.Substring(0, Math.Min(200, body.Length))}");
        return body;
    }
}
