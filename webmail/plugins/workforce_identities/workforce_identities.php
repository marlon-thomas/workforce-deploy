<?php

/**
 * Workforce shared mailboxes in webmail (mail-calendar-spec §11a).
 *
 * A shared mailbox (hr@, admin@ …) is a group on the mail server: its members see its folders
 * beside their own and may send from its address. This plugin offers those addresses in the From
 * menu. After each sign-in it asks Workforce, over the private network with the installation's
 * lookup key, which shared mailboxes the person may use, and keeps their From choices in step:
 * one identity per shared mailbox, added when access begins and removed when it ends.
 *
 * - The person's own identity is never touched, nor any identity this plugin did not add (it
 *   remembers its own in the user's preferences).
 * - identities_level stays 3: people still can't type an arbitrary From address, and the mail
 *   server refuses sending as a shared mailbox to anyone who is not a member, whatever this shows.
 * - If Workforce can't be reached, sign-in carries on and the From menu is left as it was.
 *
 * Settings (all optional): workforce_identities_url, workforce_identities_key_file.
 */
class workforce_identities extends rcube_plugin
{
    private const PREF = 'workforce_shared_identities';

    #[\Override]
    public function init()
    {
        $this->add_hook('login_after', [$this, 'login_after']);
    }

    /** Runs once the person is signed in; never stops the sign-in. */
    public function login_after($args)
    {
        try {
            $this->sync(rcmail::get_instance());
        } catch (\Throwable $e) {
            rcube::write_log('errors', 'workforce_identities: shared mailboxes not offered as From addresses this time: ' . $e->getMessage());
        }

        return $args;
    }

    private function sync(rcmail $rcmail): void
    {
        $user = $rcmail->user;
        if (!$user || !$user->ID) {
            return;
        }
        $own = strtolower(trim((string) $user->get_username()));
        if (strpos($own, '@') === false) {
            return;
        }

        $wanted = $this->lookup($rcmail, $own);
        if ($wanted === null) {
            return;
        }
        unset($wanted[$own]);

        $prefs = $user->get_prefs();
        $ours = array_map('strtolower', (array) ($prefs[self::PREF] ?? []));

        $have = [];
        foreach ($user->list_identities() as $row) {
            $have[strtolower((string) $row['email'])][] = $row;
        }

        // Access ended: take away the identities this plugin added.
        foreach ($ours as $email) {
            if (isset($wanted[$email]) || $email === $own) {
                continue;
            }
            foreach ($have[$email] ?? [] as $row) {
                $user->delete_identity($row['identity_id']);
            }
        }

        // Access began: one identity per shared mailbox, named as it is in Workforce.
        $added = [];
        foreach ($wanted as $email => $name) {
            if (!isset($have[$email])) {
                $user->insert_identity(['name' => $name, 'email' => $email, 'standard' => 0]);
            }
            if (!isset($have[$email]) || in_array($email, $ours, true)) {
                $added[] = $email;
            }
        }

        sort($added);
        sort($ours);
        if ($added !== $ours) {
            $user->save_prefs([self::PREF => $added]);
        }
    }

    /**
     * The shared mailboxes the owner of $address may use, as [address => name]; null when
     * Workforce can't be asked or answers something unexpected (then nothing is changed).
     */
    private function lookup(rcmail $rcmail, string $address): ?array
    {
        $file = $rcmail->config->get('workforce_identities_key_file', '/run/secrets/mail_lookup_key');
        $key = is_readable($file) ? trim((string) file_get_contents($file)) : '';
        if ($key === '') {
            rcube::write_log('errors', 'workforce_identities: no lookup key at ' . $file);
            return null;
        }
        $url = $rcmail->config->get('workforce_identities_url', 'http://api:8080/api/public/mail/shared-identities');

        $response = $rcmail->get_http_client(['timeout' => 4, 'connect_timeout' => 2, 'http_errors' => false])->get($url, [
            'query' => ['address' => $address],
            'headers' => ['X-Workforce-Mail-Key' => $key, 'Accept' => 'application/json'],
        ]);
        if ($response->getStatusCode() !== 200) {
            rcube::write_log('errors', 'workforce_identities: Workforce answered ' . $response->getStatusCode());
            return null;
        }
        $list = json_decode((string) $response->getBody(), true);
        if (!is_array($list)) {
            return null;
        }

        $out = [];
        foreach ($list as $item) {
            $email = strtolower(trim((string) ($item['address'] ?? '')));
            $name = trim((string) ($item['name'] ?? ''));
            if ($email === '' || strpos($email, '@') === false || !rcube_utils::check_email($email)) {
                continue;
            }
            $out[$email] = $name !== '' ? $name : $email;
        }

        return $out;
    }
}
