#!/usr/bin/env bash
# Detect and install selected USB Wi-Fi drivers; keep Bluetooth on the kernel stack.
set -Eeuo pipefail
if (( BASH_VERSINFO[0] < 4 )); then
    printf 'Erro: este aplicativo requer Bash 4 ou mais recente.\n' >&2
    exit 1
fi
PATH="${PATH}:/usr/sbin:/sbin"

APP_VERSION="1.1.0"
SRC_ROOT="${HOME}/src/linux-wireless-drivers"
BTUSB_CONF="/etc/modprobe.d/wifi-bluetooth-btusb.conf"
INIT_KIND=""
SYS_ROOT=/sys
MODULES_ROOT=/lib/modules
SECURE_BOOT=unknown
ISSUES=0

confirm() {
    local reply
    read -r -p "$1 [s/N] " reply || return 1
    [[ "$reply" =~ ^[sS]([iI][mM])?$ ]]
}

optional() {
    if [[ "$1" == bluetoothctl && ! -S /run/dbus/system_bus_socket && -z "${DBUS_SYSTEM_BUS_ADDRESS:-}" ]]; then
        warn 'D-Bus do sistema indisponível; consulta Bluetooth ignorada.'
        return 0
    fi
    if [[ "$1" == bluetoothctl ]] && command -v busctl >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
        if ! timeout 5 busctl --system --no-pager status org.bluez >/dev/null 2>&1; then
            warn 'BlueZ/D-Bus inacessível; consulta Bluetooth ignorada. Confira o serviço e as permissões.'
            return 0
        fi
    fi
    if command -v "$1" >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 15 "$@" || warn "'$1' falhou, excedeu 15s ou o recurso está indisponível."
        else
            "$@" || warn "'$1' falhou ou o recurso não está disponível nesta máquina."
        fi
    else
        printf '  %s não instalado (opcional para diagnóstico).\n' "$1"
    fi
}

detect_secure_boot() {
    SECURE_BOOT=unknown
    local state file value
    if command -v mokutil >/dev/null 2>&1; then
        state="$(LC_ALL=C mokutil --sb-state 2>/dev/null || true)"
        case "$state" in
            *'SecureBoot enabled'*) SECURE_BOOT=enabled; return ;;
            *'SecureBoot disabled'*) SECURE_BOOT=disabled; return ;;
        esac
    fi
    if [[ ! -d "$SYS_ROOT/firmware/efi" ]]; then
        SECURE_BOOT=not-uefi
        return
    fi
    for file in "$SYS_ROOT"/firmware/efi/efivars/SecureBoot-*; do
        [[ -r "$file" ]] || continue
        # efivarfs starts with four bytes of attributes, followed by the value.
        value="$(od -An -t u1 -j 4 -N 1 "$file" 2>/dev/null | tr -d ' ' || true)"
        case "$value" in 1) SECURE_BOOT=enabled;; 0) SECURE_BOOT=disabled;; esac
        return
    done
}

secure_boot_help() {
    cat <<'EOF'
Secure Boot: prefira um driver/firmware fornecido e assinado pela distribuição.
Para módulos externos, assinatura e confiança na chave são etapas distintas:
  1. Use o DKMS e o procedimento de assinatura documentado pela sua distro.
  2. Confira qual certificado ele usa. Locais comuns (não universais):
       /var/lib/dkms/mok.pub
       /var/lib/shim-signed/mok/MOK.der
  3. Com boot via shim/MokManager, solicite o cadastro do certificado público:
       ./wifi-bluetooth-universal.sh --enroll-mok /caminho/certificado.der
  4. Reinicie e confirme Enroll MOK no console local com a senha escolhida.
  5. Confira: mokutil --test-key /caminho/certificado.der
     Confira também: modinfo -F signer NOME_DO_MODULO
     Reconstrua via DKMS se o módulo ainda estiver sem assinatura.
Cadastrar uma chave não assina módulos existentes e não garante que um kernel
personalizado a aceite. Sem shim/MokManager, siga o processo da distribuição.
O aplicativo não desativa Secure Boot nem altera as chaves automaticamente.
EOF
}

enroll_mok() {
    local cert="$1"
    command -v mokutil >/dev/null 2>&1 || die 'instale mokutil pelo gerenciador da sua distro.'
    [[ -f "$cert" && -r "$cert" ]] || die 'certificado público DER inexistente ou sem permissão de leitura.'
    if mokutil --test-key "$cert"; then
        info 'Certificado já cadastrado.'
        return
    fi
    warn "Cadastrar $cert concede confiança aos módulos assinados com a chave correspondente."
    confirm 'Solicitar cadastro deste certificado no próximo boot?' || return 0
    root_run mokutil --import "$cert"
    info 'Solicitação enviada. Reinicie e confirme Enroll MOK no MokManager; o cadastro ainda está pendente.'
}

