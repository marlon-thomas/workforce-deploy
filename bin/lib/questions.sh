# questions.sh — the installer's mail questions (bin/install.sh questions 5 and 6), kept apart so
# bin/tests/install-questions-test.sh can answer them from a script. Sourced after bin/lib/common.sh;
# uses install.sh's say, warn and read_mandatory. Sets SMTP_* and OPS_ALERT_EMAIL / OPS_HEARTBEAT_URL.
# shellcheck shell=bash disable=SC2034  # the SMTP_* and OPS_* answers are read by install.sh

# Question 6: who outside this server is emailed when a health check fails (bin/healthwatch.sh).
# Pre-filled from the environment file (test: a mailpit-caught address); Enter keeps it.
ask_alert_address() {
  local def="${OPS_ALERT_EMAIL:-}" ans problems yn
  def="${def// /}"
  echo "6/6  Server alerts — who should be emailed when something breaks (backups, disk space, mail,"
  echo "     sign-in)? Use an address NOT hosted on this server, so alerts still arrive when this"
  echo "     server's own mail is down. Separate several with commas."
  while :; do
    if [ -n "$def" ]; then
      read -r -p "     Alert address [${def}] (Enter = keep, - = none): " ans
      [ -n "$ans" ] || ans="$def"
      [ "$ans" != "-" ] || ans=""
    else
      read -r -p "     Alert address (Enter = none for now): " ans
    fi
    ans="${ans// /}"
    if [ -z "$ans" ]; then
      OPS_ALERT_EMAIL=""
      warn "No alert address: problems will only be logged (logs/healthwatch.log). To add one later, set
     OPS_ALERT_EMAIL in .env, then: docker compose up -d backup   (RUNBOOK §7b)"
      return 0
    fi
    problems="$(alert_address_problems "$ans" "${APP_HOSTNAME:-}" "${AUTH_HOSTNAME:-}")"
    if printf '%s\n' "$problems" | grep -q '^bad:'; then
      printf '%s\n' "$problems" | sed -n 's/^bad:/     /p' >&2
      continue
    fi
    if [ -n "$problems" ]; then
      printf '%s\n' "$problems" | sed -n 's/^own:/     /p' >&2
      echo "     If this server handles that domain's mail, alerts would stop when it does. That's fine"
      echo "     only if the domain's mail is hosted elsewhere (for example Microsoft 365)."
      read -r -p "     Use it anyway? [y/N] " yn
      case "$yn" in y|Y|yes|YES) ;; *) continue ;; esac
    fi
    OPS_ALERT_EMAIL="$ans"
    say "Alerts will go to: ${OPS_ALERT_EMAIL}"
    break
  done
  ask_heartbeat
}

# Follow-up to question 6: an outside uptime check. A server that is switched off or has lost its
# network can't email anyone, so a free outside service (e.g. Healthchecks.io) expects a ping every
# 15 minutes from bin/healthwatch.sh and emails you when the pings stop. Optional; RUNBOOK §7c.
ask_heartbeat() {
  local def="${OPS_HEARTBEAT_URL:-}" ans
  echo "     Outside uptime check (optional): if this server stops completely it can't send alerts."
  echo "     A free service such as Healthchecks.io can expect a ping every 15 minutes and email you"
  echo "     when the pings stop. Create a check there (period 15 min, grace 15 min) and paste its"
  echo "     ping URL here."
  while :; do
    if [ -n "$def" ]; then
      read -r -p "     Ping URL [already set] (Enter = keep, - = none): " ans
      [ -n "$ans" ] || ans="$def"
      [ "$ans" != "-" ] || ans=""
    else
      read -r -p "     Ping URL (Enter = none for now): " ans
    fi
    ans="${ans// /}"
    if [ -z "$ans" ]; then
      OPS_HEARTBEAT_URL=""
      warn "No outside uptime check: if this server stops, nobody is told. Add OPS_HEARTBEAT_URL to .env later (RUNBOOK §7c)."
      return 0
    fi
    case "$ans" in
      https://?*.?*/*) OPS_HEARTBEAT_URL="$ans"; say "Uptime check ping set (the URL is kept in .env, never shown in logs)."; return 0 ;;
      *) echo "     That isn't an https:// address — paste the ping URL the service gave you." >&2 ;;
    esac
  done
}

