#!/usr/bin/env bash
# HouseCall end-to-end test: seed → patient message → PENDING_REVIEW → physician
# approves via the web app → patient asserts DELIVERED.
#
# Usage
# -----
#   cd backend
#   ./scripts/e2e.sh
#
# The script brings up the compose stack, seeds the database, then drives the
# full clinical-recommendation loop end-to-end via real HTTP calls.
#
# It detects automatically whether the server is reachable from the host
# (Docker Desktop) or only from inside the compose network (Colima with the
# macOS Virtualization.Framework, where host→container port forwarding may not
# work). In the Colima case it falls back to running every HTTP call via
# `docker compose exec housecall-server wget ...` so the test still exercises
# the real server binary over the loopback interface.
#
# Environment overrides
# ---------------------
#   API_BASE   JSON API base URL  (default: http://localhost:8080)
#   WEB_BASE   Web app base URL   (default: http://localhost:8080)
#   SKIP_UP    Set to 1 to skip `docker compose up` + seed (stack already up)
#   AGENT_POLL_TIMEOUT  Seconds to wait for the model to produce PENDING_REVIEW
#                       (default: 120)
#   EXEC_MODE  Force exec mode: "host" (curl from host) or "exec" (docker
#              compose exec wget from inside server container). Auto-detected
#              when unset.
#
# Host-curl mode (Docker Desktop or any runtime where localhost:8080 is
# accessible from the macOS host):
#   ./scripts/e2e.sh
#
# Exec mode override (Colima or unreachable ports):
#   EXEC_MODE=exec ./scripts/e2e.sh
#
# Non-default port:
#   API_BASE=http://localhost:9090 WEB_BASE=http://localhost:9090 ./scripts/e2e.sh
#
# HIPAA note: the JWT is redacted in all log output. The clinical question
# used here is a generic, non-real-patient query — no PHI is committed.

set -euo pipefail

# ---- configuration -------------------------------------------------------
API_BASE="${API_BASE:-http://localhost:8080}"
WEB_BASE="${WEB_BASE:-http://localhost:8080}"
SKIP_UP="${SKIP_UP:-0}"
AGENT_POLL_TIMEOUT="${AGENT_POLL_TIMEOUT:-120}"
POLL_INTERVAL=3  # seconds between polls
EXEC_MODE="${EXEC_MODE:-}"  # "host", "exec", or empty (auto-detect)

# Seed constants — must match cmd/seed/main.go
TENANT_ID="00000000-0000-0000-0000-000000000001"
PATIENT_EMAIL="patient@dev.housecall.local"
PATIENT_PASSWORD="PatientDev1!"
PHYSICIAN_EMAIL="physician@dev.housecall.local"
PHYSICIAN_PASSWORD="PhysicianDev1!"

# The patient question — generic clinical query, no real patient data.
PATIENT_MESSAGE="I have had a mild headache and low-grade fever for two days. What should I watch for?"

# ---- global state (set by steps; initialized to empty) -------------------
PATIENT_TOKEN=""
PHYSICIAN_TOKEN=""
CONVERSATION_ID=""
MESSAGE_ID=""
RECOMMENDATION_ID=""

# Temporary cookie jar used only in host curl mode.
COOKIE_JAR="$(mktemp /tmp/hc_e2e_cookies.XXXXXX)"
trap 'rm -f "$COOKIE_JAR"' EXIT

# ---- helpers --------------------------------------------------------------
log()  { echo "[e2e] $*"; }
fail() { echo "[e2e] FAIL: $*" >&2; exit 1; }

redact_token() {
    local tok="$1"
    printf '%s' "${tok:0:8}...<redacted>"
}

# json_field <field> <json> — extract a top-level string field.
json_field() {
    local field="$1"
    local json="$2"
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$json" \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field',''))"
    elif command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r --arg f "$field" '.[$f] // empty'
    else
        # Minimal sed fallback: "field": "value"
        printf '%s' "$json" \
            | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
            | head -1
    fi
}