external_module_guard() {
    local lockdown="" enforce=""
    detect_secure_boot
    [[ ! -r "$SYS_ROOT/kernel/security/lockdown" ]] || lockdown="$(<"$SYS_ROOT/kernel/security/lockdown")"
    [[ ! -r "$SYS_ROOT/module/module/parameters/sig_enforce" ]] || enforce="$(<"$SYS_ROOT/module/module/parameters/sig_enforce")"
    if [[ "$SECURE_BOOT" == enabled || "$SECURE_BOOT" == unknown || "$lockdown" == *'[integrity]'* || "$lockdown" == *'[confidentiality]'* || "$enforce" == Y || "$enforce" == 1 ]]; then
        warn "Secure Boot: $SECURE_BOOT; lockdown: ${lockdown:-indisponível}; assinatura obrigatória: ${enforce:-indisponível}."
        secure_boot_help
        warn 'O instalador upstream precisa assinar TODOS os módulos com uma chave aceita pelo kernel.'
        local reply
        read -r -p 'Se já preparou a assinatura DKMS/upstream, digite ASSINATURA para continuar, ou Enter para usar as alternativas nativas: ' reply || return 1
        [[ "$reply" == ASSINATURA ]] || return 1
    fi
}

manual_dependencies() {
    warn "Instale pela sua distro: git, DKMS, make, compilador e headers/devel exatos para $(uname -r)."
    warn 'Para diagnóstico: kmod, iw, rfkill, BlueZ; para firmware: pacote de firmware da distro.'
    warn 'Sem internet, use Ethernet, tethering USB do celular ou pacotes offline da mesma distro/arquitetura.'
}

offer_runtime_tools() {
    local tool missing=""
    for tool in modprobe modinfo iw rfkill bluetoothctl; do
        command -v "$tool" >/dev/null 2>&1 || missing+=" $tool"
    done
    [[ -n "$missing" ]] || return 0
    warn "Ferramentas ausentes:$missing"
    confirm 'Instalar ferramentas de Wi-Fi/Bluetooth pelo gerenciador de pacotes?' || return 0
    if command -v pacman >/dev/null 2>&1; then
        root_run pacman -S --needed kmod iw rfkill bluez bluez-utils
    elif command -v apt-get >/dev/null 2>&1; then
        root_run apt-get update || return 1
        root_run apt-get install -y kmod iw rfkill bluez
    elif command -v dnf >/dev/null 2>&1; then
        root_run dnf install -y kmod iw util-linux bluez
    elif command -v zypper >/dev/null 2>&1; then
        root_run zypper --non-interactive install kmod iw rfkill bluez
    elif command -v xbps-install >/dev/null 2>&1; then
        root_run xbps-install -S kmod iw util-linux bluez
    elif command -v apk >/dev/null 2>&1; then
        root_run apk add kmod iw rfkill bluez
    else
        manual_dependencies
        return 1
    fi
}

mutable_system() {
    if [[ -e /run/ostree-booted || -e /etc/NIXOS || -e /run/current-system/nixos-version || -e /etc/vanilla-os/config.json ]]; then
        warn 'Sistema declarativo/imutável: use módulos e firmware pela configuração do sistema hospedeiro.'
        manual_dependencies
        return 1
    fi
    if [[ -e /.dockerenv || -e /run/.containerenv ]] || { command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container --quiet; }; then
        warn 'Contêiner detectado: drivers devem ser instalados no hospedeiro.'
        return 1
    fi
}

die() { printf 'Erro: %s\n' "$*" >&2; exit 1; }
info() { printf '\n▶ %s\n' "$*"; }
warn() { printf 'Aviso: %s\n' "$*" >&2; }
root_run() {
    if (( EUID == 0 )); then "$@"
    elif command -v sudo >/dev/null 2>&1; then sudo "$@"
    elif command -v doas >/dev/null 2>&1; then doas "$@"
    else die 'instale sudo ou doas para continuar.'
    fi
}

read_usb_devices() {
    USB_ROWS=()
    local d vid pid product
    for d in "$SYS_ROOT"/bus/usb/devices/*; do
        [[ -r "$d/idVendor" && -r "$d/idProduct" ]] || continue
        vid="$(<"$d/idVendor")"; pid="$(<"$d/idProduct")"
        product="$(cat "$d/product" 2>/dev/null || true)"
        USB_ROWS+=("${d##*/}|${vid,,}:${pid,,}|${product}")
    done
}

device_wifi_driver() {
    local devpath="$1" intf drv class
    for intf in "$devpath":*; do
        [[ -d "$intf" ]] || continue
        class="$(cat "$intf/bInterfaceClass" 2>/dev/null || true)"
        # The AIC combo exposes separate Bluetooth (e0) and Wi-Fi (ff)
        # interfaces. Never mistake btusb or usb-storage for the Wi-Fi driver.
        [[ "${class,,}" == ff || "${class,,}" == 02 ]] || continue
        [[ -L "$intf/driver" ]] || continue
        drv="$(readlink -f "$intf/driver" 2>/dev/null || true)"
        drv="${drv##*/}"
        [[ -n "$drv" ]] && { printf '%s' "$drv"; return 0; }
    done
    return 1
}

