# Workforce issue 462 (ADR-0039, amendment of 14 November 2026, revised 15 November 2026; the private repo's
# docs/architecture/462-lockout-contract.md, section R, which wins over its sections 1 to 7): wrong passwords pause
# one name on one source, a source that tries many names is held, an IPv6 /48 under attack is tightened, attempts
# spread over names or sources raise alerts, and the sign-in status interface answers the application. The decision
# only: plain Python, nothing from authentik or Django, so that bin/tests/password-pause-test.sh tests it with python3
# alone, against bin/tests/password-pause-vectors.json (the vectors live here only since 15 November: the
# application no longer computes a pause, it asks the sign-in server, contract R.7).
#
# workforce-app.yaml.j2 includes this file at the top of the expression policies that decide and record, of the
# client-address probe and of the sign-in status code, and adds the authentik part below it (the lock, the records,
# the request). authentik runs an expression as the body of a function, so this file holds only constants and
# functions; nothing in it runs on its own. It is a Jinja include: never write two braces, or a brace and a percent
# or hash sign, side by side here.
#
# Words (contract R.2). A source is what the owner calls a connection: the address the gateway alone decides (an IPv4
# address; an IPv4-mapped IPv6 address as its IPv4; any other IPv6 address as its /64). Never a TCP connection, a
# browser session, a cookie, a page, a flow or a typed name: every count lives in the sign-in server's database under
# the source's key, so a new connection, session or page changes nothing. A network is an IPv6 source's /48. A try is
# a password the password stage will check; it is wrong until the flow reaches the step after the password. A refused
# request is never recorded, so it never moves an end. Times are seconds since the epoch, UTC.
#
# The rules (contract R.3 to R.6; the owner's numbers of 14 and 15 November 2026):
# - pair: 5 wrong tries for one name from one source within 15 minutes refuse that name there until 15 minutes after
#   the fifth (after the account's marker: its last password change or its last unlock, R.7.4);
# - source: 10 wrong tries from one source within 15 minutes, every name together (username, email, unknown, any
#   spelling), refuse every name there until 15 minutes after the tenth; a workplace source's cap is
#   SIGN_IN_WORKPLACE_SOURCE_LIMIT (default 50, 20 to 100; the owner's Q1): higher, never unlimited;
# - network (IPv6): 30 wrong tries from one /48 within 15 minutes (SIGN_IN_WORKPLACE_NETWORK_LIMIT for a workplace
#   network, default 300, 100 to 1000) tighten the /48: only its unproven sources (nobody completed a sign-in there in
#   30 days) and its abusive ones (5 or more wrong in its own window, each for at most 15 minutes after its own
#   newest; a right password excuses only a source the operator confirmed) are refused, quiet unproven ones too, for at
#   most 15 minutes after the /48's newest counted try (the owner's Q2); quiet, proven sources carry on;
# - a workplace source: ONLY one the operator confirmed (CLIENT_ADDRESSES_CONFIRMED: an IPv4 address or range of a /24
#   or narrower, an IPv6 address or range of a /64 or narrower); a workplace network, only a /48 holding a confirmed
#   entry from a /48 to a /63. Nothing else makes either: not completed sign-ins, however many people's (the owner's
#   Q3, 15 November 2026, removed that learned rule), and nothing from the browser, so no user can choose or claim it.
# - proven is not workplace: a source is proven when someone completed a sign-in there (the right password and the
#   right code) in the last 30 days, or it is confirmed. Being proven only keeps a quiet source out of its /48's
#   tightening and shows its address to the organisations whose people signed in there (the alerts' affected
#   accounts, the owner's Q5); it never raises a cap.

WF_PAUSE_AFTER = 5                 # wrong passwords for one pair within WF_WINDOW
WF_SOURCE_AFTER = 10               # wrong passwords from one ordinary source, every name, within WF_WINDOW (fixed)
WF_WORKPLACE_SOURCE_AFTER = 50     # the same for a workplace source: SIGN_IN_WORKPLACE_SOURCE_LIMIT's default
WF_WORKPLACE_SOURCE_RANGE = (20, 100)
WF_NETWORK_AFTER = 30              # wrong passwords from one IPv6 /48 that tighten it (fixed)
WF_WORKPLACE_NETWORK_AFTER = 300   # the same for a workplace network: SIGN_IN_WORKPLACE_NETWORK_LIMIT's default
WF_WORKPLACE_NETWORK_RANGE = (100, 1000)
WF_ABUSIVE_AFTER = 5               # wrong passwords, and no right one, that make a source abusive in a tightened /48
WF_WINDOW = 15 * 60                # every count is over this, and a hold lasts this long after the try that reached it
WF_LOOK_BACK = 30 * 60             # how far back tries are read for a decision (a window plus its wait)
WF_KNOWN_FOR = 30 * 86400          # how far back completed sign-ins count (proven; alerts' affected accounts)
WF_FUTURE = 120                    # a marker more than this far ahead is ignored (a clock gone wrong)
WF_SPREAD_HOUR = 3600              # spread detection: one source, many names; one account, many sources
WF_SPREAD_ACCOUNTS = 5
WF_SPREAD_CONNECTIONS = 3
WF_SPREAD_DAY = 86400              # or many wrong passwords for one account in a day
WF_SPREAD_DAY_WRONG = 20
WF_ALERT_GAP = 3600                # each kind of alert, for one source, network or account, at most once in this
WF_ALERT_MOST_PKS = 50             # real accounts named in one alert, at most
WF_REFUSED_GAP = 60                # a refusal is recorded at most once in this, per pair
WF_UNLOCK_SKEW = 120               # an unlock asked for more than this far from the server's time is refused (stale)
WF_ALERTS_MOST = 200               # alerts in one answer of the status interface, at most
# What a confirmed entry (CLIENT_ADDRESSES_CONFIRMED) does for the limits (contract R.4; review of 15 November 2026,
# findings 3 and 17). An IPv4 entry of a /24 or narrower, or an IPv6 entry of a /64 or narrower, makes the source(s) it
# lies in workplace sources (and proven). An IPv6 entry from a /48 to a /63 makes its /48 a workplace network only (the
# higher network limit), never its /64s: every /64 there stays an ordinary, unproven source until someone completes a
# sign-in from it, so rotating /64s inside a confirmed range are still bounded by the network's limit (R.6.2). A wider
# entry confirms concentration for the readiness check only (bin/lib/client-address.sh) and never raises a limit.
WF_CONFIRMED_SOURCE_WIDEST = {4: 24, 6: 64}
WF_CONFIRMED_NETWORK_WIDEST = 48

# How long each record is kept, whatever authentik's event retention (contract 3.2 and R.0).
WF_KEEP_TRY = 25 * 3600
WF_KEEP_RIGHT = 31 * 86400
WF_KEEP_REFUSED = 3600
WF_KEEP_ALERT = 31 * 86400
WF_KEEP_SIGNED = 31 * 86400
WF_KEEP_UNLOCK = 31 * 86400
WF_RIGHT_FALLBACK = 60             # with no try in the flow plan: the pair's newest unmarked try of this many seconds