# json_array_field0 <field> <json> — extract <field> from the first element
# of a JSON array.
json_array_field0() {
    local field="$1"
    local json="$2"
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$json" | python3 -c \
            "import sys,json; arr=json.load(sys.stdin); print(arr[0].get('$field','') if arr else '')"
    elif command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r --arg f "$field" '.[0][$f] // empty'
    else
        # Best-effort: first occurrence of "field":"value" in the JSON.
        json_field "$field" "$json"
    fi
}

check_deps() {
    command -v docker >/dev/null 2>&1 || fail "docker is required but not found"
    if ! command -v python3 >/dev/null 2>&1 && ! command -v jq >/dev/null 2>&1; then
        fail "python3 or jq is required for JSON parsing but neither is found"
    fi
    if [[ "$EXEC_MODE" != "exec" ]] && ! command -v curl >/dev/null 2>&1; then
        log "WARNING: curl not found; will auto-detect and may fall back to exec mode"
    fi
}

# ---- exec-mode detection -------------------------------------------------
# detect_exec_mode sets EXEC_MODE to "host" or "exec".
#   "host"  — curl runs on the macOS host; requires localhost:PORT to be
#             reachable (Docker Desktop, or Colima with network mode "host").
#   "exec"  — each HTTP call is run via `docker compose exec housecall-server`
#             using wget inside the Alpine container. Used when Colima with the
#             macOS Virtualization.Framework makes the forwarded port
#             unreachable from the host.
detect_exec_mode() {
    if [[ -n "$EXEC_MODE" ]]; then
        log "EXEC_MODE=$EXEC_MODE (explicit override)"
        return
    fi
    # Derive the host port from API_BASE.
    local port
    port="$(printf '%s' "$API_BASE" | sed 's|.*:\([0-9]*\)$|\1|')"
    [[ -n "$port" ]] || port="8080"

    if command -v curl >/dev/null 2>&1 \
        && curl -sf --max-time 2 "${API_BASE}/healthz" >/dev/null 2>&1; then
        EXEC_MODE="host"
        log "Auto-detected: server reachable at ${API_BASE} from host → using curl (host mode)"
    else
        EXEC_MODE="exec"
        log "Auto-detected: server NOT reachable at ${API_BASE} from host"
        log "  → falling back to docker compose exec (exec mode, Colima-safe)"
        log "  To force host mode: EXEC_MODE=host ./scripts/e2e.sh"
    fi
}

# ---- low-level HTTP abstraction ------------------------------------------
# api_get <path> [bearer_token] — returns body on stdout; exits non-zero on
# HTTP error.
api_get() {
    local path="$1"
    local token="${2:-}"
    if [[ "$EXEC_MODE" == "host" ]]; then
        local args=(-sf "${API_BASE}${path}")
        [[ -n "$token" ]] && args+=(-H "Authorization: Bearer ${token}")
        curl "${args[@]}"
    else
        # exec mode: wget inside the server container.
        local wargs=(-qO-)
        [[ -n "$token" ]] && wargs+=(--header="Authorization: Bearer ${token}")
        _docker_exec wget "${wargs[@]}" "http://localhost:8080${path}"
    fi
}

# api_post_json <path> <json_body> [bearer_token] — returns body on stdout.
api_post_json() {
    local path="$1"
    local body="$2"
    local token="${3:-}"
    if [[ "$EXEC_MODE" == "host" ]]; then
        local args=(-sf -X POST "${API_BASE}${path}" -H "Content-Type: application/json")
        [[ -n "$token" ]] && args+=(-H "Authorization: Bearer ${token}")
        args+=(-d "$body")
        curl "${args[@]}"
    else
        local wargs=(-qO- --header="Content-Type: application/json" --post-data="$body")
        [[ -n "$token" ]] && wargs+=(--header="Authorization: Bearer ${token}")
        _docker_exec wget "${wargs[@]}" "http://localhost:8080${path}"
    fi
}

