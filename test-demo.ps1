# =============================================================================
# test-demo.ps1 — Kornit OBO Demo - Outil de test automatise
# =============================================================================
# Usage:
#   .\test-demo.ps1 login david       # Se connecter comme David (ouvre le navigateur)
#   .\test-demo.ps1 login sarah       # Se connecter comme Sarah
#   .\test-demo.ps1 whoami            # Tester whoami avec le dernier user
#   .\test-demo.ps1 test-foundry      # Tester la connexion AI Foundry
#   .\test-demo.ps1 ask               # Tester le flow complet (question par defaut)
#   .\test-demo.ps1 ask "Ma question" # Tester avec une question personnalisee
#   .\test-demo.ps1 test-all          # Tout tester d'un coup
#   .\test-demo.ps1 status            # Voir les tokens sauvegardes
#   .\test-demo.ps1 token "eyJ..."    # Sauvegarder un token manuellement (depuis Postman)
# =============================================================================

param(
    [Parameter(Position = 0)]
    [string]$Action = "status",

    [Parameter(Position = 1)]
    [string]$Arg1,

    [Parameter(Position = 2)]
    [string]$Arg2
)

# --- Configuration ---
$script:Config = @{
    TenantId        = ($env:KORNIT_TENANT_ID ?? "28ebea5a-2667-45d2-a777-e778cfdf7509")
    PostmanClientId = ($env:KORNIT_POSTMAN_CLIENT_ID ?? "ccc99e15-5c21-4901-b239-1fd4b44034b5")
    PostmanSecret   = ($env:KORNIT_POSTMAN_SECRET ?? $(throw "Set KORNIT_POSTMAN_SECRET env var"))
    AIRouterClientId = ($env:KORNIT_AIROUTER_CLIENT_ID ?? "93d9ee75-62f0-4bb2-a032-cd3c40dab9e3")
    Scope           = "api://$($env:KORNIT_AIROUTER_CLIENT_ID ?? '93d9ee75-62f0-4bb2-a032-cd3c40dab9e3')/access_as_user openid profile offline_access"
    BaseUrl         = ($env:KORNIT_BASE_URL ?? "https://kornit-airouter.azurewebsites.net")
    TokenFile       = "$PSScriptRoot\.demo-tokens.json"
    ListenPort      = 5050
}

$script:Users = @{
    david = "testuser-david@365-poc.com"
    sarah = "testuser-sarah@365-poc.com"
}

# --- Helpers ---
function Write-Step($icon, $text) {
    Write-Host "  $icon " -NoNewline -ForegroundColor Cyan
    Write-Host $text
}

function Write-OK($text) {
    Write-Host "  OK " -NoNewline -ForegroundColor Green
    Write-Host $text
}

function Write-Fail($text) {
    Write-Host "  FAIL " -NoNewline -ForegroundColor Red
    Write-Host $text
}

function Write-Title($text) {
    Write-Host ""
    Write-Host "=== $text ===" -ForegroundColor Yellow
    Write-Host ""
}

# --- Token Management ---
function Get-TokenStore {
    if (Test-Path $Config.TokenFile) {
        return Get-Content $Config.TokenFile -Raw | ConvertFrom-Json
    }
    return @{}
}

function Save-TokenStore($store) {
    $store | ConvertTo-Json -Depth 5 | Set-Content $Config.TokenFile -Encoding UTF8
}

function Get-ValidToken([string]$user) {
    $store = Get-TokenStore
    if (-not $store.$user) { return $null }

    $tokenData = $store.$user
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    # Token still valid?
    if ($tokenData.access_token -and $tokenData.expires_at -gt $now) {
        $remaining = [math]::Round(($tokenData.expires_at - $now) / 60)
        Write-Step ">" "Token $user valide encore $remaining minutes"
        return $tokenData.access_token
    }

    # Try refresh
    if ($tokenData.refresh_token) {
        Write-Step ">" "Token expire, rafraichissement..."
        return Invoke-TokenRefresh $user $tokenData.refresh_token
    }

    Write-Fail "Token $user expire et pas de refresh token"
    return $null
}

