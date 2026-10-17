#!/usr/bin/env bash
# Detect and install selected USB Wi-Fi drivers; keep Bluetooth on the kernel stack.
set -Eeuo pipefail

APP_VERSION="1.0.0"
SRC_ROOT="${HOME}/src/linux-wireless-drivers"
BTUSB_CONF="/etc/modprobe.d/wifi-bluetooth-btusb.conf"
INIT_KIND=""

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
    for d in /sys/bus/usb/devices/*; do
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
        drv="$(basename "$(readlink -f "$intf/driver" 2>/dev/null || true)")"
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
        path="/sys/bus/usb/devices/$dev"
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
                    alias_driver="$(native_wifi_alias_driver "/sys/bus/usb/devices/$dev" || true)"
                    if [[ -n "$alias_driver" ]]; then
                        info "$id tem candidato nativo no kernel ('$alias_driver'); não vou substituí-lo por um módulo externo."
                    else
                        SELECTED="$profile|$id|$dev|$product"
                    fi
                fi
                ;;
        esac
    done

    if [[ "${#MATCHED[@]}" -gt 1 ]]; then
        warn 'Há mais de um adaptador reconhecido. Esta versão instala um único perfil por execução; nenhum driver será instalado automaticamente.'
        SELECTED=""
    fi
}

install_build_dependencies() {
    local manager
    if command -v pacman >/dev/null 2>&1; then
        manager=pacman
        local -a headers=(linux-headers)
        if [[ -r /etc/os-release ]] && grep -qi 'CachyOS' /etc/os-release; then
            headers=(linux-cachyos-headers)
        fi
        root_run pacman -S --needed git dkms base-devel usb_modeswitch rfkill bluez bluez-utils "${headers[@]}"
    elif command -v apt-get >/dev/null 2>&1; then
        manager=apt
        root_run apt-get update
        root_run apt-get install -y git dkms build-essential linux-headers-"$(uname -r)" usb-modeswitch rfkill bluez
    elif command -v dnf >/dev/null 2>&1; then
        manager=dnf
        root_run dnf install -y git dkms gcc make kernel-devel kernel-headers usb_modeswitch rfkill bluez
    elif command -v zypper >/dev/null 2>&1; then
        manager=zypper
        root_run zypper --non-interactive install git dkms gcc make kernel-devel usb_modeswitch rfkill bluez
    elif command -v xbps-install >/dev/null 2>&1; then
        manager=xbps
        root_run xbps-install -Sy git dkms base-devel linux-headers usb-modeswitch rfkill bluez
    elif command -v apk >/dev/null 2>&1; then
        manager=apk
        root_run apk add git dkms build-base linux-lts-dev usb-modeswitch rfkill bluez
    else
        die 'gerenciador não reconhecido. Instale manualmente git, DKMS, compilador, headers do kernel, BlueZ e usb-modeswitch.'
    fi
    info "Dependências instaladas usando $manager."
    [[ -r "/lib/modules/$(uname -r)/build/Makefile" ]] || die "headers do kernel ativo não encontrados em /lib/modules/$(uname -r)/build."
}

clone_or_update() {
    local repo="$1" dir="$2"
    mkdir -p "$SRC_ROOT"
    if [[ ! -d "$dir/.git" ]]; then
        git clone --depth 1 "$repo" "$dir"
    else
        info "Usando a cópia local em $dir sem atualizá-la."
    fi
}

install_aic_wifi_only() {
    local dir="$SRC_ROOT/aic8800d80"
    clone_or_update 'https://github.com/shenmintao/aic8800d80.git' "$dir"
    [[ -f "$dir/install.sh" && -f "$dir/dkms.conf" && -f "$dir/drivers/aic8800/Makefile" ]] || die 'a estrutura do driver AIC mudou; parei antes de instalar para revisar as alterações.'

    # Upstream also builds an optional Bluetooth quirk. This profile deliberately
    # builds only the AIC Wi-Fi and firmware-loader modules; btusb stays in-kernel.
    grep -q '^CONFIG_AIC_ZLP_QUIRK := m$' "$dir/drivers/aic8800/Makefile" || die 'não reconheci a configuração upstream do módulo AIC ZLP; nenhuma alteração foi aplicada.'
    grep -q '^BUILT_MODULE_NAME\[2\]="aic_zlp_quirk"$' "$dir/dkms.conf" || die 'não reconheci a configuração DKMS do quirk AIC; nenhuma alteração foi aplicada.'
    sed -i 's/^CONFIG_AIC_ZLP_QUIRK := m$/CONFIG_AIC_ZLP_QUIRK := n/' "$dir/drivers/aic8800/Makefile"
    sed -i '/^# Device-scoped standard-btusb ACL bulk TX ZLP quirk/,+3d' "$dir/dkms.conf"
    ! grep -q 'aic_zlp_quirk' "$dir/dkms.conf" || die 'não consegui excluir o módulo Bluetooth auxiliar do DKMS.'

    printf '\nO driver AIC compila aic8800_fdrv e aic_load_fw (este último carrega firmware necessário ao combo).\n'
    printf 'O módulo HCI Bluetooth permanece o btusb do kernel.\n\n'
    read -r -p 'Digite INSTALAR para baixar e instalar o perfil Wi-Fi AIC? ' answer
    [[ "$answer" == INSTALAR ]] || die 'instalação cancelada sem alterar o sistema.'
    root_run "$dir/install.sh"
}

kernel_version_num() {
    local version
    version="$(uname -r | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
    printf '%s' "$version"
}

version_at_least() {
    [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

install_realtek_profile() {
    local profile="$1" kernel repo dir minimum maximum
    kernel="$(kernel_version_num)"
    case "$profile" in
        rtl8812au)
            # The kernel driver is preferred from 6.14. Upstream DKMS support is
            # documented through kernel 7.0; stop beyond that instead of forcing it.
            if version_at_least "$kernel" 6.14; then
                info "Kernel $kernel já está na faixa com driver nativo rtw88 para RTL8812AU; nenhuma compilação externa."
                return 0
            fi
            if version_at_least "$kernel" 7.1; then
                die "o driver externo RTL8812AU declara suporte até kernel 7.0; este kernel é $kernel."
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
            if version_at_least "$kernel" 6.15; then
                die "não vou forçar o driver externo 88x2bu neste kernel; confira o suporte nativo rtw88 da sua distro."
            fi
            repo='https://github.com/morrownr/88x2bu-20210702.git'
            dir="$SRC_ROOT/88x2bu-20210702"
            ;;
        *) die "perfil Realtek desconhecido: $profile" ;;
    esac
    clone_or_update "$repo" "$dir"
    [[ -x "$dir/install-driver.sh" ]] || die "o instalador upstream não foi encontrado em $dir."
    read -r -p "Digite INSTALAR para executar o instalador upstream Wi-Fi ($profile)? " answer
    [[ "$answer" == INSTALAR ]] || die 'instalação cancelada.'
    root_run "$dir/install-driver.sh" NoPrompt
}

install_selected_wifi() {
    [[ -n "$SELECTED" ]] || { info 'Nenhum perfil externo selecionado; preservando os drivers de Wi-Fi presentes.'; return 0; }
    local profile id dev product answer
    IFS='|' read -r profile id dev product <<< "$SELECTED"
    info "Perfil identificado: $profile ($id, $product)."
    printf 'Os instaladores externos alteram módulos do kernel e podem exigir reinicialização.\n'
    read -r -p 'Deseja continuar? [s/N] ' answer
    [[ "$answer" =~ ^[sS]([iI][mM])?$ ]] || { info 'Instalação Wi-Fi cancelada.'; return 0; }
    install_build_dependencies
    case "$profile" in
        aic8800) install_aic_wifi_only ;;
        rtl8812au|rtl88x2bu) install_realtek_profile "$profile" ;;
    esac
}

apply_btusb_power_rule() {
    local tmp module_file
    if ! modinfo btusb >/dev/null 2>&1; then
        warn 'módulo btusb não encontrado; não criei a regra de autosuspend.'
        return 0
    fi
    module_file="$(modinfo -F filename btusb 2>/dev/null || true)"
    if [[ "$module_file" == '(builtin)' ]]; then
        warn 'btusb está compilado dentro do kernel; opções em modprobe.d não se aplicam a ele.'
        return 0
    fi
    tmp="$(mktemp)"
    printf 'options btusb enable_autosuspend=0\n' > "$tmp"
    if [[ -e "$BTUSB_CONF" ]]; then
        root_run cp -a "$BTUSB_CONF" "${BTUSB_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    fi
    root_run install -D -m 0644 "$tmp" "$BTUSB_CONF"
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
    read -r -p 'Impedir troca automática de A2DP para HSP/HFP quando um app usa o microfone? [s/N] ' choice
    [[ "$choice" =~ ^[sS]([iI][mM])?$ ]] || return 0
    config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d"
    config_file="$config_dir/51-bluetooth-autoswitch.conf"
    mkdir -p "$config_dir"
    if [[ -e "$config_file" ]]; then
        cp -a "$config_file" "${config_file}.bak.$(date +%Y%m%d%H%M%S)"
    fi
    cat > "$config_file" <<'EOF'
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
        root_run rc-update add bluetooth default
        root_run rc-service bluetooth start || root_run rc-service bluetooth restart
    else
        warn 'não reconheci systemd/OpenRC; não alterei o serviço Bluetooth.'
    fi
}

reload_btusb() {
    local answer connected
    [[ -n "$INIT_KIND" && -x "$(command -v bluetoothctl 2>/dev/null || true)" ]] || return 0
    connected="$(bluetoothctl devices Connected 2>/dev/null || true)"
    if [[ -n "$connected" ]]; then
        printf '\nDispositivos Bluetooth conectados:\n%s\n' "$connected"
        warn 'recarregar btusb desconectará esses dispositivos.'
    fi
    read -r -p 'Recarregar btusb agora? [s/N] ' answer
    [[ "$answer" =~ ^[sS]([iI][mM])?$ ]] || { info 'módulo será aplicado no próximo boot.'; return 0; }
    if [[ "$INIT_KIND" == systemd ]]; then
        root_run systemctl stop bluetooth.service
    else
        root_run rc-service bluetooth stop
    fi
    if root_run modprobe -r btusb; then
        root_run modprobe btusb
    else
        warn 'btusb está em uso e não pôde ser descarregado; reinicie o sistema para aplicar a opção.'
    fi
    if [[ "$INIT_KIND" == systemd ]]; then
        root_run systemctl start bluetooth.service
    else
        root_run rc-service bluetooth start
    fi
    bluetoothctl power on 2>&1 || true
}

show_final_status() {
    printf '\n── Estado final ──\n'
    printf 'Módulo btusb: '
    modinfo -F filename btusb 2>/dev/null || true
    printf '\nMódulos Wi-Fi AIC/Realtek presentes:\n'
    lsmod | grep -E '^(aic8800_fdrv|aic_load_fw|8812au|88x2bu|rtw88)' || printf '  nenhum\n'
    printf '\nControlador Bluetooth:\n'
    bluetoothctl list 2>&1 || true
    printf '\nRFKill:\n'
    rfkill list 2>&1 || true
    printf '\nInterfaces Wi-Fi:\n'
    iw dev 2>&1 || true
}

main() {
    local answer
    (( EUID != 0 )) || die 'rode como usuário normal; o aplicativo pedirá elevação quando necessário.'
    print_header
    printf '\nBluetooth é gerenciado pelo kernel (btusb e módulos auxiliares nativos) + BlueZ.\n'
    printf 'Este aplicativo nunca compila um driver HCI Bluetooth externo.\n'
    show_devices_and_select_profile
    install_selected_wifi

    read -r -p '\nAplicar configuração de estabilidade do btusb e liberar rfkill? [s/N] ' answer
    if [[ "$answer" =~ ^[sS]([iI][mM])?$ ]]; then
        apply_btusb_power_rule
        refresh_initramfs
        root_run rfkill unblock all || true
        apply_wireplumber_rule
        start_bluetooth_service
        reload_btusb
    else
        info 'ajustes globais de Bluetooth cancelados.'
    fi
    show_final_status
    printf '\nConcluído. Reinicie se o kernel ou o módulo não refletir as alterações.\n'
}

main "$@"
