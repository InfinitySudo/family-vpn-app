#!/bin/sh
# Xcode Cloud: запускается сразу после клона, до разрешения зависимостей и xcodebuild.
# Место важно: ios/ci_scripts/ рядом с Runner.xcworkspace.
# Ставит Flutter, качает hiddify-core.xcframework, генерирует код, пишет
# ios/Flutter/Generated.xcconfig с dart-define (публичная сборка: subscription_url = адрес
# агрегатора, ключ приложение берёт через бота) и делает pod install. Подпись — Xcode Cloud.
set -eu
cd "$CI_PRIMARY_REPOSITORY_PATH"

FLUTTER_VERSION="$(sed -n 's/^ *FLUTTER_VERSION: *'"'"'\([^'"'"']*\)'"'"'.*/\1/p' .github/workflows/build.yml | head -1)"
FLUTTER_VERSION="${FLUTTER_VERSION:-3.38.5}"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
if ! command -v pod >/dev/null 2>&1; then brew install cocoapods; fi

FLUTTER_HOME="$HOME/flutter"
if [ ! -x "$FLUTTER_HOME/bin/flutter" ]; then
  git clone --depth 1 -b "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$FLUTTER_HOME"
fi
export PATH="$FLUTTER_HOME/bin:$PATH"
flutter config --no-analytics >/dev/null 2>&1 || true
flutter --version

# hiddify-core для iOS (как шаг «Fetch hiddify-core iOS framework» в codemagic.yaml)
CORE_VERSION="$(grep core.version dependencies.properties | cut -d= -f2 | tr -d '[:space:]')"
mkdir -p ios/Frameworks && rm -rf ios/Frameworks/HiddifyCore.xcframework
curl -fL "https://github.com/hiddify/hiddify-core/releases/download/v${CORE_VERSION}/hiddify-lib-ios.tar.gz" | tar xz -C ios/Frameworks
ls ios/Frameworks

flutter pub get
dart run build_runner build --delete-conflicting-outputs
dart run slang

# Адреса подписки: переменные окружения воркфлоу Xcode Cloud (SUBSCRIPTION_URL, SUBSCRIPTION_FALLBACKS);
# без них — публичный режим с адресом агрегатора (как vars.SUBSCRIPTION_URL в GitHub Actions).
SUB_URL="${SUBSCRIPTION_URL:-http://46.8.238.102:2097}"
SUB_FALLBACKS="${SUBSCRIPTION_FALLBACKS:-}"
flutter build ios --config-only --release --no-codesign --target lib/main_prod.dart \
  --build-number "${CI_BUILD_NUMBER:-1}" \
  --dart-define sentry_dsn= --dart-define subscription_url="$SUB_URL" --dart-define subscription_fallbacks="$SUB_FALLBACKS"
grep -E 'FLUTTER_BUILD_(NAME|NUMBER)|FLUTTER_ROOT' ios/Flutter/Generated.xcconfig

cd ios && pod install --repo-update || pod install
echo "post-clone done: flutter=$FLUTTER_VERSION core=$CORE_VERSION build=${CI_BUILD_NUMBER:-1} sub=$SUB_URL"