function Invoke-TokenRefresh([string]$user, [string]$refreshToken) {
    try {
        $body = @{
            client_id     = $Config.PostmanClientId
            client_secret = $Config.PostmanSecret
            grant_type    = "refresh_token"
            refresh_token = $refreshToken
            scope         = $Config.Scope
        }
        $response = Invoke-RestMethod `
            -Uri "https://login.microsoftonline.com/$($Config.TenantId)/oauth2/v2.0/token" `
            -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"

        Save-UserToken $user $response
        Write-OK "Token rafraichi pour $user"
        return $response.access_token
    }
    catch {
        Write-Fail "Refresh echoue: $($_.Exception.Message)"
        return $null
    }
}

function Save-UserToken([string]$user, $tokenResponse) {
    $store = Get-TokenStore
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    # Create a proper object
    $tokenObj = [PSCustomObject]@{
        access_token  = $tokenResponse.access_token
        refresh_token = if ($tokenResponse.refresh_token) { $tokenResponse.refresh_token } else { $null }
        expires_at    = $now + $tokenResponse.expires_in - 60  # 60s margin
        obtained_at   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        user          = $user
    }

    # Update store
    $storeHash = @{}
    if (Test-Path $Config.TokenFile) {
        $existing = Get-Content $Config.TokenFile -Raw | ConvertFrom-Json
        foreach ($prop in $existing.PSObject.Properties) {
            $storeHash[$prop.Name] = $prop.Value
        }
    }
    $storeHash[$user] = $tokenObj
    $storeHash["last_user"] = $user

    [PSCustomObject]$storeHash | ConvertTo-Json -Depth 5 | Set-Content $Config.TokenFile -Encoding UTF8

    $expiresMin = [math]::Round($tokenResponse.expires_in / 60)
    Write-OK "Token sauvegarde pour $user (expire dans ${expiresMin}min)"
}

