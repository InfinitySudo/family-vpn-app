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
echo
echo "Открываю Xcode. Дальше: иконка ОБЛАКА в тулбаре → Create Workflow → Next →"
echo "Grant Access (GitHub, выбрать family-vpn-app) → Complete. Сборку НЕ запускать."
open ios/Runner.xcworkspace
