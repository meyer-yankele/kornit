using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Identity.Web;

var builder = WebApplication.CreateBuilder(args);

// === OUTIL 1 : Microsoft.Identity.Web — Auth + OBO en quelques lignes ===
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("AzureAd"))
    .EnableTokenAcquisitionToCallDownstreamApi()
    .AddInMemoryTokenCaches();

builder.Services.AddAuthorization();
builder.Services.AddControllers();

// HttpClient for calling FakeBobData (used by BobDataPlugin)
builder.Services.AddHttpClient("FakeBobData", client =>
{
    var baseUrl = builder.Configuration["FakeBobData:BaseUrl"] ?? "https://localhost:7002";
    client.BaseAddress = new Uri(baseUrl);
});

var app = builder.Build();

app.UseHttpsRedirection();
app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();

app.Run();