# --- OAuth Login (Authorization Code + localhost listener) ---
function Invoke-Login([string]$user) {
    if (-not $Users.ContainsKey($user)) {
        Write-Fail "Utilisateur inconnu: $user (utiliser 'david' ou 'sarah')"
        return
    }

    Write-Title "LOGIN: $($Users[$user])"

    $redirectUri = "http://localhost:$($Config.ListenPort)"
    $authUrl = "https://login.microsoftonline.com/$($Config.TenantId)/oauth2/v2.0/authorize?" +
        "client_id=$($Config.PostmanClientId)" +
        "&response_type=code" +
        "&redirect_uri=$([uri]::EscapeDataString($redirectUri))" +
        "&scope=$([uri]::EscapeDataString($Config.Scope))" +
        "&login_hint=$([uri]::EscapeDataString($Users[$user]))" +
        "&prompt=login"

    # Start local HTTP listener
    $listener = $null
    try {
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("$redirectUri/")
        $listener.Start()
        Write-Step ">" "Serveur local demarre sur port $($Config.ListenPort)"
    }
    catch {
        Write-Fail "Impossible de demarrer le serveur local sur port $($Config.ListenPort)"
        Write-Host "  Essayez: netsh http add urlacl url=http://localhost:$($Config.ListenPort)/ user=$env:USERNAME" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  OU utilisez la methode manuelle:" -ForegroundColor Yellow
        Write-Host "  .\test-demo.ps1 token `"eyJ...`"" -ForegroundColor White
        return
    }

    # Open browser
    Write-Step ">" "Ouverture du navigateur..."
    Start-Process $authUrl
    Write-Host ""
    Write-Host "  Connectez-vous comme $($Users[$user]) dans le navigateur" -ForegroundColor Cyan
    Write-Host "  En attente de la reponse..." -ForegroundColor Gray
    Write-Host ""

    # Wait for callback (timeout 120s)
    $asyncResult = $listener.BeginGetContext($null, $null)
    $waited = $asyncResult.AsyncWaitHandle.WaitOne(300000)

    if (-not $waited) {
        $listener.Stop()
        Write-Fail "Timeout (120s) - reessayez"
        return
    }

    $context = $listener.EndGetContext($asyncResult)
    $code = $context.Request.QueryString["code"]
    $error_desc = $context.Request.QueryString["error_description"]

    # Send response to browser
    $html = if ($code) {
        "<html><body style='font-family:Arial;text-align:center;padding:50px'>" +
        "<h1 style='color:green'>Login reussi!</h1>" +
        "<p>Vous pouvez fermer cet onglet.</p>" +
        "<p style='color:gray'>$($Users[$user])</p></body></html>"
    } else {
        "<html><body style='font-family:Arial;text-align:center;padding:50px'>" +
        "<h1 style='color:red'>Erreur de login</h1>" +
        "<p>$error_desc</p></body></html>"
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
    $context.Response.ContentType = "text/html; charset=utf-8"
    $context.Response.ContentLength64 = $bytes.Length
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.Close()
    $listener.Stop()

    if (-not $code) {
        Write-Fail "Login echoue: $error_desc"
        return
    }

    Write-OK "Code d'autorisation recu"

    # Exchange code for tokens
    Write-Step ">" "Echange du code contre un token..."
    try {
        $body = @{
            client_id     = $Config.PostmanClientId
            client_secret = $Config.PostmanSecret
            grant_type    = "authorization_code"
            code          = $code
            redirect_uri  = $redirectUri
            scope         = $Config.Scope
        }
        $response = Invoke-RestMethod `
            -Uri "https://login.microsoftonline.com/$($Config.TenantId)/oauth2/v2.0/token" `
            -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"

        Save-UserToken $user $response
        Write-Host ""
        Write-OK "Connecte comme $($Users[$user])!"
        Write-Host "  Le token sera automatiquement rafraichi quand il expire." -ForegroundColor Gray
        Write-Host ""
    }
    catch {
        $err = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($err.error -eq "invalid_grant" -and $err.error_description -match "redirect_uri") {
            Write-Fail "Redirect URI non enregistree!"
            Write-Host ""
            Write-Host "  Ajoutez http://localhost:$($Config.ListenPort) dans Azure Portal:" -ForegroundColor Yellow
            Write-Host "  Azure Portal > App registrations > Postman-KornitDemo" -ForegroundColor White
            Write-Host "  > Authentication > Add a platform > Web" -ForegroundColor White
            Write-Host "  > Redirect URI: http://localhost:$($Config.ListenPort)" -ForegroundColor White
            Write-Host ""
            Write-Host "  OU utilisez la methode manuelle:" -ForegroundColor Yellow
            Write-Host "  1. Obtenez un token dans Postman" -ForegroundColor White
            Write-Host "  2. .\test-demo.ps1 token `"eyJ...`"" -ForegroundColor White
        }
        else {
            Write-Fail "Echange echoue: $($_.Exception.Message)"
            if ($err) { Write-Host "  $($err.error): $($err.error_description)" -ForegroundColor Gray }
        }
    }
}

# --- API Calls ---
function Invoke-API([string]$method, [string]$endpoint, [string]$token, $body = $null) {
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type"  = "application/json"
    }
    $url = "$($Config.BaseUrl)$endpoint"

    try {
        $params = @{
            Uri     = $url
            Method  = $method
            Headers = $headers
        }
        if ($body) {
            $params["Body"] = ($body | ConvertTo-Json)
        }
        $response = Invoke-RestMethod @params
        return @{ success = $true; data = $response }
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__
        $detail = $null
        try { $detail = $_.ErrorDetails.Message | ConvertFrom-Json } catch {}
        return @{
            success = $false
            status  = $status
            error   = if ($detail) { $detail } else { $_.Exception.Message }
        }
    }
}

function Test-WhoAmI([string]$token) {
    Write-Title "TEST: /api/Chat/whoami"
    $result = Invoke-API "GET" "/api/Chat/whoami" $token
    if ($result.success) {
        Write-OK "Identity confirmee"
        Write-Host "  Nom:  $($result.data.name)" -ForegroundColor White
        Write-Host "  UPN:  $($result.data.upn)" -ForegroundColor White
        Write-Host "  OID:  $($result.data.objectId)" -ForegroundColor White
    }
    else {
        Write-Fail "HTTP $($result.status): $($result.error)"
    }
    return $result
}