native_wifi_alias_driver() {
    local devpath="$1" intf class alias modules
    for intf in "$devpath":*; do
        [[ -d "$intf" ]] || continue
        class="$(cat "$intf/bInterfaceClass" 2>/dev/null || true)"
        [[ "${class,,}" == ff || "${class,,}" == 02 ]] || continue
        alias="$(cat "$intf/modalias" 2>/dev/null || true)"
        [[ -n "$alias" ]] || continue
        modules="$(modprobe --resolve-alias "$alias" 2>/dev/null || true)"
        [[ -n "$modules" ]] && { printf '%s\n' "$modules" | head -n 1; return 0; }
    done
    return 1
}

classify_wifi_id() {
    case "$1" in
        # AIC8800D80 operational mode and its USB storage/boot mode.
        a69c:8d81|1111:1111) printf 'aic8800';;
        # RTL8812AU, including common TP-Link, ASUS, D-Link and Realtek IDs.
        0bda:8812|0bda:881a|0bda:881b|0bda:881c|0b05:17d2|0846:9051|\
        2001:330e|2001:3313|2001:3315|2001:3316|2357:0101|2357:0103|\
        2357:010d|2357:010e|2357:010f|7392:a822) printf 'rtl8812au';;
        # RTL8812BU / RTL8822BU common adapters.
        0bda:b812|0bda:b82c|0bda:b81a|2357:0115) printf 'rtl88x2bu';;
        # This AIC VID:PID currently needs a device-specific BT quirk. Keep the
        # strict native-btusb policy and do not auto-install it.
        368b:8d81) printf 'aic-needs-bt-quirk';;
        *) return 1;;
    esac
}

print_header() {
    printf '\n===============================================\n'
    printf ' Wi-Fi + Bluetooth Driver Helper  v%s\n' "$APP_VERSION"
    printf '===============================================\n'
    printf 'Sistema: %s | Kernel: %s\n' "$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-Linux}")" "$(uname -r)"
}