# web_post_form_with_cookies <path> <form_data> — POST a URL-encoded form,
# capturing the session cookie (login) and following the redirect.
# Returns 0 on success (final HTTP status 200 or 302/303).
web_post_form_with_cookies() {
    local path="$1"
    local data="$2"
    if [[ "$EXEC_MODE" == "host" ]]; then
        local code
        code="$(curl -sf --cookie-jar "$COOKIE_JAR" \
            -o /dev/null -w "%{http_code}" \
            -L \
            -X POST "${WEB_BASE}${path}" \
            -d "$data")"
        echo "$code"
    else
        # In exec mode we can't use the host cookie jar.  Instead, capture
        # the Set-Cookie header from wget and store the value in a shell var.
        # wget in Alpine writes headers to stderr with -S; we pipe stderr to
        # stdout and extract the Set-Cookie line.
        # Pass form data and path via env vars so a crafted server response
        # value cannot break out of the sh -c string and execute commands.
        local output
        output="$(docker exec \
            -e _HC_POST_DATA="$data" \
            -e _HC_PATH="$path" \
            housecall-server \
            sh -c 'wget -qO- -S --post-data="$_HC_POST_DATA" "http://localhost:8080$_HC_PATH" 2>&1')" || true
        local cookie_val
        cookie_val="$(printf '%s\n' "$output" | grep -i "Set-Cookie:" | grep "hc_session" \
            | sed 's/.*hc_session=\([^;]*\).*/\1/' | head -1)"
        if [[ -n "$cookie_val" ]]; then
            # Store for subsequent exec-mode cookie POSTs.
            WEB_SESSION_COOKIE_VALUE="$cookie_val"
        fi
        # Report final HTTP status: 200 (after redirect) on success.
        local status
        status="$(printf '%s\n' "$output" | grep "HTTP/" | tail -1 \
            | awk '{print $2}' || true)"
        echo "${status:-000}"
    fi
}

# web_get_with_cookies <path> — GET a web app page with the session cookie.
web_get_with_cookies() {
    local path="$1"
    if [[ "$EXEC_MODE" == "host" ]]; then
        curl -sf --cookie "$COOKIE_JAR" "${WEB_BASE}${path}"
    else
        # Pass cookie value via env var to prevent injection from a
        # server-response-derived value breaking out of the header string.
        docker exec \
            -e _HC_SESSION="$WEB_SESSION_COOKIE_VALUE" \
            -e _HC_PATH="$path" \
            housecall-server \
            sh -c 'wget -qO- --header="Cookie: hc_session=$_HC_SESSION" "http://localhost:8080$_HC_PATH"'
    fi
}

# web_post_form_approve <path> <form_data> — POST the approve form, reusing
# the captured session cookie.
web_post_form_approve() {
    local path="$1"
    local data="$2"
    if [[ "$EXEC_MODE" == "host" ]]; then
        local code
        code="$(curl -sf --cookie "$COOKIE_JAR" \
            -o /dev/null -w "%{http_code}" \
            -L \
            -X POST "${WEB_BASE}${path}" \
            -d "$data")"
        echo "$code"
    else
        # Pass cookie value, form data, and path via env vars so a crafted
        # server-response-derived value (cookie, recommendation id) cannot
        # break out of the sh -c string and execute commands in the container.
        local output
        output="$(docker exec \
            -e _HC_SESSION="$WEB_SESSION_COOKIE_VALUE" \
            -e _HC_POST_DATA="$data" \
            -e _HC_PATH="$path" \
            housecall-server \
            sh -c 'wget -qO- -S \
                --header="Cookie: hc_session=$_HC_SESSION" \
                --post-data="$_HC_POST_DATA" \
                "http://localhost:8080$_HC_PATH" 2>&1')" || true
        local status
        status="$(printf '%s\n' "$output" | grep "HTTP/" | tail -1 \
            | awk '{print $2}' || true)"
        echo "${status:-000}"
    fi
}

# _docker_exec — run a command inside the server container via docker exec.
_docker_exec() {
    docker exec housecall-server "$@"
}