function Test-Foundry([string]$token) {
    Write-Title "TEST: /api/Chat/test-foundry"
    Write-Step ">" "Connexion a AI Foundry (peut prendre 10-30s)..."
    $result = Invoke-API "GET" "/api/Chat/test-foundry" $token
    if ($result.success) {
        Write-OK "AI Foundry connecte!"
        Write-Host "  Agent:  $($result.data.agentName)" -ForegroundColor White
        Write-Host "  Model:  $($result.data.model)" -ForegroundColor White
        Write-Host "  Cred:   $($result.data.credentialType)" -ForegroundColor White
    }
    else {
        Write-Fail "HTTP $($result.status)"
        if ($result.error.message) {
            Write-Host "  Erreur: $($result.error.message)" -ForegroundColor Red
            if ($result.error.innerError) {
                Write-Host "  Detail: $($result.error.innerError)" -ForegroundColor Gray
            }
        }
    }
    return $result
}

function Test-Ask([string]$token, [string]$question = "Who am I? Give me my HR profile.") {
    Write-Title "TEST: /api/Chat/ask"
    Write-Step ">" "Question: $question"
    Write-Step ">" "Flow: OBO + AI Foundry + BobDataPlugin (peut prendre 30-60s)..."
    $result = Invoke-API "POST" "/api/Chat/ask" $token @{ question = $question }
    if ($result.success) {
        Write-OK "Reponse recue!"
        Write-Host ""
        Write-Host "  Employee: $($result.data.employee)" -ForegroundColor Cyan
        Write-Host "  Reponse:" -ForegroundColor Cyan
        Write-Host "  $($result.data.answer)" -ForegroundColor White
        Write-Host ""
        Write-Host "  --- Security Flow ---" -ForegroundColor Yellow
        $sf = $result.data.securityFlow
        Write-Host "  1. $($sf.step1)" -ForegroundColor Gray
        Write-Host "  2. $($sf.step2)" -ForegroundColor Gray
        Write-Host "  3. $($sf.step3)" -ForegroundColor Gray
        Write-Host "  4. $($sf.step4)" -ForegroundColor Gray
        Write-Host "  5. $($sf.step5)" -ForegroundColor Gray
        Write-Host "  6. $($sf.step6)" -ForegroundColor Gray
        Write-Host "  Token Isolation: $($sf.tokenIsolation)" -ForegroundColor Green
    }
    else {
        Write-Fail "HTTP $($result.status)"
        if ($result.error.error) {
            Write-Host "  Erreur: $($result.error.error)" -ForegroundColor Red
            Write-Host "  Step:   $($result.error.step)" -ForegroundColor Gray
            Write-Host "  Msg:    $($result.error.message)" -ForegroundColor Gray
        }
        else {
            Write-Host "  $($result.error)" -ForegroundColor Red
        }
    }
    return $result
}

