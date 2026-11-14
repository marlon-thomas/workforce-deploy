# Workforce issue 462 (ADR-0039, amendment of 14 November 2026; the private repo's
# docs/architecture/462-lockout-contract.md, sections 1 and 3.2 to 3.6): wrong passwords pause one account on one
# connection, a connection that tries many unknown accounts is throttled, and attempts spread over accounts or
# connections raise alerts. The decision only: plain Python, nothing from authentik or Django, so that
# bin/tests/password-pause-test.sh tests it with python3 alone, against the same vectors as the application's
# PasswordPause (bin/tests/password-pause-vectors.json, a copy of the application's file).
#
# workforce-app.yaml.j2 includes this file at the top of the expression policies workforce-password-paused,
# workforce-password-try, workforce-password-right and workforce-client-address, and adds the authentik part below
# it (the lock, the records, the request). authentik runs an expression as the body of a function, so this file holds
# only constants and functions; nothing in it runs on its own. It is a Jinja include: never write two braces, or a
# brace and a percent or hash sign, side by side here.
#
# The owner's values (14 November 2026; the fix round of the same day): five wrong passwords for one account from one
# connection within 15 minutes pause that pair until 15 minutes after the fifth. Ten wrong passwords from one connection
# within 15 minutes, whatever names were typed, throttle it until 15 minutes after the tenth; for IPv6 also thirty from
# one /48. A workplace (a connection, or a /48, where 3 or more real accounts typed the right password in the last 30
# days) is never throttled. The throttle never depends on the typed name (an exemption by name would tell anyone on a
# throttled connection which names exist), and an unlock or a new password never touches it. A refused request is
# never recorded, so it can't move either end. Times are seconds since the epoch, UTC.

WF_PAUSE_AFTER = 5                 # wrong passwords for one pair within WF_WINDOW
WF_THROTTLE_AFTER = 10             # wrong passwords from one connection, any names, within WF_WINDOW
WF_NETWORK_THROTTLE_AFTER = 30     # and from one IPv6 /48
WF_WORKPLACE_ACCOUNTS = 3          # real accounts with a right password from a connection (or /48) make it a workplace
WF_WINDOW = 15 * 60                # both are counted over this, and last this long after the last one counted
WF_LOOK_BACK = 30 * 60             # how far back tries are read for a decision (a window plus its wait)
WF_KNOWN_FOR = 30 * 86400          # how far back right passwords count towards a workplace
WF_FUTURE = 120                    # a marker more than this far ahead is ignored (a clock or a hand gone wrong)
WF_SPREAD_HOUR = 3600              # spread detection: one connection, many accounts; one account, many connections
WF_SPREAD_ACCOUNTS = 5
WF_SPREAD_CONNECTIONS = 3
WF_SPREAD_DAY = 86400              # or many wrong passwords for one account in a day
WF_SPREAD_DAY_WRONG = 20
WF_ALERT_GAP = 3600                # each kind of alert, for one connection or account, at most once in this
WF_ALERT_MOST_PKS = 50             # real accounts named in one alert, at most
WF_REFUSED_GAP = 60                # a refusal is recorded at most once in this, per pair

# How long each record is kept, whatever authentik's event retention (contract 3.2).
WF_KEEP_TRY = 25 * 3600
WF_KEEP_RIGHT = 31 * 86400
WF_KEEP_REFUSED = 3600
WF_KEEP_ALERT = 31 * 86400
WF_RIGHT_FALLBACK = 60             # with no try in the flow plan: the pair's newest unmarked try of this many seconds

# authentik events (custom_<name>); the context keys are fixed (contract 3.2) and nothing else goes in.
WF_TRY = "workforce_password_try"
WF_RIGHT = "workforce_password_right"
WF_REFUSED = "workforce_password_refused"
WF_ALERT = "workforce_password_alert"
WF_PLAN_TRY = "wf_password_try"    # the flow plan's key for this sign-in's newest try
WF_FORWARDED_HEADER = "HTTP_X_WORKFORCE_FORWARDED"   # the gateway's mark: forwarding headers from a peer nobody named
WF_LOCK_CONN = 1464225601          # first key of the PostgreSQL advisory lock per connection (always taken first)
WF_LOCK_PAIR = 1464225602          # and per pair (account and connection), taken second
WF_UNLOCK_ATTRIBUTE = "password_unlocked_at"   # attributes.workforce.<this>, written by the application
WF_CODE_CLASSES = ("totp", "static", "sms", "email")


