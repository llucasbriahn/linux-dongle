# Diagnóstico e recuperação

Comece com `./wifi-bluetooth-universal.sh --diagnose`. Para salvar a saída, use `--report diagnostico.txt` (arquivo novo). Informe distro, arquitetura, versão exata do kernel, VID:PID ou modalias e erro observado ao pedir ajuda. Revise o relatório antes de publicar: ele pode conter nomes e endereços Bluetooth.

## Sem rede para baixar pacotes

Use Ethernet, tethering USB de um celular ou outro adaptador já suportado. Para instalação offline, obtenha pacotes e dependências da mesma distro, versão, arquitetura e kernel. O script não consegue obter drivers ou firmware ausentes sem uma fonte disponível. Uma cópia Git existente é reutilizada sem atualizar automaticamente.

## Módulo não encontrado, firmware ou headers ausentes

- `Module not found`: confira `uname -r` e o pacote de módulos correspondente da distro. Um driver presente no Linux upstream pode estar desativado na configuração do kernel instalado.
- `Direct firmware load ... failed`: procure o nome exato do arquivo em `journalctl -k -b` ou `dmesg` (podem exigir sudo). Instale firmware pela distro; não copie arquivos de origem desconhecida por tentativa.
- Headers ausentes: a árvore `/lib/modules/$(uname -r)/build` precisa corresponder ao kernel ativo. Debian/Ubuntu usam normalmente `linux-headers-VERSAO`; Fedora usa `kernel-devel-VERSAO`; Arch identifica o flavor em `/lib/modules/$(uname -r)/pkgbase`. openSUSE exige pacotes de desenvolvimento da versão e flavor em uso. Alpine, Void e kernels personalizados exigem preparação específica.
- Se a versão exata saiu do repositório, atualize kernel e headers juntos pelo procedimento da distro, reinicie nesse kernel e tente novamente. Não aponte `build` para headers de outra versão.
- Falha DKMS: veja `dkms status` e o `make.log` da compilação em `/var/lib/dkms`. Para AIC, confira também `/var/log/aic8800-install.log`. A versão do compilador e a arquitetura também precisam ser aceitas pelo driver upstream.

## Secure Boot e assinatura

`Key was rejected by service`, `Required key not available` e mensagens de verificação de assinatura exigem conferir a política do kernel. Secure Boot desativado não exclui lockdown ou `module.sig_enforce`.

```bash
mokutil --sb-state
cat /sys/kernel/security/lockdown
cat /sys/module/module/parameters/sig_enforce
modinfo -F signer NOME_DO_MODULO
modinfo -F vermagic NOME_DO_MODULO
```

Alguns arquivos/comandos podem não existir. Isso deve ser tratado como informação indisponível. Uma assinatura não vazia em `modinfo` não comprova que o kernel confia nela.

1. Prefira o módulo assinado fornecido pela distro. Atualizar kernel/firmware costuma evitar módulos externos.
2. Para driver externo, use o fluxo de assinatura DKMS da sua distro, com chave privada protegida. O script não configura esse fluxo e não gera chaves.
3. Identifique o certificado público usado pelo DKMS. Caminhos comuns são `/var/lib/dkms/mok.pub` e `/var/lib/shim-signed/mok/MOK.der`; configurações locais podem mudar esses caminhos.
4. Se o boot usa shim/MokManager, solicite `./wifi-bluetooth-universal.sh --enroll-mok /caminho/certificado.der`. Só cadastre certificados cuja origem você conhece.
5. Reinicie e confirme **Enroll MOK**, confira a impressão digital e use a senha temporária escolhida na importação. Essa etapa exige acesso ao console local.
6. Confira `mokutil --test-key /caminho/certificado.der`. Se o módulo foi compilado antes da configuração de assinatura, reconstrua-o usando o procedimento DKMS da distro e confirme a assinatura de todos os módulos envolvidos (no AIC: `aic8800_fdrv` e `aic_load_fw`).

Sem shim/MokManager, siga a documentação da distro/bootloader para cadastrar uma chave aceita pelo kernel. `--enroll-mok` solicita cadastro; não comprova assinatura, carregamento nem conectividade. `ASSINATURA` é uma confirmação do usuário antes do instalador upstream. A alternativa de desativar Secure Boot depende da política da máquina e não é aplicada por este projeto.

Referências: [DKMS](https://github.com/dkms-project/dkms#module-signing), [kernel Linux](https://docs.kernel.org/admin-guide/module-signing.html), [Ubuntu Secure Boot](https://documentation.ubuntu.com/security/security-features/platform-protections/secure-boot/).

## Driver ligado, mas sem conexão

Confira `iw dev`, `rfkill list`, os logs do kernel e o gerenciador de rede da distro. `Hard blocked: yes` exige tecla/chave física, BIOS/UEFI ou configuração do equipamento; `rfkill unblock` não remove esse bloqueio.

Inspecione `modprobe -n -v NOME_DO_MODULO` e arquivos em `/etc/modprobe.d` e `/usr/lib/modprobe.d`. Blacklists ou regras `install` podem impedir o carregamento mesmo com o módulo presente. Não remova todas as blacklists: identifique a regra e o conflito primeiro. O aplicativo preserva drivers ligados e não força associação de IDs desconhecidos.

Em máquinas virtuais, confirme passthrough USB. Em contêineres, instale drivers no hospedeiro. Sistemas imutáveis/declarativos exigem instalação pela imagem ou configuração do hospedeiro; não tente instalar DKMS somente dentro de um toolbox/Distrobox.

## Bluetooth sem controlador ou áudio instável

Confira alimentação/porta USB, firmware, `btusb`, D-Bus e serviço BlueZ. A presença do pacote BlueZ não garante que o serviço esteja ativo. Em runit, habilite primeiro o serviço da distro em `/var/service/bluetooth`. Em outros inits não reconhecidos, inicie BlueZ pelo procedimento local.

Recarregar `btusb` desconecta teclados, mouses e áudio Bluetooth. Se o descarregamento falhar por uso, mantenha o serviço ativo e reinicie quando conveniente. Se o carregamento falhar, o assistente tenta restaurar o serviço, mas o controlador continuará indisponível até corrigir o módulo/firmware.

Desativar autosuspend pode ajudar a estabilidade e aumentar consumo. A regra de áudio só é aplicada ao WirePlumber 0.5; sistemas com PulseAudio ou outras versões exigem sua própria configuração. Bloquear a troca automática de perfil pode impedir o uso automático do microfone do headset.

## Desfazer ajustes

O arquivo de autosuspend é `/etc/modprobe.d/wifi-bluetooth-btusb.conf`. Restaure o backup `.bak.DATA` se ele existia, ou remova somente esse arquivo se ele foi criado pelo aplicativo. Atualize o initramfs com a ferramenta da distro (`mkinitcpio`, `update-initramfs` ou `dracut`) e reinicie quando conveniente. Se a atualização do initramfs falhou, corrija o erro antes do próximo boot.

A regra de áudio é `${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d/51-bluetooth-autoswitch.conf`. Restaure seu backup ou remova esse arquivo e reinicie a sessão de áudio.

Drivers externos precisam ser removidos pelo procedimento do projeto upstream na cópia em `~/src/linux-wireless-drivers`. Realtek fornece `remove-driver.sh`. Consulte `dkms status` antes de remover qualquer versão; não apague módulos ou firmware indiscriminadamente. A remoção não é feita automaticamente por este assistente. Pacotes instalados e habilitação do serviço BlueZ também não são revertidos automaticamente.
