#!/bin/bash
# Одноразово на Mac Артёма: открыть iOS-проект Окна в Xcode и создать первый
# воркфлоу Xcode Cloud (иконка облака в тулбаре → Create Workflow → Grant Access
# GitHub → выбрать family-vpn-app → Complete). Flutter/Pods на Mac НЕ нужны —
# воркфлоу создаётся без сборки, красные ссылки на Pods в Xcode игнорируем.
# Использование:
#   cd ~ && git clone git@github.com:InfinitySudo/family-vpn-app.git
#   cd family-vpn-app && bash scripts/mac_bootstrap.sh
set -euo pipefail
cd "$(dirname "$0")/.."
git pull --ff-only 2>/dev/null || true
xcode-select -p >/dev/null 2>&1 || { echo "Xcode не выбран: sudo xcode-select -s /Applications/Xcode.app"; exit 1; }
# HiddifyCore.xcframework не в репо (его качает CI) — без него Xcode не резолвит
# локальный Swift-пакет и ругается «local binary target 'HiddifyCore'».
if [ ! -d ios/Frameworks/HiddifyCore.xcframework ]; then
  CORE_VERSION="$(grep core.version dependencies.properties | cut -d= -f2 | tr -d '[:space:]')"
  mkdir -p ios/Frameworks
  curl -fL "https://github.com/hiddify/hiddify-core/releases/download/v${CORE_VERSION}/hiddify-lib-ios.tar.gz" | tar xz -C ios/Frameworks
fi
echo
echo "Открываю Xcode. Дальше: иконка ОБЛАКА в тулбаре → Create Workflow → Next →"
echo "Grant Access (GitHub, выбрать family-vpn-app) → Complete. Сборку НЕ запускать."
open ios/Runner.xcworkspace