def wf_connection_key(address):
    """The connection an address belongs to: IPv4 as a dotted quad; an IPv4-mapped IPv6 address as its IPv4; any other
    IPv6 address as its /64 network ("2001:db8:1:2::/64"), because one home or phone line holds billions of them. A key
    is its own key. Anything that isn't an address is kept as it is, trimmed and lower-cased (never looked up)."""
    import ipaddress
    text = str(address if address is not None else "").strip().lower()
    bare = text[:-3] if text.endswith("/64") else text
    if bare.startswith("[") and bare.endswith("]"):
        bare = bare[1:-1]
    try:
        ip = ipaddress.ip_address(bare)
    except ValueError:
        return text
    if ip.version == 6 and ip.ipv4_mapped is not None:
        return str(ip.ipv4_mapped)
    if ip.version == 4:
        return str(ip)
    return str(ipaddress.ip_network((ip, 64), strict=False))


def wf_network_key(address):
    """The network an address (or a connection key) belongs to: IPv4 (and IPv4-mapped) as the address; IPv6 as its /48
    ("2001:db8:1::/48"), because one hosting or home allocation holds 65,536 /64s or more. A key is its own key."""
    import ipaddress
    text = str(address if address is not None else "").strip().lower()
    if text.endswith("/48"):
        text = text[:-3]
    key = wf_connection_key(text)
    if not key.endswith("/64"):
        return key
    try:
        return str(ipaddress.ip_network((ipaddress.ip_address(key[:-3]), 48), strict=False))
    except ValueError:
        return key


def wf_name_key(secret, typed):
    """An unknown name's account key: never the name itself, an HMAC of it under the server's own secret."""
    import hashlib
    import hmac
    name = str(typed if typed is not None else "").strip().lower()
    digest = hmac.new(str(secret).encode("utf-8"), ("wf-name:" + name).encode("utf-8"), hashlib.sha256).hexdigest()
    return "n:" + digest[:32]


def wf_account_key(pk, typed, secret):
    """u:<pk> for a real account; for authentik's pretend user (a name nobody has, no pk) the name's key."""
    if pk is not None:
        return "u:%d" % int(pk)
    return wf_name_key(secret, typed)


def wf_parse_time(value):
    """Seconds for an ISO-8601 time ("2026-11-14T14:05:02Z", or with an offset), or None if it isn't one. A datetime
    is taken as it is; one without a zone is UTC."""
    import datetime
    if value is None:
        return None
    if isinstance(value, datetime.datetime):
        moment = value
    else:
        text = str(value).strip()
        if not text:
            return None
        if text.endswith("Z") or text.endswith("z"):
            text = text[:-1] + "+00:00"
        try:
            moment = datetime.datetime.fromisoformat(text)
        except ValueError:
            return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=datetime.timezone.utc)
    return moment.timestamp()


def wf_marker(password_changed, attributes, now):
    """An account's marker: the later of its last password change and its last unlock in Workforce
    (attributes.workforce.password_unlocked_at). Wrong passwords before it don't count. A time more than WF_FUTURE
    ahead, or one that can't be read, is ignored. None when there is none."""
    unlocked = None
    if isinstance(attributes, dict) and isinstance(attributes.get("workforce"), dict):
        unlocked = wf_parse_time(attributes["workforce"].get(WF_UNLOCK_ATTRIBUTE))
    best = None
    for t in (wf_parse_time(password_changed), unlocked):
        if t is not None and t <= now + WF_FUTURE and (best is None or t > best):
            best = t
    return best


def wf_right_tries(events):
    return set(e.get("try") for e in events if e.get("kind") == "right" and e.get("try") is not None)


def wf_is_wrong(e, right, now, since):
    return e.get("kind") == "try" and e.get("try") not in right and since <= e["at"] <= now


def wf_held_until(times, limit, now):
    """Let L be the newest; held while `limit` or more fell in [L - WF_WINDOW, L] and now is before L + WF_WINDOW.
    Returns the end, or None."""
    if not times:
        return None
    newest = max(times)
    if sum(1 for t in times if t >= newest - WF_WINDOW) >= limit and now < newest + WF_WINDOW:
        return newest + WF_WINDOW
    return None


