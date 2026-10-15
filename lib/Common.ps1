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

# SIDs em vez de nomes: em Windows pt-BR os nomes viram "Administradores" e
# "SISTEMA", e um NTAccount('Administrators') nao resolveria.
$script:SidsConfiaveis = @('S-1-5-32-544', 'S-1-5-18')   # Administradores, SYSTEM

# Direitos que deixam alterar uma pasta ou o que esta nela: gravar, criar,
# apagar, trocar ACL ou dono. Inclui GENERIC_ALL e GENERIC_WRITE, que aparecem
# crus em ACEs herdaveis.
$script:DireitosDeAlteracao = [int64][Security.AccessControl.FileSystemRights](
    'WriteData, AppendData, WriteExtendedAttributes, DeleteSubdirectoriesAndFiles, ' +
    'WriteAttributes, Delete, ChangePermissions, TakeOwnership') -bor 0x10000000 -bor 0x40000000

function Format-Sid {
    param([Parameter(Mandatory)][string]$Sid)
    try { ([Security.Principal.SecurityIdentifier]$Sid).Translate([Security.Principal.NTAccount]).Value }
    catch { $Sid }
}

<#
    ACL de pasta de trabalho de processo elevado: sem heranca, controle total so
    para Administradores e SYSTEM (herdado pelo conteudo), dono Administradores.
#>
function New-AclSoAdmin {
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)   # corta a heranca sem copiar as ACEs herdadas
    foreach ($sid in $script:SidsConfiaveis) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]$sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow))
    }
    $acl.SetOwner([Security.Principal.SecurityIdentifier]$script:SidsConfiaveis[0])
    return $acl
}

<#
    Diz por que uma pasta pode ser alterada por quem nao e Administradores/SYSTEM,
    ou devolve $null se nao pode. Com -Raiz (a propria pasta de trabalho) exige
    tambem ACL sem heranca e confere as ACEs que so valem para o conteudo.
#>
function Get-BrechaDePasta {
    param([Parameter(Mandatory)][string]$Path, [switch]$Raiz)

    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) { return "$Path nao e pasta" }
    # Junction/symlink: a ACL lida seria a do destino, e o destino pode mudar.
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return "$Path e junction/symlink" }

    try { $acl = Get-Acl -LiteralPath $Path }
    catch { return "nao foi possivel ler a ACL de $Path ($($_.Exception.Message))" }

    if ($Raiz -and -not $acl.AreAccessRulesProtected) { return "$Path herda permissoes da pasta-pai" }
    foreach ($r in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($r.AccessControlType -ne 'Allow') { continue }
        if ($script:SidsConfiaveis -contains $r.IdentityReference.Value) { continue }
        # ACE so-herdavel nao vale para a pasta em si; na raiz vale para o conteudo.
        if (-not $Raiz -and ($r.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
        if ([int64]$r.FileSystemRights -band $script:DireitosDeAlteracao) {
            return "$(Format-Sid $r.IdentityReference.Value) pode alterar $Path"
        }
    }
    # Dono comum reescreve a ACL quando quiser, entao nao basta a ACL estar certa.
    $dono = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($script:SidsConfiaveis -notcontains $dono) {
        return "o dono de $Path e $(Format-Sid $dono), nao Administradores/SYSTEM"
    }
    return $null
}

<#
    Cria ou confere a pasta de trabalho de um processo elevado.

    POR QUE: na raiz do C:\ o Windows deixa "Usuarios autenticados" criar pasta, e
    o que e criado ali herda Modify para eles. Uma pasta de trabalho nesse lugar
    pode ser pre-criada ou alterada por qualquer usuario - e o conteudo dela (ISO
    extraida, .msu) e injetado na imagem pelo DISM como administrador. Trocar o
    padrao por $env:ProgramData nao resolve: la "Usuarios" tambem cria pasta.

    Regras:
      - pasta nova nasce num passo so com a ACL de New-AclSoAdmin: nao existe
        instante em que ela fique com a heranca aberta da raiz;
      - pasta que ja existe so e usada se ja estiver assim. Se nao estiver, RECUSA
        em vez de corrigir: quem teve acesso pode ter deixado arquivo, junction ou
        handle aberto, e trocar a ACL depois nao desfaz nada disso;
      - as pastas-pai (abaixo da raiz do volume) tambem nao podem ser alteraveis
        por usuario comum, senao ele renomeia o pai e troca a pasta inteira.
#>
function Initialize-PastaProtegida {
    param([Parameter(Mandatory)][string]$Path)

    $Path       = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $raizVolume = [IO.Path]::GetPathRoot($Path).TrimEnd('\')
    if ($Path -eq $raizVolume) { throw "A pasta de trabalho nao pode ser a raiz do volume ($Path)." }

    $criada = $false
    if (-not (Test-Path -LiteralPath $Path)) {
        $acl = New-AclSoAdmin
        if ($PSVersionTable.PSEdition -eq 'Core') {
            [IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]$Path, $acl)
        } else {
            ([IO.DirectoryInfo]$Path).Create($acl)
        }
        $criada = $true
    }

    # Confere ate a recem-criada: se outro usuario criou a pasta entre o teste e o
    # Create, o Create nao falha - mas o dono e a ACL denunciam.
    $pai = Split-Path $Path -Parent
    while ($pai.TrimEnd('\') -ne $raizVolume) {
        $brecha = Get-BrechaDePasta -Path $pai
        if ($brecha) {
            throw "Pasta-pai da area de trabalho insegura: $brecha. Use uma pasta direto na raiz do volume (ex.: C:\VentoyBuild)."
        }
        $pai = Split-Path $pai -Parent
    }
    $brecha = Get-BrechaDePasta -Path $Path -Raiz
    if ($brecha) {
        throw ("Area de trabalho nao confiavel: $brecha. O conteudo pode ter sido alterado por usuario comum. " +
               "Apague a pasta (cmd /c rd /s /q `"$Path`") e rode de novo: ela sera recriada so com Administradores e SYSTEM.")
    }
    [pscustomobject]@{ Path = $Path; Criada = $criada }
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
        [ValidateSet('MD5','SHA1','SHA256')][string]$Algorithm = 'MD5',
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
