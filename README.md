# EUSign GPO Auto-Deploy

Автоматичне розгортання [EUSign](https://iit.com.ua) (IIT Користувач ЦСК-1) у домені через GPO.

## Архітектура

- **`Update-EUSign.ps1`** — на DC, Scheduled Task щодня о 06:00. Качає актуальний інсталятор з iit.com.ua на файлову шару.
- **`EUSign.ps1`** — на клієнтах, GPO Startup Script. Порівнює версії й тихо встановлює.

## Update-EUSign.ps1

Завантажує `EUSignWebInstall.exe` з iit.com.ua, валідує його й атомарно оновлює файл на шарі.

### Що робить

1. Читає поточну версію інсталятора з шари
2. Завантажує свіжий з iit.com.ua (з retry)
3. Перевіряє розмір (≥ 1 MB) та Authenticode-підпис
4. Порівнює версії — якщо актуальна, виходить
5. Атомарно замінює файл + пише SHA256 поряд
6. Логує в `Logs\DC_Update.log` (ротація 5 MB × 5 бекапів)

### Запуск

```powershell
# Production (від Scheduled Task / SYSTEM)
powershell.exe -ExecutionPolicy Bypass -File "C:\tmp\Scripts\EUSign\Update-EUSign.ps1"

# Тестовий прогон без змін
.\Update-EUSign.ps1 -WhatIf

# З виводом у консоль
.\Update-EUSign.ps1 -Verbose
```

### Параметри

| Параметр | За замовчуванням | Опис |
|---|---|---|
| `-Url` | `https://iit.com.ua/download/productfiles/EUSignWebInstall.exe` | URL інсталятора |
| `-ShareDir` | `C:\tmp\Scripts\EUSign` | Локальний шлях до шари |
| `-MinFileSize` | `1MB` | Мінімальний розмір завантаженого файлу |
| `-MaxRetries` | `3` | Кількість спроб завантаження |
| `-RetryDelay` | `15` | Базова затримка між спробами (сек, з backoff) |
| `-MaxLogSize` | `5MB` | Розмір для ротації логу |
| `-KeepBackups` | `5` | Кількість архівних логів |

### Exit codes

| Код | Значення |
|---|---|
| `0` | OK / вже актуальна версія |
| `1` | Помилка завантаження |
| `2` | Помилка валідації (підпис, розмір, версія) |
| `3` | Необроблена помилка |

### Scheduled Task

| Параметр | Значення |
|---|---|
| Назва | `EUSign Update` |
| Від | `SYSTEM` |
| Тригер | Щодня о 06:00 |
| Команда | `powershell.exe -ExecutionPolicy Bypass -File "C:\doctors-data\Scripts\EUSign\Update-EUSign.ps1"` |

| або з вказанням папки
  powershell.exe -ExecutionPolicy Bypass -File "D:\Shares\EUSign\Update-EUSign.ps1" -ShareDir "D:\Shares\EUSign"


### Логи

```powershell
Get-Content 'C:\tmp\Scripts\EUSign\Logs\DC_Update.log' -Tail 50
```

## License

Internal use only.
