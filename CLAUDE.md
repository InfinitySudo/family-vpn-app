# Окно — семейное VPN-приложение (форк Hiddify)

Одна кнопка для родных в РФ. Flutter + hiddify-core (sing-box). Репо `InfinitySudo/family-vpn-app`,
серверная часть — `InfinitySudo/okno-infra` (локально `/root/okno-infra`, симлинки `/root/okno-fleet`,
`/root/okno-bot`, `/root/family-vpn-server`).

## Где что
- `lib/features/family/family_profile.dart` — подписка: **самообновляемый список зеркал** (`okno_mirrors.json` на устройстве ← `<url>/mirrors` агрегатора после каждого удачного обращения) → зашитые `subscription_url` + `subscription_fallbacks` (СЕКРЕТЫ сборки: GH secret `SUBSCRIPTION_FALLBACKS`, Codemagic var группы okno; в репозитории адресов НЕТ) → GitHub raw. Отчёты о сбое шлются на те же адреса (`/okno/crash`).
- `lib/features/family/country/` — **выбор страны**: `okno_country.dart` (справочник стран, флаг/город/достопримечательность/AI-доступность, разбор тега `Окно-LV-1-Reality`), `okno_country_notifier.dart` (пref `okno_country`, список стран от ядра или из конфига + TCP-проба без VPN, сторож страны), `country_picker.dart` (карточка на главном, нижний лист, флаг с картинкой по наведению/долгому тапу).
- `assets/landmarks/<cc>.jpg` — фото достопримечательностей (Wikimedia Commons, лицензии в `credits.json`).
- Главный экран `lib/features/home/widget/home_page.dart`: кнопка «Меню» → `/settings` (долгий тап по заголовку тоже работает).
- Цвета/кнопка подключения — `connection_button.dart`.

## Правила
- **Правило Артёма (06.09): любая функция — сразу для ВСЕХ платформ** (Android, iPhone, Mac, Windows, Linux). Сделал для одной — не закончил.
- Строки семейной сборки — по-русски прямо в коде (локаль ru зашита), переводы Hiddify не трогаем.
- Без codegen: новые провайдеры — обычные `Provider/StreamProvider/FutureProvider`, а не `@riverpod` (build_runner в CI, локально Flutter нет).
- Стабильность страны важнее пары мс: сторож переключает узел только если текущий из другой страны или не отвечает.
- Тег узла со страной ставит агрегатор (`okno-infra/server/aggregator.py`, карта `fleet/okno_countries.txt`); старые теги `Окно-N-…` = LV.

## Сторож чужих VPN (1.0.11)
`lib/features/family/guard/okno_vpn_guard.dart` + `android/.../OknoChannel.kt` (каналы `com.hiddify.app/okno`, `…/okno.events`).
Android держит один туннель: старый клиент (Happ и т.п.) с автоподключением перехватывает его → `onRevoke` → раньше молча гасли («выкинуло»).
Теперь: проверка перед подключением (чужой туннель / чужой «постоянный VPN») → лист «Мешает другой VPN» (список VPN-приложений,
«Открыть»/«Удалить», «Настройки VPN»), `onRevoke` → событие в Dart + уведомление + тот же лист с «Подключить Окно»;
строка «Постоянный VPN» в настройках. Молча отобрать туннель назад нельзя (после prepare() чужого наше согласие отозвано) —
единственный 100%: пользователь назначает Окно «постоянным VPN». iOS: `okno_foreign_vpn` в MethodHandler.swift, On-Demand уже держит нашу конфигурацию.

