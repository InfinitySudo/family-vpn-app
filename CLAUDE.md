# Окно — семейное VPN-приложение (форк Hiddify)

Одна кнопка для родных в РФ. Flutter + hiddify-core (sing-box). Репо `InfinitySudo/family-vpn-app`,
серверная часть — `InfinitySudo/okno-infra` (локально `/root/okno-infra`, симлинки `/root/okno-fleet`,
`/root/okno-bot`, `/root/family-vpn-server`).

## Где что
- `lib/features/family/family_profile.dart` — зашитая подписка, перебор адресов (зеркала флота → GitHub raw → Рига).
- `lib/features/family/country/` — **выбор страны**: `okno_country.dart` (справочник стран, флаг/город/достопримечательность/AI-доступность, разбор тега `Окно-LV-1-Reality`), `okno_country_notifier.dart` (пref `okno_country`, список стран от ядра или из конфига + TCP-проба без VPN, сторож страны), `country_picker.dart` (карточка на главном, нижний лист, флаг с картинкой по наведению/долгому тапу).
- `assets/landmarks/<cc>.jpg` — фото достопримечательностей (Wikimedia Commons, лицензии в `credits.json`).
- Главный экран `lib/features/home/widget/home_page.dart`: кнопка «Меню» → `/settings` (долгий тап по заголовку тоже работает).
- Цвета/кнопка подключения — `connection_button.dart`.

## Правила
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
**Android (1.0.12): обновление внутри приложения** — `installAndroid`: APK качается в `filesDir/updates/` (не в «Загрузки», прошлые файлы удаляются, прогресс на плашке), затем `OknoChannel.install_apk` → `OknoFileProvider` (`${applicationId}.okno.fileprovider`, `res/xml/okno_file_paths.xml`) → системный установщик (ACTION_VIEW package-archive). Android 8+: без разрешения «установка из этого источника» открывается его экран, потом нажать «Обновить» ещё раз. Файл текущей версии чистится при следующем запуске. iOS — TestFlight, Mac/Win — установщик через браузер, как раньше.

## ⚠ Адрес подписки в сборках
GitHub Actions берёт `vars.SUBSCRIPTION_URL`, Codemagic (iOS/macOS) — переменную группы `okno` в своём кабинете (API `/apps/<id>/variables`, менять = DELETE + POST, PUT не работает). 06.09 в Codemagic лежал `217.60.2.82:2096/sub/…` (подписка самого x-ui: один узел, без стран и HY2) → на iPhone/Mac «только Латвия». Оба должны быть = агрегатор `http://46.8.238.102:2097/okno/38fa3eb3adb9258d`.

## Проверка ДО сборки (с 06.09 — правило Артёма: «сначала смотрю, потом выкатываем»)
- Flutter стоит на VPS (`/opt/flutter`, PATH): `flutter analyze` ловит ошибки компиляции за секунды — гонять ПЕРЕД каждым коммитом.
- Linux-сборка локально (`make linux-amd64-prepare && flutter build linux`) + Xvfb → скриншоты экранов (`scripts/preview.sh`) → Артёму в TG/чат. UI-правки показывать картинкой до CI.
- CI-сборки = **бета** (prerelease, приложения их не видят). Сторож шлёт в TG ссылки на APK/dmg/TestFlight. После «выкатываем» → `bash /root/okno-infra/server/okno_release_go.sh vX.Y.Z-okno` (latest).

## Релиз
1. `pubspec.yaml` version bump → commit → push → тег `vX.Y.Z-okno` (push тега запускает release.yml; либо `gh workflow run release.yml -f tag=…`).
2. Сторож `release_watch.py` (запуск ТОЛЬКО с `--setenv=GITHUB_TOKEN="$GITHUB_TOKEN"`) оставляет релиз бетой; latest — `okno_release_go.sh` по слову Артёма (или `OKNO_AUTO_LATEST=1` сторожу).
3. iOS/macOS — Codemagic (appId `6a99eb3c3d7334c2a56148d5`, workflows `ios-testflight`, `macos-notarize`), запуск POST /builds по API; Mac-dmg из Codemagic заливать в релиз поверх GH-сборки (ядро 4.1.0).
4. Страница загрузки для родных ведёт на `releases/latest`.