def wf_workplace(events, key, network, now):
    """3 or more different real accounts typed the right password from here (a connection key, or with `network` a /48)
    in the last WF_KNOWN_FOR. Never depends on a typed name."""
    accounts = set()
    for e in events:
        if e.get("kind") != "right" or not str(e.get("account") or "").startswith("u:"):
            continue
        if not now - WF_KNOWN_FOR <= e["at"] <= now:
            continue
        if (wf_network_key(e.get("conn")) if network else e.get("conn")) == key:
            accounts.add(e["account"])
    return len(accounts) >= WF_WORKPLACE_ACCOUNTS


def wf_paused_until(events, right, account, conn, marker, now):
    times = [e["at"] for e in events
             if e.get("account") == account and e.get("conn") == conn and wf_is_wrong(e, right, now, now - WF_LOOK_BACK)
             and (marker is None or e["at"] > marker)]
    return wf_held_until(times, WF_PAUSE_AFTER, now)


def wf_throttled_until(events, right, key, network, now):
    """The throttle of a connection (or, with `network`, an IPv6 /48): wrong tries from it in the last WF_LOOK_BACK, any
    name, any marker. None for a workplace."""
    if wf_workplace(events, key, network, now):
        return None
    times = [e["at"] for e in events if wf_is_wrong(e, right, now, now - WF_LOOK_BACK)
             and (wf_network_key(e.get("conn")) if network else e.get("conn")) == key]
    return wf_held_until(times, WF_NETWORK_THROTTLE_AFTER if network else WF_THROTTLE_AFTER, now)


def wf_decide(events, account, conn, markers, now):
    """May `account` try a password from `conn` now? `events` are the records, each a dict: at (seconds), kind ("try"
    or "right"), try (the try's id, which a right record names), account (account key), conn (connection key).
    `markers` maps an account key to its marker (seconds), where it has one; it lifts the pause only. Returns paused,
    throttled and until (the later end, or None)."""
    conn = wf_connection_key(conn)
    right = wf_right_tries(events)
    paused_until = wf_paused_until(events, right, account, conn, markers.get(account), now)
    ends = [wf_throttled_until(events, right, conn, False, now)]
    if ":" in conn:
        ends.append(wf_throttled_until(events, right, wf_network_key(conn), True, now))
    ends = [t for t in ends if t is not None]
    throttled_until = max(ends) if ends else None
    ends = [t for t in (paused_until, throttled_until) if t is not None]
    return {"paused": paused_until is not None, "throttled": throttled_until is not None,
            "until": max(ends) if ends else None}


