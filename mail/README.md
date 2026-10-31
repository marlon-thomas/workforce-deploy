# Staff mail server (Stalwart)

`config.json` only tells Stalwart where its data store is: the `stalwart` database on the suite's
PostgreSQL (created by the `mail-db-init` one-shot), so mail is in the nightly backup. Everything
else (domains, accounts, who may send outside, sign-in, the relay) is set by Workforce through
Stalwart's management API from the organisation's Setup → Email (mail-calendar-spec §11).
Nothing here names an organisation or a domain.
