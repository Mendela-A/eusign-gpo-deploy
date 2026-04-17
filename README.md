# EUSign GPO Auto-Deploy

Два PowerShell-скрипти для автоматичного розгортання [EUSign](https://iit.com.ua)
(IIT Користувач ЦСК-1) у Windows-домені через GPO.

## Як це працює

```
iit.com.ua ──► [DC] Update-EUSign.ps1 ──► \\share\EUSign\ ──► [клієнт] EUSign.ps1 ──► install
     (HTTPS)        щодня о 06:00             exe + .sha256       GPO Startup
```

- **`Update-EUSign.ps1`** — на контролері домену, Scheduled Task. Раз на добу
  качає свіжий `EUSignWebInstall.exe` з iit.com.ua, валідує підпис та розмір,
  атомарно кладе файл на файлову шару разом з `.sha256`.
- **`EUSign.ps1`** — на клієнтах, GPO Startup Script. Копіює інсталятор із шари,
  звіряє SHA256, порівнює версії, тихо встановлює якщо треба.

## Налаштування

### 1. DC: Update-EUSign.ps1

Покладіть скрипт куди зручно (напр. `C:\Scripts\EUSign\Update-EUSign.ps1`).
Створіть Scheduled Task від `SYSTEM`:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\EUSign\Update-EUSign.ps1" -ShareDir "C:\Shares\EUSign"
```

Параметри (всі опційні):

| Параметр | За замовчуванням | Опис |
|---|---|---|
| `-Url` | `https://iit.com.ua/download/productfiles/EUSignWebInstall.exe` | URL інсталятора |
| `-ShareDir` | `C:\doctors-data\Scripts\EUSign` | Локальний шлях до шари |
| `-MinFileSize` | `1MB` | Мінімальний розмір exe |
| `-MaxRetries` | `3` | Спроб завантаження |
| `-RetryDelay` | `15` | Базова пауза між спробами (сек, з backoff) |
| `-MaxLogSize` | `5MB` | Поріг ротації логу |
| `-KeepBackups` | `5` | Архівних логів |

Exit codes: `0` OK, `1` download fail, `2` validation fail, `3` unhandled.

Логи: `{ShareDir}\Logs\DC_Update.log`.

### 2. Клієнти: EUSign.ps1

У `EUSign.ps1` один рядок під ваше середовище:

```powershell
$share = '\\dc-001\doctors-data\Scripts\EUSign'
```

Далі підключіть скрипт як **GPO → Computer Configuration → Policies →
Windows Settings → Scripts → Startup**.

Логи на клієнті: `C:\Windows\Temp\EUSign_<HOSTNAME>_<дата>.log`.

## Тестовий запуск

```powershell
# Dry-run на DC, без змін на шарі
.\Update-EUSign.ps1 -WhatIf -Verbose

# Ручний прогін на клієнті
powershell.exe -ExecutionPolicy Bypass -File .\EUSign.ps1
```

## License

MIT (див. [LICENSE](LICENSE)).
