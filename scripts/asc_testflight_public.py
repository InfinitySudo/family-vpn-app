#!/usr/bin/env python3
"""Окно — публичная ссылка TestFlight для родителей (внешняя группа «Родители»).
Классификатор авто-режима блокирует сабмит в ASC из сессии Claude → Артём запускает сам:
    ! python3 /root/family-vpn-app/scripts/asc_testflight_public.py "+1403XXXXXXX"
(телефон — контакт для Beta App Review, Apple требует; без аргумента берётся из другого
приложения аккаунта, если там заполнен).
Делает: Beta App Description (ru/en-US), контакт ревью, последний VALID билд → в группу
«Родители», сабмит на Beta App Review. После одобрения Apple (обычно 1–2 дня) ссылка
https://testflight.apple.com/join/UJYhuaWF заработает для всех.
Использует хелпер /root/ontime/scripts/asc.py (JWT из /root/secrets/asc_api.env)."""
import json, sys
sys.path.insert(0, "/root/ontime/scripts")
import asc  # noqa: E402

APP = "6808414420"                                   # ASC id приложения «Окно»
GROUP = "d846905f-bb86-438f-8936-a3a451e5c781"       # betaGroup «Родители» (publicLink UJYhuaWF)
EMAIL = "borysiukartem55@gmail.com"
PHONE = sys.argv[1] if len(sys.argv) > 1 else ""

DESC = {
    "ru": "«Окно» — семейный VPN одной кнопкой. Установите приложение, нажмите «Подключить» — "
          "настройки подтягиваются автоматически, ничего вводить не нужно.",
    "en-US": "Okno is a one-button family VPN. Install, tap Connect - settings are fetched "
             "automatically, nothing to enter.",
}


def localizations():
    st, d = asc.req("GET", f"/v1/apps/{APP}/betaAppLocalizations")
    have = {l["attributes"]["locale"]: l["id"] for l in (d.get("data") or [])}
    for locale, desc in DESC.items():
        attrs = {"description": desc, "feedbackEmail": EMAIL}
        if locale in have:
            st, d = asc.req("PATCH", f"/v1/betaAppLocalizations/{have[locale]}",
                            {"data": {"type": "betaAppLocalizations", "id": have[locale], "attributes": attrs}})
        else:
            st, d = asc.req("POST", "/v1/betaAppLocalizations",
                            {"data": {"type": "betaAppLocalizations", "attributes": dict(attrs, locale=locale),
                                      "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
        print("beta description", locale, st, "" if st < 400 else json.dumps(d)[:200])


def review_contact():
    st, d = asc.req("GET", f"/v1/apps/{APP}/betaAppReviewDetail")
    cur = d.get("data") or {}
    rid, at = cur.get("id"), cur.get("attributes", {})
    phone = PHONE or at.get("contactPhone") or ""
    if not phone:  # берём контакт из другого приложения аккаунта
        st, apps = asc.req("GET", "/v1/apps?limit=20")
        for a in apps.get("data", []):
            if a["id"] == APP:
                continue
            s2, r2 = asc.req("GET", f"/v1/apps/{a['id']}/betaAppReviewDetail")
            da = (r2.get("data") or {}).get("attributes", {})
            if da.get("contactPhone"):
                phone = da["contactPhone"]; print("телефон взят из:", a["attributes"].get("name")); break
    if not phone:
        print("НЕТ ТЕЛЕФОНА: запусти с аргументом \"+1403...\""); sys.exit(1)
    attrs = {"contactFirstName": at.get("contactFirstName") or "Artem", "contactLastName": at.get("contactLastName") or "Borysiuk",
             "contactEmail": at.get("contactEmail") or EMAIL, "contactPhone": phone, "demoAccountRequired": False,
             "notes": "Family VPN app (VLESS/Hysteria2 via xray/sing-box). Tap Connect; no account needed."}
    st, d = asc.req("PATCH", f"/v1/betaAppReviewDetails/{rid}",
                    {"data": {"type": "betaAppReviewDetails", "id": rid, "attributes": attrs}})
    print("review contact", st, "" if st < 400 else json.dumps(d)[:300])


def submit_latest():
    st, d = asc.req("GET", f"/v1/builds?filter[app]={APP}&limit=5&sort=-uploadedDate"
                           f"&fields[builds]=version,processingState,uploadedDate,expired")
    builds = [b for b in (d.get("data") or []) if not b["attributes"].get("expired")]
    for b in builds:
        print("  build", b["attributes"]["version"], b["attributes"]["processingState"], b["attributes"]["uploadedDate"])
    target = next((b for b in builds if b["attributes"]["processingState"] == "VALID"), None)
    if not target:
        print("нет VALID билда"); sys.exit(1)
    st, d = asc.req("POST", f"/v1/betaGroups/{GROUP}/relationships/builds",
                    {"data": [{"type": "builds", "id": target["id"]}]})
    print("в группу «Родители»:", target["attributes"]["version"], st)
    st, d = asc.req("POST", "/v1/betaAppReviewSubmissions",
                    {"data": {"type": "betaAppReviewSubmissions",
                              "relationships": {"build": {"data": {"type": "builds", "id": target["id"]}}}}})
    print("Beta App Review submit:", target["attributes"]["version"], st, "" if st < 400 else json.dumps(d)[:400])


if __name__ == "__main__":
    localizations()
    review_contact()
    submit_latest()
    print("Публичная ссылка (заработает после одобрения Apple): https://testflight.apple.com/join/UJYhuaWF")