def wf_spread(events, account, conn, user_pk, now, before=None):
    """Alerts the newest try (already in `events`) raises: connection-spread (one connection, or one IPv6 /48, many
    names), account-spread, throttled. `before` are the events without it (for "has just become throttled"); `events`
    must reach back WF_SPREAD_DAY. Each alert is a dict of the record's context. Alerts only: nothing here changes a
    decision."""
    conn = wf_connection_key(conn)
    right = wf_right_tries(events)
    alerts = []

    def pks(accounts):
        out = []
        for a in sorted(accounts):
            if a.startswith("u:") and a[2:].isdigit() and int(a[2:]) not in out:
                out.append(int(a[2:]))
        return out[:WF_ALERT_MOST_PKS]

    hour = [e for e in events if wf_is_wrong(e, right, now, now - WF_SPREAD_HOUR)]
    keys = [(conn, False)] + ([(wf_network_key(conn), True)] if ":" in conn else [])
    for key, network in keys:
        from_here = [e for e in hour if (wf_network_key(e.get("conn")) if network else e.get("conn")) == key]
        names = set(e.get("account") for e in from_here)
        if len(names) >= WF_SPREAD_ACCOUNTS:
            alerts.append({"wf_kind": "connection-spread", "wf_conn": key, "wf_user_pk": None,
                           "wf_user_pks": pks(names), "wf_accounts": len(names),
                           "wf_connections": len(set(e.get("conn") for e in from_here)), "wf_wrong": len(from_here),
                           "wf_window": WF_SPREAD_HOUR})
    if user_pk is not None:
        mine_hour = [e for e in hour if e.get("account") == account]
        conns = set(e.get("conn") for e in mine_hour)
        mine_day = [e for e in events if e.get("account") == account and wf_is_wrong(e, right, now, now - WF_SPREAD_DAY)]
        if len(conns) >= WF_SPREAD_CONNECTIONS:
            alerts.append({"wf_kind": "account-spread", "wf_conn": None, "wf_user_pk": int(user_pk),
                           "wf_user_pks": [int(user_pk)], "wf_accounts": 1, "wf_connections": len(conns),
                           "wf_wrong": len(mine_hour), "wf_window": WF_SPREAD_HOUR})
        elif len(mine_day) >= WF_SPREAD_DAY_WRONG:
            alerts.append({"wf_kind": "account-spread", "wf_conn": None, "wf_user_pk": int(user_pk),
                           "wf_user_pks": [int(user_pk)], "wf_accounts": 1,
                           "wf_connections": len(set(e.get("conn") for e in mine_day)),
                           "wf_wrong": len(mine_day), "wf_window": WF_SPREAD_DAY})
    if before is not None:
        for key, network in keys:
            if wf_throttled_until(events, right, key, network, now) is None:
                continue
            if wf_throttled_until(before, wf_right_tries(before), key, network, now) is not None:
                continue
            held = [e for e in events if wf_is_wrong(e, right, now, now - WF_LOOK_BACK)
                    and (wf_network_key(e.get("conn")) if network else e.get("conn")) == key]
            names = set(e.get("account") for e in held)
            alerts.append({"wf_kind": "throttled", "wf_conn": key, "wf_user_pk": None, "wf_user_pks": pks(names),
                           "wf_accounts": len(names), "wf_connections": len(set(e.get("conn") for e in held)),
                           "wf_wrong": len(held), "wf_window": WF_WINDOW})
    return alerts


def wf_alert_key(alert):
    """What "at most once an hour" counts by: the kind and its connection or account."""
    if alert.get("wf_kind") == "account-spread":
        return ("wf_user_pk", alert.get("wf_user_pk"))
    return ("wf_conn", alert.get("wf_conn"))


def wf_password_request(method, data):
    """Will authentik's password stage check a password with this request? Exactly when it is a POST (the only method
    that reaches the stage's answer handling) whose parsed data (`data`: Django REST framework's request.data, the one
    parse the stage uses too; never the raw body) carries a password its serializer accepts: REST framework's
    CharField(trim_whitespace=False) takes a string, an integer or a decimal number, and refuses a missing value, null,
    true or false, anything else, and "" (the stage then never calls a backend). Any other request is never counted."""
    if str(method or "").upper() != "POST" or not hasattr(data, "get"):
        return False
    value = data.get("password", None)
    if value is None or isinstance(value, bool) or not isinstance(value, (str, int, float)):
        return False
    return value != ""


def wf_code_request(method, data, device_classes):
    """Will authentik's code step check a code with this request? A POST carrying a code its serializer accepts (as
    wf_password_request, except that the code's CharField trims spaces, so a code of spaces is blank and never checked)
    while this sign-in offers a method that takes codes. A request that only asks for an email code, or a security
    key's answer, carries no code and is never a code try."""
    if str(method or "").upper() != "POST" or not hasattr(data, "get"):
        return False
    value = data.get("code", None)
    if value is None or isinstance(value, bool) or not isinstance(value, (str, int, float)) or str(value).strip() == "":
        return False
    return any(c in WF_CODE_CLASSES for c in (device_classes or []))


def wf_events(rows, kind):
    """Records as wf_decide reads them, from (created seconds, context) pairs of one kind."""
    out = []
    for at, ctx in rows:
        if not isinstance(ctx, dict):
            continue
        out.append({"at": at, "kind": kind, "try": ctx.get("wf_try"), "account": ctx.get("wf_account"),
                    "conn": wf_connection_key(ctx.get("wf_conn"))})
    return out


# ---- the authentik part: functions only, each importing what it needs when called (python3 alone never calls them;
# bin/tests/authentik-lock-e2e.sh runs them on the pinned authentik with a real database) ----

