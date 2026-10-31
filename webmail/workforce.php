<?php
// Workforce webmail (mail-calendar-spec §11). Roundcube, unmodified, signs people in through the
// suite's identity provider only: no mail passwords. The provider adds the person's mailbox to the
// sign-in (claim workforce_mailbox), which Roundcube uses as the account name; the mail server
// accepts the provider's token for that account. Host names come from the deployment's .env.
$auth = 'https://' . getenv('AUTH_HOSTNAME');
$config['oauth_provider'] = 'generic';
$config['oauth_provider_name'] = getenv('WEBMAIL_PRODUCT_NAME') ?: 'Workforce';
$config['oauth_client_id'] = getenv('WEBMAIL_OIDC_CLIENT_ID') ?: 'workforce-webmail';
$config['oauth_auth_uri'] = $auth . '/application/o/authorize/';
$config['oauth_token_uri'] = $auth . '/application/o/token/';
$config['oauth_identity_uri'] = $auth . '/application/o/userinfo/';
$config['oauth_logout_uri'] = $auth . '/application/o/webmail/end-session/';
$config['oauth_scope'] = 'openid email profile workforce_mail';
$config['oauth_identity_fields'] = ['workforce_mailbox'];
$config['oauth_login_redirect'] = true;
// Test appliances use a private CA (ADR-0014); production verifies the identity provider's certificate.
$config['oauth_verify_peer'] = getenv('MAIL_TLS_VERIFY') !== 'false';
// IMAP and SMTP stay on the private network, to the suite's own mail server.
$config['imap_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]];
$config['smtp_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]];
$config['product_name'] = getenv('WEBMAIL_PRODUCT_NAME') ?: 'Workforce Mail';
$config['support_url'] = '';
$config['use_https'] = true;
$config['session_lifetime'] = 30;
$config['login_autocomplete'] = 0;
// One identity per person; the address itself can't be changed (no sending as someone else).
$config['identities_level'] = 3;
$config['enable_installer'] = false;
