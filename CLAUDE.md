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

## Обновления в приложении
`lib/features/family/update/okno_update.dart` — проверка последнего релиза GitHub при запуске и каждые 12 ч, плашка на главном + строка в настройках. Ссылка на файл по платформе из assets релиза (имена Okno-*.apk/.dmg/.exe/.AppImage — не переименовывать в build.yml).

## Релиз
1. `pubspec.yaml` version bump → commit → push → тег `vX.Y.Z-okno` (push тега запускает release.yml; либо `gh workflow run release.yml -f tag=…`).
2. После релиза: `gh release edit vX.Y.Z-okno --prerelease=false --latest`.
3. iOS/macOS — Codemagic (appId `6a99eb3c3d7334c2a56148d5`, workflows `ios-testflight`, `macos-notarize`), запуск POST /builds по API; Mac-dmg из Codemagic заливать в релиз поверх GH-сборки (ядро 4.1.0).
4. Страница загрузки для родных ведёт на `releases/latest`.
