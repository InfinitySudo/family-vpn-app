#!/usr/bin/env python3
"""Окно → Google Play по API (сервис-аккаунт CW).
  python3 scripts/play_publish.py status                  # треки, релизы, листинг
  python3 scripts/play_publish.py listing                 # ru-RU + en-US листинг, графика (marketing/google_play)
  python3 scripts/play_publish.py upload path.aab [track] [status]   # AAB → трек (internal draft)
"""
import glob, json, os, sys, requests
import google.auth.transport.requests, google.oauth2.service_account as sa
PKG = 'app.okno.family'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAY = os.path.join(ROOT, 'marketing', 'google_play')
BASE = f'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{PKG}'
UP = f'https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/{PKG}'
creds = sa.Credentials.from_service_account_file('/root/secrets/constant-wrestling-play-publisher.json',
                                                 scopes=['https://www.googleapis.com/auth/androidpublisher'])
creds.refresh(google.auth.transport.requests.Request())
S = requests.Session(); S.headers['Authorization'] = f'Bearer {creds.token}'

LISTINGS = {
 'ru-RU': {
  'title': 'Окно',
  'shortDescription': 'Интернет без границ одной кнопкой — для всей семьи, без настроек.',
  'fullDescription': (
   'Окно — простое приложение для доступа к интернету одной кнопкой.\n\n'
   'Открыли, нажали кнопку — и сайты, мессенджеры, видео и звонки снова работают. '
   'Никаких настроек, серверов и инструкций: всё уже внутри.\n\n'
   '• Одна кнопка — включить и выключить.\n'
   '• Выбор страны подключения, если нужно.\n'
   '• Приложение само следит за соединением и переключается на рабочий сервер.\n'
   '• Обновления приходят внутри приложения.\n'
   '• Сделано для родных: понятно бабушкам и дедушкам.\n\n'
   'Доступ выдаётся через Telegram-бот @OKHO_VPN_BOT — приложение откроет его само.\n\n'
   'Политика конфиденциальности: https://infinitysudo.github.io/family-vpn-app/privacy.html'),
 },
 'en-US': {
  'title': 'Okno',
  'shortDescription': 'Open internet with one tap — made for the whole family, no setup.',
  'fullDescription': (
   'Okno is a one-button app for an open and private internet connection.\n\n'
   'Open the app, tap the button, and websites, messengers, video and calls work again. '
   'No settings, no server lists, no manuals — everything is built in.\n\n'
   '• One button to connect and disconnect.\n'
   '• Choose the connection country when you need to.\n'
   '• The app watches the connection and switches to a working server by itself.\n'
   '• Updates arrive inside the app.\n'
   '• Built for families: simple enough for grandparents.\n\n'
   'Access is issued through the Telegram bot @OKHO_VPN_BOT — the app opens it for you.\n\n'
   'Privacy policy: https://infinitysudo.github.io/family-vpn-app/privacy.html'),
 },
}

def edit():
    r = S.post(f'{BASE}/edits'); r.raise_for_status(); return r.json()['id']

def commit(eid):
    r = S.post(f'{BASE}/edits/{eid}:commit'); print('commit', r.status_code, r.text[:300] if r.status_code != 200 else 'ok')

def status():
    eid = edit()
    print(json.dumps(S.get(f'{BASE}/edits/{eid}/tracks').json(), indent=1, ensure_ascii=False)[:2000])
    for l in S.get(f'{BASE}/edits/{eid}/listings').json().get('listings', []):
        print('listing', l['language'], l['title'], '|', l['shortDescription'])
    for t in ('internal', 'alpha'):
        print('testers', t, S.get(f'{BASE}/edits/{eid}/testers/{t}').json())
    S.delete(f'{BASE}/edits/{eid}')

def listing():
    eid = edit()
    for lang, body in LISTINGS.items():
        r = S.put(f'{BASE}/edits/{eid}/listings/{lang}', json=dict(language=lang, **body))
        print('listing', lang, r.status_code, '' if r.status_code == 200 else r.text[:200])
    r = S.patch(f'{BASE}/edits/{eid}/details', json={'defaultLanguage': 'ru-RU', 'contactEmail': 'borysiukartem55@gmail.com',
                                                     'contactWebsite': 'https://infinitysudo.github.io/family-vpn-app/'})
    print('details', r.status_code, '' if r.status_code == 200 else r.text[:200])
    imgs = [('icon', [os.path.join(PLAY, 'icon-512.png')]),
            ('featureGraphic', [os.path.join(PLAY, 'feature-graphic-1024x500.png')]),
            ('phoneScreenshots', sorted(glob.glob(os.path.join(PLAY, 'phone', '*.png'))))]
    for lang in LISTINGS:
        for kind, files in imgs:
            S.delete(f'{BASE}/edits/{eid}/listings/{lang}/{kind}')
            for f in files:
                r = S.post(f'{UP}/edits/{eid}/listings/{lang}/{kind}?uploadType=media', data=open(f, 'rb').read(),
                           headers={'Content-Type': 'image/png'})
                print(' ', lang, kind, os.path.basename(f), r.status_code, '' if r.status_code == 200 else r.text[:200])
    commit(eid)

def upload(path, track='internal', st='draft'):
    eid = edit()
    r = S.post(f'{UP}/edits/{eid}/bundles?uploadType=media', data=open(path, 'rb').read(),
               headers={'Content-Type': 'application/octet-stream'})
    print('bundle', r.status_code, r.text[:300])
    if r.status_code != 200: return
    vc = r.json()['versionCode']
    r = S.put(f'{BASE}/edits/{eid}/tracks/{track}', json={'track': track, 'releases': [
        {'name': f'{os.path.basename(path)} ({vc})', 'versionCodes': [str(vc)], 'status': st}]})
    print('track', track, st, r.status_code, '' if r.status_code == 200 else r.text[:300])
    commit(eid)

if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'status'
    if cmd == 'status': status()
    elif cmd == 'listing': listing()
    elif cmd == 'upload': upload(sys.argv[2], *(sys.argv[3:5]))
