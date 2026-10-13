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
    s = re.sub(r'\s*<uses-permission\s+android:name="android.permission.QUERY_ALL_PACKAGES"\s+tools:ignore="QueryAllPackagesPermission" />', '', s)
    assert 'REQUEST_INSTALL_PACKAGES' not in s and 'QUERY_ALL_PACKAGES' not in s, 'strip failed'
    open(P, 'w').write(s); print('manifest: Play permissions stripped')
elif sys.argv[1:] == ['restore']:
    subprocess.run(['git', 'checkout', '--', P], check=True); print('manifest restored')
else:
    sys.exit(__doc__)
