# Guia de uso do SSD de formatação

Guia operacional para quem vai usar o drive no dia a dia. A visão geral do projeto
está no [README](../README.md).

Drive de referência: SSD USB externo formatado em **exFAT**, com Ventoy instalado.
Nos exemplos ele aparece como `D:` — troque pela letra do seu drive.

---

## 1. O menu de boot

Ligue a máquina com o SSD plugado e chame o menu de boot da BIOS (`F12` na Dell,
`F12` ou `Enter` na Lenovo). Escolha o dispositivo USB. Com o
[`ventoy.json`](../ventoy/ventoy.json) de exemplo, o Ventoy abre em português com
quatro opções:

| Entrada | Arquivo | Quando usar |
|---|---|---|
| **>> USAR ESTA** — Windows 11 Pro 24H2 | `/ISO/WIN11_UPD_24H2_<AAAAMM>.iso` | Padrão. Imagem gerada pelo toolkit, já atualizada e com drivers críticos |
| Plano B — Windows 11 24H2 original | `/ISO/Win11_24H2_BrazilianPortuguese_x64.iso` | Só se a atualizada falhar; vai baixar todo o Windows Update depois |
| Resgate — Lubuntu Live | `/ISO/lubuntu-*.iso` | Windows não inicia e é preciso salvar arquivos. Escolha **Try**, nunca **Install** |
| Antigo — Hiren's BootCD PE | `/ISO/HBCD_PE_x64.iso` | Build de 2020; pode não listar SSD NVMe moderno (sem driver Intel VMD/RST) |

Dois ajustes do `ventoy.json` importam:

- `VTOY_WIN11_BYPASS_CHECK` — instala Win11 em máquina sem TPM 2.0 ou Secure Boot.
- `VTOY_WIN11_BYPASS_NRO` — dispensa a exigência de internet no OOBE. Era exatamente
  ali que a máquina sem driver de rede travava.

---

## 2. Formatar uma máquina

1. **Salve o que o usuário precisa.** Se o Windows não inicia, use o Lubuntu Live.
2. **Boote pelo SSD e escolha a imagem padrão** (`USAR ESTA`).
3. **Instale normalmente.** O disco aparece mesmo em máquina nova com Intel VMD
   ligado, porque os drivers de storage também foram injetados no `boot.wim`.
4. **Confira a build no primeiro logon** com `winver`. Número menor que o da imagem
   gerada significa que você bootou pela imagem original por engano.
5. **Complete os drivers** (seção 3).

---

## 3. Depois de instalar

Na máquina recém-formatada, com o SSD plugado, em PowerShell **como administrador**:

```powershell
D:\_toolkit\Apply-Drivers.ps1
```

Identifica fabricante e modelo, procura o pack em `D:\Drivers` e instala tudo com
`pnputil`. Informa quantos dispositivos ficaram sem driver antes e depois. Reinicie
para concluir.

Só diagnosticar, sem instalar:

```powershell
D:\_toolkit\Apply-Drivers.ps1 -RelatorioSomente
```

Se não houver pack para o modelo, o script avisa e não instala nada — vá para a
seção 4.

---

## 4. Modelo novo no parque

Rode na própria máquina (não precisa de administrador):

```powershell
D:\_toolkit\Sync-DriverPacks.ps1 -Auto
```

Funciona para Dell e Lenovo, consultando os catálogos oficiais e conferindo o hash
do que baixa. Depois acrescente a entrada em `models.json` para que a manutenção
trimestral passe a incluir o modelo.

Descobrir a chave de catálogo na mão:

| Fabricante | Comando | Exemplo |
|---|---|---|
| Dell | `(Get-CimInstance -Namespace root\wmi -ClassName MS_SystemInformation).SystemSKU` | `0C1E` |
| Lenovo | `(Get-CimInstance Win32_ComputerSystem).Model.Substring(0,4)` | `21F6` |

Um pack extraído ocupa bem mais que o instalador: o da Latitude 3540 sai de 3,4 GB
comprimidos para 12,2 GB extraídos (2.464 arquivos, 274 INF).

---

## 5. Manutenção trimestral

A cada três meses, ou quando sair versão nova do Windows. ~1h15, quase toda sem
supervisão.