function Show-Status {
    Write-Title "STATUT DES TOKENS"
    $store = Get-TokenStore
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $hasTokens = $false
    foreach ($user in @("david", "sarah")) {
        if ($store.$user) {
            $hasTokens = $true
            $remaining = [math]::Round(($store.$user.expires_at - $now) / 60)
            $hasRefresh = if ($store.$user.refresh_token) { "oui" } else { "non" }
            if ($remaining -gt 0) {
                Write-OK "$user - Token valide ($remaining min restantes, refresh: $hasRefresh)"
            }
            else {
                if ($store.$user.refresh_token) {
                    Write-Step ">" "$user - Token expire (refresh disponible)"
                }
                else {
                    Write-Fail "$user - Token expire (pas de refresh)"
                }
            }
            Write-Host "    Obtenu: $($store.$user.obtained_at)" -ForegroundColor Gray
        }
    }

    if (-not $hasTokens) {
        Write-Host "  Aucun token sauvegarde." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Pour commencer:" -ForegroundColor Yellow
        Write-Host "    .\test-demo.ps1 login david     # Connexion via navigateur" -ForegroundColor White
        Write-Host "    .\test-demo.ps1 token `"eyJ...`"  # Coller un token Postman" -ForegroundColor White
    }

    if ($store.last_user) {
        Write-Host ""
        Write-Host "  Dernier utilisateur: $($store.last_user)" -ForegroundColor Cyan
    }
}

# --- Manual Token ---
function Save-ManualToken([string]$tokenStr, [string]$user = "manual") {
    # Try to decode the token to find the user
    try {
        $parts = $tokenStr.Split(".")
        $payload = $parts[1]
        # Fix padding
        switch ($payload.Length % 4) {
            2 { $payload += "==" }
            3 { $payload += "=" }
        }
        $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        $upn = if ($decoded.preferred_username) { $decoded.preferred_username } elseif ($decoded.upn) { $decoded.upn } else { "unknown" }

        # Match to known user
        foreach ($key in $Users.Keys) {
            if ($Users[$key] -eq $upn) {
                $user = $key
                break
            }
        }

        $expiresIn = $decoded.exp - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Write-OK "Token decode: $upn (expire dans $([math]::Round($expiresIn / 60)) min)"
    }
    catch {
        Write-Step ">" "Token non decodable, sauvegarde comme '$user'"
        $expiresIn = 3600
    }

    $fakeResponse = [PSCustomObject]@{
        access_token  = $tokenStr
        refresh_token = $null
        expires_in    = [math]::Max($expiresIn, 60)
    }
    Save-UserToken $user $fakeResponse
}

# --- Resolve Token for Commands ---
function Get-ActiveToken {
    $store = Get-TokenStore
    $lastUser = $store.last_user
    if (-not $lastUser) {
        Write-Fail "Aucun token disponible. Faites d'abord: .\test-demo.ps1 login david"
        return $null
    }

    $token = Get-ValidToken $lastUser
    if (-not $token) {
        Write-Fail "Token pour $lastUser invalide. Reconnectez-vous: .\test-demo.ps1 login $lastUser"
        return $null
    }
    return $token
}

# =============================================================================
# MAIN
# =============================================================================
Write-Host ""
Write-Host "  KORNIT OBO DEMO - Test Tool" -ForegroundColor Magenta
Write-Host "  ============================" -ForegroundColor Magenta

switch ($Action.ToLower()) {
    "login" {
        $user = if ($Arg1) { $Arg1.ToLower() } else { "david" }
        Invoke-Login $user
    }
    "token" {
        if (-not $Arg1) {
            Write-Fail "Usage: .\test-demo.ps1 token `"eyJ...votre_token...`""
            return
        }
        Save-ManualToken $Arg1
    }
    "whoami" {
        $token = Get-ActiveToken
        if ($token) { Test-WhoAmI $token }
    }
    "test-foundry" {
        $token = Get-ActiveToken
        if ($token) { Test-Foundry $token }
    }
    "ask" {
        $question = if ($Arg1) { $Arg1 } else { "Who am I? Give me my HR profile." }
        $token = Get-ActiveToken
        if ($token) { Test-Ask $token $question }
    }
    "test-all" {
        $token = Get-ActiveToken
        if (-not $token) { return }

        Test-WhoAmI $token
        Test-Foundry $token
        Test-Ask $token
    }
    "status" {
        Show-Status
    }
    default {
        Write-Host ""
        Write-Host "  Commandes:" -ForegroundColor Yellow
        Write-Host "    login david|sarah    Se connecter (navigateur)" -ForegroundColor White
        Write-Host "    token `"eyJ...`"       Sauvegarder un token Postman" -ForegroundColor White
        Write-Host "    whoami               Tester l'identite" -ForegroundColor White
        Write-Host "    test-foundry         Tester AI Foundry" -ForegroundColor White
        Write-Host "    ask [question]       Tester le flow complet" -ForegroundColor White
        Write-Host "    test-all             Tout tester" -ForegroundColor White
        Write-Host "    status               Voir les tokens" -ForegroundColor White
    }
}

Write-Host ""
