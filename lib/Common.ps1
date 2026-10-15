<#
    Common.ps1 - Funcoes compartilhadas do toolkit de imagem Windows (SSD Ventoy).
    Carregue com:  . "$PSScriptRoot\lib\Common.ps1"
#>

Set-StrictMode -Version Latest

# Download paralelo por faixas HTTP Range - ver o cabecalho do arquivo para os
# numeros medidos que justificam essa abordagem.
. "$PSScriptRoot\FastDownload.ps1"

$script:DellCatalogUrl   = 'https://downloads.dell.com/catalog/DriverPackCatalog.cab'
$script:LenovoCatalogUrl = 'https://download.lenovo.com/cdrt/td/catalogv2.xml'

# Classes de driver criticas para a maquina "nascer" com rede.
# Usadas para montar o conjunto _Critical injetado no install.wim.
$script:CriticalClasses = @('Net', 'System', 'HDC', 'SCSIAdapter', 'USB', 'Bluetooth')

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','OK','WARN','ERRO','STEP')][string]$Level = 'INFO'
    )
    $cor = switch ($Level) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'ERRO' { 'Red' }
        'STEP' { 'Cyan' }
        default { 'Gray' }
    }
    $ts = (Get-Date).ToString('HH:mm:ss')
    Write-Host ("[{0}] {1,-4} {2}" -f $ts, $Level, $Message) -ForegroundColor $cor
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-Admin)) {
        throw "Este script exige PowerShell elevado (Executar como administrador)."
    }
}

<#
    Download com verificacao de hash.

    Delega para Get-RemoteFileFast (lib\FastDownload.ps1), que baixa em faixas
    HTTP Range paralelas. Isso importa muito aqui: downloads.dell.com limita por
    conexao (182 KB/s medidos), mas aceita varias em paralelo (11,9 MB/s com 6).
    Servidores que nao aceitam Range caem sozinhos para fluxo unico.
#>
function Get-RemoteFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$ExpectedHash,
        [ValidateSet('MD5','SHA256')][string]$Algorithm = 'MD5',
        [int]$Connections = 6,
        [switch]$Force
    )

    Get-RemoteFileFast -Uri $Uri -OutFile $OutFile -ExpectedHash $ExpectedHash `
        -Algorithm $Algorithm -Connections $Connections -Force:$Force
}

function Get-DellCatalog {
    param([Parameter(Mandatory)][string]$CacheDir, [switch]$Refresh)

    $xmlPath = Join-Path $CacheDir 'DriverPackCatalog.xml'
    $cabPath = Join-Path $CacheDir 'DriverPackCatalog.cab'
    $stale   = (-not (Test-Path $xmlPath)) -or
               ((Get-Item $xmlPath).LastWriteTime -lt (Get-Date).AddDays(-14))

    if ($Refresh -or $stale) {
        Get-RemoteFile -Uri $script:DellCatalogUrl -OutFile $cabPath -Force | Out-Null
        $out = Join-Path $CacheDir '_dellcab'
        if (Test-Path $out) { Remove-Item $out -Recurse -Force }
        New-Item -ItemType Directory -Path $out -Force | Out-Null
        # O CAB da Dell traz o XML com o nome interno .cab - normalizamos aqui.
        & "$env:SystemRoot\System32\expand.exe" $cabPath '-F:*' $out | Out-Null
        $inner = Get-ChildItem $out | Select-Object -First 1
        Move-Item $inner.FullName $xmlPath -Force
        Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
    }

    [xml]$x = Get-Content $xmlPath
    Write-Log ("Catalogo Dell versao {0}" -f $x.DriverPackManifest.version) 'INFO'
    return $x
}

function Get-LenovoCatalog {
    param([Parameter(Mandatory)][string]$CacheDir, [switch]$Refresh)

    $xmlPath = Join-Path $CacheDir 'lenovo-catalogv2.xml'
    $stale   = (-not (Test-Path $xmlPath)) -or
               ((Get-Item $xmlPath).LastWriteTime -lt (Get-Date).AddDays(-14))

    if ($Refresh -or $stale) {
        Get-RemoteFile -Uri $script:LenovoCatalogUrl -OutFile $xmlPath -Force | Out-Null
    }

    [xml]$x = Get-Content $xmlPath
    Write-Log ("Catalogo Lenovo carregado ({0} modelos)" -f $x.ModelList.Model.Count) 'INFO'
    return $x
}

<#
    Identifica a maquina local: fabricante, modelo e a chave usada por cada
    catalogo (SKU de 4 digitos na Dell, Machine Type de 4 caracteres na Lenovo).
#>
function Get-LocalMachine {
    $cs  = Get-CimInstance Win32_ComputerSystem
    $fab = switch -Regex ($cs.Manufacturer) {
        'Dell'            { 'Dell';   break }
        'LENOVO'          { 'Lenovo'; break }
        default           { $cs.Manufacturer }
    }

    $chave = switch ($fab) {
        'Dell' {
            (Get-CimInstance -Namespace root\wmi -ClassName MS_SystemInformation `
                -ErrorAction SilentlyContinue).SystemSKU
        }
        'Lenovo' {
            # Na Lenovo o modelo real fica em Win32_ComputerSystemProduct.Version;
            # o Machine Type sao os 4 primeiros caracteres de Win32_ComputerSystem.Model.
            if ($cs.Model.Length -ge 4) { $cs.Model.Substring(0,4) } else { $cs.Model }
        }
        default { $null }
    }

    $nomeAmigavel = if ($fab -eq 'Lenovo') {
        (Get-CimInstance Win32_ComputerSystemProduct).Version
    } else { $cs.Model }

    [pscustomobject]@{
        Fabricante = $fab
        Modelo     = $nomeAmigavel
        Chave      = $chave
        Serial     = (Get-CimInstance Win32_BIOS).SerialNumber
    }
}

function Get-ToolkitRoot {
    Split-Path $PSScriptRoot -Parent
}

<#
    Normaliza nome de modelo vindo do catalogo para uso como nome de pasta:
    remove caracteres invalidos no Windows e espacos duplicados das bordas.
#>
function Format-NomePasta {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Nome)
    $limpo = $Nome -replace '[<>:"/\|?*]', '_'
    $limpo = ($limpo -replace '\s+', ' ').Trim().TrimEnd('.')
    if (-not $limpo) { $limpo = 'Desconhecido' }
    return $limpo
}
