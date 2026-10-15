<#
    MsCatalog.ps1 - Consulta ao Microsoft Update Catalog.

    O catalogo nao expoe API publica; estas funcoes fazem o mesmo que o navegador
    faz (Search.aspx + DownloadDialog.aspx) e extraem os .msu reais.

    Atencao ao "checkpoint update": a partir do Windows 11 24H2 um LCU pode
    depender de um pacote checkpoint (ex. KB5043080). Por isso Get-CatalogFileUrl
    devolve TODOS os arquivos da entrada, e o servicing aplica em laco com
    retentativa ate nao haver mais progresso - assim a ordem se resolve sozinha.
#>

$script:CatalogBase = 'https://www.catalog.update.microsoft.com'

function Search-MsCatalog {
    <#
    .SYNOPSIS
        Pesquisa o Microsoft Update Catalog e devolve as linhas de resultado.
    #>
    param([Parameter(Mandatory)][string]$Query)

    $antigo = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $uri = "$script:CatalogBase/Search.aspx?q=" + [uri]::EscapeDataString($Query)
        $resp = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 90
    } finally {
        $ProgressPreference = $antigo
    }

    $linhas = [regex]::Matches($resp.Content, '(?s)<tr id="([0-9a-fA-F\-]{36})_R\d+".*?</tr>')
    foreach ($m in $linhas) {
        $guid  = $m.Groups[1].Value
        $bloco = $m.Value

        $mTit  = [regex]::Match($bloco, "(?s)_link'.*?>(.*?)</a>")
        if (-not $mTit.Success) { continue }
        $mData = [regex]::Match($bloco, '(?s)_C4_R\d+">\s*([\d/]+)\s*</td>')
        $mTam  = [regex]::Match($bloco, '_originalSize">(\d+)<')

        [pscustomobject]@{
            UpdateID = $guid
            Titulo   = ($mTit.Groups[1].Value -replace '\s+', ' ').Trim()
            Data     = if ($mData.Success) {
                           [datetime]::ParseExact($mData.Groups[1].Value.Trim(), 'M/d/yyyy',
                               [cultureinfo]::InvariantCulture)
                       } else { [datetime]::MinValue }
            Bytes    = if ($mTam.Success) { [int64]$mTam.Groups[1].Value } else { 0 }
        }
    }
}

function Get-CatalogFileUrl {
    <#
    .SYNOPSIS
        Resolve as URLs reais de download de uma entrada do catalogo.
    #>
    param([Parameter(Mandatory)][string]$UpdateID)

    $payload = '[{"size":0,"languages":"","uidInfo":"' + $UpdateID + '","updateID":"' + $UpdateID + '"}]'
    $body    = 'updateIDs=' + [uri]::EscapeDataString($payload)

    $antigo = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $resp = Invoke-WebRequest -Uri "$script:CatalogBase/DownloadDialog.aspx" -Method Post `
                    -Body $body -ContentType 'application/x-www-form-urlencoded' `
                    -UseBasicParsing -TimeoutSec 90
    } finally {
        $ProgressPreference = $antigo
    }

    [regex]::Matches($resp.Content, "url\s*=\s*'([^']+)'") |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object   { $_ -match '\.(msu|cab)$' } |
        Select-Object -Unique
}

function Get-LatestCumulativeUpdate {
    <#
    .SYNOPSIS
        Devolve a entrada mais recente do LCU para uma versao do Windows 11.

    .PARAMETER Version
        24H2, 25H2, etc.
    #>
    param(
        [Parameter(Mandatory)][string]$Version,
        [ValidateSet('x64', 'arm64')][string]$Arch = 'x64'
    )

    $query = "Cumulative Update for Windows 11 Version $Version for $Arch-based Systems"
    $todos = @(Search-MsCatalog -Query $query)

    $lcu = $todos |
        Where-Object {
            $_.Titulo -match 'Cumulative Update for Windows 11' -and
            $_.Titulo -match [regex]::Escape($Version)          -and
            $_.Titulo -notmatch '\.NET|Dynamic Update|Safe OS'
        } |
        Sort-Object Data -Descending |
        Select-Object -First 1

    if (-not $lcu) { throw "Nenhum LCU encontrado para Windows 11 $Version $Arch." }
    return $lcu
}

function Get-LatestDotNetUpdate {
    <#
    .SYNOPSIS
        LCU do .NET Framework - opcional, mas evita mais um ciclo de reboot pos-install.
    #>
    param([Parameter(Mandatory)][string]$Version)

    $query = ".NET Framework Cumulative Update for Windows 11 Version $Version x64"
    $todos = @(Search-MsCatalog -Query $query)

    $todos |
        Where-Object {
            $_.Titulo -match '\.NET Framework' -and
            $_.Titulo -match [regex]::Escape($Version) -and
            $_.Titulo -match 'x64'
        } |
        Sort-Object Data -Descending |
        Select-Object -First 1
}