# authentik events (custom_<name>); the context keys are fixed (contract 3.2, R.7) and nothing else goes in.
WF_TRY = "workforce_password_try"
WF_RIGHT = "workforce_password_right"
WF_REFUSED = "workforce_password_refused"
WF_ALERT = "workforce_password_alert"
WF_SIGNED = "workforce_signed_in"                    # a completed sign-in: the right password and the right code
WF_UNLOCK = "workforce_password_unlock"              # an unlock, written only by the sign-in status interface
WF_UNLOCK_VOID = "workforce_password_unlock_void"    # an unlock id asked about before it was applied: never applied
WF_PLAN_TRY = "wf_password_try"    # the flow plan's key for this sign-in's newest try
WF_FORWARDED_HEADER = "HTTP_X_WORKFORCE_FORWARDED"   # the gateway's mark: forwarding headers from a peer nobody named
WF_LOCK_CONN = 1464225601          # first key of the PostgreSQL advisory lock per source (always taken first)
WF_LOCK_NET = 1464225604           # then per IPv6 /48, when a try is recorded (review finding 4)
WF_LOCK_PAIR = 1464225602          # then per pair (name and source)
WF_LOCK_ACCOUNT = 1464225605       # an unlock: per account, then per unlock id
WF_LOCK_UNLOCK_ID = 1464225606
WF_PLAN_IDENTIFIER = "pending_user_identifier"   # authentik's flow plan key for the name as typed (show_matched_user off)
WF_CODE_CLASSES = ("totp", "static", "sms", "email")
WF_STATUS_NAME = "workforce-sign-in-status"      # the property mapping the application tests (contract R.7.2)
WF_STATUS_CALLER = "workforce-invites"           # the application's service account, the only caller answered
WF_KEYS = dict()                   # source and network keys already worked out in this evaluation (by kind and text)


def wf_connection_key(address):
    """The source an address belongs to: IPv4 as a dotted quad; an IPv4-mapped IPv6 address as its IPv4; any other
    IPv6 address as its /64 network ("2001:db8:1:2::/64"), because one home or phone line holds billions of them. A key
    is its own key. Anything that isn't an address is kept as it is, trimmed and lower-cased (never looked up)."""
    import ipaddress
    text = str(address if address is not None else "").strip().lower()
    known = WF_KEYS.get(("c", text))
    if known is not None:
        return known
    WF_KEYS[("c", text)] = key = wf_connection_key_of(text, ipaddress)
    return key


def wf_connection_key_of(text, ipaddress):
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
    """The network an address (or a source key) belongs to: IPv4 (and IPv4-mapped) as the address; IPv6 as its /48
    ("2001:db8:1::/48"), because one hosting or home allocation holds 65,536 /64s or more. A key is its own key."""
    import ipaddress
    text = str(address if address is not None else "").strip().lower()
    known = WF_KEYS.get(("n", text))
    if known is not None:
        return known
    WF_KEYS[("n", text)] = key = wf_network_key_of(text, ipaddress)
    return key


def wf_network_key_of(text, ipaddress):
    if text.endswith("/48"):
        text = text[:-3]
    key = wf_connection_key(text)
    if not key.endswith("/64"):
        return key
    try:
        return str(ipaddress.ip_network((ipaddress.ip_address(key[:-3]), 48), strict=False))
    except ValueError:
        return key


def wf_name_key(secret, folded):
    """A name's account key: never the name itself, an HMAC of it under the server's own secret. `folded` is the name
    as typed, folded exactly as authentik's lookup folds it (PostgreSQL's UPPER, which its case-insensitive match
    compares: wf_ak_subject asks the database), so two spellings share a key exactly when they find the same
    account."""
    import hashlib
    import hmac
    name = str(folded if folded is not None else "")
    digest = hmac.new(str(secret).encode("utf-8"), ("wf-name:" + name).encode("utf-8"), hashlib.sha256).hexdigest()
    return "n:" + digest[:32]


def wf_account_key(pk, typed, username, secret):
    """The pause's account key for a name as typed (`typed` and the account's `username` both folded, see
    wf_name_key): u:<pk> when a real account was found by its username; otherwise the typed name's key, for a name
    nobody has (authentik's pretend user, no pk) and for a real account found by another name (its email). So the
    count follows the typed name alike for every name, real or not, and the pause can't tell anyone which exist."""
    if pk is not None and (typed is None or typed == username):
        return "u:%d" % int(pk)
    return wf_name_key(secret, typed if typed is not None else username)


def wf_parse_time(value):
    """Seconds for an ISO-8601 time ("2026-11-14T14:05:02Z", or with an offset or microseconds), or None if it isn't
    one. A datetime is taken as it is; one without a zone is UTC."""
    import datetime
    if value is None or isinstance(value, bool):
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


