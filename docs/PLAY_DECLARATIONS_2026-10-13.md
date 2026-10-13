# Окно → Google Play: декларации для закрытого теста (13.10.2026)

С AAB **1.0.27 (vc 28)** в манифесте Play-сборки больше нет `REQUEST_INSTALL_PACKAGES` и `QUERY_ALL_PACKAGES`
(`scripts/play_manifest.py strip` в `make android-aab-release`), поэтому две ошибки «permissions that haven't been
declared» исчезают сами. Остаётся одна форма — **Foreground service**.

## Policy → App content → Foreground service permissions
- **Does your app use any foreground service permissions?** → Yes
- **Foreground service types used:** `Special use` (FOREGROUND_SERVICE_SPECIAL_USE)
- **Describe the functionality (EN):**

  Okno is a family VPN app. The foreground service is the VpnService tunnel itself: while the user has the VPN switched on,
  the service keeps the encrypted tunnel open in the background and shows a persistent notification with the connection
  status and a "Disconnect" action. Android requires a running foreground service for a VpnService to keep the tunnel alive;
  there is no dedicated foreground service type for VPN, so the service is declared as `specialUse` with the subtype
  `vpn` (android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE = "vpn"). The service starts only after the user taps "Connect" and
  grants the system VPN consent, and it stops when the user taps "Disconnect".

- **Video (обязательно для Special use):** 20–40 с с телефона: открыть Окно → нажать «Подключить» → системный диалог VPN
  → «OK» → показать уведомление в шторке (значок ключа VPN + уведомление Окна) → нажать «Отключить». Залить на YouTube
  как **Unlisted**, вставить ссылку.

## Sensitive permissions (если форма всё ещё показывает)
После загрузки vc 28 в релиз старый AAB 27 из релиза убрать (Release → App bundles → удалить 27), тогда проверка идёт по
новому манифесту. Если Play всё же спросит про `QUERY_ALL_PACKAGES` — ответ «не используется» (в vc 28 его нет).

## Что НЕ менялось
`CAMERA` (сканер QR) и `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` деклараций не требуют. Самообновление и оплата в боте в
Play-сборке выключены (`kOknoPlayBuild`).