# _docker_exec_raw — run a shell command string inside the server container
# (used when we need to capture stderr as well as stdout).
_docker_exec_raw() {
    docker exec housecall-server "$@"
}

# WEB_SESSION_COOKIE_VALUE — used only in exec mode (host mode uses the
# cookie jar file).
WEB_SESSION_COOKIE_VALUE=""

# ---- step 0: bring up the stack ------------------------------------------
bring_up_stack() {
    if [[ "$SKIP_UP" == "1" ]]; then
        log "SKIP_UP=1: skipping compose up + seed"
        return
    fi

    log "Bringing up compose stack (docker compose up -d --build --wait)..."
    local script_dir backend_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    backend_dir="$(cd "$script_dir/.." && pwd)"

    (cd "$backend_dir" && docker compose up -d --build --wait) \
        || fail "docker compose up failed"

    log "Stack is up. Seeding database..."
    (cd "$backend_dir" && make seed) \
        || fail "make seed failed"
    log "Seed complete."
}

# ---- step 1: patient login -----------------------------------------------
patient_login() {
    log "Step 1: patient login..."
    local body
    body="$(api_post_json "/api/auth/login" \
        "{\"tenant_id\":\"${TENANT_ID}\",\"email\":\"${PATIENT_EMAIL}\",\"password\":\"${PATIENT_PASSWORD}\"}" \
    )" || fail "patient login request failed (server at ${API_BASE} not responding)"

    # Auth response uses json-tagged lowercase fields ("token", "actor_id", etc.)
    PATIENT_TOKEN="$(json_field token "$body")"
    [[ -n "$PATIENT_TOKEN" ]] || fail "patient login: no token in response: $body"
    log "Patient logged in. token=$(redact_token "$PATIENT_TOKEN")"
}

# ---- step 2: create conversation -----------------------------------------
create_conversation() {
    log "Step 2: patient creates conversation..."
    local body
    body="$(api_post_json "/api/conversations" \
        '{"title":"E2E test conversation"}' \
        "$PATIENT_TOKEN" \
    )" || fail "create conversation request failed"

    # Conversation struct has no json tags → Go default "ID" (capital).
    CONVERSATION_ID="$(json_field ID "$body")"
    [[ -n "$CONVERSATION_ID" ]] || fail "create conversation: no ID in response: $body"
    log "Conversation created: $CONVERSATION_ID"
}

# ---- step 3: post patient message (triggers DraftAsync) ------------------
post_message() {
    log "Step 3: patient posts message (triggers agent draft)..."
    # Escape the message as a JSON string.
    local escaped_msg
    escaped_msg="$(printf '%s' "$PATIENT_MESSAGE" \
        | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null \
        || printf '"%s"' "$PATIENT_MESSAGE")"

    local body
    body="$(api_post_json \
        "/api/conversations/${CONVERSATION_ID}/messages" \
        "{\"content\":${escaped_msg}}" \
        "$PATIENT_TOKEN" \
    )" || fail "post message request failed"

    # Message struct has no json tags → Go default "ID" (capital).
    MESSAGE_ID="$(json_field ID "$body")"
    [[ -n "$MESSAGE_ID" ]] || fail "post message: no ID in response: $body"
    log "Message posted: $MESSAGE_ID"
    log "Agent is drafting in the background..."
}

# ---- step 4: physician JSON API login (to poll queue) --------------------
physician_api_login() {
    log "Step 4a: physician API login (to poll queue for PENDING_REVIEW)..."
    local body
    body="$(api_post_json "/api/auth/login" \
        "{\"tenant_id\":\"${TENANT_ID}\",\"email\":\"${PHYSICIAN_EMAIL}\",\"password\":\"${PHYSICIAN_PASSWORD}\"}" \
    )" || fail "physician API login request failed"

    # Auth response uses json-tagged lowercase fields.
    PHYSICIAN_TOKEN="$(json_field token "$body")"
    [[ -n "$PHYSICIAN_TOKEN" ]] || fail "physician API login: no token in response: $body"
    log "Physician API login OK. token=$(redact_token "$PHYSICIAN_TOKEN")"
}

