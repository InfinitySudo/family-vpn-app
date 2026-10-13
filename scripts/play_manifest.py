#!/usr/bin/env python3
"""Play-сборка Окна (make android-aab-release): убрать из манифеста разрешения, которые Google Play
требует декларировать с видео, а Play-сборке они не нужны:
  REQUEST_INSTALL_PACKAGES — самообновление APK выключено (kOknoPlayBuild), Play обновляет сам;
  QUERY_ALL_PACKAGES      — список приложений для per-app режима берём через <queries> (launcher intents).
Использование: play_manifest.py strip | restore   (restore = git checkout манифеста)."""
import re, subprocess, sys
P = 'android/app/src/main/AndroidManifest.xml'
if sys.argv[1:] == ['strip']:
    s = open(P).read()
    s = re.sub(r'\s*<!-- Окно: обновление прямо из приложения[^>]*-->\s*<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />', '', s)
    # QUERY_ALL_PACKAGES приходит и из манифеста плагина installed_apps — поэтому не удаляем, а
    # помечаем tools:node="remove": manifest merger выкинет его из итогового манифеста AAB.
    s = re.sub(r'<uses-permission\s+android:name="android.permission.QUERY_ALL_PACKAGES"\s+tools:ignore="QueryAllPackagesPermission" />',
               '<uses-permission android:name="android.permission.QUERY_ALL_PACKAGES" tools:node="remove" />\n'
               '    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" tools:node="remove" />', s)
    assert s.count('tools:node="remove"') == 2, 'strip failed'
    open(P, 'w').write(s); print('manifest: Play permissions stripped')
elif sys.argv[1:] == ['restore']:
    subprocess.run(['git', 'checkout', '--', P], check=True); print('manifest restored')
else:
    sys.exit(__doc__)
