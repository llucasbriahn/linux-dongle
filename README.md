# Wi-Fi + Bluetooth Universal

Aplicativo de terminal em Bash para detectar alguns adaptadores USB Wi-Fi comuns, instalar um driver externo somente quando o perfil é conhecido e deixar o Bluetooth sob controle dos drivers nativos do kernel e do BlueZ.

## Perfis reconhecidos

| Família | Identificação USB (VID:PID) | Ação |
| --- | --- | --- |
| AIC8800D80 | `a69c:8d81`, modo USB `1111:1111` | Instala o driver Wi-Fi AIC e o carregador de firmware. Desativa a compilação do módulo opcional `aic_zlp_quirk`; o HCI Bluetooth usa `btusb` do kernel. |
| Realtek RTL8812AU | IDs comuns `0bda:8812`, `0bda:881a`, TP-Link `2357:0101/0103/010d/010e/010f`, entre outros | Usa o driver do kernel quando disponível; oferece o módulo comunitário apenas em kernels antigos compatíveis. |
| Realtek RTL8812BU / RTL8822BU | `0bda:b812`, `0bda:b82c`, `0bda:b81a`, `2357:0115` | Prefere `rtw88` nativo em kernels modernos; oferece o módulo comunitário somente em kernels antigos compatíveis. |

O catálogo é intencionalmente conservador. IDs desconhecidos não acionam instalação de drivers. Para incluir novos adaptadores, confirme primeiro o chipset e os IDs USB, depois adicione o perfil e a origem do driver.

## Bluetooth

O aplicativo não instala nem substitui drivers HCI Bluetooth. `btusb` e auxiliares como `btintel`, `btbcm`, `btrtl` e `btmtk` são módulos do kernel Linux. Para combos AIC8800, `aic_load_fw` é necessário para inicializar o firmware do chipset; ele não substitui `btusb`.

Opcionalmente, o aplicativo pode desativar autosuspend no módulo `btusb`, atualizar o initramfs, remover bloqueios RFKill e criar uma configuração de usuário para o WirePlumber 0.5 impedir a troca automática de A2DP para HSP/HFP quando um aplicativo usa o microfone. Desativar autosuspend afeta todos os controladores que usam `btusb`; isso pode aumentar o consumo de energia. O script pede confirmação antes de aplicar esses ajustes.

## Requisitos e distros

- Linux com Bash, `modprobe`, `rfkill` e `bluetoothctl`
- `sudo` ou `doas`
- Para compilar: Git, DKMS, compilador, Make e headers correspondentes ao kernel ativo
- Instalação automatizada de dependências para Arch/CachyOS, Debian/Ubuntu, Fedora, openSUSE, Void e Alpine
- Bluetooth service: systemd ou OpenRC

Cada driver externo tem seus próprios limites de kernel e distribuição. O aplicativo não instala nada para IDs desconhecidos, não substitui um driver já ligado ao dispositivo e prefere um módulo nativo quando encontra um candidato no kernel. Se o kernel estiver fora da faixa declarada pelo driver comunitário, a instalação externa é interrompida. A versão inicial detecta adaptadores USB; Wi-Fi PCI interno permanece com a configuração da distribuição.

## Uso

```bash
chmod +x wifi-bluetooth-universal.sh
./wifi-bluetooth-universal.sh
```

Execute como usuário normal. O aplicativo solicita elevação quando necessário e pede confirmação antes de instalar pacotes, compilar módulos ou recarregar o Bluetooth. Revise os scripts upstream antes de executar e faça backup de dados importantes.

Os nomes antigos `ax900-cachyos.sh` e `bluetooth-universal.sh` são mantidos como atalhos para este aplicativo.

## Fontes dos drivers

- [AIC8800D80](https://github.com/shenmintao/aic8800d80)
- [RTL8812AU](https://github.com/morrownr/8812au-20210820)
- [RTL8812BU / RTL8822BU](https://github.com/morrownr/88x2bu-20210702)
- [WirePlumber: configuração Bluetooth](https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/bluetooth.html)

Os projetos upstream mantêm seus próprios códigos, licenças e avisos de compatibilidade. Este aplicativo não é afiliado aos mantenedores desses drivers.
