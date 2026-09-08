#!/usr/bin/env python3
"""Create / inspect the Xcode Cloud workflow for Окно (family-vpn-app) via the
App Store Connect API.

Prereq (one-time, web UI only — the API can't do it): App Store Connect →
Окно → Xcode Cloud → Get Started → connect GitHub (InfinitySudo)
→ pick repo family-vpn-app. That creates the ciProduct and the
scmRepository this script looks up.

  python3 scripts/xcode_cloud_workflow.py status          # products / repos / workflows
  python3 scripts/xcode_cloud_workflow.py create          # workflow "TestFlight (main)"
  python3 scripts/xcode_cloud_workflow.py run [WORKFLOW]  # start a build now
"""
import json, sys, time, jwt, requests

ENV = dict(l.strip().split('=', 1) for l in open('/root/secrets/asc_api.env') if '=' in l)
KEY = open('/root/secrets/asc_api_key.p8').read()
API = 'https://api.appstoreconnect.apple.com'
BUNDLE = 'app.okno.family'
BRANCH = 'main'
SCHEME = 'Runner'


def tok():
    return jwt.encode({'iss': ENV['ASC_ISSUER_ID'], 'iat': int(time.time()), 'exp': int(time.time()) + 1000,
                       'aud': 'appstoreconnect-v1'}, KEY, algorithm='ES256', headers={'kid': ENV['ASC_KEY_ID']})


def call(method, path, body=None, **params):
    r = requests.request(method, API + path, headers={'Authorization': 'Bearer ' + tok(),
                         'Content-Type': 'application/json'}, params=params, data=json.dumps(body) if body else None)
    if r.status_code >= 400:
        sys.exit(f'{method} {path} → {r.status_code}\n{r.text[:2000]}')
    return r.json() if r.text else {}


def product():
    prods = call('GET', '/v1/ciProducts', **{'include': 'app,primaryRepositories'})['data']
    for p in prods:
        app_id = (p['relationships'].get('app', {}).get('data') or {}).get('id')
        if app_id:
            app = call('GET', f'/v1/apps/{app_id}', **{'fields[apps]': 'bundleId'})['data']
            if app['attributes']['bundleId'] == BUNDLE:
                return p
    sys.exit('No Xcode Cloud product for %s yet — do the one-time "Get Started" in App Store Connect first.' % BUNDLE)


def status():
    prods = call('GET', '/v1/ciProducts')['data']
    print('products:', [(p['id'], p['attributes']['name']) for p in prods])
    for p in prods:
        repos = call('GET', f"/v1/ciProducts/{p['id']}/primaryRepositories")['data']
        print(' repos:', [(r['id'], r['attributes'].get('repositoryName')) for r in repos])
        wfs = call('GET', f"/v1/ciProducts/{p['id']}/workflows")['data']
        for w in wfs:
            print(' workflow:', w['id'], w['attributes']['name'], 'enabled=', w['attributes']['isEnabled'])


def create():
    p = product()
    repo = call('GET', f"/v1/ciProducts/{p['id']}/primaryRepositories")['data'][0]
    xcodes = call('GET', '/v1/ciXcodeVersions', **{'limit': 50})['data']
    xcode = next(x for x in xcodes if 'beta' not in x['attributes']['name'].lower())  # newest stable first
    macs = call('GET', f"/v1/ciXcodeVersions/{xcode['id']}/macOsVersions")['data']
    mac = macs[0]
    body = {'data': {'type': 'ciWorkflows', 'attributes': {
        'name': 'TestFlight (main)',
        'description': 'Push to main → archive → TestFlight (internal). Created via ASC API.',
        'isEnabled': True, 'isLockedForEditing': False, 'clean': False,
        'containerFilePath': 'ios/Runner.xcworkspace',
        # старт ТОЛЬКО ручной (`run`): автозапуск на каждый push жёг 25 бесплатных часов
        'branchStartCondition': None,
        'manualBranchStartCondition': {'source': {'isAllMatch': False, 'patterns': [{'pattern': BRANCH, 'isPrefix': False}]}},
        # ARCHIVE actions take no `destination` (that's for build/test device targets);
        # distribution is `buildDistributionAudience`: APP_STORE_ELIGIBLE (TestFlight +
        # App Store submit) or INTERNAL_ONLY (TestFlight internal group only).
        'actions': [{'name': 'Archive - iOS', 'actionType': 'ARCHIVE',
                     'buildDistributionAudience': 'APP_STORE_ELIGIBLE',
                     'scheme': SCHEME, 'platform': 'IOS', 'isRequiredToPass': True}],
    }, 'relationships': {
        'product': {'data': {'type': 'ciProducts', 'id': p['id']}},
        'repository': {'data': {'type': 'scmRepositories', 'id': repo['id']}},
        'xcodeVersion': {'data': {'type': 'ciXcodeVersions', 'id': xcode['id']}},
        'macOsVersion': {'data': {'type': 'ciMacOsVersions', 'id': mac['id']}},
    }}}
    w = call('POST', '/v1/ciWorkflows', body)['data']
    print('created workflow', w['id'], w['attributes']['name'], 'xcode=', xcode['attributes']['name'])
    print('Build is uploaded to App Store Connect → TestFlight automatically (APP_STORE_ELIGIBLE).')


def run(wf_id=None):
    if not wf_id:
        p = product()
        wf_id = call('GET', f"/v1/ciProducts/{p['id']}/workflows")['data'][0]['id']
    r = call('POST', '/v1/ciBuildRuns', {'data': {'type': 'ciBuildRuns', 'relationships': {
        'workflow': {'data': {'type': 'ciWorkflows', 'id': wf_id}}}}})
    print('build run', r['data']['id'], r['data']['attributes'].get('number'))


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'status'
    {'status': status, 'create': create, 'run': lambda: run(sys.argv[2] if len(sys.argv) > 2 else None)}[cmd]()