show_devices_and_select_profile() {
    read_usb_devices
    local row dev id product path alias_driver bound profile
    MATCHED=()
    printf '\nDispositivos USB: VID:PID — produto — driver ligado\n'
    for row in "${USB_ROWS[@]}"; do
        IFS='|' read -r dev id product <<< "$row"
        path="$SYS_ROOT/bus/usb/devices/$dev"
        bound="$(device_wifi_driver "$path" || true)"
        printf '  %s — %s — %s\n' "$id" "${product:-sem descrição}" "${bound:-sem driver USB}"
        if profile="$(classify_wifi_id "$id")"; then
            MATCHED+=("$profile|$id|$dev|${product:-sem descrição}|${bound:-}")
        fi
    done

    SELECTED=""
    for row in "${MATCHED[@]}"; do
        IFS='|' read -r profile id dev product bound <<< "$row"
        case "$profile" in
            aic-needs-bt-quirk)
                warn "$id é AIC8800, mas o perfil Bluetooth estritamente nativo ainda não está validado para este ID; nenhum driver será compilado para ele."
                ;;
            *)
                if [[ -n "$bound" ]]; then
                    info "$id já está ligado ao driver '$bound'; não vou substituí-lo automaticamente."
                else
                    alias_driver="$(native_wifi_alias_driver "$SYS_ROOT/bus/usb/devices/$dev" || true)"
                    if [[ -n "$alias_driver" ]]; then
                        info "$id tem candidato já instalado ('$alias_driver'); confira carregamento, assinatura e firmware com --diagnose."
                    else
                        SELECTED="$profile|$id|$dev|$product"
                    fi
                fi
                ;;
        esac
    done

    if [[ "${#MATCHED[@]}" -gt 1 ]]; then
        local index=0 choice
        SELECTED=""
        printf '\nEscolha um perfil para esta execução (Enter ignora):\n'
        for row in "${MATCHED[@]}"; do
            index=$((index + 1))
            printf '  %s) %s\n' "$index" "$row"
        done
        read -r -p 'Número: ' choice || return 0
        if [[ "$choice" =~ ^[1-9][0-9]*$ && ${#choice} -le 3 ]] && (( choice <= ${#MATCHED[@]} )); then
            IFS='|' read -r profile id dev product bound <<< "${MATCHED[choice-1]}"
            if [[ -z "$bound" && "$profile" != aic-needs-bt-quirk ]] &&
               ! native_wifi_alias_driver "$SYS_ROOT/bus/usb/devices/$dev" >/dev/null; then
                SELECTED="$profile|$id|$dev|$product"
            fi
        fi
    fi
}

install_build_dependencies() {
    mutable_system || return 1
    local kernel header manager=manual
    kernel="$(uname -r)"
    # Derive the kernel flavor from the installed kernel, never from distro name.
    local -a headers=()
    if [[ ! -r "$MODULES_ROOT/$kernel/build/Makefile" ]]; then
        if command -v pacman >/dev/null 2>&1; then
            header="$(cat "$MODULES_ROOT/$kernel/pkgbase" 2>/dev/null || true)"
            [[ "$header" =~ ^[a-zA-Z0-9._+-]+$ ]] || { manual_dependencies; return 1; }
            headers=("${header}-headers")
        elif command -v apt-get >/dev/null 2>&1; then
            headers=("linux-headers-$kernel")
        elif command -v dnf >/dev/null 2>&1; then
            headers=("kernel-devel-$kernel")
        elif command -v zypper >/dev/null 2>&1; then
            # SUSE flavor and ABI vary; do not silently install another kernel.
            manual_dependencies
            warn 'openSUSE: instale kernel-devel e kernel-FLAVOR-devel correspondentes ao kernel ativo e execute novamente.'
            return 1
        else
            manual_dependencies
            return 1
        fi
    fi
    if command -v pacman >/dev/null 2>&1; then
        manager=pacman
        root_run pacman -S --needed git dkms base-devel "${headers[@]}" || return 1
    elif command -v apt-get >/dev/null 2>&1; then
        manager=apt
        root_run apt-get update || return 1
        root_run apt-get install -y git dkms build-essential "${headers[@]}" || return 1
    elif command -v dnf >/dev/null 2>&1; then
        manager=dnf
        root_run dnf install -y git dkms gcc make "${headers[@]}" || return 1
    elif command -v zypper >/dev/null 2>&1; then
        manager=zypper
        root_run zypper --non-interactive install git dkms gcc make || return 1
    elif command -v xbps-install >/dev/null 2>&1; then
        manager=xbps
        root_run xbps-install -S git dkms base-devel || return 1
    elif command -v apk >/dev/null 2>&1; then
        manager=apk
        root_run apk add git dkms build-base || return 1
    else
        manual_dependencies
        # Allow manually prepared Gentoo, Slackware, etc.
    fi
    local tool
    for tool in git dkms make cc; do
        command -v "$tool" >/dev/null 2>&1 || { warn "Dependência ausente: $tool"; return 1; }
    done
    [[ -r "$MODULES_ROOT/$kernel/build/Makefile" ]] || {
        warn "Headers do kernel ativo ausentes em $MODULES_ROOT/$kernel/build."
        warn 'Se o kernel foi atualizado, reinicie no kernel correspondente aos headers; depois execute novamente.'
        return 1
    }
    if [[ -r "$MODULES_ROOT/$kernel/build/include/config/kernel.release" ]] &&
       [[ "$(<"$MODULES_ROOT/$kernel/build/include/config/kernel.release")" != "$kernel" ]]; then
        warn 'A árvore de headers pertence a outro kernel; corrija o link build ou reinicie no kernel correspondente.'
        return 1
    fi
    info "Dependências verificadas ($manager)."
}

clone_or_update() {
    local repo="$1" dir="$2"
    mkdir -p "$SRC_ROOT" || return 1
    if [[ ! -d "$dir/.git" ]]; then
        git clone --depth 1 "$repo" "$dir" || { manual_dependencies; return 1; }
    else
        info "Usando a cópia local em $dir sem atualizá-la."
    fi
}

install_aic_wifi_only() (
    local dir="$SRC_ROOT/aic8800d80"
    clone_or_update 'https://github.com/shenmintao/aic8800d80.git' "$dir" || return 1
    [[ -f "$dir/install.sh" && -f "$dir/dkms.conf" && -f "$dir/drivers/aic8800/Makefile" ]] || die 'a estrutura do driver AIC mudou; parei antes de instalar para revisar as alterações.'

    # Upstream also builds an optional Bluetooth quirk. This profile deliberately
    # builds only the AIC Wi-Fi and firmware-loader modules; btusb stays in-kernel.
    grep -qE '^CONFIG_AIC_ZLP_QUIRK := [mn]$' "$dir/drivers/aic8800/Makefile" || die 'não reconheci a configuração upstream do módulo AIC ZLP; nenhuma alteração foi aplicada.'
    if grep -q 'aic_zlp_quirk' "$dir/dkms.conf"; then
        grep -q '^BUILT_MODULE_NAME\[2\]="aic_zlp_quirk"$' "$dir/dkms.conf" || die 'configuração DKMS do quirk AIC desconhecida.'
        sed -i '/^# Device-scoped standard-btusb ACL bulk TX ZLP quirk/,+3d' "$dir/dkms.conf" || return 1
    fi
    sed -i 's/^CONFIG_AIC_ZLP_QUIRK := m$/CONFIG_AIC_ZLP_QUIRK := n/' "$dir/drivers/aic8800/Makefile" || return 1
    ! grep -q 'aic_zlp_quirk' "$dir/dkms.conf" || die 'não consegui excluir o módulo Bluetooth auxiliar do DKMS.'

    printf '\nO driver AIC compila aic8800_fdrv e aic_load_fw (este último carrega firmware necessário ao combo).\n'
    printf 'O módulo HCI Bluetooth permanece o btusb do kernel.\n\n'
    read -r -p 'Digite INSTALAR para executar o instalador upstream Wi-Fi AIC? ' answer || return 0
    [[ "$answer" == INSTALAR ]] || { info 'Instalação cancelada.'; return 0; }
    root_run "$dir/install.sh"
)

kernel_version_num() {
    local version
    version="$(uname -r | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
    printf '%s' "$version"
}

version_at_least() {
    [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

install_realtek_profile() (
    local profile="$1" kernel repo dir
    kernel="$(kernel_version_num)"
    case "$profile" in
        rtl8812au)
            # The kernel driver is preferred from 6.14. Upstream DKMS support is
            # documented through kernel 7.0; stop beyond that instead of forcing it.
            if version_at_least "$kernel" 6.14; then
                info "Kernel $kernel já está na faixa com driver nativo rtw88 para RTL8812AU; nenhuma compilação externa."
                return 0
            fi
            repo='https://github.com/morrownr/8812au-20210820.git'
            dir="$SRC_ROOT/8812au-20210820"
            ;;
        rtl88x2bu)
            # rtw88 is preferred on 6.12+, while the out-of-tree project documents
            # support through 6.14 (with later exceptions limited to specific distros).
            if version_at_least "$kernel" 6.12; then
                info "Kernel $kernel tem suporte nativo rtw88 para RTL8812BU/RTL8822BU; nenhuma compilação externa."
                return 0
            fi
            repo='https://github.com/morrownr/88x2bu-20210702.git'
            dir="$SRC_ROOT/88x2bu-20210702"
            ;;
        *) die "perfil Realtek desconhecido: $profile" ;;
    esac
    clone_or_update "$repo" "$dir" || return 1
    [[ -x "$dir/install-driver.sh" ]] || die "o instalador upstream não foi encontrado em $dir."
    read -r -p "Digite INSTALAR para executar o instalador upstream Wi-Fi ($profile)? " answer || return 0
    [[ "$answer" == INSTALAR ]] || { info 'Instalação cancelada.'; return 0; }
    root_run "$dir/install-driver.sh" NoPrompt
)

install_selected_wifi() {
    [[ -n "$SELECTED" ]] || { info 'Nenhum perfil externo selecionado; preservando os drivers de Wi-Fi presentes.'; return 0; }
    local profile id dev product answer
    if ! command -v modprobe >/dev/null 2>&1 || ! command -v modinfo >/dev/null 2>&1; then
        warn 'Instale kmod e execute novamente para verificar os drivers existentes antes de compilar.'
        return 1
    fi
    IFS='|' read -r profile id dev product <<< "$SELECTED"
    info "Perfil identificado: $profile ($id, $product)."
    printf 'Os instaladores externos alteram módulos do kernel e podem exigir reinicialização.\n'
    read -r -p 'Deseja continuar? [s/N] ' answer || return 0
    [[ "$answer" =~ ^[sS]([iI][mM])?$ ]] || { info 'Instalação Wi-Fi cancelada.'; return 0; }
    local kernel
    kernel="$(kernel_version_num)"
    if { [[ "$profile" == rtl8812au ]] && version_at_least "$kernel" 6.14; } ||
       { [[ "$profile" == rtl88x2bu ]] && version_at_least "$kernel" 6.12; }; then
        warn 'Este perfil deve usar rtw88 neste kernel. Instale os módulos extras/firmware da distro; não vou compilar o driver legado.'
        return 0
    fi
    external_module_guard || { info 'Instalação externa adiada; o diagnóstico e Bluetooth continuam disponíveis.'; return 0; }
    install_build_dependencies || return 1
    case "$profile" in
        aic8800) install_aic_wifi_only || return 1 ;;
        rtl8812au|rtl88x2bu) install_realtek_profile "$profile" || return 1 ;;
    esac
    info 'Confira os módulos com modinfo -F signer e dkms status; instalação concluída não comprova que a conexão funciona.'
}

