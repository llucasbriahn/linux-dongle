# Wi-Fi + Bluetooth Universal

Assistente em Bash para diagnosticar Wi-Fi/Bluetooth no Linux, tentar drivers do próprio kernel e instalar drivers externos apenas para adaptadores USB com perfil conhecido. Versão 1.1.0.

O objetivo é funcionar em mais ambientes e oferecer caminhos de recuperação. **Não existe garantia de funcionar em qualquer dispositivo ou distro**: isso depende do chipset, firmware, configuração do kernel, arquitetura e suporte upstream. IDs desconhecidos nunca acionam compilação externa.

## Uso

```bash
chmod +x wifi-bluetooth-universal.sh
./wifi-bluetooth-universal.sh
```

Execute o assistente como usuário normal. Ele pede confirmação antes de instalar ferramentas, carregar módulos, executar instaladores e aplicar ajustes Bluetooth. Precisa de Bash 4 ou mais recente e Linux; as ferramentas opcionais ausentes são indicadas. `sudo` ou `doas` só são necessários para alterar o sistema.

Para investigar sem instalar pacotes, acessar a rede ou solicitar sudo:

```bash
./wifi-bluetooth-universal.sh --diagnose
./wifi-bluetooth-universal.sh --report diagnostico.txt
./wifi-bluetooth-universal.sh --secure-boot-help
```

O relatório usa permissão `600` e não sobrescreve arquivos existentes. Revise nomes, IDs e endereços Bluetooth antes de compartilhar. A consulta de controladores, módulos e interfaces não comprova acesso à internet; o diagnóstico pode ser parcial em contêineres, ambientes restritos ou quando faltam ferramentas.

## Compatibilidade e alternativas

| Ambiente | Comportamento |
| --- | --- |
| USB, PCI/PCIe e SDIO | Diagnóstico por sysfs; tenta módulos nativos de Wi-Fi identificados por modalias, quando disponíveis e sem driver ligado. |
| Arch e derivados | Headers derivados do `pkgbase` do kernel ativo, inclusive flavors como zen, LTS e CachyOS. |
| Debian/Ubuntu e derivados | Solicita `linux-headers-$(uname -r)` quando a árvore de compilação está ausente. |
| Fedora e derivados com DNF | Solicita `kernel-devel-$(uname -r)`, evitando selecionar silenciosamente outro kernel. DKMS pode exigir repositório adicional da distro. |
| openSUSE | Ferramentas automatizadas; headers ausentes precisam ser preparados para a versão e flavor ativos. |
| Void e Alpine | Ferramentas automatizadas; prepare manualmente a árvore de headers do kernel ativo antes de compilar. |
| Outras distribuições | Diagnóstico e módulos nativos disponíveis; dependências externas devem ser preparadas manualmente. O instalador upstream pode ter restrições adicionais. |
| Sistemas OSTree, NixOS e alguns imutáveis detectados | O assistente oferece somente diagnóstico; instale módulos pela configuração do hospedeiro. A detecção não cobre todos os sistemas imutáveis. |
| Contêineres detectados | Somente diagnóstico: o kernel pertence ao hospedeiro. |
| systemd, OpenRC, runit e SysV | Inicia BlueZ quando o serviço correspondente está disponível. Em runit, requer serviço já habilitado em `/var/service/bluetooth`. |
| Secure Boot, lockdown ou assinatura obrigatória | Prefere módulos da distro; exige confirmação específica de preparação da assinatura antes de delegar compilação ao upstream. |

O assistente não substitui um driver ligado ao dispositivo. Drivers externos continuam limitados aos perfis USB abaixo. Adaptadores PCI/SDIO desconhecidos podem usar módulos nativos, mas não recebem drivers externos por tentativa. Um módulo nativo precisa estar incluído no pacote de kernel da distro e pode precisar de firmware separado.

## Perfis externos reconhecidos

