"""Regression checks with fake sysfs and commands; never install or reload drivers."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'wifi-bluetooth-universal.sh'


class HelperTests(unittest.TestCase):
    def run_bash(self, body, stdin=''):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                ['bash', '-c', f'source {shlex.quote(str(SCRIPT))}\n'
                 'SYS_ROOT="$TEST_TMP/sys"\nMODULES_ROOT="$TEST_TMP/modules"\n'
                 'mkdir -p "$SYS_ROOT" "$MODULES_ROOT"\n' + body],
                input=stdin, text=True, capture_output=True,
                env={**os.environ, 'TEST_TMP': directory}, timeout=15)
        return result

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_no_fake_driver_from_absent_symlink(self):
        self.assert_ok(self.run_bash('''
mkdir -p "$SYS_ROOT/bus/usb/devices/1-1:1.0"
printf ff > "$SYS_ROOT/bus/usb/devices/1-1:1.0/bInterfaceClass"
if device_wifi_driver "$SYS_ROOT/bus/usb/devices/1-1"; then exit 9; fi
'''))

    def test_bluetooth_binding_is_not_wifi(self):
        self.assert_ok(self.run_bash('''
mkdir -p "$SYS_ROOT/bus/usb/devices/1-1:1.0" "$SYS_ROOT/drivers/btusb"
printf e0 > "$SYS_ROOT/bus/usb/devices/1-1:1.0/bInterfaceClass"
ln -s "$SYS_ROOT/drivers/btusb" "$SYS_ROOT/bus/usb/devices/1-1:1.0/driver"
if device_wifi_driver "$SYS_ROOT/bus/usb/devices/1-1"; then exit 9; fi
'''))

    def test_bound_wifi_detected(self):
        r = self.run_bash('''
mkdir -p "$SYS_ROOT/bus/usb/devices/1-1:1.0" "$SYS_ROOT/drivers/rtw88"
printf ff > "$SYS_ROOT/bus/usb/devices/1-1:1.0/bInterfaceClass"
ln -s "$SYS_ROOT/drivers/rtw88" "$SYS_ROOT/bus/usb/devices/1-1:1.0/driver"
device_wifi_driver "$SYS_ROOT/bus/usb/devices/1-1"
''')
        self.assert_ok(r)
        self.assertEqual(r.stdout, 'rtw88')

    def test_secureboot_efivar_payload(self):
        self.assert_ok(self.run_bash('''
mokutil() { return 1; }
mkdir -p "$SYS_ROOT/firmware/efi/efivars"
printf '\\007\\000\\000\\000\\001' > "$SYS_ROOT/firmware/efi/efivars/SecureBoot-test"
detect_secure_boot
[[ "$SECURE_BOOT" == enabled ]]
printf '\\007\\000\\000\\000\\000' > "$SYS_ROOT/firmware/efi/efivars/SecureBoot-test"
detect_secure_boot
[[ "$SECURE_BOOT" == disabled ]]
'''))

    def test_unknown_efi_and_bios(self):
        self.assert_ok(self.run_bash('''
mokutil() { return 1; }
detect_secure_boot
[[ "$SECURE_BOOT" == not-uefi ]]
mkdir -p "$SYS_ROOT/firmware/efi"
detect_secure_boot
[[ "$SECURE_BOOT" == unknown ]]
'''))

    def test_secureboot_and_lockdown_require_opt_in(self):
        for state, lockdown, enforcement in [('enabled', '[none]', 'N'),
                                             ('unknown', '[none]', 'N'),
                                             ('disabled', '[integrity]', 'N'),
                                             ('disabled', '[none]', 'Y')]:
            with self.subTest(state=state, lockdown=lockdown, enforce=enforcement):
                self.assert_ok(self.run_bash(f'''
detect_secure_boot() {{ SECURE_BOOT={state}; }}
mkdir -p "$SYS_ROOT/kernel/security" "$SYS_ROOT/module/module/parameters"
printf '%s' {shlex.quote(lockdown)} > "$SYS_ROOT/kernel/security/lockdown"
printf '%s' {enforcement} > "$SYS_ROOT/module/module/parameters/sig_enforce"
if external_module_guard; then exit 9; fi
''', '\n'))

    def test_native_candidates_all_buses_exclude_external_and_nonwifi(self):
        r = self.run_bash('''
for p in usb/devices/1-1:1.0 pci/devices/0000:01:00.0 sdio/devices/mmc1:1; do
    mkdir -p "$SYS_ROOT/bus/$p"
    printf alias > "$SYS_ROOT/bus/$p/modalias"
done
printf ff > "$SYS_ROOT/bus/usb/devices/1-1:1.0/bInterfaceClass"
printf 0x028000 > "$SYS_ROOT/bus/pci/devices/0000:01:00.0/class"
modprobe() { printf 'native\nfrontend\nexternal\nnonwifi\n'; }
modinfo() {
    case "$2:$3" in
        intree:external) printf N;;
        intree:*) printf Y;;
        depends:native) printf cfg80211;;
        filename:frontend) printf /lib/modules/test/kernel/drivers/net/wireless/realtek/rtw88/rtw88_8812au.ko;;
    esac
}
native_candidates
''')
        self.assert_ok(r)
        self.assertEqual(r.stdout.splitlines(), ['native', 'frontend'] * 3)

    def test_bluetooth_service_restored_after_load_failure(self):
        r = self.run_bash('''
INIT_KIND=sysv
bluetoothctl() { :; }
root_run() {
    printf '%s\n' "$*"
    [[ "$*" != 'modprobe btusb' ]]
}
optional() { :; }
if reload_btusb; then exit 9; fi
''', 's\n')
        self.assert_ok(r)
        self.assertIn('service bluetooth stop', r.stdout)
        self.assertIn('service bluetooth start', r.stdout)

    def test_aic_patch_can_be_applied_twice(self):
        self.assert_ok(self.run_bash('''
SRC_ROOT="$TEST_TMP/src"
dir="$SRC_ROOT/aic8800d80"
mkdir -p "$dir/drivers/aic8800" "$dir/.git"
printf '#!/bin/bash\n' > "$dir/install.sh"
printf 'CONFIG_AIC_ZLP_QUIRK := m\n' > "$dir/drivers/aic8800/Makefile"
cat > "$dir/dkms.conf" <<'EOF'
BUILT_MODULE_NAME[0]="aic8800_fdrv"
BUILT_MODULE_NAME[1]="aic_load_fw"
# Device-scoped standard-btusb ACL bulk TX ZLP quirk (368b:8d81 only)
BUILT_MODULE_NAME[2]="aic_zlp_quirk"
BUILT_MODULE_LOCATION[2]="drivers/aic8800/aic_zlp_quirk"
DEST_MODULE_LOCATION[2]="/updates/dkms"
AUTOINSTALL="yes"
EOF
clone_or_update() { :; }
root_run() { :; }
install_aic_wifi_only <<< INSTALAR
install_aic_wifi_only <<< INSTALAR
! grep -q aic_zlp_quirk "$dir/dkms.conf"
grep -q '^AUTOINSTALL=' "$dir/dkms.conf"
'''))

    def test_aic_structure_failure_is_contained(self):
        self.assert_ok(self.run_bash('''
SRC_ROOT="$TEST_TMP/empty"
clone_or_update() { :; }
if install_aic_wifi_only; then exit 9; fi
printf 'still running'
'''))

    def test_arch_headers_follow_pkgbase(self):
        r = self.run_bash('''
mutable_system() { :; }
uname() { printf 'test-kernel'; }
mkdir -p "$MODULES_ROOT/test-kernel"
printf linux-zen > "$MODULES_ROOT/test-kernel/pkgbase"
pacman() { :; }
root_run() { printf '%s\n' "$*"; return 1; }
if install_build_dependencies; then exit 9; fi
''')
        self.assert_ok(r)
        self.assertIn('linux-zen-headers', r.stdout)
        self.assertNotIn('linux-cachyos-headers', r.stdout)

    def test_report_private_and_no_overwrite(self):
        self.assert_ok(self.run_bash('''
diagnose() { printf 'fixture report'; }
main --report "$TEST_TMP/report"
[[ "$(stat -c %a "$TEST_TMP/report")" == 600 ]]
if (main --report "$TEST_TMP/report"); then exit 9; fi
[[ "$(cat "$TEST_TMP/report")" == 'fixture report' ]]
'''))

    def test_mok_decline_never_imports(self):
        self.assert_ok(self.run_bash('''
cert="$TEST_TMP/cert.der"
printf fixture > "$cert"
mokutil() { return 1; }
root_run() { exit 9; }
enroll_mok "$cert"
''', '\n'))

    def test_mok_already_enrolled_never_imports(self):
        self.assert_ok(self.run_bash('''
cert="$TEST_TMP/cert.der"
printf fixture > "$cert"
mokutil() { [[ "$1" == --test-key ]]; }
root_run() { exit 9; }
enroll_mok "$cert"
'''))

    def test_mok_confirm_imports_only_public_certificate(self):
        r = self.run_bash('''
cert="$TEST_TMP/cert.der"
printf fixture > "$cert"
mokutil() { return 1; }
root_run() { printf '%s\\n' "$*"; }
enroll_mok "$cert"
''', 's\n')
        self.assert_ok(r)
        self.assertIn('mokutil --import ', r.stdout)
        self.assertIn('cadastro ainda está pendente', r.stdout)

    def test_modern_realtek_skips_build_dependencies(self):
        self.assert_ok(self.run_bash('''
SELECTED='rtl8812au|0bda:8812|1-1|fixture'
modprobe() { :; }
modinfo() { :; }
uname() { printf '6.14.1-custom'; }
install_build_dependencies() { exit 9; }
install_selected_wifi
''', 's\n'))

    def test_noninteractive_requires_diagnose(self):
        r = subprocess.run(['bash', str(SCRIPT)], input='', text=True,
                           capture_output=True, timeout=10)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('--diagnose', r.stderr)

    def test_unknown_ids_never_install(self):
        self.assert_ok(self.run_bash('''
if classify_wifi_id dead:beef; then exit 9; fi
[[ "$(classify_wifi_id 0bda:8812)" == rtl8812au ]]
'''))


if __name__ == '__main__':
    unittest.main()
