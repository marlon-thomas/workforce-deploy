#!/usr/bin/env python3
"""check-identity-templates.py - the sign-in server's templates stay renderable by the appliance controller.

Workforce issue 453: under the controller (ADR-0032) nothing runs Ansible, so the controller renders the authentik role's
blueprint templates itself (controller/src/identity/template.mjs in the Workforce source repository). It is not a template
engine: it knows exactly the forms below, puts each value in as plain text after checking it strictly, and refuses
anything else, so that no value is ever evaluated. The same templates stay the one source for both: Ansible renders them
on the host layout, the controller from the copy in its image. This fails CI here when a template gains a form the
controller would refuse (its own test, run against a checkout of this repository, compares the two renderings byte for
byte). Run by bin/ci-validate.sh:

    python3 -I bin/check-identity-templates.py ansible/roles/authentik/templates

The forms, and the values (any other variable is refused):
  {{ name }}
  {% if name | default('') | length > 0 %} / == 0 %}, {% else %}, {% endif %}
  {% for name in ['plain-word', ...] %} ... {% endfor %}
  {% filter indent(N, true) %} ... {% endfilter %}
  {% include 'file-in-this-folder' %}
and no comments, whitespace control or anything else.
"""
import re
import sys
from pathlib import Path

VALUES = {"app_hostname", "auth_hostname", "webmail_hostname", "oidc_client_id", "oidc_client_secret",
          "webmail_oidc_secret", "mail_lookup_key", "ak_admin_password"}
WORD = r"[a-z0-9][a-z0-9-]*"
FORMS = [
    re.compile(r"\{\{ ([a-z_]+) \}\}"),
    re.compile(r"\{% if ([a-z_]+) \| default\(''\) \| length (?:> 0|== 0) %\}"),
    re.compile(r"\{% (else|endif|endfor|endfilter) %\}"),
    re.compile(r"\{% for ([a-z_]+) in \[(?:'" + WORD + r"'(?:, '" + WORD + r"')*)\] %\}"),
    re.compile(r"\{% filter indent\(\d{1,2}, true\) %\}"),
    re.compile(r"\{% include '([a-z0-9][a-z0-9._-]*)' %\}"),
]
TAG = re.compile(r"\{\{.*?\}\}|\{%.*?%\}|\{#", re.S)
LOOP = re.compile(r"\{% for ([a-z_]+) in ")


def problems_in(path, seen):
    out = []
    text = path.read_text(encoding="utf-8")
    loops = set(LOOP.findall(text))
    for m in TAG.finditer(text):
        tag = m.group(0)
        line = text.count("\n", 0, m.start()) + 1
        form = next((f for f in FORMS if f.fullmatch(tag)), None)
        if form is None:
            out.append(f"{path.name}:{line}: the controller can't render {tag[:60]!r}")
            continue
        name = form.fullmatch(tag).group(1) if form.groups else None
        if form is FORMS[5]:
            target = path.parent / name
            if not target.is_file() or target.is_symlink():
                out.append(f"{path.name}:{line}: includes {name}, which isn't a plain file beside it")
            elif target not in seen:
                seen.add(target)
                out.extend(problems_in(target, seen))
        elif name and form is not FORMS[2] and name not in VALUES and name not in loops:
            out.append(f"{path.name}:{line}: {name} is not a value the controller gives")
    return out


def main(folder):
    seen = set()
    problems = []
    for path in sorted(Path(folder).glob("*.j2")):
        problems.extend(problems_in(path, seen))
    for p in problems:
        print(f"FAIL {p}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "ansible/roles/authentik/templates"))