def wf_lock_key(text):
    """The second key of an advisory lock, from a digest of `text` (a signed 32-bit integer)."""
    import hashlib
    return int(hashlib.sha256(text.encode("utf-8")).hexdigest()[:8], 16) - 2 ** 31


def wf_ak_subject(request):
    """(http request, user or None, account key, connection key, address) of the sign-in this policy decides for. The
    user is a real account (it has a pk), or None for a name nobody has. The address is authentik's own
    (ClientIPMiddleware.get_client_ip, which the gateway decides: contract 2.1); never a header read here, never
    anything from the request's body."""
    from django.conf import settings
    from authentik.root.middleware import ClientIPMiddleware
    http = request.http_request
    user = request.user
    address = ClientIPMiddleware.get_client_ip(http)
    pk = getattr(user, "pk", None)
    account = wf_account_key(pk, getattr(user, "username", ""), settings.SECRET_KEY)
    return http, (user if pk is not None else None), account, wf_connection_key(address), address


def wf_ak_lock(cursor, first, second):
    """Advisory locks for this transaction, in the order given (always the connection's, then the pair's). A lock or a
    query that takes too long fails, and the policy with it (closed)."""
    cursor.execute("SET LOCAL lock_timeout = '5s'")
    cursor.execute("SET LOCAL statement_timeout = '10s'")
    for space, text in (first, second):
        if text is not None:
            cursor.execute("SELECT pg_advisory_xact_lock(%s, %s)", [space, wf_lock_key(text)])


def wf_ak_rows(action, since, within=None, most=None, **context):
    """(created seconds, context) of one kind of record since a time, matching context values; with `within` (an IPv6
    /48), every record whose address lies in it instead of a wf_conn match (authentik keeps the address as PostgreSQL
    inet); with `most`, only the newest that many. Expired records too: authentik hides events past their retention,
    which an administrator can shorten."""
    from authentik.events.models import Event
    rows = Event.objects.db_manager("default").including_expired().filter(action="custom_" + action, created__gte=since)
    for key, value in context.items():
        rows = rows.filter(**{"context__" + key: value})
    if within is not None:
        import ipaddress
        rows = rows.extra(where=["client_ip <<= %s::inet"], params=[str(ipaddress.ip_network(within))])
    rows = rows.order_by("-created").values_list("created", "context")
    if most is not None:
        rows = rows[:most]
    return [(created.timestamp(), ctx) for created, ctx in rows]


def wf_ak_workplace_rows(since, within=None, **context):
    """For a workplace (wf_workplace): one right record per real account with a right password here since a time (the
    newest), at most WF_WORKPLACE_ACCOUNTS of them, so a busy office's month of sign-ins isn't read for every try. The
    records stand in for the account's sign-ins there; they mark no try right (no wf_try)."""
    from django.db.models import Max
    from authentik.events.models import Event
    rows = Event.objects.db_manager("default").including_expired().filter(
        action="custom_" + WF_RIGHT, created__gte=since, context__wf_account__startswith="u:")
    for key, value in context.items():
        rows = rows.filter(**{"context__" + key: value})
    if within is not None:
        import ipaddress
        rows = rows.extra(where=["client_ip <<= %s::inet"], params=[str(ipaddress.ip_network(within))])
    rows = rows.values("context__wf_account").annotate(newest=Max("created")).order_by()[:WF_WORKPLACE_ACCOUNTS]
    return [(r["newest"].timestamp(), {"wf_account": r["context__wf_account"]}) for r in rows]


def wf_ak_record(action, keep, address, user=None, **context):
    """Writes one record (an authentik event, custom_<action>), kept at least `keep` seconds. The context is exactly
    what is given. A real account's records carry it as the event's user ({pk, username}: the application asks for one
    person's records with ?username=); a name nobody has carries no user (it is never stored readably)."""
    from datetime import timedelta
    from django.utils import timezone
    from authentik.events.models import Event
    record = Event.new(action, app="workforce", **context)
    record.expires = timezone.now() + timedelta(seconds=keep)
    record.user = {"pk": int(user.pk), "username": str(user.username)} if user is not None else {}
    try:
        import ipaddress
        record.client_ip = str(ipaddress.ip_address(str(address)))
    except ValueError:
        record.client_ip = None
    record.save()
    return record


