using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace FakeBobData.Controllers;

[ApiController]
[Route("api/[controller]")]
[Authorize]
public class HrDataController : ControllerBase
{
    // Simulated BobData HR database — different data per employee
    private static readonly Dictionary<string, object> EmployeeDatabase = new(StringComparer.OrdinalIgnoreCase)
    {
        ["testuser-david"] = new
        {
            FullName = "David Cohen",
            EmployeeId = "KRN-2847",
            Department = "R&D — Ink Chemistry",
            Title = "Senior Ink Formulation Engineer",
            Site = "Rosh Ha'Ayin, Israel",
            Manager = "Dr. Yael Stern",
            StartDate = "2019-03-15",
            AnnualLeaveBalance = 18,
            LastReview = "Exceeds Expectations",
            Salary = "Confidential — Grade E7"
        },
        ["testuser-sarah"] = new
        {
            FullName = "Sarah Levy",
            EmployeeId = "KRN-3912",
            Department = "Digital Printing — Software",
            Title = "Principal Software Engineer",
            Site = "Kiryat Gat, Israel",
            Manager = "Oren Barak",
            StartDate = "2021-07-01",
            AnnualLeaveBalance = 22,
            LastReview = "Outstanding",
            Salary = "Confidential — Grade E8"
        }
    };

    /// <summary>
    /// GET /api/HrData/my-profile
    /// Returns the HR profile of the AUTHENTICATED employee.
    /// The identity comes from the OBO Token (Token B) — proving end-to-end identity preservation.
    /// </summary>
    [HttpGet("my-profile")]
    public IActionResult GetMyProfile()
    {
        // Extract identity from JWT claims (Token B received via OBO chain)
        var upn = User.FindFirst("preferred_username")?.Value
                ?? User.FindFirst("upn")?.Value
                ?? User.FindFirst("http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn")?.Value;

        var oid = User.FindFirst("http://schemas.microsoft.com/identity/claims/objectidentifier")?.Value
                ?? User.FindFirst("oid")?.Value;

        var name = User.FindFirst("name")?.Value;

        if (string.IsNullOrEmpty(upn))
        {
            return Unauthorized(new
            {
                error = "Identity not found",
                message = "Token does not contain UPN claim. OBO chain may be broken.",
                claims = User.Claims.Select(c => new { c.Type, c.Value }).ToList()
            });
        }

        // Extract username prefix (e.g., "testuser-david" from "testuser-david@kornit.onmicrosoft.com")
        var username = upn.Split('@')[0].ToLowerInvariant();

        if (!EmployeeDatabase.TryGetValue(username, out var profile))
        {
            return NotFound(new
            {
                error = "Employee not found",
                message = $"No HR record found for '{username}'.",
                hint = "Only testuser-david and testuser-sarah have HR records in this demo."
            });
        }

        return Ok(new
        {
            source = "FakeBobData (BobHR Simulator)",
            authenticatedAs = upn,
            objectId = oid,
            displayName = name,
            tokenType = "OBO Token B — identity preserved from original user",
            hrProfile = profile,
            proofOfIsolation = $"This data belongs exclusively to {username}. " +
                               "Another user calling the same endpoint sees DIFFERENT data. " +
                               "Identity flows end-to-end via OBO — no shared service account."
        });
    }
}
