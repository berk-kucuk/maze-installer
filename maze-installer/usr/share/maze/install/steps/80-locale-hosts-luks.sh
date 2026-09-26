# 5c) Locale: make date/number formats follow the LANGUAGE -----------------
# Calamares can set the FORMAT locales (LC_TIME, LC_NUMERIC, ...) to the install
# LOCATION's country (e.g. Turkey -> tr_TR) even when the chosen language is
# English — so the clock/date show up in Turkish on an "English" system. Align
# everything to LANG: drop the LC_* overrides so the whole locale follows the
# language (the same clean setup a stock English machine has). Timezone is
# separate (/etc/localtime) and is left as the user chose it.
lconf="${TARGET}/etc/locale.conf"
if [[ -f "${lconf}" ]] && grep -q '^LANG=' "${lconf}"; then
    _lang="$(sed -n 's/^LANG=//p' "${lconf}" | tr -d '"' | head -1)"
    log "Aligning format locales to the language (${_lang})"
    sed -i '/^LC_/d' "${lconf}"
fi

# 5d) /etc/hosts: map the hostname so name resolution is clean (and lynis
# NAME-4404 stops warning). Add the loopback hostname line if missing.
_hn="$(cat "${TARGET}/etc/hostname" 2>/dev/null | head -1)"
if [[ -n "${_hn}" ]]; then
    [[ -f "${TARGET}/etc/hosts" ]] || printf '127.0.0.1\tlocalhost\n::1\t\tlocalhost\n' > "${TARGET}/etc/hosts"
    grep -qE "[[:space:]]${_hn}([[:space:]]|\$)" "${TARGET}/etc/hosts" 2>/dev/null \
        || printf '127.0.1.1\t%s.localdomain %s\n' "${_hn}" "${_hn}" >> "${TARGET}/etc/hosts"
fi

# 5c) Encrypted root: enable TRIM/discard pass-through on the LUKS layer.
# Without this, fstrim / fstrim.timer cannot reach the SSD — dm-crypt silently
# drops discard requests — so on DRAM-less QLC drives the FTL free-block pool is
# never reclaimed and large writes collapse into multi-second I/O stalls / full
# freezes that only clear on reboot. Persisting the flag into the LUKS2 header
# makes every unlock (initramfs `encrypt` hook, crypttab, manual) honour it,
# independent of bootloader or kernel cmdline. Runs live (dontChroot) against the
# already-open target mapper; refresh re-uses the in-kernel key (no passphrase).
_root_src="$(findmnt -no SOURCE "${TARGET}" 2>/dev/null | sed 's/\[.*\]//')"
if [[ "${_root_src}" == /dev/mapper/* ]]; then
    _luks_name="${_root_src##*/}"
    if cryptsetup status "${_luks_name}" >/dev/null 2>&1; then
        if cryptsetup --allow-discards --persistent refresh "${_luks_name}" >/dev/null 2>&1; then
            log "LUKS: persisted allow-discards on ${_luks_name} (TRIM pass-through enabled)"
        else
            # Expected, and not a bug: per cryptsetup-refresh(8) the "mandatory
            # parameters are identical to those of an open action", i.e. refresh
            # wants the passphrase, which the installer deliberately does not
            # keep (and --persistent is LUKS2-only). TRIM is already handled by
            # the allow-discards flag written onto the kernel cmdline earlier, so
            # this is only the belt-and-braces header flag — report accordingly
            # instead of raising an alarm about something that is working.
            if [[ "${MAZE_LUKS_DISCARD_CMDLINE:-0}" -eq 1 ]]; then
                log "LUKS: header flag not persisted on ${_luks_name} (needs the passphrase) — not a problem, TRIM comes from the cmdline allow-discards."
                log "      To also store it in the LUKS2 header, run once on the installed system:"
                log "          sudo cryptsetup --allow-discards --persistent refresh ${_luks_name}"
            else
                warn "LUKS: TRIM pass-through is NOT enabled on ${_luks_name} — the cmdline route did not apply either."
                warn "      Run this once on the installed system:"
                warn "          sudo cryptsetup --allow-discards --persistent refresh ${_luks_name}"
                warn "      Verify with: sudo cryptsetup luksDump <device> | grep -i flags"
            fi
        fi
    fi
fi