def wf_ak_marker(user, now):
    """The account's marker (wf_marker), read from the database now (not from the sign-in's copy of the account, which
    is as old as the sign-in: an unlock while the password page is open counts at once). None for a name nobody has."""
    from authentik.core.models import User
    if user is None:
        return None
    row = User.objects.filter(pk=int(user.pk)).values_list("password_change_date", "attributes").first()
    return wf_marker(row[0], row[1], now) if row else None


WF_MOST_ROWS = 2000                # newest tries read from one connection or /48 (only a workplace, never throttled, has more)


def wf_ak_events(conn, account, user, now, spread):
    """The records a decision (and, with `spread`, the alerts) needs, and the markers: tries from this connection (and
    its /48) in the look-back (an hour for alerts) and the right records that mark them; this pair's own tries; whether
    the connection (and /48) is a workplace; and for alerts this account's tries of the last day."""
    from datetime import datetime, timezone as tz
    def at(seconds):
        return datetime.fromtimestamp(seconds, tz.utc)
    back = WF_SPREAD_HOUR if spread else WF_LOOK_BACK
    tries = wf_ak_rows(WF_TRY, at(now - back), most=WF_MOST_ROWS, wf_conn=conn)
    rights = wf_ak_rows(WF_RIGHT, at(now - back), wf_conn=conn)
    # The pair's own tries, always all of them (the newest WF_MOST_ROWS above can't hide a pause).
    tries = tries + wf_ak_rows(WF_TRY, at(now - WF_LOOK_BACK), wf_account=account, wf_conn=conn)
    places = [(wf_ak_workplace_rows(at(now - WF_KNOWN_FOR), wf_conn=conn), conn)]
    if ":" in conn:
        net = wf_network_key(conn)
        tries = tries + wf_ak_rows(WF_TRY, at(now - back), within=net, most=WF_MOST_ROWS)
        rights = rights + wf_ak_rows(WF_RIGHT, at(now - back), within=net)
        places.append((wf_ak_workplace_rows(at(now - WF_KNOWN_FOR), within=net), net))
    if spread and user is not None:
        tries = tries + wf_ak_rows(WF_TRY, at(now - WF_SPREAD_DAY), wf_account=account)
        rights = rights + wf_ak_rows(WF_RIGHT, at(now - WF_SPREAD_DAY), wf_account=account)
    seen = set()
    events = []
    for e in wf_events(tries, "try") + wf_events(rights, "right"):
        key = (e["kind"], e["try"], e["at"])
        if key not in seen:
            seen.add(key)
            events.append(e)
    for rows, where in places:
        for at_, ctx in rows:
            events.append({"at": at_, "kind": "right", "try": None, "account": ctx.get("wf_account"), "conn": where})
    marker = wf_ak_marker(user, now)
    return events, ({account: marker} if marker is not None else {})


def wf_ak_refused(decision, address, person, account, conn, now, locked=False):
    """Records a refusal (custom_workforce_password_refused: why and until when), at most once a WF_REFUSED_GAP per
    pair, under the pair's locks unless the caller holds them. A refusal is never a try: it moves no pause or throttle.
    Returns whether the request is refused (paused or throttled)."""
    from datetime import datetime, timezone as tz
    from django.db import connections, transaction
    if not (decision["paused"] or decision["throttled"]):
        return False
    with transaction.atomic(using="default"):
        if not locked:
            with connections["default"].cursor() as cursor:
                wf_ak_lock(cursor, (WF_LOCK_CONN, "conn:" + conn), (WF_LOCK_PAIR, "pair:" + account + "|" + conn))
        if not wf_ak_rows(WF_REFUSED, datetime.fromtimestamp(now - WF_REFUSED_GAP, tz.utc), wf_conn=conn,
                          wf_account=account):
            wf_ak_record(WF_REFUSED, WF_KEEP_REFUSED, address, person, wf_account=account, wf_conn=conn,
                         wf_user_pk=getattr(person, "pk", None), wf_why="throttled" if decision["throttled"] else "paused",
                         wf_until=wf_iso(decision["until"]))
    return True


def wf_iso(seconds):
    from datetime import datetime, timezone as tz
    return datetime.fromtimestamp(int(seconds), tz.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
