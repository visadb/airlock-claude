if [ "$DISTRO" != alpine ]; then
  airlock_fail 10 "airlock-claude supports Alpine only, not $DISTRO"
fi

airlock_steps 3

airlock_status "installing tmux"
airlock_pkg_install tmux || airlock_fail 11 "could not install tmux"

airlock_status "writing the tmux and shell config"
cat > /etc/tmux.conf <<'TMUX_CONF'
set -g mouse on
set -g set-clipboard on
set -as terminal-features ",*:clipboard"
set -g default-terminal "tmux-256color"
set -g base-index 1
TMUX_CONF
mkdir -p /etc/bash
cat > /etc/bash/ls-aliases.sh <<'LS_ALIASES'
alias ls='ls --color=auto'
alias l='ls -CF'
alias la='ls -A'
alias ll='ls -lh'
alias lll='ls -lha'
LS_ALIASES
if [ -x /bin/bash ]; then
  sed -i 's#^\(root:.*:\)/bin/sh$#\1/bin/bash#' /etc/passwd
fi

airlock_status "writing the Claude Code managed settings"
mkdir -p /etc/claude-code
cat > /etc/claude-code/managed-settings.json <<'SETTINGS'
{
  "permissions": { "defaultMode": "bypassPermissions" },
  "skipDangerousModePermissionPrompt": true
}
SETTINGS
cat > /etc/claude-code/CLAUDE.md <<'CLAUDE_MD'
# Sandbox notes (airlock-claude)

This session runs inside an airlock VM. Outbound network access is denied
except for allowlisted hosts, and the HTTPS traffic that is allowed goes
through the airlock TLS proxy, which re-signs every host with its own
"airlock CA". The system trust store already includes that CA, so curl,
git and pip work unchanged.

An HTTP request the policy denies is answered by the proxy itself with
403 Forbidden and the body "denied by network policy" (one line). That
response means the airlock policy blocked the request, not that the
remote server refused it.

## Blocked traffic can be allowed interactively

The user can usually enable traffic that does not match the allow/deny
rules of the airlock policy, temporarily and interactively, from outside
the session. If network access beyond the allowlist would be important
for the task, ask the user to allow the traffic instead of working
around the block. When they do, remind them to revert the airlock
network policy once the part of the work that needed the extra access
is done.

## Alpine Linux

The sandbox is Alpine Linux on musl, not glibc. Install packages with
apk add; the Alpine package mirrors are allowed under the network policy.
A prebuilt binary built for glibc does not run here: look for a musl
build or for the apk package instead.

## Python HTTPS fails with "Missing Authority Key Identifier"

Every Python HTTPS client fails certificate verification here: urllib,
http.client, urllib3, requests, httpx and aiohttp all raise
CERTIFICATE_VERIFY_FAILED with "Missing Authority Key Identifier" (requests
and httpx may say "unable to get local issuer certificate" first). Python
3.13+ turns on VERIFY_X509_STRICT by default, and the per-host certificates
the proxy issues carry no Authority Key Identifier extension, so strict
checking rejects them. SSL_CERT_FILE and REQUESTS_CA_BUNDLE do not help.

Fix: build one SSL context with strict checking off and pass it explicitly.
Verification itself stays on; do not use verify=False or CERT_NONE.

    import ssl
    ctx = ssl.create_default_context()
    ctx.verify_flags &= ~ssl.VERIFY_X509_STRICT

    urllib.request.urlopen(url, context=ctx)
    http.client.HTTPSConnection(host, context=ctx)
    urllib3.PoolManager(ssl_context=ctx)
    httpx.get(url, verify=ctx)            # or httpx.Client(verify=ctx)
    session.get(url, ssl=ctx)             # aiohttp

    class Adapter(requests.adapters.HTTPAdapter):    # requests
        def init_poolmanager(self, *args, **kwargs):
            kwargs["ssl_context"] = ctx
            return super().init_poolmanager(*args, **kwargs)
    s = requests.Session(); s.mount("https://", Adapter())

For a one-off download, curl works without any of this.

## Virtualenvs you find here belong to the host

The working directory is shared with the host, so any .venv, venv or other
virtualenv already in it was almost certainly created on the host, with a
different Python at a different path. Its interpreter symlinks, pyvenv.cfg
and compiled wheels will not match this sandbox. Never activate, reuse,
delete or overwrite a virtualenv you did not create in this session. Make
your own under a different name, for example python3 -m venv .venv-airlock,
and leave the existing one alone.

## Describe the present only

When you write or change comments or documentation, describe how things
are now. Never add notes about how something used to work, what an
approach replaced, or why an old way is gone. That history belongs in
the commit message, and nowhere else.
CLAUDE_MD