apply_btusb_power_rule() {
    local tmp module_file
    if ! modinfo btusb >/dev/null 2>&1; then
        warn 'módulo btusb não encontrado; não criei a regra de autosuspend.'
        return 1
    fi
    module_file="$(modinfo -F filename btusb 2>/dev/null || true)"
    if [[ "$module_file" == '(builtin)' ]]; then
        warn 'btusb está compilado dentro do kernel; opções em modprobe.d não se aplicam a ele.'
        return 1
    fi
    modinfo -p btusb | grep -q '^enable_autosuspend:' || { warn 'btusb não oferece enable_autosuspend neste kernel.'; return 1; }
    tmp="$(mktemp)" || return 1
    printf 'options btusb enable_autosuspend=0\n' > "$tmp"
    if [[ -e "$BTUSB_CONF" ]]; then
        root_run cp -a "$BTUSB_CONF" "${BTUSB_CONF}.bak.$(date +%Y%m%d%H%M%S)" || { rm -f "$tmp"; return 1; }
    fi
    root_run install -D -m 0644 "$tmp" "$BTUSB_CONF" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    info "Regra instalada: $BTUSB_CONF (desativa autosuspend apenas no btusb)."
}

refresh_initramfs() {
    if command -v mkinitcpio >/dev/null 2>&1; then
        root_run mkinitcpio -P
    elif command -v update-initramfs >/dev/null 2>&1; then
        root_run update-initramfs -u
    elif command -v dracut >/dev/null 2>&1; then
        root_run dracut --force --regenerate-all
    else
        warn 'não encontrei mkinitcpio, update-initramfs ou dracut; a regra será lida no próximo carregamento do btusb.'
    fi
}