```powershell
# 1. atualiza os packs de todo o parque cadastrado
D:\_toolkit\Sync-DriverPacks.ps1 -FromManifest -RefreshCatalog

# 2. refaz o conjunto crítico que vai dentro da imagem
D:\_toolkit\New-CriticalDriverSet.ps1 -Limpar

# 3. gera a ISO nova  << COMO ADMINISTRADOR >>
D:\_toolkit\Update-WindowsImage.ps1
```

O passo 3 produz `D:\ISO\<IsoPrefix>_<versão>_<AAAAMM>.iso` (prefixo padrão
`WIN11_UPD`). Depois de gerar, aponte o `menu_alias` e o `VTOY_DEFAULT_IMAGE` em
`D:\ventoy\ventoy.json` para ela.

**Se falhar no meio**, rode de novo com `-ReuseScratch`: reaproveita a ISO já
extraída e os `.msu` já baixados.

---

## 6. Saúde do drive

Verificação rápida, sem alterar nada:

```powershell
Get-Volume -DriveLetter D | Select-Object HealthStatus, OperationalStatus
```

Esperado: `Healthy` e `OK`. Qualquer outra coisa — em especial `Full Repair Needed` —
pede reparo antes de usar o drive.

```powershell
# COMO ADMINISTRADOR — antes, copie o que não pode perder
chkdsk D: /f
# depois reconfira, sem /f
chkdsk D:
```

Lição aprendida: avisos de E/S repetida no log `disk` e resets do driver `UASPStor`
com o sistema de arquivos limpo e `0 KB em setores defeituosos` apontam para cabo,
porta ou gabinete USB — não para a memória do SSD. Use cabo de boa qualidade e porta
direta na máquina, sem hub.

Para conferir a integridade da ISO entregue, guarde o hash ao lado dela:

```powershell
(Get-FileHash 'D:\ISO\<sua-iso>.iso' -Algorithm SHA256).Hash
```

---

## 7. Quando dá problema

| Sintoma | Causa | O que fazer |
|---|---|---|
| Pasta criada some da listagem, ou "erro do dispositivo de E/S" | Corrupção do exFAT, quase sempre cabo/porta instável | Backup, trocar cabo e porta, `chkdsk D: /f` elevado |
| `chkdsk` aborta com erro de instantâneo | Falta elevação, ou um reset do dispositivo invalidou o snapshot | Rodar em PowerShell elevado |
| Log diz "pacote dispensado (já coberto ou não aplicável)" | **Normal.** O catálogo entrega o cumulative junto com um checkpoint que fica redundante depois que o cumulative aplica | Nada. O script segue em frente de propósito |
| Extração de driver pack termina sem nenhum arquivo | Espaço no caminho de destino — o extrator da Dell falha em silêncio, código 10 | Já tratado: extrai em pasta temporária sem espaço e move depois |
| DISM recusa montar a imagem | Tentativa de montar em exFAT, que não suporta as ACLs que o DISM grava | Já tratado: a área de trabalho é `C:\VentoyBuild`, em NTFS |
| Setup não lista o disco | Falta driver Intel VMD/RST no ambiente de instalação | Use a imagem gerada, não a original |
| Máquina sem rede depois de instalar | Bootou pela imagem original | Conferir `winver`; paliativo é `Apply-Drivers.ps1` |
| Download de driver pack a ~180 KB/s | A Dell limita por conexão, não por banda | Já tratado: 6 faixas HTTP Range paralelas |

---

## 8. Referência rápida

| Script | Onde rodar | Admin | Para quê |
|---|---|---|---|
| `Sync-DriverPacks.ps1` | bancada ou máquina alvo | não | Baixar packs oficiais Dell/Lenovo |
| `New-CriticalDriverSet.ps1` | bancada | não | Filtrar o subconjunto que entra na imagem |
| `Update-WindowsImage.ps1` | bancada | **sim** | Gerar a ISO atualizada |
| `Apply-Drivers.ps1` | máquina recém-formatada | **sim** | Instalar o pack completo do modelo |

Todos aceitam `Get-Help <script> -Full`.

- **Área de trabalho** — `C:\VentoyBuild` guarda a ISO extraída e os updates. Pode
  apagar quando não for reprocessar (o script já apaga, a menos que receba
  `-KeepScratch`).