# ---- step 5: poll physician queue for PENDING_REVIEW ---------------------
poll_for_pending() {
    log "Step 5: polling physician queue for PENDING_REVIEW (timeout ${AGENT_POLL_TIMEOUT}s)..."
    local elapsed=0

    while [[ $elapsed -lt $AGENT_POLL_TIMEOUT ]]; do
        local body rec_id
        body="$(api_get "/api/recommendations?state=PENDING_REVIEW" "$PHYSICIAN_TOKEN" 2>/dev/null)" || true
        # Recommendation struct has no json tags → Go default "ID" (capital).
        rec_id="$(json_array_field0 ID "$body" 2>/dev/null || true)"

        if [[ -n "$rec_id" && "$rec_id" != "null" && "$rec_id" != "" ]]; then
            RECOMMENDATION_ID="$rec_id"
            log "PENDING_REVIEW recommendation found: $RECOMMENDATION_ID (after ${elapsed}s)"
            return
        fi

        log "  ...waiting for agent draft (${elapsed}s elapsed, will retry in ${POLL_INTERVAL}s)"
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    # Diagnosis
    log ""
    log "Diagnosis: checking if Ollama is reachable on host port 11434..."
    if curl -sf --max-time 3 "http://localhost:11434/api/tags" >/dev/null 2>&1 \
        || docker exec housecall-server wget -qO- --timeout=3 "http://host.docker.internal:11434/api/tags" >/dev/null 2>&1; then
        log "  Ollama appears reachable. Check server logs:"
        log "    docker compose logs server | tail -50"
    else
        log "  Ollama is NOT reachable."
        log "  Steps to fix:"
        log "    1. ollama serve          (if not already running)"
        log "    2. ollama pull medgemma:4b"
        log "    3. Re-run this script"
    fi
    fail "Timed out after ${AGENT_POLL_TIMEOUT}s waiting for a PENDING_REVIEW recommendation."
}

# ---- step 6: physician web app login + approve ---------------------------
# This exercises the real server-rendered physician UI path. A physician
# using a browser would:
#   1. Visit /web/login, enter credentials → gets an hc_session cookie.
#   2. Visit /web/queue → sees pending recommendations.
#   3. Click Approve (POST /web/recommendations/{id}/review, action=approve).
#
# We replicate all three steps with HTTP calls so the full HTML/form path is
# exercised, not just the JSON API.
#
# Note on the Secure cookie flag: the hc_session cookie is issued with
# Secure: true. Standard browsers refuse to send Secure cookies over plain
# HTTP. curl ignores this restriction and sends the cookie regardless —
# which is the correct behaviour for a local integration-test driver that
# has no TLS terminator. In exec mode we capture the cookie value from the
# Set-Cookie header and pass it explicitly, achieving the same result.
physician_web_approve() {
    log "Step 6: physician approves recommendation ${RECOMMENDATION_ID} via web app..."

    # 6a. POST /web/login with physician credentials.
    log "  6a. Web app login..."
    local login_status
    login_status="$(web_post_form_with_cookies "/web/login" \
        "tenant_id=${TENANT_ID}&email=${PHYSICIAN_EMAIL}&password=${PHYSICIAN_PASSWORD}")"

    # With -L (follow redirect) the final status should be 200 (queue page).
    # In exec mode we may get the redirect status (303) if wget doesn't follow.
    case "$login_status" in
        200|303)
            : # OK
            ;;
        *)
            fail "web login: unexpected HTTP status ${login_status} (expected 200 or 303)"
            ;;
    esac

    # Verify the session cookie was captured.
    if [[ "$EXEC_MODE" == "host" ]]; then
        grep -q "hc_session" "$COOKIE_JAR" \
            || fail "web login: no hc_session cookie issued — check physician credentials"
    else
        [[ -n "$WEB_SESSION_COOKIE_VALUE" ]] \
            || fail "web login: no hc_session cookie captured from Set-Cookie header"
    fi
    log "  Web login OK, hc_session cookie captured."

    # 6b. GET /web/queue — smoke-check that the recommendation appears.
    log "  6b. Loading physician queue page..."
    local queue_body
    queue_body="$(web_get_with_cookies "/web/queue")" \
        || fail "GET /web/queue failed"

    if ! printf '%s' "$queue_body" | grep -q "$RECOMMENDATION_ID"; then
        log "WARNING: recommendation $RECOMMENDATION_ID not visible in queue HTML."
        log "  Continuing anyway — the approve POST will fail if access is denied."
    else
        log "  Recommendation visible in queue."
    fi

    # 6c. POST /web/recommendations/{id}/review with action=approve.
    log "  6c. Submitting approve form..."
    local review_status
    review_status="$(web_post_form_approve \
        "/web/recommendations/${RECOMMENDATION_ID}/review" \
        "action=approve")"

    case "$review_status" in
        200|303)
            : # OK — 303 redirect to /web/queue is the success path
            ;;
        *)
            fail "web approve: unexpected HTTP status ${review_status} (expected 200 or 303)"
            ;;
    esac
    log "  Approve form submitted (HTTP ${review_status} — success)."
}

