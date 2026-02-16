# ============================================================
#   KOFAX EQUITRAC - OUTIL DE GESTION API
# ============================================================

# ============================
# CONFIGURATION
# ============================

$BaseUrl = "https://mon-serveur:8282/equitracapi"
$TokenFile = "$env:TEMP\equitrac_token.json"
$LogFile = "C:\Logs\EquitracScript.log"
$SkipCertCheck = $true   # Mettre à $false en production avec certificat valide

# ============================
# LOGGING
# ============================

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )

    if (!(Test-Path (Split-Path $LogFile))) {
        New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force | Out-Null
    }

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $entry = "$timestamp [$Level] $Message"

    Add-Content -Path $LogFile -Value $entry
    Write-Host $entry
}

# ============================
# AUTHENTIFICATION
# ============================

function Get-EquitracToken {

    if (Test-Path $TokenFile) {
        $tokenData = Get-Content $TokenFile | ConvertFrom-Json
        if ((Get-Date $tokenData.expiration) -gt (Get-Date)) {
            return $tokenData.accessToken
        }
    }

    Write-Log "Authentification API..."

    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($global:Credential.Password)
    )

    $body = @{
        username = $global:Credential.UserName
        password = $plainPassword
    } | ConvertTo-Json

    $params = @{
        Uri         = "$BaseUrl/auth"
        Method      = "POST"
        Body        = $body
        ContentType = "application/json"
    }

    if ($SkipCertCheck) { $params.SkipCertificateCheck = $true }

    $response = Invoke-RestMethod @params

    $tokenInfo = @{
        accessToken = $response.accessToken
        expiration  = (Get-Date).AddMinutes(30)
    }

    $tokenInfo | ConvertTo-Json | Set-Content $TokenFile

    Write-Log "Nouveau token généré."
    return $response.accessToken
}

# ============================
# WRAPPER API
# ============================

function Invoke-EquitracApi {

    param (
        [string]$Uri,
        [string]$Method,
        $Body = $null
    )

    $token = Get-EquitracToken

    $headers = @{
        Authorization = "Bearer $token"
        Accept        = "application/json"
    }

    $params = @{
        Uri     = $Uri
        Method  = $Method
        Headers = $headers
    }

    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json)
        $params.ContentType = "application/json"
    }

    if ($SkipCertCheck) { $params.SkipCertificateCheck = $true }

    try {
        return Invoke-RestMethod @params
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 401) {
            Write-Log "Token expiré côté serveur. Renouvellement..." "WARNING"
            Remove-Item $TokenFile -ErrorAction SilentlyContinue
            return Invoke-EquitracApi -Uri $Uri -Method $Method -Body $Body
        }
        else {
            Write-Log $_.Exception.Message "ERROR"
            throw $_
        }
    }
}

# ============================
# UTILISATEUR
# ============================

function Test-EquitracUserExists {
    param ([string]$UserId)

    try {
        Invoke-EquitracApi -Uri "$BaseUrl/users/$UserId" -Method "GET" | Out-Null
        return $true
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 404) { return $false }
        else { throw $_ }
    }
}

function Remove-EquitracUser {

    [CmdletBinding(SupportsShouldProcess=$true)]
    param ([string]$UserId)

    Write-Log "Demande suppression utilisateur $UserId"

    if (-not (Test-EquitracUserExists -UserId $UserId)) {
        Write-Log "Utilisateur introuvable." "WARNING"
        return
    }

    if ($PSCmdlet.ShouldProcess("Utilisateur $UserId", "Suppression")) {
        Invoke-EquitracApi -Uri "$BaseUrl/users/$UserId" -Method "DELETE"
        Write-Log "Utilisateur supprimé."
    }
}

# ============================
# DELEGATIONS
# ============================

function Test-EquitracDelegationExists {
    param ($AccountId, $DelegateUserId)

    $delegations = Invoke-EquitracApi -Uri "$BaseUrl/accounts/$AccountId/delegations" -Method "GET"

    return ($delegations | Where-Object {
        $_.delegateUserId -eq $DelegateUserId
    }) -ne $null
}

function Add-EquitracAccountDelegation {

    [CmdletBinding(SupportsShouldProcess=$true)]
    param ($AccountId, $DelegateUserId)

    Write-Log "Demande ajout délégation Account:$AccountId Delegate:$DelegateUserId"

    if (Test-EquitracDelegationExists -AccountId $AccountId -DelegateUserId $DelegateUserId) {
        Write-Log "Délégation déjà existante." "WARNING"
        return
    }

    if ($PSCmdlet.ShouldProcess("Compte $AccountId", "Ajouter délégation vers $DelegateUserId")) {

        $body = @{ delegateUserId = $DelegateUserId }

        Invoke-EquitracApi `
            -Uri "$BaseUrl/accounts/$AccountId/delegations" `
            -Method "POST" `
            -Body $body

        Write-Log "Délégation ajoutée."
    }
}

function Remove-EquitracAccountDelegation {

    [CmdletBinding(SupportsShouldProcess=$true)]
    param ($AccountId, $DelegateUserId)

    Write-Log "Demande suppression délégation Account:$AccountId Delegate:$DelegateUserId"

    if (-not (Test-EquitracDelegationExists -AccountId $AccountId -DelegateUserId $DelegateUserId)) {
        Write-Log "Aucune délégation trouvée." "WARNING"
        return
    }

    if ($PSCmdlet.ShouldProcess("Compte $AccountId", "Supprimer délégation vers $DelegateUserId")) {

        Invoke-EquitracApi `
            -Uri "$BaseUrl/accounts/$AccountId/delegations/$DelegateUserId" `
            -Method "DELETE"

        Write-Log "Délégation supprimée."
    }
}

# ============================
# MENU
# ============================

function Show-Menu {
    Clear-Host
    Write-Host "========================================="
    Write-Host "  GESTION KOFAX EQUITRAC - OUTIL API"
    Write-Host "========================================="
    Write-Host ""
    Write-Host "1 - Supprimer un utilisateur"
    Write-Host "2 - Ajouter une délégation"
    Write-Host "3 - Supprimer une délégation"
    Write-Host "Q - Quitter"
    Write-Host ""
}

function Start-EquitracTool {

    $global:Credential = Get-Credential -Message "Authentification API Equitrac"

    do {
        Show-Menu
        $choice = Read-Host "Choisissez une action"

        switch ($choice.ToUpper()) {

            "1" {
                $userId = Read-Host "ID utilisateur"
                Remove-EquitracUser -UserId $userId
                Pause
            }

            "2" {
                $accountId = Read-Host "ID compte"
                $delegateId = Read-Host "ID utilisateur délégué"
                Add-EquitracAccountDelegation -AccountId $accountId -DelegateUserId $delegateId
                Pause
            }

            "3" {
                $accountId = Read-Host "ID compte"
                $delegateId = Read-Host "ID utilisateur délégué"
                Remove-EquitracAccountDelegation -AccountId $accountId -DelegateUserId $delegateId
                Pause
            }

            "Q" {
                Write-Host "Fermeture."
            }

            default {
                Write-Host "Choix invalide."
                Start-Sleep 2
            }
        }

    } while ($choice.ToUpper() -ne "Q")
}

# ============================
# LANCEMENT
# ============================

Start-EquitracTool