apply_wireplumber_rule() {
    local choice version config_dir config_file
    command -v wireplumber >/dev/null 2>&1 || { info 'WirePlumber não encontrado; regra de perfil de áudio ignorada.'; return 0; }
    version="$(wireplumber --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
    [[ "$version" == 0.5* ]] || { info "WirePlumber $version não é 0.5; não apliquei a sintaxe de configuração 0.5."; return 0; }
    read -r -p 'Impedir troca automática de A2DP para HSP/HFP quando um app usa o microfone? [s/N] ' choice || return 0
    [[ "$choice" =~ ^[sS]([iI][mM])?$ ]] || return 0
    config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d"
    config_file="$config_dir/51-bluetooth-autoswitch.conf"
    mkdir -p "$config_dir" || return 1
    if [[ -e "$config_file" ]]; then
        cp -a "$config_file" "${config_file}.bak.$(date +%Y%m%d%H%M%S)" || return 1
    fi
    cat > "$config_file" <<'EOF' || return 1
wireplumber.settings = {
  bluetooth.autoswitch-to-headset-profile = false
}
EOF
    info "Regra do WirePlumber criada em $config_file. Reinicie a sessão de áudio ou encerre e entre novamente."
}

start_bluetooth_service() {
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        INIT_KIND=systemd
        root_run systemctl enable --now bluetooth.service
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_KIND=openrc
        root_run rc-update add bluetooth default || return 1
        root_run rc-service bluetooth start || root_run rc-service bluetooth restart
    elif command -v sv >/dev/null 2>&1 && [[ -e /var/service/bluetooth ]]; then
        INIT_KIND=runit
        root_run sv up /var/service/bluetooth
    elif command -v service >/dev/null 2>&1 && [[ -x /etc/init.d/bluetooth ]]; then
        INIT_KIND=sysv
        root_run service bluetooth start
    else
        warn 'Serviço BlueZ não localizado em systemd/OpenRC/runit/SysV. Instale BlueZ e habilite o serviço pela distro.'
        return 1
    fi
}

bluetooth_service_action() {
    case "$INIT_KIND" in
        systemd) root_run systemctl "$1" bluetooth.service ;;
        openrc) root_run rc-service bluetooth "$1" ;;
        runit)
            if [[ "$1" == stop ]]; then root_run sv down /var/service/bluetooth
            else root_run sv up /var/service/bluetooth; fi ;;
        sysv) root_run service bluetooth "$1" ;;
        *) return 1 ;;
    esac
}

reload_btusb() {
    local answer connected failed=0
    [[ -n "$INIT_KIND" ]] && command -v bluetoothctl >/dev/null 2>&1 || return 0
    connected="$(bluetoothctl devices Connected 2>/dev/null || true)"
    if [[ -n "$connected" ]]; then
        printf '\nDispositivos Bluetooth conectados:\n%s\n' "$connected"
        warn 'recarregar btusb desconectará esses dispositivos.'
    fi
    read -r -p 'Recarregar btusb agora? [s/N] ' answer || return 0
    [[ "$answer" =~ ^[sS]([iI][mM])?$ ]] || { info 'módulo será aplicado no próximo boot.'; return 0; }
    bluetooth_service_action stop || return 1
    if root_run modprobe -r btusb; then
        root_run modprobe btusb || { warn 'btusb não carregou; o serviço será restaurado mesmo assim.'; failed=1; }
    else
        warn 'btusb está em uso e não pôde ser descarregado; reinicie o sistema para aplicar a opção.'
        failed=1
    fi
    bluetooth_service_action start || return 1
    optional bluetoothctl power on
    return "$failed"
}

show_final_status() {
    printf '\n── Estado final ──\n'
    printf 'Módulo btusb: '
    optional modinfo -F filename btusb
    printf '\nMódulos Wi-Fi AIC/Realtek presentes:\n'
    if command -v lsmod >/dev/null 2>&1; then
        lsmod | grep -E '^(aic8800_fdrv|aic_load_fw|8812au|88x2bu|rtw88|ath|iwl|mt7|brcm)' || printf '  nenhum identificado\n'
    fi
    printf '\nControlador Bluetooth:\n'
    optional bluetoothctl list
    printf '\nRFKill:\n'
    optional rfkill list
    printf '\nInterfaces Wi-Fi:\n'
    optional iw dev
}

