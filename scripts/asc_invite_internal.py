#!/usr/bin/env python3
"""Окно — пустить конкретного человека в TestFlight СЕЙЧАС, не дожидаясь Beta App Review Apple.
Публичная ссылка «Родители» не работает ни у кого, пока Apple не одобрит бету (WAITING_FOR_REVIEW с 04.09) —
это не блокировка из РФ. Обход: внутренняя группа TestFlight (Internal) — работает без ревью, но человек
должен быть участником команды App Store Connect. Скрипт:
  1) приглашает Apple ID в команду с минимальной ролью Customer Support (видит только «Окно»);
  2) прикрепляет последний билд к группе Internal;
  3) добавляет человека тестером в Internal (получится только ПОСЛЕ того, как он принял приглашение —
     тогда запустить ещё раз тем же адресом).
Запуск (Артём, классификатор блокирует ASC-записи из сессии):
    ! python3 /root/family-vpn-app/scripts/asc_invite_internal.py tescha@icloud.com "Имя" "Фамилия"
Человеку придёт письмо от Apple «You're invited to join … App Store Connect» → Accept invitation (войти своим
Apple ID) → поставить TestFlight из App Store → в нём появится «Окно» → Установить."""
import sys
sys.path.insert(0, "/root/ontime/scripts")
import asc  # noqa: E402

APP = "6808414420"
INTERNAL_GROUP = "52aa3e4d-afac-4fd0-bfa9-d03814bdc4b5"

# По умолчанию — тёща Артёма (iPad), данные с фото 05.09. Пароль от её Apple ID сюда НЕ записан и не нужен:
# приглашение принимается на её устройстве. Другой человек: аргументами <email> [Имя] [Фамилия].
DEFAULT_EMAIL = "marinaminjener@gmail.com"  # уточнено Артёмом 05.09 (с фото читалось «minfener»)
DEFAULT_FIRST = "Marina"
DEFAULT_LAST = "Minjener"
# приглашения, ушедшие по ошибочному адресу — отзываем при каждом запуске
STALE_EMAILS = ["marinaminfener@gmail.com"]


def main():
    resend = "--resend" in sys.argv
    if resend:
        sys.argv.remove("--resend")
    email = sys.argv[1].strip() if len(sys.argv) > 1 else DEFAULT_EMAIL
    first = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_FIRST
    last = sys.argv[3] if len(sys.argv) > 3 else DEFAULT_LAST
    print(f"== TestFlight Internal для {email} ({first} {last})")
    for stale in STALE_EMAILS:
        if stale == email:
            continue
        c, inv = asc.req("GET", f"/v1/userInvitations?filter[email]={stale}")
        for x in inv.get("data", []) if isinstance(inv, dict) else []:
            c, r = asc.req("DELETE", f"/v1/userInvitations/{x['id']}")
            print(f"ошибочное приглашение {stale} отозвано:", c)

    # 0) --resend: удалить висящее приглашение и выслать заново (Apple шлёт письмо ещё раз)
    if resend:
        c, inv = asc.req("GET", f"/v1/userInvitations?filter[email]={email}")
        for x in inv.get("data", []) if isinstance(inv, dict) else []:
            c, r = asc.req("DELETE", f"/v1/userInvitations/{x['id']}")
            print("старое приглашение удалено:", c)

    # 1) приглашение в команду. После DELETE Apple ещё ~минуту отвечает 409 «email is already being used»
    #    (удаление доезжает не сразу) — повторяем до 8 раз с паузой. Если человек уже В КОМАНДЕ — тоже 409, тогда ок.
    import time
    body = {"data": {"type": "userInvitations", "attributes": {
        "email": email, "firstName": first, "lastName": last, "roles": ["CUSTOMER_SUPPORT"],
        "allAppsVisible": False, "provisioningAllowed": False},
        "relationships": {"visibleApps": {"data": [{"type": "apps", "id": APP}]}}}}
    for attempt in range(8):
        c, r = asc.req("POST", "/v1/userInvitations", body)
        if c == 201 or not (c == 409 and "already" in str(r)):
            break
        time.sleep(10)
    print("invite:", c, "ok — письмо отправлено" if c == 201 else asc.errmsg(r))

    # 2) группа Internal имеет hasAccessToAllBuilds=true — все билды доступны ей автоматически,
    #    прикреплять вручную не нужно (POST даёт 422 «Cannot add internal group to a build»).
    c, g = asc.req("GET", f"/v1/betaGroups/{INTERNAL_GROUP}")
    print("Internal group: все билды доступны =", g["data"]["attributes"].get("hasAccessToAllBuilds"))

    # 3) тестер в Internal (сработает после принятия приглашения)
    c, r = asc.req("POST", "/v1/betaTesters", {"data": {"type": "betaTesters", "attributes": {
        "email": email, "firstName": first, "lastName": last},
        "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": INTERNAL_GROUP}]}}}})
    if c == 201:
        print("tester → Internal: ok — в TestFlight у человека появится «Окно»")
    else:
        print("tester → Internal:", c, asc.errmsg(r))
        print("→ если человек ещё не принял приглашение из письма Apple — пусть примет, потом запустить скрипт ещё раз.")


if __name__ == "__main__":
    main()
