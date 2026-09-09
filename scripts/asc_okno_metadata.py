import time, jwt, requests, json, sys
env=dict(l.strip().split('=',1) for l in open('/root/secrets/asc_api.env') if '=' in l)
tok=jwt.encode({'iss':env['ASC_ISSUER_ID'],'iat':int(time.time()),'exp':int(time.time())+1200,'aud':'appstoreconnect-v1'}, open('/root/secrets/asc_api_key.p8').read(), algorithm='ES256', headers={'kid':env['ASC_KEY_ID']})
H={'Authorization':'Bearer '+tok,'Content-Type':'application/json'}; B='https://api.appstoreconnect.apple.com/v1'
def req(m,p,body=None):
    r=requests.request(m,B+p,headers=H,data=json.dumps(body) if body else None)
    try: d=r.json()
    except Exception: d={}
    err=(d.get('errors') or [{}])[0].get('detail','')
    print(f"{m} {p.split('?')[0][:60]} → {r.status_code} {err[:120]}")
    return r.status_code,d
APP='6808414420'; VER='f0f13fc5-0ee2-4454-90c6-0da564503312'; INFO='0364bb8b-0d23-4648-9b5b-69ea2241d18b'
INFO_LOC='b29316a7-cf8c-4e5d-b513-5471ebe1e724'; VER_LOC='aa94e70a-d535-43cd-bbe2-b899c5b42f35'; BUILD='3f2dacf8-7fbe-479d-bcec-87d48e58f548'
SITE='https://infinitysudo.github.io/family-vpn-app/'
# 1. app: content rights
req('PATCH',f'/apps/{APP}',{'data':{'type':'apps','id':APP,'attributes':{'contentRightsDeclaration':'DOES_NOT_USE_THIRD_PARTY_CONTENT'}}})
# 2. version string + copyright + build
req('PATCH',f'/appStoreVersions/{VER}',{'data':{'type':'appStoreVersions','id':VER,'attributes':{'versionString':'1.0.26','copyright':'2026 Artem Borysiuk','releaseType':'AFTER_APPROVAL'},
    'relationships':{'build':{'data':{'type':'builds','id':BUILD}}}}})
# 3. categories
req('PATCH',f'/appInfos/{INFO}',{'data':{'type':'appInfos','id':INFO,'relationships':{'primaryCategory':{'data':{'type':'appCategories','id':'UTILITIES'}}}}})
# 4. appInfo localization ru
req('PATCH',f'/appInfoLocalizations/{INFO_LOC}',{'data':{'type':'appInfoLocalizations','id':INFO_LOC,'attributes':{
    'subtitle':'Защищённое соединение для семьи','privacyPolicyUrl':SITE+'privacy.html'}}})
# 5. version localization ru
desc="""Окно — простое защищённое соединение для всей семьи. Одна большая кнопка: нажали — подключились.

• Быстрые серверы в Европе: Латвия, Финляндия, Нидерланды. Приложение само выбирает самый надёжный.
• Выбор страны одним нажатием — полезно, если сервису нужен постоянный адрес.
• Работает на iPhone, iPad и Mac, а также на Android, Windows и Linux — ключ один на все устройства.
• Ничего не записываем: ни сайты, ни приложения, ни содержимое трафика. Без рекламы и трекеров.
• Сторож соединения: если другое VPN-приложение мешает, Окно предупредит и подскажет, что сделать.
• Обновления приходят сами, без переустановки.

Сделано для родителей и близких: никаких настроек, ничего вводить не нужно. Ключ доступа выдаётся в Telegram, дальше приложение всё делает само.

Окно построено на открытом коде (форк Hiddify, лицензия GPL v3). Исходники: github.com/InfinitySudo/family-vpn-app"""
req('PATCH',f'/appStoreVersionLocalizations/{VER_LOC}',{'data':{'type':'appStoreVersionLocalizations','id':VER_LOC,'attributes':{
    'description':desc,'keywords':'vpn,впн,защита,приватность,семья,интернет,безопасность,соединение,прокси,окно',
    'supportUrl':SITE,'marketingUrl':SITE,'promotionalText':'Одна кнопка — и связь с близкими работает.',
    'whatsNew':'Первая версия в App Store: большая кнопка, выбор страны, обновления без переустановки.'}}})
# 6. age rating: truthful — no content categories, no web browser
SCALE=["alcoholTobaccoOrDrugUseOrReferences","contests","gamblingSimulated","gunsOrOtherWeapons","horrorOrFearThemes","matureOrSuggestiveThemes","medicalOrTreatmentInformation","profanityOrCrudeHumor","sexualContentGraphicAndNudity","sexualContentOrNudity","violenceCartoonOrFantasy","violenceRealistic","violenceRealisticProlongedGraphicOrSadistic"]
attrs={k:'NONE' for k in SCALE}; attrs.update({'gambling':False,'unrestrictedWebAccess':False,'advertising':False,'lootBox':False,'healthOrWellnessTopics':False,'parentalControls':False,'ageAssurance':False,'messagingAndChat':False,'userGeneratedContent':False})
s,d=req('GET',f'/appInfos/{INFO}/ageRatingDeclaration'); decl=d['data']['id']
req('PATCH',f'/ageRatingDeclarations/{decl}',{'data':{'type':'ageRatingDeclarations','id':decl,'attributes':attrs}})
# 7. review details
notes="""Okno is a personal/family VPN client built on the open-source Hiddify app (sing-box / Xray cores). It uses NEPacketTunnelProvider (Network Extension) to establish the tunnel; no MDM, no configuration profiles.

HOW TO TEST: after install, tap "Получить доступ в Telegram" (Get access in Telegram) ONLY if you want the public flow; for review please use the reviewer key below — open the app, go to Настройки (Menu → Settings) → "Ключ доступа" and paste the key. Then tap the big button on the main screen; iOS will ask to allow the VPN configuration. Once connected the button turns green and a country card shows the current server.

Reviewer key (full access, no expiry): [REVIEW_KEY]

Data: the app does not log or inspect user traffic. Servers keep only a hash of the client IP for load statistics. Crash reports (app log, device model, error text) are sent only on failure. Privacy policy: https://infinitysudo.github.io/family-vpn-app/privacy.html"""
body={'contactFirstName':'Artem','contactLastName':'Borysiuk','contactPhone':'+14034044274','contactEmail':'borysiukartem55@gmail.com','demoAccountRequired':False,'notes':notes}
s,d=req('GET',f'/appStoreVersions/{VER}/appStoreReviewDetail')
if s==200 and d.get('data'):
    req('PATCH',f"/appStoreReviewDetails/{d['data']['id']}",{'data':{'type':'appStoreReviewDetails','id':d['data']['id'],'attributes':body}})
else:
    req('POST','/appStoreReviewDetails',{'data':{'type':'appStoreReviewDetails','attributes':body,'relationships':{'appStoreVersion':{'data':{'type':'appStoreVersions','id':VER}}}}})
# 8. state check
s,d=req('GET',f'/appStoreVersions/{VER}'); print('version now', d['data']['attributes']['versionString'], d['data']['attributes']['appStoreState'])
s,d=req('GET',f'/appStoreVersions/{VER}/build'); print('build attached', (d.get('data') or {}).get('id'))
s,d=req('GET',f'/appInfos/{INFO}'); print('age rating', d['data']['attributes'].get('appStoreAgeRating'))