native_candidates() {
    local path alias module class deps filename
    # USB vendor-specific/network interfaces, PCI network controllers and SDIO.
    for path in "$SYS_ROOT"/bus/usb/devices/*:* "$SYS_ROOT"/bus/pci/devices/* "$SYS_ROOT"/bus/sdio/devices/*; do
        [[ -r "$path/modalias" && ! -L "$path/driver" ]] || continue
        if [[ "$path" == */usb/* ]]; then
            class="$(cat "$path/bInterfaceClass" 2>/dev/null || true)"
            [[ "$class" == ff || "$class" == 02 ]] || continue
        elif [[ "$path" == */pci/* ]]; then
            class="$(cat "$path/class" 2>/dev/null || true)"
            [[ "$class" == 0x02* ]] || continue
        fi
        alias="$(<"$path/modalias")"
        while IFS= read -r module; do
            [[ "$module" =~ ^[a-zA-Z0-9_-]+$ ]] || continue
            [[ "$(modinfo -F intree "$module" 2>/dev/null || true)" == Y ]] || continue
            deps="$(modinfo -F depends "$module" 2>/dev/null || true)"
            filename="$(modinfo -F filename "$module" 2>/dev/null || true)"
            # USB frontends (e.g. rtw88) may depend on cfg80211 only indirectly.
            [[ "$filename" == */drivers/net/wireless/* || "$deps" == *cfg80211* || "$deps" == *mac80211* ]] || continue
            printf '%s\n' "$module"
        done < <(modprobe --resolve-alias "$alias" 2>/dev/null || true)
    done
}

try_native_drivers() {
    local candidates module
    command -v modprobe >/dev/null 2>&1 && command -v modinfo >/dev/null 2>&1 || {
        warn 'Instale kmod para resolver e carregar módulos nativos.'; return 0;
    }
    candidates="$(native_candidates | sort -u)"
    [[ -n "$candidates" ]] || { info 'Nenhum módulo Wi-Fi nativo disponível para os dispositivos sem driver.'; return 0; }
    printf '\nCandidatos nativos (não substituem drivers já ligados):\n%s\n' "$candidates"
    confirm 'Tentar carregar esses módulos do kernel?' || return 0
    while IFS= read -r module; do
        if root_run modprobe "$module"; then
            info "$module carregado. Confira a interface e o firmware no diagnóstico."
        else
            ISSUES=$((ISSUES + 1))
            warn "Falha ao carregar $module. Confira firmware, assinatura, blacklist e mensagens do kernel."
        fi
    done <<< "$candidates"
}

diagnose() {
    local path driver kind file missing=0
    print_header
    detect_secure_boot
    printf 'Arquitetura: %s | Secure Boot: %s\n' "$(uname -m)" "$SECURE_BOOT"
    printf 'Headers do kernel ativo: '
    if [[ -r "$MODULES_ROOT/$(uname -r)/build/Makefile" ]]; then printf 'presentes\n'; else printf 'ausentes\n'; fi
    for file in "$SYS_ROOT/kernel/security/lockdown" "$SYS_ROOT/module/module/parameters/sig_enforce"; do
        [[ ! -r "$file" ]] || printf '%s: %s\n' "${file##*/}" "$(<"$file")"
    done
    printf '\nFerramentas ausentes:\n'
    for kind in modprobe modinfo iw rfkill bluetoothctl mokutil; do
        command -v "$kind" >/dev/null 2>&1 || { printf '  %s\n' "$kind"; missing=1; }
    done
    (( missing )) || printf '  nenhuma\n'
    printf '\nUSB (VID:PID):\n'
    read_usb_devices
    printf '  %s\n' "${USB_ROWS[@]}"
    printf '\nControladores PCI de rede e SDIO (modalias e driver):\n'
    for path in "$SYS_ROOT"/bus/pci/devices/* "$SYS_ROOT"/bus/sdio/devices/*; do
        [[ -r "$path/modalias" ]] || continue
        if [[ "$path" == */pci/* ]]; then
            kind="$(cat "$path/class" 2>/dev/null || true)"
            [[ "$kind" == 0x02* ]] || continue
        fi
        driver="$(readlink "$path/driver" 2>/dev/null || true)"
        printf '  %s | %s | %s\n' "${path##*/}" "$(<"$path/modalias")" "${driver##*/}"
    done
    printf '\nInterfaces (sem endereços de rede):\n'
    for path in "$SYS_ROOT"/class/net/*; do
        [[ -e "$path" ]] || continue
        driver="$(readlink "$path/device/driver" 2>/dev/null || true)"
        printf '  %s | driver: %s | estado: %s\n' "${path##*/}" "${driver##*/}" "$(cat "$path/operstate" 2>/dev/null || true)"
    done
    printf '\nMódulos nativos candidatos para dispositivos sem driver:\n'
    native_candidates | sort -u
    show_final_status
    printf '\nDKMS:\n'
    optional dkms status
    cat <<'EOF'

Alternativas para resolver falhas:
  • "Key was rejected" / "Required key not available": veja --secure-boot-help.
  • "Module not found": instale o pacote de módulos do kernel ativo da distro.
  • "Invalid module format": reconstrua para o kernel ativo e confira vermagic.
  • Firmware ausente: atualize o pacote linux-firmware/firmware-* da distro.
  • Confira os detalhes com: journalctl -k -b ou dmesg (podem exigir sudo).
  • Driver disponível sem interface: confira modprobe -n -v MODULO e blacklists
    em /etc/modprobe.d e /usr/lib/modprobe.d; revise antes de removê-las.
  • RFKill "Hard blocked: yes": use a tecla/chave física ou opção da BIOS/UEFI.
  • Bluetooth sem controlador: confira btusb, firmware, serviço BlueZ e USB.
  • Em VM, habilite passthrough USB; o driver precisa rodar onde o USB aparece.
  • Sem internet: Ethernet, tethering USB ou pacotes offline compatíveis.
EOF
}

