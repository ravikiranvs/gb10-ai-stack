FROM ubuntu:24.04

# ttyd (the browser terminal) and the ssh client the launcher uses. Both come from Ubuntu's own packages (arm64). curl is only for the build step below.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ttyd openssh-client ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

COPY gb10-shell /usr/local/bin/gb10-shell

# The browser page: ttyd's own page with one added script (shift-enter.js: Shift+Enter inserts a new line in Claude Code). It is made from the
# installed ttyd's page at build time, so it always matches that version. ttyd serves it with -I (see compose.yaml).
COPY shift-enter.js /tmp/shift-enter.js
RUN set -e; \
    ttyd -i lo -p 7681 sleep 60 >/dev/null 2>&1 & TTYD_PID=$!; \
    for i in $(seq 1 30); do curl -fs http://127.0.0.1:7681/ -o /tmp/index.html && break; sleep 0.5; done; \
    kill "$TTYD_PID" 2>/dev/null || true; \
    test -s /tmp/index.html; grep -q '</body>' /tmp/index.html; \
    mkdir -p /opt/ttyd; \
    perl -0777 -pe 'BEGIN { local $/; open F, "/tmp/shift-enter.js" or die "no script"; $js = <F>; } s#</body>#<script>$js</script></body>#' /tmp/index.html > /opt/ttyd/index.html; \
    grep -q 'gb10-shift-enter' /opt/ttyd/index.html; \
    chmod 644 /opt/ttyd/index.html; rm -f /tmp/index.html /tmp/shift-enter.js

EXPOSE 7681
ENTRYPOINT ["ttyd"]
