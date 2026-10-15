# bin/

Pasta para os binários do **Windows ADK** que o `Update-WindowsImage.ps1` usa para
remontar a ISO. Eles **não** são distribuídos neste repositório (licença Microsoft),
e o `.gitignore` impede que sejam versionados por engano.

## Como obter o `oscdimg.exe`

1. Instale o [Windows ADK](https://learn.microsoft.com/windows-hardware/get-started/adk-install)
   marcando apenas o componente **Deployment Tools**, ou
2. Copie o executável de uma máquina que já tenha o ADK.

Origem típica:

```
C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe
```

O script procura primeiro em `bin\oscdimg.exe`, depois nas pastas padrão do ADK e
por fim no `PATH`. Com o executável aqui, o toolkit roda em máquinas sem o ADK
instalado.

Os arquivos de boot (`etfsboot.com`, `efisys.bin`) **não** precisam ficar nesta
pasta: o script usa os que vêm dentro da própria ISO extraída.