# ---- step 7: patient polls for DELIVERED ---------------------------------
poll_for_delivered() {
    log "Step 7: patient polls for DELIVERED recommendation (timeout 30s)..."
    local elapsed=0
    local delivered_timeout=30

    while [[ $elapsed -lt $delivered_timeout ]]; do
        local body state
        body="$(api_get "/api/recommendations/${RECOMMENDATION_ID}" "$PATIENT_TOKEN" 2>/dev/null)" || true
        # Recommendation struct has no json tags → Go default "State",
        # "FinalContent" (capital).
        state="$(json_field State "$body" 2>/dev/null || true)"

        if [[ "$state" == "DELIVERED" ]]; then
            # Assert FinalContent is non-empty (HIPAA: assert presence, not value).
            local has_content
            if command -v python3 >/dev/null 2>&1; then
                has_content="$(printf '%s' "$body" | python3 -c \
                    'import sys,json; d=json.load(sys.stdin); fc=d.get("FinalContent"); print(fc if fc else "")' \
                    2>/dev/null || true)"
            elif command -v jq >/dev/null 2>&1; then
                has_content="$(printf '%s' "$body" | jq -r '.FinalContent // empty' 2>/dev/null || true)"
            else
                has_content="nonempty"  # fallback: assume ok
            fi
            [[ -n "$has_content" ]] \
                || fail "Recommendation is DELIVERED but final_content is empty — state-machine invariant violated"
            log "Recommendation $RECOMMENDATION_ID is DELIVERED. final_content: [non-empty, content redacted]"
            return
        fi

        if [[ -n "$state" && "$state" != "null" && "$state" != "" ]]; then
            log "  ...state=$state (waiting for DELIVERED)"
        else
            log "  ...recommendation not yet visible to patient (not DELIVERED)"
        fi

        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    fail "Timed out after ${delivered_timeout}s waiting for DELIVERED state"
}

# ---- main ----------------------------------------------------------------
main() {
    log "========================================"
    log "HouseCall E2E Test"
    log "  API:  $API_BASE"
    log "  WEB:  $WEB_BASE"
    log "========================================"

    check_deps
    bring_up_stack
    detect_exec_mode
    patient_login
    create_conversation
    post_message
    physician_api_login
    poll_for_pending
    physician_web_approve
    poll_for_delivered

    log ""
    log "========================================"
    log "E2E PASSED"
    log "Full loop verified:"
    log "  patient message → agent draft → PENDING_REVIEW"
    log "  physician approved via web app → DELIVERED"
    log "  patient sees DELIVERED recommendation with non-empty content"
    log "========================================"
    exit 0
}

main "$@"
