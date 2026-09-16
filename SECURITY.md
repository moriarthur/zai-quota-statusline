# Security Policy

## Supported versions

Security fixes are provided for the latest released version only.

## Reporting a vulnerability

Please do **not** open a public issue for security vulnerabilities.

Report privately via [GitHub Security Advisories](https://github.com/moriarthur/zai-quota-statusline/security/advisories/new)
("Report a vulnerability" — private by default). If that is unavailable, open a bare
issue asking the maintainer to make contact, without any details.

When reporting, never include:

- your `ANTHROPIC_AUTH_TOKEN` (in any fragment),
- `config.env`,
- `quota.cache`,
- `hook.log` or `statusline-debug.log` excerpts that could contain request data.

Log excerpts are fine once secrets are redacted.
