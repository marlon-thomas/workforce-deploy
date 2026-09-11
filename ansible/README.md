# Ansible provisioning (deployment-spec §B — converged-state edition)

One playbook provisions both environments idempotently. Re-running is always
safe: every task declares desired state, never a sequence of mutations.

## Prerequisites (control machine)
    pip install ansible
    ansible-galaxy collection install community.general community.docker

## Production (VPS)
    ansible-playbook -i inventories/prod/hosts.yml site.yml --ask-pass
    # or with the session key: --key-file ~/.ssh/id_ed25519

## Dev (Vagrant VM)
    cd ../environments && vagrant up
    ansible-playbook -i inventories/dev/hosts.yml site.yml

## What it does
1. common — packages, service user, docker, sysctl (unprivileged port floor), firewall
2. authentik — secrets (0444 rootless-readable), blueprint render + mounts,
   identity-plane up, waits for OIDC discovery 200
3. workforce — .env (pinned version, correct image), JVM truststore from the
   gateway chain, app-plane up, waits for build-meta 200

install.sh remains the interactive front door (prompts, handover); it delegates
the convergent work here via `connection=local` on the server.