| Família | IDs USB (VID:PID) | Ação |
| --- | --- | --- |
| AIC8800D80 | `a69c:8d81`, modo boot/armazenamento `1111:1111` | Instala Wi-Fi e carregador de firmware AIC; desativa o módulo opcional `aic_zlp_quirk`. |
| RTL8812AU | `0bda:8812`, `0bda:881a`, TP-Link `2357:0101/0103/010d/010e/010f` e outros IDs no script | Prefere driver instalado; compilação legada somente abaixo de 6.14. |
| RTL8812BU / RTL8822BU | `0bda:b812`, `0bda:b82c`, `0bda:b81a`, `2357:0115` | Prefere driver instalado; compilação legada somente abaixo de 6.12. |
| AIC com quirk específico | `368b:8d81` | Informa a limitação; não instala automaticamente. |

A versão do kernel orienta a escolha, mas não comprova suporte na configuração da distro. Em kernels modernos sem o módulo esperado, instale módulos/firmware da distribuição. Com vários adaptadores conhecidos, o assistente permite selecionar um perfil por execução. Não adicione IDs somente pela marca comercial: confirme chipset e suporte upstream.

## Secure Boot

O assistente detecta o estado usando `mokutil` ou a variável EFI (ignorando corretamente os quatro bytes de atributos). Estado desconhecido, lockdown ativo e exigência explícita de assinatura também acionam orientação antes de compilar.

Para manter Secure Boot ativo, use primeiro módulos assinados fornecidos pela distro. Para módulos externos, configure a assinatura DKMS conforme a distro. Quando ela usa shim/MokManager, é possível solicitar o cadastro de um **certificado público DER existente**:

```bash
./wifi-bluetooth-universal.sh --enroll-mok /caminho/certificado.der
```

O comando pede confirmação, solicita elevação e executa `mokutil --import`. Reinicie e conclua **Enroll MOK** no console local. Cadastrar a chave não assina os módulos e não garante que um kernel personalizado a aceite. O aplicativo não gera chaves, não configura automaticamente a assinatura DKMS, não desativa Secure Boot e não reinicia a máquina. A palavra `ASSINATURA` confirma que você preparou o processo; ela não valida criptograficamente a configuração. Veja [o guia de recuperação](TROUBLESHOOTING.md).

## Bluetooth e recuperação

Bluetooth permanece com `btusb` e auxiliares nativos (`btintel`, `btbcm`, `btrtl`, `btmtk`) e BlueZ. Em combos AIC, `aic_load_fw` inicializa firmware; ele não substitui o driver HCI.

Os ajustes opcionais desativam autosuspend em todos os controladores `btusb` (podem aumentar consumo), liberam apenas RFKill Bluetooth e oferecem configuração WirePlumber 0.5 para impedir troca automática A2DP → HSP/HFP. Arquivos existentes recebem backup antes da substituição. A configuração de áudio é do usuário; não execute o assistente com sudo.

Falhas na instalação Wi-Fi permitem continuar com Bluetooth e diagnóstico. Ao recarregar `btusb`, o assistente tenta restaurar o serviço mesmo se o módulo falhar. Ele contabiliza falhas detectadas; isso não é uma validação completa da conectividade. Consulte [TROUBLESHOOTING.md](TROUBLESHOOTING.md) para firmware, falta de internet, RFKill, headers e reversão.

## Verificação do projeto

Os testes usam sysfs e comandos simulados, sem instalar pacotes ou modificar drivers:

```bash
bash -n wifi-bluetooth-universal.sh
python3 -m unittest discover -s tests -v
```

Esses testes não substituem validação em hardware real e diferentes distribuições.

## Fontes

- [AIC8800D80](https://github.com/shenmintao/aic8800d80)
- [RTL8812AU e preferência pelo driver nativo](https://github.com/morrownr/8812au-20210820)
- [RTL8812BU / RTL8822BU](https://github.com/morrownr/88x2bu-20210702)
- [Assinatura de módulos no kernel](https://docs.kernel.org/admin-guide/module-signing.html)
- [DKMS: assinatura e certificados MOK](https://github.com/dkms-project/dkms#module-signing)
- [Ubuntu: Secure Boot e cadastro MOK](https://documentation.ubuntu.com/security/security-features/platform-protections/secure-boot/)
- [WirePlumber: configuração Bluetooth](https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/bluetooth.html)

Os projetos upstream têm seus próprios códigos, licenças e limites de suporte. Revise seus instaladores antes da execução: eles alteram módulos, firmware e configurações do sistema e podem instalar dependências adicionais. Este aplicativo não é afiliado aos mantenedores desses projetos.
