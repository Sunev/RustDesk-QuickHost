# Compatibility Notes

RustDesk QuickHost focuses on the host-side remote support scenario.

This project is designed as a lightweight native C++ Win32 host-only client for Windows XP / 7 / 10 / 11. It is intentionally smaller than the full RustDesk client and does not aim to provide controller-side features.

## Scope

Included focus:

- Host-only remote support workflow
- ID and password display
- Fixed password support
- Optional random one-time password behavior
- System tray resident mode
- Auto start with Windows
- INI-based configuration
- Custom RustDesk server settings
- Self-hosted server configuration
- Built-in Traditional Chinese and English templates
- Custom `.txt` language files

Not the main focus:

- Full RustDesk desktop client replacement
- Controller-side operation
- File transfer
- Printing
- Non-minimal management features

## Runtime Files

On first run, the program generates these files beside the executable:

```text
rustdesk_cpp_host.ini
en.txt
tw.txt
```

The generated INI file can be edited to use official RustDesk public servers or a private self-hosted RustDesk server.