## Обновления в приложении
`lib/features/family/update/okno_update.dart` — проверка последнего релиза GitHub при запуске и каждые 12 ч, плашка на главном + строка в настройках. Ссылка на файл по платформе из assets релиза (имена Okno-*.apk/.dmg/.exe/.AppImage — не переименовывать в build.yml).
**Android (1.0.12): обновление внутри приложения** — `installAndroid`: APK качается в `filesDir/updates/` (не в «Загрузки», прошлые файлы удаляются, прогресс на плашке), затем `OknoChannel.install_apk` → `OknoFileProvider` (`${applicationId}.okno.fileprovider`, `res/xml/okno_file_paths.xml`) → системный установщик (ACTION_VIEW package-archive). Android 8+: без разрешения «установка из этого источника» открывается его экран, потом нажать «Обновить» ещё раз. Файл текущей версии чистится при следующем запуске. **Mac:** dmg → hdiutil attach → подмена бандла по Platform.resolvedExecutable (mv в .old, ditto, xattr -dr quarantine) → `open -n` + exit; из /Volumes — просим перетащить в Программы. **Windows:** Setup.exe `/SILENT /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS`. **Linux:** AppImage подменяет `$APPIMAGE`. iOS — TestFlight (Apple).

## ⚠ Адрес подписки в сборках
GitHub Actions берёт `vars.SUBSCRIPTION_URL`, Codemagic (iOS/macOS) — переменную группы `okno` в своём кабинете (API `/apps/<id>/variables`, менять = DELETE + POST, PUT не работает). 06.09 в Codemagic лежал `217.60.2.82:2096/sub/…` (подписка самого x-ui: один узел, без стран и HY2) → на iPhone/Mac «только Латвия». Оба должны быть = агрегатор `http://46.8.238.102:2097/okno/38fa3eb3adb9258d`.

## Проверка ДО сборки (с 06.09 — правило Артёма: «сначала смотрю, потом выкатываем»)
- **Сборки CI — только по слову Артёма и одной пачкой.** Xcode Cloud (iOS) — 25 ч/мес бесплатно, Codemagic сгорел и не нужен → iOS собирать ТОЛЬКО под выкатывание. Правки проверять на dev-экране и `flutter analyze`, Android при нужде одной GH-сборкой.
- Flutter стоит на VPS (`/opt/flutter`, PATH): `flutter analyze` ловит ошибки компиляции за секунды — гонять ПЕРЕД каждым коммитом.
- Linux-сборка локально (`make linux-amd64-prepare && flutter build linux`) + Xvfb → скриншоты экранов (`scripts/preview.sh`) → Артёму в TG/чат. UI-правки показывать картинкой до CI.
- CI-сборки = **бета** (prerelease, приложения их не видят). Сторож шлёт в TG ссылки на APK/dmg/TestFlight. После «выкатываем» → `bash /root/okno-infra/server/okno_release_go.sh vX.Y.Z-okno` (latest).

## ⚠ Разрешения Android
Манифест ДОЛЖЕН содержать `ACCESS_NETWORK_STATE` и `ACCESS_WIFI_STATE`: ядро sing-box при настройке tun на Wi-Fi обращается к WifiService, без разрешения — FATAL «configure tun interface» → «Непредвиденный сбой»/вылет (06.09, нашли по скриншоту логов). При ребрендинге не трогать блок uses-permission.

## Подпись Android (с 1.0.19)
CI подписывает release только если есть секрет `ANDROID_SIGNING_KEY` (+ `_STORE_PASSWORD`, `_KEY_PASSWORD`, `_KEY_ALIAS`); без них — случайный debug-ключ на каждую сборку → «конфликтует с другим приложением» при установке поверх. Ключ: `/root/secrets/okno-release.jks` + `okno-release.env` (НЕ терять — иначе все пользователи переустанавливают). SHA-256 сертификата зашит в `okno_update.dart` (`releaseCertSha256`): старые debug-копии получают подсказку «удалите и поставьте заново».