usage() {
    cat <<'EOF'
Uso: ./wifi-bluetooth-universal.sh [opção]
  (sem opção)           Assistente interativo (usuário normal)
  --diagnose            Diagnóstico sem alterar o sistema, sem sudo e sem rede
  --report ARQUIVO      Salva diagnóstico em arquivo novo, com permissão 600
  --secure-boot-help    Explica assinatura de módulos e cadastro MOK
  --enroll-mok CERT     Solicita cadastro de certificado público DER, após confirmação
  --help                Mostra esta ajuda
EOF
}

main() {
    local answer
    [[ "$(uname -s)" == Linux ]] || die 'este aplicativo requer Linux.'
    case "${1:-}" in
        --help|-h) usage; return ;;
        --diagnose) [[ $# == 1 ]] || die 'use --diagnose sem outros argumentos.'; diagnose; return ;;
        --report)
            [[ $# == 2 ]] || die 'use --report ARQUIVO.'
            (umask 077; set -o noclobber; diagnose > "$2" 2>&1) || die 'não foi possível criar o relatório (o arquivo já existe ou o diagnóstico falhou).'
            info "Relatório salvo em $2. Revise IDs, nomes e endereços Bluetooth antes de compartilhar."
            return ;;
        --secure-boot-help) secure_boot_help; return ;;
        --enroll-mok)
            [[ $# == 2 ]] || die 'use --enroll-mok CERTIFICADO.der.'
            [[ -t 0 ]] || die 'o cadastro MOK requer um terminal interativo.'
            enroll_mok "$2"; return ;;
        '') ;;
        *) usage; die "opção desconhecida: $1" ;;
    esac
    [[ -t 0 ]] || die 'use --diagnose ou --report quando não houver terminal interativo.'
    (( EUID != 0 )) || die 'rode como usuário normal; o aplicativo pedirá elevação quando necessário.'
    print_header
    printf '\nBluetooth é gerenciado pelo kernel (btusb e módulos auxiliares nativos) + BlueZ.\n'
    printf 'Este aplicativo nunca compila um driver HCI Bluetooth externo.\n'
    mutable_system || { diagnose; return 0; }
    detect_secure_boot
    info "Secure Boot: $SECURE_BOOT | arquitetura: $(uname -m)"
    offer_runtime_tools || { ISSUES=$((ISSUES + 1)); warn 'Ferramentas não instaladas; confira a rede e os repositórios ou prepare pacotes offline.'; }
    try_native_drivers
    show_devices_and_select_profile
    install_selected_wifi || { ISSUES=$((ISSUES + 1)); warn 'Instalação Wi-Fi falhou; use --diagnose e confira o log DKMS em /var/lib/dkms. Bluetooth e diagnóstico continuam disponíveis.'; }

    read -r -p '\nAplicar configuração de estabilidade do btusb e liberar rfkill? [s/N] ' answer || answer=''
    if [[ "$answer" =~ ^[sS]([iI][mM])?$ ]]; then
        if apply_btusb_power_rule; then
            refresh_initramfs || { ISSUES=$((ISSUES + 1)); warn 'Falha ao atualizar initramfs; consulte a ferramenta da sua distro antes de reiniciar.'; }
        else
            ISSUES=$((ISSUES + 1))
        fi
        if command -v rfkill >/dev/null 2>&1; then
            root_run rfkill unblock bluetooth || { ISSUES=$((ISSUES + 1)); warn 'Não foi possível liberar RFKill Bluetooth.'; }
        fi
        apply_wireplumber_rule || { ISSUES=$((ISSUES + 1)); warn 'Não foi possível gravar a regra WirePlumber.'; }
        if start_bluetooth_service; then
            reload_btusb || { ISSUES=$((ISSUES + 1)); warn 'Bluetooth não recarregou; confira o serviço e execute --diagnose.'; }
        else
            ISSUES=$((ISSUES + 1))
            warn 'Serviço Bluetooth não iniciou; confira BlueZ, D-Bus e seu gerenciador de serviços.'
        fi
    else
        info 'ajustes globais de Bluetooth cancelados.'
    fi
    show_final_status
    printf '\nAssistente encerrado com %s falha(s) detectada(s). Confira o estado acima.\n' "$ISSUES"
    printf 'Se a conexão continuar indisponível, execute --diagnose ou --report ARQUIVO.\n'
    (( ISSUES == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