def wf_iso(seconds):
    """An instant as the records and answers write it: UTC, with microseconds ("2026-11-15T10:00:00.123456Z")."""
    from datetime import datetime, timezone as tz
    return datetime.fromtimestamp(float(seconds), tz.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def wf_limits(environ):
    """The settings the rules read (contract R.3, R.4), from the sign-in server's environment, checked again here: a
    value missing gives the default; one that isn't a whole number in range, or a workplace source limit not below the
    workplace network limit (one source could then tighten a /48 alone), gives the default and is named in
    `warnings` (the health check's "sign-in limits" row checks the same). CLIENT_ADDRESSES_CONFIRMED: addresses,
    IPv6 source keys or ranges, separated by spaces or commas; an entry that isn't one is ignored and named.
    `confirmed` holds the entries that make sources workplace sources, `confirmed_networks` those that make a /48 a
    workplace network, and `readiness_only` counts the wider ones, which raise no limit (WF_CONFIRMED_SOURCE_WIDEST)."""
    import ipaddress
    import re
    env = environ if hasattr(environ, "get") else {}
    warnings = []

    def number(name, default, low, high):
        raw = str(env.get(name, "") or "").strip()
        if raw == "":
            return default
        if not re.fullmatch(r"[0-9]{1,6}", raw) or not low <= int(raw) <= high:
            warnings.append(name)
            return default
        return int(raw)

    source = number("SIGN_IN_WORKPLACE_SOURCE_LIMIT", WF_WORKPLACE_SOURCE_AFTER, *WF_WORKPLACE_SOURCE_RANGE)
    network = number("SIGN_IN_WORKPLACE_NETWORK_LIMIT", WF_WORKPLACE_NETWORK_AFTER, *WF_WORKPLACE_NETWORK_RANGE)
    if source >= network:
        warnings += ["SIGN_IN_WORKPLACE_SOURCE_LIMIT", "SIGN_IN_WORKPLACE_NETWORK_LIMIT"]
        source, network = WF_WORKPLACE_SOURCE_AFTER, WF_WORKPLACE_NETWORK_AFTER
    confirmed = []
    networks = []
    readiness_only = 0
    for item in re.split(r"[\s,]+", str(env.get("CLIENT_ADDRESSES_CONFIRMED", "") or "").strip()):
        if not item:
            continue
        text = item.strip().lower()
        if text.startswith("[") and "]" in text:
            text = text[1:].replace("]", "", 1)
        try:
            net = ipaddress.ip_network(text, strict=False)
            if net.version == 6 and net.network_address.ipv4_mapped is not None and net.prefixlen >= 96:
                net = ipaddress.ip_network((net.network_address.ipv4_mapped, net.prefixlen - 96), strict=False)
        except ValueError:
            warnings.append("CLIENT_ADDRESSES_CONFIRMED")
            continue
        if net.prefixlen >= WF_CONFIRMED_SOURCE_WIDEST[net.version]:
            confirmed.append(net)
        elif net.version == 6 and net.prefixlen >= WF_CONFIRMED_NETWORK_WIDEST:
            networks.append(net)
        else:
            readiness_only += 1
    return {"source": source, "network": network, "confirmed": confirmed, "confirmed_networks": networks,
            "readiness_only": readiness_only, "warnings": sorted(set(warnings))}


def wf_confirmed(key, confirmed):
    """Is this source (or /48) the operator's: does it overlap an entry of the list given (wf_limits' `confirmed` for a
    source, whose entries are never wider than a source, so overlapping is lying inside it; `confirmed_networks` for a
    /48, whose entries are never wider than it)?"""
    import ipaddress
    try:
        net = ipaddress.ip_network(str(key), strict=False)
    except ValueError:
        return False
    return any(net.version == c.version and net.overlaps(c) for c in (confirmed or []))


def wf_marker(password_changed, unlocks, now):
    """An account's marker: the later of its last password change and its last unlock (the times of the
    custom_workforce_password_unlock records the sign-in server wrote, by its own clock; never an attribute, which
    the application's credential could write). Wrong passwords before it no longer count for a pair. A time more than
    WF_FUTURE ahead, or one that can't be read, is ignored; `unlocks` that isn't a list is ignored whole. None when
    there is none."""
    times = [wf_parse_time(password_changed)]
    if isinstance(unlocks, (list, tuple)):
        times += [wf_parse_time(u) for u in unlocks]
    best = None
    for t in times:
        if t is not None and t <= now + WF_FUTURE and (best is None or t > best):
            best = t
    return best


def wf_right_tries(events):
    return set(e.get("try") for e in events if e.get("kind") == "right" and e.get("try") is not None)


def wf_is_wrong(e, right, now, since):
    return e.get("kind") == "try" and e.get("try") not in right and since <= e["at"] <= now


def wf_held_until(times, limit, now):
    """The hold rule (contract R.2): let L be the newest; held while `limit` or more fell in [L - WF_WINDOW, L] and now
    is before L + WF_WINDOW. Returns the end, or None."""
    if not times:
        return None
    newest = max(times)
    if sum(1 for t in times if t >= newest - WF_WINDOW) >= limit and now < newest + WF_WINDOW:
        return newest + WF_WINDOW
    return None


def wf_signed_accounts(events, key, network, now):
    """Different real accounts with a completed sign-in (a "signed" record) from here (a source key, or with `network`
    a /48) in the last WF_KNOWN_FOR. One account counts once, however often it signed in. Used for proven (any) and
    for the alerts' affected accounts; never for workplace (the owner's Q3)."""
    accounts = set()
    for e in events:
        if e.get("kind") != "signed" or not str(e.get("account") or "").startswith("u:"):
            continue
        if not now - WF_KNOWN_FOR <= e["at"] <= now:
            continue
        if (wf_network_key(e.get("conn")) if network else e.get("conn")) == key:
            accounts.add(e["account"])
    return accounts


def wf_proven(events, conn, cfg, now):
    """A proven source: someone completed a sign-in from it in the last 30 days, or the operator confirmed it. Proven
    only spares a source its /48's tightening (wf_network_refusal); it is never a workplace and never raises a cap."""
    return wf_confirmed(conn, cfg["confirmed"]) or bool(wf_signed_accounts(events, conn, False, now))


def wf_workplace(key, network, cfg):
    """A workplace source (or, with `network`, a workplace /48): confirmed by the operator, and only that (the owner's
    Q3): a source by an entry no wider than a source, a /48 by an entry from a /48 to a /63. No record is read, so no
    sign-in, typed name or anything the browser sends can make one."""
    listed = cfg.get("confirmed_networks", []) if network else cfg["confirmed"]
    return wf_confirmed(key, listed)


def wf_paused_until(events, right, account, conn, marker, now):
    times = [e["at"] for e in events
             if e.get("account") == account and e.get("conn") == conn and wf_is_wrong(e, right, now, now - WF_LOOK_BACK)
             and (marker is None or e["at"] > marker)]
    return wf_held_until(times, WF_PAUSE_AFTER, now)


def wf_source_times(events, right, key, network, now):
    return [e["at"] for e in events if wf_is_wrong(e, right, now, now - WF_LOOK_BACK)
            and (wf_network_key(e.get("conn")) if network else e.get("conn")) == key]


def wf_source_until(events, right, conn, cfg, now):
    """The source cap (contract R.3): (the hold's end or None, whether it is a workplace source)."""
    workplace = wf_workplace(conn, False, cfg)
    limit = cfg["source"] if workplace else WF_SOURCE_AFTER
    return wf_held_until(wf_source_times(events, right, conn, False, now), limit, now), workplace


def wf_network_until(events, right, net, cfg, now):
    """The network's tightening (contract R.6): (its end or None, whether it is a workplace network)."""
    workplace = wf_workplace(net, True, cfg)
    limit = cfg["network"] if workplace else WF_NETWORK_AFTER
    return wf_held_until(wf_source_times(events, right, net, True, now), limit, now), workplace


def wf_network_refusal(events, right, conn, net_until, cfg, now):
    """While the /48 is tightened (until `net_until`): this source's refusal end, or None (contract R.6.2). Unproven:
    refused until the tightening ends. Abusive (WF_ABUSIVE_AFTER or more wrong in its own window): refused, never after
    15 minutes from its own newest wrong try. A right password from the source in that window excuses it only when the
    operator confirmed the source (review of 15 November 2026, finding 2: otherwise anyone with an account could
    excuse their own source by typing their own password once). Any other source (quiet and proven) is never refused
    by the network."""
    if net_until is None:
        return None
    if not wf_proven(events, conn, cfg, now):
        return net_until
    times = wf_source_times(events, right, conn, False, now)
    if not times:
        return None
    newest = max(times)
    recent = [t for t in times if t >= newest - WF_WINDOW]
    righted = wf_confirmed(conn, cfg["confirmed"]) and any(
        e.get("kind") == "right" and e.get("conn") == conn and newest - WF_WINDOW <= e["at"] <= now for e in events)
    if len(recent) >= WF_ABUSIVE_AFTER and not righted and now < newest + WF_WINDOW:
        return min(newest + WF_WINDOW, net_until)
    return None


def wf_decide(events, account, conn, markers, now, cfg=None):
    """May `account` try a password from `conn` now? `events` are the records, each a dict: at (seconds), kind ("try",
    "right" or "signed"), try (the try's id, which a right record names), account (account key), conn (source key).
    `markers` maps an account key to its marker (seconds), where it has one; it lifts the pair only. `cfg` is
    wf_limits(). Returns paused (the pair), source (the source cap), network (refused by a tightened /48), throttled
    (source or network), rule (which words: "source", then "network", then "paused": an unlock lifts only the last),
    workplace (a workplace source) and until (the latest end, or None)."""
    cfg = cfg if cfg is not None else wf_limits({})
    conn = wf_connection_key(conn)
    right = wf_right_tries(events)
    paused_until = wf_paused_until(events, right, account, conn, markers.get(account), now)
    source_until, workplace = wf_source_until(events, right, conn, cfg, now)
    network_until = None
    if ":" in conn:
        net_until, _ = wf_network_until(events, right, wf_network_key(conn), cfg, now)
        network_until = wf_network_refusal(events, right, conn, net_until, cfg, now)
    rule = "source" if source_until else "network" if network_until else "paused" if paused_until else None
    ends = [t for t in (paused_until, source_until, network_until) if t is not None]
    return {"paused": paused_until is not None, "source": source_until is not None, "network": network_until is not None,
            "throttled": source_until is not None or network_until is not None, "rule": rule, "workplace": workplace,
            "until": max(ends) if ends else None}


def wf_spread(events, account, conn, user_pk, now, before=None, cfg=None):
    """Alerts the newest try (already in `events`) raises: connection-spread (one source, or one IPv6 /48, many
    names), account-spread, and, with `before` (the events without it), a hold that has just begun: throttled (an
    ordinary source's cap), workplace-throttled (a workplace source's), network-tightened (a /48). Every alert about a
    source or a /48 names, as wf_affected_pks, the accounts with a completed sign-in from there in the last 30 days (at
    most WF_ALERT_MOST_PKS): the application shows the place's address only to an organisation with one of its own
    people among them (the owner's Q5). `events` must reach back WF_SPREAD_DAY, and WF_KNOWN_FOR for "signed" records.
    Each alert is a dict of the record's context. Alerts only: nothing here changes a decision."""
    cfg = cfg if cfg is not None else wf_limits({})
    conn = wf_connection_key(conn)
    right = wf_right_tries(events)
    alerts = []

    def pks(accounts):
        out = []
        for a in sorted(accounts):
            if str(a).startswith("u:") and a[2:].isdigit() and int(a[2:]) not in out:
                out.append(int(a[2:]))
        return out[:WF_ALERT_MOST_PKS]

    def alert(kind, key, user, names, conns, wrong, window, workplace=False, affected=()):
        return {"wf_kind": kind, "wf_conn": key, "wf_user_pk": user, "wf_user_pks": pks(names), "wf_accounts": len(names),
                "wf_connections": conns, "wf_wrong": wrong, "wf_window": window, "wf_workplace": bool(workplace),
                "wf_affected_pks": pks(affected)}

    hour = [e for e in events if wf_is_wrong(e, right, now, now - WF_SPREAD_HOUR)]
    keys = [(conn, False)] + ([(wf_network_key(conn), True)] if ":" in conn else [])
    for key, network in keys:
        from_here = [e for e in hour if (wf_network_key(e.get("conn")) if network else e.get("conn")) == key]
        names = set(e.get("account") for e in from_here)
        if len(names) >= WF_SPREAD_ACCOUNTS:
            alerts.append(alert("connection-spread", key, None, names, len(set(e.get("conn") for e in from_here)),
                                len(from_here), WF_SPREAD_HOUR, False, wf_signed_accounts(events, key, network, now)))
    if user_pk is not None:
        # The person, whichever of their names was typed (each counts apart for the pause, never for an alert).
        def mine(e):
            return e.get("account") == account or (e.get("pk") is not None and e.get("pk") == int(user_pk))
        mine_hour = [e for e in hour if mine(e)]
        conns = set(e.get("conn") for e in mine_hour)
        mine_day = [e for e in events if mine(e) and wf_is_wrong(e, right, now, now - WF_SPREAD_DAY)]
        if len(conns) >= WF_SPREAD_CONNECTIONS:
            alerts.append(alert("account-spread", None, int(user_pk), ["u:%d" % int(user_pk)], len(conns),
                                len(mine_hour), WF_SPREAD_HOUR))
        elif len(mine_day) >= WF_SPREAD_DAY_WRONG:
            alerts.append(alert("account-spread", None, int(user_pk), ["u:%d" % int(user_pk)],
                                len(set(e.get("conn") for e in mine_day)), len(mine_day), WF_SPREAD_DAY))
    if before is not None:
        right_before = wf_right_tries(before)
        held, workplace = wf_source_until(events, right, conn, cfg, now)
        if held is not None and wf_source_until(before, right_before, conn, cfg, now)[0] is None:
            times = [e for e in events if wf_is_wrong(e, right, now, now - WF_LOOK_BACK) and e.get("conn") == conn]
            names = set(e.get("account") for e in times)
            alerts.append(alert("workplace-throttled" if workplace else "throttled", conn, None, names, 1, len(times),
                                WF_WINDOW, workplace, wf_signed_accounts(events, conn, False, now)))
        if ":" in conn:
            net = wf_network_key(conn)
            held, workplace = wf_network_until(events, right, net, cfg, now)
            if held is not None and wf_network_until(before, right_before, net, cfg, now)[0] is None:
                times = [e for e in events if wf_is_wrong(e, right, now, now - WF_LOOK_BACK)
                         and wf_network_key(e.get("conn")) == net]
                names = set(e.get("account") for e in times)
                alerts.append(alert("network-tightened", net, None, names, len(set(e.get("conn") for e in times)),
                                    len(times), WF_WINDOW, workplace, wf_signed_accounts(events, net, True, now)))
    return alerts


def wf_alert_key(alert):
    """What "at most once an hour" counts by: the kind and its source, network or account."""
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
        pk = ctx.get("wf_user_pk")
        pk = pk if isinstance(pk, int) and not isinstance(pk, bool) else None
        account = ctx.get("wf_account")
        if kind == "signed":
            account = "u:%d" % pk if pk is not None else None
        out.append({"at": at, "kind": kind, "try": ctx.get("wf_try"), "account": account,
                    "conn": wf_connection_key(ctx.get("wf_conn")), "pk": pk})
    return out


# ---- the sign-in status interface (contract R.7): pure parts ----

def wf_status(events, user_pk, marker, now):
    """Is this person paused anywhere? The pair rule over every name the records tie to them (their username's key,
    and any other name that found their account, such as their email), each per source, after their marker. Returns
    paused, pausedSources (how many sources) and until (the latest end, or None)."""
    right = wf_right_tries(events)
    own = "u:%d" % int(user_pk)
    pairs = set((e.get("account"), e.get("conn")) for e in events
                if e.get("kind") == "try" and (e.get("account") == own or e.get("pk") == int(user_pk)))
    ends = {}
    for account, conn in pairs:
        until = wf_paused_until(events, right, account, conn, marker, now)
        if until is not None:
            ends[conn] = max(until, ends.get(conn, until))
    return {"paused": bool(ends), "pausedSources": len(ends), "until": max(ends.values()) if ends else None}


def wf_unlock_id_ok(text):
    """An unlock id: a random UUID (version 4), lower-case."""
    import re
    return isinstance(text, str) and re.fullmatch(
        r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", text) is not None


def wf_unlock_decide(applied, voided, unlock_id, user_pk, requested_at, now):
    """What to do with an unlock (contract R.7.4). `applied` are (seconds, user pk, was paused) of the unlock records
    with this id (any account); `voided` whether the id was voided. Returns ("apply", None), or ("answer", the answer)
    for an id already used: the same id for the same account answers as the first time and changes nothing; for
    another account, or voided, it is refused ("reused"); a request time more than WF_UNLOCK_SKEW from the server's is
    refused ("stale"), so a captured request can't be used later; an id that isn't a fresh random one, "invalid"."""
    if not wf_unlock_id_ok(unlock_id):
        return "answer", {"v": 1, "op": "unlock", "applied": False, "why": "invalid"}
    for at, pk, was in applied:
        if pk == user_pk:
            return "answer", {"v": 1, "op": "unlock", "applied": True, "id": unlock_id, "at": wf_iso(at),
                              "wasPaused": bool(was), "repeated": True}
        return "answer", {"v": 1, "op": "unlock", "applied": False, "why": "reused"}
    if voided:
        return "answer", {"v": 1, "op": "unlock", "applied": False, "why": "reused"}
    asked = wf_parse_time(requested_at)
    if asked is None or abs(now - asked) > WF_UNLOCK_SKEW:
        return "answer", {"v": 1, "op": "unlock", "applied": False, "why": "stale"}
    return "apply", None


def wf_unlock_status_decide(applied, voided, unlock_id, user_pk):
    """The answer to "was this unlock applied?" (contract R.7.4): ("answer", it), or ("void", it) when the id was never
    applied nor voided, which the caller then voids, so a delayed unlock with it can never apply afterwards."""
    if not wf_unlock_id_ok(unlock_id):
        return "answer", {"v": 1, "op": "unlock-status", "applied": False, "why": "invalid"}
    for at, pk, was in applied:
        if pk == user_pk:
            return "answer", {"v": 1, "op": "unlock-status", "applied": True, "id": unlock_id, "at": wf_iso(at)}
        return "answer", {"v": 1, "op": "unlock-status", "applied": False, "why": "reused"}
    if voided:
        return "answer", {"v": 1, "op": "unlock-status", "applied": False, "voided": True, "id": unlock_id}
    return "void", {"v": 1, "op": "unlock-status", "applied": False, "voided": True, "id": unlock_id}


def wf_alert_out(event_id, at, ctx):
    """One alert as the status interface answers it: counts, keys and account numbers only, never a typed name."""
    ctx = ctx if isinstance(ctx, dict) else {}
    kind = str(ctx.get("wf_kind") or "")
    source = ctx.get("wf_conn")
    if kind == "account-spread":
        scope = "account"
    elif kind == "network-tightened" or str(source or "").endswith("/48"):
        scope = "network"
    else:
        scope = "source"

    def ints(value):
        return [int(x) for x in (value or []) if isinstance(x, int) and not isinstance(x, bool)][:WF_ALERT_MOST_PKS]

    def count(value):
        return int(value) if isinstance(value, int) and not isinstance(value, bool) else 0
    return {"id": str(event_id), "at": wf_iso(at), "kind": kind, "scope": scope,
            "source": str(source) if source is not None else None, "workplace": ctx.get("wf_workplace") is True,
            "accounts": count(ctx.get("wf_accounts")), "sources": count(ctx.get("wf_connections")),
            "wrong": count(ctx.get("wf_wrong")), "window": count(ctx.get("wf_window")),
            "userPks": ints(ctx.get("wf_user_pks")), "affectedPks": ints(ctx.get("wf_affected_pks"))}


def wf_alert_cursor(text):
    """(seconds, event id) from an alerts cursor ("<ISO time>|<event id>"), or None for none or one that isn't."""
    import re
    parts = str(text or "").split("|")
    if len(parts) != 2 or not re.fullmatch(r"[0-9a-f-]{32,36}", parts[1]):
        return None
    at = wf_parse_time(parts[0])
    return (at, parts[1]) if at is not None else None


# ---- the authentik part: functions only, each importing what it needs when called (python3 alone never calls them;
# bin/tests/authentik-lock-e2e.sh runs them on the pinned authentik with a real database) ----

def wf_lock_key(text):
    """The second key of an advisory lock, from a digest of `text` (a signed 32-bit integer)."""
    import hashlib
    return int(hashlib.sha256(text.encode("utf-8")).hexdigest()[:8], 16) - 2 ** 31


def wf_ak_limits():
    """wf_limits() of the sign-in server's own environment (compose.yaml passes the three settings)."""
    import os
    return wf_limits(os.environ)


def wf_ak_subject(request):
    """(http request, user or None, account key, source key, address) of the sign-in this policy decides for. The
    user is a real account (it has a pk), or None for a name nobody has. The account key is by the name as typed
    (the flow plan's pending_user_identifier, which the identification stage keeps for every name with
    show_matched_user off; the pending user's username otherwise), folded by the database exactly as authentik's
    lookup folds it (its iexact is UPPER(field) = UPPER(typed)): wf_account_key. The address is authentik's own
    (ClientIPMiddleware.get_client_ip, which the gateway decides: contract 2.1); never a header read here, never
    anything from the request's body."""
    from django.conf import settings
    from django.db import connections
    from authentik.root.middleware import ClientIPMiddleware
    http = request.http_request
    user = request.user
    address = ClientIPMiddleware.get_client_ip(http)
    pk = getattr(user, "pk", None)
    username = str(getattr(user, "username", "") or "")
    plan = request.context.get("flow_plan")
    typed = plan.context.get(WF_PLAN_IDENTIFIER) if plan is not None else None
    typed = str(typed).strip() if isinstance(typed, str) and typed.strip() else username
    with connections["default"].cursor() as cursor:
        cursor.execute("SELECT UPPER(%s), UPPER(%s)", [typed, username])
        folded, own = cursor.fetchone()
    account = wf_account_key(pk, folded, own, settings.SECRET_KEY)
    return http, (user if pk is not None else None), account, wf_connection_key(address), address


def wf_ak_lock(cursor, *locks):
    """Advisory locks for this transaction, in the order given: always the source's, then (recording a try) its IPv6
    /48's, then the pair's, so no two requests ever wait on each other in a circle. A lock given as None is skipped.
    A lock or a query that takes too long fails, and the policy with it (closed)."""
    cursor.execute("SET LOCAL lock_timeout = '5s'")
    cursor.execute("SET LOCAL statement_timeout = '10s'")
    for lock in locks:
        if lock is not None and lock[1] is not None:
            cursor.execute("SELECT pg_advisory_xact_lock(%s, %s)", [lock[0], wf_lock_key(lock[1])])


def wf_ak_try_locks(account, conn, proven=False):
    """The locks a try is recorded under: the source, its IPv6 /48 (review finding 4: tries from many /64s of one
    /48 at the same moment are counted one at a time against the /48's limit too), the pair. A proven source skips the
    /48's lock (review of 15 November 2026, findings 4 and 15): a tightened /48 refuses it only for its own wrong tries,
    which its source lock already takes one at a time, so it never waits behind an attack's tries elsewhere in the /48
    (a wait of 5 seconds fails closed). Its tries still count towards the /48; at most as many as are sent at the same
    moment from proven sources can then overshoot the /48's limit, which refuses only unproven and abusive sources."""
    net = (WF_LOCK_NET, "net:" + wf_network_key(conn)) if ":" in conn and not proven else None
    return (WF_LOCK_CONN, "conn:" + conn), net, (WF_LOCK_PAIR, "pair:" + account + "|" + conn)


def wf_ak_where_conn(rows, conn):
    """Narrows rows to a source's records by the event's address too, which authentik indexes (client_ip, PostgreSQL
    inet), as well as by the context's wf_conn, which it doesn't (review of 15 November 2026, findings 4 and 15: a
    JSON filter alone scanned every try of the look-back, and under a distributed attack ran into statement_timeout,
    failing every password sign-in closed). An IPv4 source is matched in both of the forms an address was ever kept in
    (dotted, and IPv4-mapped IPv6); a /64 by containment. A key that isn't an address keeps the context match only."""
    import ipaddress
    try:
        net = ipaddress.ip_network(str(conn), strict=False)
    except ValueError:
        return rows
    if net.version == 4:
        mapped = "::ffff:%s/128" % net.network_address
        return rows.extra(where=["(client_ip <<= %s::inet OR client_ip <<= %s::inet)"], params=[str(net), mapped])
    return rows.extra(where=["client_ip <<= %s::inet"], params=[str(net)])


# The records whose event carries the account as its user (wf_ak_record's `user`) whenever their context names it:
# their wf_user_pk is matched by authentik's index on user->pk too.
WF_USER_INDEXED = (WF_TRY, WF_RIGHT, WF_SIGNED, WF_UNLOCK, WF_UNLOCK_VOID)


def wf_ak_rows(action, since, within=None, most=None, **context):
    """(created seconds, context) of one kind of record since a time, matching context values; with `within` (an IPv6
    /48), every record whose address lies in it instead of a wf_conn match (authentik keeps the address as PostgreSQL
    inet); with `most`, only the newest that many. Expired records too: authentik hides events past their retention,
    which an administrator can shorten. A wf_conn or wf_user_pk match also uses authentik's indexes (wf_ak_where_conn,
    WF_USER_INDEXED)."""
    from authentik.events.models import Event
    rows = Event.objects.db_manager("default").including_expired().filter(action="custom_" + action, created__gte=since)
    for key, value in context.items():
        rows = rows.filter(**{"context__" + key: value})
    if "wf_conn" in context:
        rows = wf_ak_where_conn(rows, context["wf_conn"])
    pk = context.get("wf_user_pk")
    if action in WF_USER_INDEXED and isinstance(pk, int) and not isinstance(pk, bool):
        rows = rows.filter(user__pk=pk)
    if within is not None:
        import ipaddress
        rows = rows.extra(where=["client_ip <<= %s::inet"], params=[str(ipaddress.ip_network(within))])
    rows = rows.order_by("-created").values_list("created", "context")
    if most is not None:
        rows = rows[:most]
    return [(created.timestamp(), ctx) for created, ctx in rows]


def wf_ak_signed_rows(since, most, within=None, **context):
    """For proven and the alerts' affected accounts (wf_signed_accounts): one "signed" record per account that completed a sign-in here
    since a time (its newest), at most `most` of them, so a busy office's month of sign-ins isn't read for every
    try."""
    from django.db.models import Max
    from authentik.events.models import Event
    rows = Event.objects.db_manager("default").including_expired().filter(
        action="custom_" + WF_SIGNED, created__gte=since, context__has_key="wf_user_pk").exclude(context__wf_user_pk=None)
    for key, value in context.items():
        rows = rows.filter(**{"context__" + key: value})
    if "wf_conn" in context:
        rows = wf_ak_where_conn(rows, context["wf_conn"])
    if within is not None:
        import ipaddress
        rows = rows.extra(where=["client_ip <<= %s::inet"], params=[str(ipaddress.ip_network(within))])
    rows = rows.values("context__wf_user_pk").annotate(newest=Max("created")).order_by()[:most]
    return [(r["newest"].timestamp(), int(r["context__wf_user_pk"])) for r in rows]


def wf_ak_record(action, keep, address, user=None, **context):
    """Writes one record (an authentik event, custom_<action>), kept at least `keep` seconds. The context is exactly
    what is given. A real account's records carry it as the event's user ({pk, username}); a name nobody has carries
    no user (it is never stored readably)."""
    from datetime import timedelta
    from django.utils import timezone
    from authentik.events.models import Event
    record = Event.new(action, app="workforce", **context)
    record.expires = timezone.now() + timedelta(seconds=keep)
    record.user = {"pk": int(user.pk), "username": str(user.username)} if user is not None else {}
    try:
        import ipaddress
        ip = ipaddress.ip_address(str(address))
        # An IPv4-mapped address is kept as its IPv4, as its source key has it (wf_ak_where_conn finds both forms).
        record.client_ip = str(ip.ipv4_mapped if ip.version == 6 and ip.ipv4_mapped is not None else ip)
    except ValueError:
        record.client_ip = None
    record.save()
    return record


def wf_ak_marker(pk, now):
    """The account's marker (wf_marker), read from the database now (not from the sign-in's copy of the account, which
    is as old as the sign-in: an unlock while the password page is open counts at once): its password change and its
    unlock records' own times (wf_at, the sign-in server's clock). None for a name nobody has."""
    from datetime import datetime, timezone as tz
    from authentik.core.models import User
    if pk is None:
        return None
    changed = User.objects.filter(pk=int(pk)).values_list("password_change_date", flat=True).first()
    since = datetime.fromtimestamp(now - WF_KEEP_UNLOCK, tz.utc)
    unlocks = [c.get("wf_at") for at, c in wf_ak_rows(WF_UNLOCK, since, most=1, wf_user_pk=int(pk)) if isinstance(c, dict)]
    return wf_marker(changed, unlocks, now)


WF_MOST_ROWS = 2000                # newest records of one kind read for one source, /48 or account (more than any
                                   # limit counts), so no read grows with an attack (review findings 4 and 15)


def wf_ak_proven_now(conn, cfg, now):
    """Is this source proven (wf_proven, never a workplace) now: confirmed, or someone completed a sign-in from it in
    the last 30 days?
    One indexed read, before the try's locks are taken (wf_ak_try_locks)."""
    from datetime import datetime, timezone as tz
    if wf_confirmed(conn, cfg["confirmed"]):
        return True
    return bool(wf_ak_rows(WF_SIGNED, datetime.fromtimestamp(now - WF_KNOWN_FOR, tz.utc), most=1, wf_conn=conn))


def wf_ak_events(conn, account, user, now, spread):
    """The records a decision (and, with `spread`, the alerts) needs, and the markers: tries from this source (and its
    /48) in the look-back (an hour for alerts) and the right records that mark them; this pair's own tries; whether
    someone completed a sign-in from this source (proven: one record is enough; never a workplace, which only the
    operator's list makes); with `spread`, up to WF_ALERT_MOST_PKS accounts with a completed sign-in from this source
    and from its /48, for the alerts' affected accounts, and this account's tries of the last day."""
    from datetime import datetime, timezone as tz

    def at(seconds):
        return datetime.fromtimestamp(seconds, tz.utc)
    back = WF_SPREAD_HOUR if spread else WF_LOOK_BACK
    most = WF_ALERT_MOST_PKS if spread else 1
    tries = wf_ak_rows(WF_TRY, at(now - back), most=WF_MOST_ROWS, wf_conn=conn)
    rights = wf_ak_rows(WF_RIGHT, at(now - back), most=WF_MOST_ROWS, wf_conn=conn)
    # The pair's own tries (the newest WF_MOST_ROWS of the source above can't hide a pause; a pause needs 5).
    tries = tries + wf_ak_rows(WF_TRY, at(now - WF_LOOK_BACK), most=WF_MOST_ROWS, wf_account=account, wf_conn=conn)
    signed = [(t, pk, conn) for t, pk in wf_ak_signed_rows(at(now - WF_KNOWN_FOR), most, wf_conn=conn)]
    if ":" in conn:
        net = wf_network_key(conn)
        tries = tries + wf_ak_rows(WF_TRY, at(now - back), within=net, most=WF_MOST_ROWS)
        rights = rights + wf_ak_rows(WF_RIGHT, at(now - back), within=net, most=WF_MOST_ROWS)
        if spread:
            # The /48's accounts stand at the /48's key: they are a network alert's affected accounts, never a source's.
            signed += [(t, pk, net) for t, pk in wf_ak_signed_rows(at(now - WF_KNOWN_FOR), most, within=net)]
    if spread and user is not None:
        # The person's tries of the day, under any of their names.
        tries = tries + wf_ak_rows(WF_TRY, at(now - WF_SPREAD_DAY), most=WF_MOST_ROWS, wf_user_pk=int(user.pk))
        rights = rights + wf_ak_rows(WF_RIGHT, at(now - WF_SPREAD_DAY), most=WF_MOST_ROWS, wf_user_pk=int(user.pk))
    seen = set()
    events = []
    for e in wf_events(tries, "try") + wf_events(rights, "right"):
        key = (e["kind"], e["try"], e["at"])
        if key not in seen:
            seen.add(key)
            events.append(e)
    for t, pk, where in signed:
        events.append({"at": t, "kind": "signed", "try": None, "account": "u:%d" % pk, "conn": where, "pk": pk})
    marker = wf_ak_marker(getattr(user, "pk", None), now) if user is not None else None
    return events, ({account: marker} if marker is not None else {})


def wf_ak_refused(decision, address, person, account, conn, now, locked=False):
    """Records a refusal (custom_workforce_password_refused: which rule and until when), at most once a WF_REFUSED_GAP
    per pair, under the pair's locks unless the caller holds them. A refusal is never a try: it moves no end.
    Returns whether the request is refused."""
    from datetime import datetime, timezone as tz
    from django.db import connections, transaction
    if decision["rule"] is None:
        return False
    with transaction.atomic(using="default"):
        if not locked:
            with connections["default"].cursor() as cursor:
                wf_ak_lock(cursor, (WF_LOCK_CONN, "conn:" + conn), (WF_LOCK_PAIR, "pair:" + account + "|" + conn))
        if not wf_ak_rows(WF_REFUSED, datetime.fromtimestamp(now - WF_REFUSED_GAP, tz.utc), wf_conn=conn,
                          wf_account=account):
            wf_ak_record(WF_REFUSED, WF_KEEP_REFUSED, address, person, wf_account=account, wf_conn=conn,
                         wf_user_pk=getattr(person, "pk", None), wf_why=decision["rule"],
                         wf_until=wf_iso(decision["until"]))
    return True


def wf_ak_decide(request):
    """The decision for this request, without recording a try: (decision, http, person, account, conn, address, now).
    Worked out once per HTTP request (orders 15, 16 and 17, or 21 and 22, ask in the same request); the try's policy
    (20) forgets it whenever it records a try."""
    from django.utils import timezone
    http, person, account, conn, address = wf_ak_subject(request)
    decided = getattr(http, "_wf_decided", None)
    if isinstance(decided, dict) and (account, conn) in decided:
        decision, now = decided[(account, conn)]
        return decision, http, person, account, conn, address, now
    now = timezone.now().timestamp()
    events, markers = wf_ak_events(conn, account, person, now, False)
    decision = wf_decide(events, account, conn, markers, now, wf_ak_limits())
    try:
        setattr(http, "_wf_decided", {(account, conn): (decision, now)})
    except (AttributeError, TypeError):
        pass
    return decision, http, person, account, conn, address, now


# ---- the sign-in status interface (contract R.7): the authentik part ----

def wf_ak_status_caller(request):
    """Is this the application's own credential? The request must be the status interface's property mapping being
    tested through authentik's API (request.obj), by the service account WF_STATUS_CALLER, active, authenticated by
    one of its own API tokens. Anyone else, a superuser included, is answered nothing."""
    from authentik.core.models import Token, TokenIntents, UserTypes
    obj = getattr(request, "obj", None)
    if type(obj).__name__ != "PropertyMapping" or getattr(obj, "name", None) != WF_STATUS_NAME:
        return False
    http = getattr(request, "http_request", None)
    caller = getattr(http, "user", None)
    token = getattr(http, "auth", None)
    return (isinstance(token, Token) and token.intent == TokenIntents.INTENT_API and caller is not None
            and getattr(caller, "pk", None) is not None and token.user_id == caller.pk
            and caller.username == WF_STATUS_CALLER and caller.type == UserTypes.SERVICE_ACCOUNT and caller.is_active
            and not caller.is_superuser)


def wf_ak_target(request):
    """The person the application asks about (the test's `user`): a saved account, or None."""
    from authentik.core.models import User
    user = getattr(request, "user", None)
    if not isinstance(user, User) or getattr(user, "pk", None) is None:
        return None
    return User.objects.filter(pk=user.pk).first()


def wf_ak_unlockable(user):
    """May an unlock lift this account's pause? Only an active internal account that is not a superuser, not in
    "authentik Admins", not a service account and not the emergency administrator (whose way back is
    ./bin/reset-admin.sh)."""
    from authentik.core.models import UserTypes
    return (user.is_active and user.type == UserTypes.INTERNAL and not user.is_superuser
            and user.username != "admin" and not user.ak_groups.filter(name="authentik Admins").exists())


def wf_ak_status_of(user, now):
    """wf_status for one person, from the records, and the newest unlock."""
    from datetime import datetime, timezone as tz

    def at(seconds):
        return datetime.fromtimestamp(seconds, tz.utc)
    pk = int(user.pk)
    tries = wf_ak_rows(WF_TRY, at(now - WF_LOOK_BACK), most=WF_MOST_ROWS, wf_user_pk=pk)
    rights = wf_ak_rows(WF_RIGHT, at(now - WF_LOOK_BACK), most=WF_MOST_ROWS, wf_user_pk=pk)
    events = wf_events(tries, "try") + wf_events(rights, "right")
    status = wf_status(events, pk, wf_ak_marker(pk, now), now)
    last = wf_ak_rows(WF_UNLOCK, at(now - WF_KEEP_UNLOCK), most=1, wf_user_pk=pk)
    status["lastUnlock"] = ({"id": str(last[0][1].get("wf_unlock_id")), "at": str(last[0][1].get("wf_at"))}
                           if last and isinstance(last[0][1], dict) else None)
    status["triedFromSeveralPlaces"] = bool(wf_ak_rows(WF_ALERT, at(now - WF_SPREAD_DAY), most=1,
                                                       wf_kind="account-spread", wf_user_pk=pk))
    return status


def wf_ak_unlock_records(unlock_id, now):
    """(applied, voided) for one unlock id: its unlock records as (seconds, user pk, was paused), and whether it was
    voided."""
    from datetime import datetime, timezone as tz
    since = datetime.fromtimestamp(now - WF_KEEP_UNLOCK, tz.utc)
    applied = []
    for at, c in wf_ak_rows(WF_UNLOCK, since, wf_unlock_id=unlock_id):
        if isinstance(c, dict):
            t = wf_parse_time(c.get("wf_at"))
            applied.append((t if t is not None else at, c.get("wf_user_pk"), c.get("wf_was_paused") is True))
    applied.sort(key=lambda r: r[0])
    return applied, bool(wf_ak_rows(WF_UNLOCK_VOID, since, most=1, wf_unlock_id=unlock_id))


def wf_ak_status_answer(request):
    """The answer of the status interface (contract R.7.2) to one test of its property mapping. Every answer is a
    dict with "v": 1; anything unexpected is {"known": false} with a reason, never a traceback (the caller can't tell
    an error from a refusal, and learns nothing either way). It reads only the custom_workforce_* records and the
    person's password change date, and writes only unlock and void records."""
    from django.db import connections, transaction
    from django.utils import timezone
    if not wf_ak_status_caller(request):
        return {"v": 1, "known": False, "why": "caller"}
    context = getattr(request, "context", None)
    context = context if isinstance(context, dict) else {}
    op = context.get("wf_op")
    now = timezone.now().timestamp()
    if op == "alerts":
        from datetime import datetime, timezone as tz
        from django.db.models import Q
        from authentik.events.models import Event
        limit = context.get("wf_limit")
        limit = limit if isinstance(limit, int) and not isinstance(limit, bool) and 0 < limit <= WF_ALERTS_MOST else WF_ALERTS_MOST
        cursor = wf_alert_cursor(context.get("wf_after"))
        rows = Event.objects.db_manager("default").including_expired().filter(
            action="custom_" + WF_ALERT, created__gte=datetime.fromtimestamp(now - WF_KEEP_ALERT, tz.utc))
        if cursor is not None:
            after = datetime.fromtimestamp(cursor[0], tz.utc)
            rows = rows.filter(Q(created__gt=after) | Q(created=after, event_uuid__gt=cursor[1]))
        rows = list(rows.order_by("created", "event_uuid").values_list("event_uuid", "created", "context")[:limit])
        alerts = [wf_alert_out(uid, created.timestamp(), ctx) for uid, created, ctx in rows]
        nxt = (wf_iso(rows[-1][1].timestamp()) + "|" + str(rows[-1][0])) if rows else context.get("wf_after")
        return {"v": 1, "op": "alerts", "known": True, "checkedAt": wf_iso(now), "alerts": alerts,
                "next": nxt if isinstance(nxt, str) else None}
    user = wf_ak_target(request)
    if user is None:
        return {"v": 1, "known": False, "why": "account"}
    if op == "status":
        status = wf_ak_status_of(user, now)
        return {"v": 1, "op": "status", "known": True, "checkedAt": wf_iso(now), "paused": status["paused"],
                "pausedSources": status["pausedSources"],
                "until": wf_iso(status["until"]) if status["until"] is not None else None,
                "triedFromSeveralPlaces": status["triedFromSeveralPlaces"], "lastUnlock": status["lastUnlock"]}
    if op not in ("unlock", "unlock-status"):
        return {"v": 1, "known": False, "why": "op"}
    unlock_id = context.get("wf_unlock_id")
    with transaction.atomic(using="default"):
        with connections["default"].cursor() as cursor:
            wf_ak_lock(cursor, (WF_LOCK_ACCOUNT, "account:%d" % int(user.pk)),
                       (WF_LOCK_UNLOCK_ID, "unlock:" + str(unlock_id)))
        now = timezone.now().timestamp()
        applied, voided = wf_ak_unlock_records(unlock_id, now) if wf_unlock_id_ok(unlock_id) else ([], False)
        if op == "unlock-status":
            what, answer = wf_unlock_status_decide(applied, voided, unlock_id, int(user.pk))
            if what == "void":
                wf_ak_record(WF_UNLOCK_VOID, WF_KEEP_UNLOCK, None, user, wf_unlock_id=unlock_id,
                             wf_user_pk=int(user.pk), wf_at=wf_iso(now))
            return dict(answer, known=True)
        if not wf_ak_unlockable(user):
            return {"v": 1, "op": "unlock", "known": True, "applied": False, "why": "account"}
        what, answer = wf_unlock_decide(applied, voided, unlock_id, int(user.pk), context.get("wf_requested_at"), now)
        if what != "apply":
            return dict(answer, known=True)
        was = wf_ak_status_of(user, now)["paused"]
        wf_ak_record(WF_UNLOCK, WF_KEEP_UNLOCK, None, user, wf_unlock_id=unlock_id, wf_user_pk=int(user.pk),
                     wf_at=wf_iso(now), wf_was_paused=was)
        return {"v": 1, "op": "unlock", "known": True, "applied": True, "id": unlock_id, "at": wf_iso(now),
                "wasPaused": was}