## Релиз
1. `pubspec.yaml` version bump → commit → push → тег `vX.Y.Z-okno` (push тега запускает release.yml; либо `gh workflow run release.yml -f tag=…`).
2. Сторож `release_watch.py` (запуск ТОЛЬКО с `--setenv=GITHUB_TOKEN="$GITHUB_TOKEN"`) оставляет релиз бетой; latest — `okno_release_go.sh` по слову Артёма (или `OKNO_AUTO_LATEST=1` сторожу).
3. iOS — **Xcode Cloud** (с 08.09, Codemagic сгорел): `python3 scripts/xcode_cloud_workflow.py run` (воркфлоу «TestFlight (main)» `5C72425C-…`, ТОЛЬКО ручной старт, push в main минуты не жгёт) → архив → TestFlight, группа Internal получает сборку сама. Сборка ~10–15 мин, 25 ч/мес бесплатно. Перед сборкой поднять `version:` в pubspec (build number = CI_BUILD_NUMBER, Apple требует номер выше только внутри одной версии). `ios/ci_scripts/ci_post_clone.sh` ставит Flutter, качает HiddifyCore.xcframework, пишет Generated.xcconfig. Env `SUBSCRIPTION_URL/FALLBACKS` в Xcode Cloud через API не ставится → адрес агрегатора по умолчанию, фолбэки пустые (список зеркал приложение обновляет само). macOS-нотаризация через Xcode Cloud пока не настроена (нужен отдельный воркфлоу с `macos/Runner.xcworkspace`); Mac-dmg = GH-сборка.
   На Mac Артёма проект открывается `bash scripts/mac_bootstrap.sh` (клон по HTTPS, SSH-ключа нет) — нужно только для создания воркфлоу в Xcode.
4. Страница загрузки для родных ведёт на `releases/latest`.

## Личный ключ через бота (07.09) — путь к продажам
- `lib/features/family/access/okno_access.dart`: публичная сборка (в `subscription_url` только origin агрегатора, без `/okno/<id>`) → на главном экране «Получить доступ в Telegram»: приложение хранит `okno_pair.json` (код 10 + секрет 16 симв.), открывает `https://t.me/OKHO_VPN_BOT?start=p_<код>_<секрет>`, каждые 3 с опрашивает `<origin>/okno/pair/<код>?t=<секрет>` по `pairingBases()` (сохранённые зеркала + зашитые origin), при 200 → `saveKey()` → `okno_key.json` {sub, mirrors} → `ensureFamilyProfile`. На компьютере ещё QR той же ссылки.
- `familyBuild` (`subscription_url` содержит `/okno/`) — старое поведение, ключ зашит. Семейная сборка живёт, пока родные на общем ключе.
- `oknoAccess` (ValueNotifier: ok / needKey / expired / noServer) выставляет `ensureFamilyProfile`; агрегатор отвечает **402** для выключенного/истёкшего ключа → плашка `OknoAccessBanner` «Срок доступа закончился → Оплатить / Проверить» (и под профилем, и вместо него).
- Проверка на dev-экране: `OKNO_PUBLIC=1 bash /root/okno-infra/server/dev_run.sh start` (данные приложения `/root/.local/share/app.hiddify.com` перед этим убрать, иначе останется старый профиль).
- **Переключение публичных сборок** (по слову Артёма): GH `vars.SUBSCRIPTION_URL=http://46.8.238.102:2097`, secret `SUBSCRIPTION_FALLBACKS=http://151.242.69.245:2097;http://95.182.90.237:2097;http://217.60.2.82:2097`; в Codemagic то же для группы okno. Сервер: бот `/start p_…` (pair_start), агрегатор `/okno/pair`, зеркала проксируют pair и 402.

## Dev-экран (noVNC) — всегда последний код (08.09)
https://constantwrestling.cloud/okno-dev/vnc.html?autoconnect=1&path=okno-dev/websockify&resize=scale (логин okno, пароль /root/secrets/okno-dev-vnc.pass).
Приложение = `okno-dev-app.service` (`flutter run -d linux --pid-file /run/okno-dev.pid`, экран :99, адреса из /root/secrets/okno-dev.env,
лог `journalctl -u okno-dev-app`). Синхронизация с кодом — `/root/okno-infra/server/okno_dev_sync.sh` (таймер `okno-dev-sync` раз в минуту
+ `.git/hooks/post-commit`): любой коммит или правка в рабочем дереве → hot restart (SIGUSR2); pubspec/linux/assets/dependencies.properties →
полный перезапуск; файлы с `part '*.g.dart'` → build_runner, переводы → slang. Принудительно: `okno_dev_sync.sh full`.
Артёму про «старая версия на экране» напоминать не нужно — экран обновляется сам.