# Question 5: the outgoing email relay, for Workforce's own email (reminders, invitations, password
# resets) and the server alerts. Pre-filled from the environment file (test: mailpit); otherwise a
# provider list with their standard STARTTLS addresses. Workforce sends with STARTTLS, so port 465
# (implicit TLS only) can't be used.
ask_relay() {
  local choice relay hint="" fromdef
  if [ -n "${SMTP_HOST:-}" ]; then
    say "5/6  Outgoing email (from environment file): ${SMTP_HOST}:${SMTP_PORT:-587}"
    return 0
  fi
  cat <<'TXT'
5/6  Outgoing email — the service that delivers Workforce's email: reminders, invitations,
     password resets and server alerts. Choose your provider:
       1) Microsoft 365          smtp.office365.com:587
       2) Google Workspace       smtp-relay.gmail.com:587
       3) Brevo                  smtp-relay.brevo.com:587
       4) SMTP2GO                mail.smtp2go.com:587
       5) Amazon SES (London)    email-smtp.eu-west-2.amazonaws.com:587
       6) Mailgun (EU)           smtp.eu.mailgun.org:587
       7) Other                  type the host and port
     Enter = none for now: emails are only logged and nothing is sent.
TXT
  while :; do
    read -r -p "     Provider [1-7, Enter = none]: " choice
    SMTP_PORT=587
    case "$choice" in
      "")
        SMTP_HOST=""; SMTP_USERNAME=""; SMTP_PASSWORD=""
        warn "No outgoing email: reminders, invitations, password resets and alerts are only logged.
     To add one later, set SMTP_HOST, SMTP_PORT, SMTP_USERNAME, SMTP_PASSWORD, SMTP_STARTTLS=true
     and SMTP_FROM in .env, then: docker compose up -d api worker backup"
        return 0 ;;
      1) SMTP_HOST=smtp.office365.com
         hint="Sign in as the mailbox that sends (e.g. noreply@your-domain). Its 'Authenticated SMTP' must be switched on in Microsoft 365, and the From address must be that mailbox." ;;
      2) SMTP_HOST=smtp-relay.gmail.com
         hint="In the Google Admin console, add an SMTP relay rule that allows this server's IP address (leave the user name blank) or requires SMTP authentication." ;;
      3) SMTP_HOST=smtp-relay.brevo.com
         hint="Use your Brevo SMTP login and an SMTP key (Settings > SMTP & API), not your account password." ;;
      4) SMTP_HOST=mail.smtp2go.com
         hint="Use an SMTP user created under Sending > SMTP Users." ;;
      5) SMTP_HOST=email-smtp.eu-west-2.amazonaws.com
         hint="Use SES SMTP credentials (created in the SES console), not AWS access keys. The From domain must be verified in SES." ;;
      6) SMTP_HOST=smtp.eu.mailgun.org
         hint="Use the SMTP login and password from your sending domain's settings in Mailgun." ;;
      7) read_mandatory relay "     Host and port (e.g. smtp.example.net:587): "
         relay="${relay// /}"
         SMTP_HOST="${relay%%:*}"
         [ "$relay" = "$SMTP_HOST" ] || SMTP_PORT="${relay##*:}"
         case "$SMTP_PORT" in
           ''|*[!0-9]*) echo "     The port must be a number (usually 587)." >&2; continue ;;
           465) echo "     Workforce sends with STARTTLS, so port 465 (implicit TLS) won't work. Use the provider's port 587." >&2; continue ;;
         esac ;;
      *) echo "     Choose 1 to 7, or press Enter for none." >&2; continue ;;
    esac
    break
  done
  SMTP_STARTTLS=true
  [ -z "$hint" ] || printf '     %s\n' "$hint"
  read -r -p "     User name (Enter if the provider allows this server by its IP address): " SMTP_USERNAME
  SMTP_USERNAME="${SMTP_USERNAME// /}"
  SMTP_PASSWORD=""
  if [ -n "$SMTP_USERNAME" ]; then
    while :; do
      read_mandatory SMTP_PASSWORD "     Password or SMTP key (not shown): " silent
      # .env keeps it in single quotes (compose and bash both read that literally); a single quote
      # inside can't be written that way, so ask for another key rather than store a broken one.
      case "$SMTP_PASSWORD" in
        *"'"*) echo "     That password contains a single quote ('), which .env can't hold safely. Create an SMTP key or password without one." >&2 ;;
        *) break ;;
      esac
    done
  fi
  fromdef="noreply@${BASE_DOMAIN:-${APP_HOSTNAME#*.}}"
  case "$SMTP_USERNAME" in *@*.*) [ "$choice" = 1 ] && fromdef="$SMTP_USERNAME" ;; esac
  read -r -p "     Send as (From address) [${fromdef}]: " SMTP_FROM
  SMTP_FROM="${SMTP_FROM// /}"; SMTP_FROM="${SMTP_FROM:-$fromdef}"
  say "Outgoing email: ${SMTP_HOST}:${SMTP_PORT} as ${SMTP_FROM}. Ask your provider for the DNS records (SPF and DKIM)"
  echo "     for $(printf '%s' "${SMTP_FROM##*@}") — without them, email from Workforce is likely to land in spam."
}
