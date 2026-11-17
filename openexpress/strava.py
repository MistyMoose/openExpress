"""Strava upload: OAuth2 authorization-code sign-in, token refresh, and uploading FIT files
to Strava's API (POST /uploads, polled until Strava has matched the file to an activity or
reports an error). The user registers their own Strava API application (client ID and
secret, free, at strava.com/settings/api, Authorization Callback Domain "localhost") - this
program ships with none of its own, as it does with no Garmin application key either
(settings.py).

Public API, used by this module's own CLI commands (`strava connect|disconnect|status|upload`,
cli.py) and by the macOS app (openexpress/engine.py, not part of this module):

  - status() -> Status
        What is configured and connected now, read only (no network).
  - authorize_url(redirect_uri) -> str
        The address of Strava's consent page for `redirect_uri`; NotConfigured when no
        client ID/secret is saved yet (connect(), or save_client() directly).
  - connect_with_code(code, redirect_uri) -> Status
        Exchange the code Strava's redirect sent to `redirect_uri` for a token, saved for
        later uploads. The macOS app runs its own browser and callback and calls this once
        it has the code; connect() below does both itself, for the command line.
  - disconnect() -> bool
        Revoke the token at Strava (best effort) and remove what is saved of it.
  - upload_files(paths, apply, progress=None) -> UploadReport
        Upload the named FIT files, each once (a local record keeps what was sent, so a file
        already uploaded is never read or sent again); `apply` False only says what would be
        sent. sync.py's sync integration (cli.py's `sync`, Settings.strava_upload) and the
        `strava upload FILE...` command both call this.

connect() is the CLI-only interactive flow: it saves the client ID/secret (once; later runs
reuse what is saved), opens the browser at authorize_url() for a one-shot local HTTP server
on 127.0.0.1 (a random free port, as Strava's callback domain "localhost" allows any port),
and exchanges the code that server receives.

Tokens and the client ID/secret are kept with auth.store.save_secret/read_secret/delete_secret
(the macOS Keychain, items "strava_client" and "strava_token"; on Linux, or where the Keychain
cannot be reached, 0600 files of the same names). The local record of what has already been
uploaded (never sent to Strava) is a plain file in the data directory, next to sync.py's own
records of each device: data_dir()/strava/uploaded.json.
"""

from __future__ import annotations

import http.server
import json
import logging
import re
import threading
import time
import webbrowser
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlsplit

import requests

from openexpress import applog, fit, paths
from openexpress.auth.store import delete_secret, read_secret, save_secret
from openexpress.errors import UserFacingError
from openexpress.i18n import _
from openexpress.progress import Step, say_to
from openexpress.useragent import session as user_agent_session

log = logging.getLogger(__name__)

AUTHORIZE_URL = "https://www.strava.com/oauth/authorize"
TOKEN_URL = "https://www.strava.com/oauth/token"
DEAUTHORIZE_URL = "https://www.strava.com/oauth/deauthorize"
UPLOAD_URL = "https://www.strava.com/api/v3/uploads"
# Write access for the sync integration, read access so the athlete and the upload's
# activity can be looked up; nothing beyond what openExpress itself needs.
SCOPE = "activity:write,read"
TIMEOUT = 60
# Refreshed a little before it actually expires, so that a slow upload does not start with a
# token that expires mid-way.
EXPIRY_MARGIN = 120
# How long the local callback server waits for the browser to send the code back.
CALLBACK_TIMEOUT = 180
# How long polling an upload waits for Strava to finish processing it.
POLL_TIMEOUT = 60

# The Keychain items on macOS (auth.store.read_secret/save_secret/delete_secret); the file
# names everywhere else.
CLIENT_ITEM = "strava_client"
TOKEN_ITEM = "strava_token"


class StravaError(UserFacingError):
    pass


class NotConfigured(StravaError):
    """No Strava API application (client ID/secret) is saved yet."""


class NotConnected(StravaError):
    """No token is saved: `strava connect` was not run, or `disconnect` removed it."""


class RateLimited(StravaError):
    """Strava answered 429: too many requests for now (its X-RateLimit-* headers, if any, in
    `usage`). The files after this one wait for the next call of upload_files."""

    def __init__(self, message: str, usage: str = ""):
        super().__init__(message)
        self.usage = usage


@dataclass
class Client:
    """The user's own Strava API application (strava.com/settings/api)."""

    client_id: str
    client_secret: str = field(repr=False)


@dataclass
class Token:
    access_token: str = field(repr=False)
    refresh_token: str = field(repr=False)
    expires_at: int = 0
    athlete_id: int | None = None
    athlete_name: str | None = None
    scope: str = SCOPE


@dataclass
class Status:
    """What `strava status` and the macOS app's own status row show: read only, no network."""

    configured: bool  # a client ID/secret is saved (connect(), or save_client())
    connected: bool  # a token is saved
    athlete_id: int | None = None
    athlete_name: str | None = None
    scope: str = ""
    expires_at: int | None = None


@dataclass
class UploadReport:
    uploaded: list[str] = field(default_factory=list)
    # Not sent: the local record already has it (and, for a file actually sent, one Strava
    # itself says is "duplicate of activity …").
    duplicates: list[str] = field(default_factory=list)
    failed: list[tuple[str, str]] = field(default_factory=list)
    # Not a FIT file, or could not be read: {name: why}, for a sync's report (its own files
    # never stop it, as a failed upload does not either).
    skipped: list[tuple[str, str]] = field(default_factory=list)
    # Strava answered 429: the files after it were not tried; see RateLimited.
    rate_limited: bool = False


# --- the client ID/secret and the token, saved with auth.store -------------------------


def _client_path() -> Path:
    return paths.config_dir() / f"{CLIENT_ITEM}.json"


def load_client() -> Client | None:
    text = read_secret(CLIENT_ITEM, _client_path())
    if text is None:
        return None
    try:
        data = json.loads(text)
        return Client(str(data["client_id"]), str(data["client_secret"]))
    except (ValueError, KeyError, TypeError):
        log.warning("strava: the saved client ID/secret is damaged")
        return None


def save_client(client: Client) -> None:
    save_secret(CLIENT_ITEM,
               json.dumps({"client_id": client.client_id, "client_secret": client.client_secret}),
               _client_path())


def _token_path() -> Path:
    return paths.config_dir() / f"{TOKEN_ITEM}.json"


def load_token() -> Token | None:
    text = read_secret(TOKEN_ITEM, _token_path())
    if text is None:
        return None
    try:
        data = json.loads(text)
        return Token(
            access_token=str(data["access_token"]), refresh_token=str(data["refresh_token"]),
            expires_at=int(data.get("expires_at") or 0), athlete_id=data.get("athlete_id"),
            athlete_name=data.get("athlete_name"), scope=str(data.get("scope") or SCOPE))
    except (ValueError, KeyError, TypeError):
        log.warning("strava: the saved token is damaged")
        return None


def save_token(token: Token) -> None:
    save_secret(TOKEN_ITEM, json.dumps({
        "access_token": token.access_token, "refresh_token": token.refresh_token,
        "expires_at": token.expires_at, "athlete_id": token.athlete_id,
        "athlete_name": token.athlete_name, "scope": token.scope}), _token_path())


def delete_token() -> bool:
    return delete_secret(TOKEN_ITEM, _token_path())


# --- the local record of what has already been uploaded --------------------------------


def _record_path() -> Path:
    return paths.data_dir() / "strava" / "uploaded.json"


def _load_record() -> dict:
    try:
        data = json.loads(_record_path().read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _save_record(record: dict) -> None:
    paths.write_private(_record_path(), json.dumps(record, indent=1))


def uploaded_activity(ext_id: str) -> int | None:
    """Strava's activity ID already on record for `ext_id` (external_id); None: not uploaded
    by this installation yet."""
    entry = _load_record().get(ext_id)
    return entry.get("activity_id") if isinstance(entry, dict) else None


def external_id(name: str, data: bytes) -> str:
    """A stable ID for Strava's `external_id` (also this module's own local record, dedupe):
    the same every time the same file is uploaded again (a retry, or the same device file
    copied by two installations of openExpress), so it is never uploaded twice. Built from
    the FIT file's own device - file_id's serial_number, a watch's Unit ID ("-" when the file
    does not say, or is not a FIT file) - and the file's name."""
    try:
        serial = fit.parse_file_id(data).serial_number
    except fit.FitError:
        serial = None
    return f"openexpress-{serial if serial is not None else '-'}-{name}"


def pending_dir(unit_id: int) -> Path:
    """Where the sync integration (cli.py's `sync`, Settings.strava_upload) stages a device's
    activity FIT files for upload to Strava, next to sync.py's own records of the device
    (sync.records_dir): filled by sync.plan_drop_folder/run_drop_folder, emptied here as each
    file is uploaded (or given up on: rejected, not a FIT file)."""
    from openexpress import sync

    return sync.records_dir(unit_id) / "strava"


# --- status / connecting ----------------------------------------------------------------


def status() -> Status:
    """What is configured (a client ID/secret saved) and connected (a token saved), with the
    athlete and when the token expires; read only, no network and no refresh - a token that
    is due or overdue still counts as connected (upload_files refreshes it when it is used)."""
    token = load_token()
    if token is None:
        return Status(configured=load_client() is not None, connected=False)
    return Status(configured=True, connected=True, athlete_id=token.athlete_id,
                 athlete_name=token.athlete_name, scope=token.scope,
                 expires_at=token.expires_at or None)


def _not_configured() -> NotConfigured:
    return NotConfigured(_(
        "No Strava API application is set up yet. Create one (free) at "
        "strava.com/settings/api - Authorization Callback Domain: localhost - then run: "
        "openexpress strava connect"))


def authorize_url(redirect_uri: str) -> str:
    """The address of Strava's consent page for `redirect_uri`, with the client ID saved by
    connect() (or save_client()); NotConfigured when none is saved yet."""
    client = load_client()
    if client is None:
        raise _not_configured()
    params = {"client_id": client.client_id, "redirect_uri": redirect_uri,
              "response_type": "code", "approval_prompt": "auto", "scope": SCOPE}
    return AUTHORIZE_URL + "?" + urlencode(params)


def connect_with_code(code: str, redirect_uri: str) -> Status:
    """Exchange `code` (from Strava's redirect to `redirect_uri`, authorize_url()) for a
    token, saved for later uploads. NotConfigured: no client ID/secret saved yet."""
    client = load_client()
    if client is None:
        raise _not_configured()
    what = _("Strava sign-in")
    resp = _request("POST", TOKEN_URL, data={
        "client_id": client.client_id, "client_secret": client.client_secret,
        "code": code, "grant_type": "authorization_code"})
    data = _json(resp)
    if resp.status_code != 200 or "access_token" not in data:
        raise StravaError(_("{what} failed: {error}").format(
            what=what, error=_answer_text(data, resp)))
    athlete = data.get("athlete") or {}
    token = Token(
        access_token=data["access_token"], refresh_token=data["refresh_token"],
        expires_at=int(data.get("expires_at") or 0), athlete_id=athlete.get("id"),
        athlete_name=_athlete_name(athlete), scope=SCOPE)
    save_token(token)
    log.info("strava: connected (athlete id known: %s)", token.athlete_id is not None)
    return status()


def disconnect() -> bool:
    """Revoke the token at Strava (best effort: its own failure is only logged, as the token
    is removed here all the same) and remove what is saved of it. The client ID/secret
    (connect()'s own application) are kept, so reconnecting needs them only once. Whether
    anything was saved to remove."""
    token = load_token()
    if token is not None:
        try:
            _request("POST", DEAUTHORIZE_URL, data={"access_token": token.access_token})
        except StravaError as e:
            log.info("strava: deauthorize at Strava failed (%s); removed here all the same", e)
    removed = delete_token()
    log.info("strava: disconnected" if removed else "strava: nothing was connected")
    return removed


# --- the interactive flow for the command line ------------------------------------------


class _CallbackHTTPServer(http.server.HTTPServer):
    """http.server.HTTPServer with the two fields _CallbackHandler fills in: plain attributes
    (not a dataclass; the base class is not one either)."""

    code: str | None = None
    error: str | None = None


class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    """One answer, for the one redirect Strava's consent page makes; the server
    (_CallbackServer) is used for exactly one request and then closed."""

    server: _CallbackHTTPServer

    def do_GET(self) -> None:
        query = parse_qs(urlsplit(self.path).query)
        self.server.code = (query.get("code") or [None])[0]
        self.server.error = (query.get("error") or [None])[0]
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        # TRANSLATORS: the page shown in the browser once Strava's consent page sends it back
        # here; the command line itself tells the result
        text = (_("Connected to Strava. You can close this window.") if self.server.code
                else _("Strava sign-in was not completed. You can close this window."))
        self.wfile.write(text.encode("utf-8"))

    def log_message(self, log_format: str, *args) -> None:
        pass  # the command line tells its own result; nothing of this request is logged here


class _CallbackServer:
    """A one-shot local HTTP server on 127.0.0.1, a random free port (Strava's callback
    domain "localhost" allows any port): answers exactly one request, the redirect of
    Strava's consent page, then is done."""

    def __init__(self):
        self._httpd = _CallbackHTTPServer(("127.0.0.1", 0), _CallbackHandler)
        self.port = self._httpd.server_address[1]
        self._thread = threading.Thread(target=self._httpd.handle_request, daemon=True)
        self._thread.start()

    def wait_for_code(self, timeout: float) -> str:
        self._thread.join(timeout)
        if self._thread.is_alive():
            raise StravaError(_("Strava did not answer in time: the browser may not have "
                                "opened, or the consent was not given."))
        code = self._httpd.code
        if not code:
            raise StravaError(_("Strava sign-in was not completed: {error}").format(
                error=self._httpd.error or "?"))
        return code

    def close(self) -> None:
        self._httpd.server_close()


def connect(client_id: str | None = None, client_secret: str | None = None,
           open_browser: Callable[[str], bool] | None = None,
           timeout: float = CALLBACK_TIMEOUT) -> Status:
    """The interactive flow for `strava connect`: `client_id`/`client_secret` saved (once;
    a later call may omit them, reusing what connect() saved before), a one-shot local HTTP
    server started here, the browser opened (`open_browser`, default webbrowser.open) at
    Strava's consent page with that server's address as the redirect URI, and the code it
    receives exchanged for a token (connect_with_code). The macOS app does not call this: it
    runs its own browser and callback, and calls connect_with_code directly once it has the
    code. NotConfigured: no client ID/secret given now or saved before."""
    if client_id and client_secret:
        save_client(Client(client_id, client_secret))
    elif load_client() is None:
        raise _not_configured()
    server = _CallbackServer()
    try:
        redirect_uri = f"http://localhost:{server.port}/strava"
        url = authorize_url(redirect_uri)
        (open_browser or webbrowser.open)(url)
        code = server.wait_for_code(timeout)
    finally:
        server.close()
    return connect_with_code(code, redirect_uri)


# --- HTTP helpers --------------------------------------------------------------------------

_http: requests.Session | None = None


def _session() -> requests.Session:
    global _http
    if _http is None:
        _http = user_agent_session()
    return _http


def _request(method: str, url: str, **kw) -> requests.Response:
    kw.setdefault("timeout", TIMEOUT)
    where = urlsplit(url)._replace(query="").geturl()
    try:
        resp = _session().request(method, url, **kw)
    except requests.RequestException as e:
        log.warning("strava: HTTP %s %s failed: %s", method, where, type(e).__name__)
        raise StravaError(_("Strava could not be reached: {error}").format(
            error=applog.network_error_text(e))) from e
    log.info("strava: HTTP %s %s -> %s", method, where, resp.status_code)
    return resp


def _json(resp: requests.Response) -> dict:
    try:
        data = resp.json()
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def _answer_text(data: dict, resp: requests.Response) -> str:
    message = data.get("message") if isinstance(data, dict) else None
    if message:
        return str(message)
    errors = data.get("errors") if isinstance(data, dict) else None
    return str(errors) if errors else f"HTTP {resp.status_code}"


def _athlete_name(athlete: dict) -> str | None:
    name = " ".join(p for p in (athlete.get("firstname"), athlete.get("lastname")) if p)
    return name or None


def _ensure_fresh(token: Token) -> Token:
    """`token`, refreshed first if it is due within EXPIRY_MARGIN or already past its
    expiry."""
    if token.expires_at - time.time() > EXPIRY_MARGIN:
        return token
    return _refresh(token)


def _refresh(token: Token) -> Token:
    client = load_client()
    if client is None:
        raise _not_configured()
    resp = _request("POST", TOKEN_URL, data={
        "client_id": client.client_id, "client_secret": client.client_secret,
        "refresh_token": token.refresh_token, "grant_type": "refresh_token"})
    data = _json(resp)
    if resp.status_code != 200 or "access_token" not in data:
        raise NotConnected(_("The Strava sign-in has expired: {error}. Run: "
                             "openexpress strava connect").format(
            error=_answer_text(data, resp)))
    new = Token(access_token=data["access_token"],
               refresh_token=data.get("refresh_token") or token.refresh_token,
               expires_at=int(data.get("expires_at") or 0), athlete_id=token.athlete_id,
               athlete_name=token.athlete_name, scope=token.scope)
    save_token(new)
    log.info("strava: token refreshed")
    return new


def _require_token() -> Token:
    token = load_token()
    if token is None:
        raise NotConnected(_("Not connected to Strava. Run: openexpress strava connect"))
    return _ensure_fresh(token)


def _authed_request(method: str, url: str, token: Token, **kw) -> tuple[requests.Response, Token]:
    """`token`, refreshed first if due; the request, and once more after a 401 (the token
    expired sooner than it said): the caller gets the (possibly refreshed) token back, to use
    for the rest of its own work."""
    token = _ensure_fresh(token)
    headers = dict(kw.pop("headers", None) or {})
    headers["Authorization"] = f"Bearer {token.access_token}"
    resp = _request(method, url, headers=headers, **kw)
    if resp.status_code == 401:
        token = _refresh(token)
        headers["Authorization"] = f"Bearer {token.access_token}"
        resp = _request(method, url, headers=headers, **kw)
    return resp, token


_DUPLICATE_RE = re.compile(r"duplicate of activity (\d+)")


def _poll(token: Token, upload_id, first: dict, timeout: float = POLL_TIMEOUT
         ) -> tuple[Token, int | None, bool]:
    """Wait for Strava to finish processing an upload: its activity_id, and whether it is a
    duplicate of one already there (its error message says so: not an error for this
    program). Raises RateLimited (429) and StravaError for anything else."""
    body = first
    deadline = time.monotonic() + timeout
    while True:
        error = body.get("error")
        if error:
            duplicate = _DUPLICATE_RE.search(str(error))
            if duplicate:
                return token, int(duplicate.group(1)), True
            raise StravaError(_("Strava rejected the file: {error}").format(error=error))
        activity_id = body.get("activity_id")
        if activity_id:
            return token, int(activity_id), False
        if time.monotonic() >= deadline:
            raise StravaError(_("Strava did not finish processing the upload in time"))
        time.sleep(1.5)
        resp, token = _authed_request("GET", f"{UPLOAD_URL}/{upload_id}", token)
        if resp.status_code == 429:
            raise RateLimited(_("Strava: too many requests for now"),
                              usage=resp.headers.get("X-RateLimit-Usage", ""))
        body = _json(resp)


def _upload_one(token: Token, name: str, data: bytes,
                ext_id: str) -> tuple[Token, int | None, bool]:
    """POST the file and poll until it is matched to an activity (_poll); returns the
    (possibly refreshed) token, Strava's activity_id, and whether it is a duplicate of one
    already there. Raises RateLimited (429) and StravaError for anything else."""
    files = {"file": (name, data, "application/octet-stream")}
    form = {"data_type": "fit", "external_id": ext_id}
    resp, token = _authed_request("POST", UPLOAD_URL, token, data=form, files=files)
    if resp.status_code == 429:
        raise RateLimited(_("Strava: too many uploads for now"),
                          usage=resp.headers.get("X-RateLimit-Usage", ""))
    body = _json(resp)
    if not resp.ok:
        raise StravaError(_("Strava upload failed: {error}").format(
            error=_answer_text(body, resp)))
    return _poll(token, body.get("id"), body)


# --- uploading ---------------------------------------------------------------------------


def upload_files(paths_: Iterable[str | Path], apply: bool,
                 progress: Callable[[str], None] | None = None) -> UploadReport:
    """Upload the FIT files named by `paths_` to Strava, each once: a file whose external_id
    (external_id()) is already in the local record is a duplicate, not read or sent again -
    also across different calls, so a file already sent by an earlier sync or an earlier
    `strava upload` is never sent twice. `apply` False only says what would be sent (no
    network, no token needed, unless a file turns out to be a duplicate already, which the
    local record alone can say). NotConnected/NotConfigured are raised at once, before any
    file is sent, when `apply` is true and no token is saved - the caller (cli.py's `strava
    upload`, or the sync integration, which catches it around the whole call) decides what
    that means; once a token is there, a 429 (RateLimited) stops the rest of the list for
    this call (`rate_limited` on the report), but any other failure of one file is reported
    and does not stop the others - as sync.py's own uploads to Garmin Connect, and so that
    Settings.strava_upload never fails a sync for a reason that is only one file's."""
    progress = say_to(progress)
    report = UploadReport()
    items = [Path(p) for p in paths_]
    record = _load_record()
    token: Token | None = _require_token() if apply and items else None
    for idx, path in enumerate(items, 1):
        try:
            data = path.read_bytes()
        except OSError as e:
            report.skipped.append((path.name, str(e)))
            continue
        if not path.name.lower().endswith(".fit"):
            report.skipped.append((path.name, _("not a FIT file")))
            continue
        ext_id = external_id(path.name, data)
        if ext_id in record:
            report.duplicates.append(path.name)
            continue
        if not apply:
            report.uploaded.append(path.name)
            continue
        try:
            # TRANSLATORS: a step of a sync, or of `strava upload`, telling how many FIT
            # files are sent to Strava ("… · 3 of 8")
            progress(Step(_("Uploading to Strava"), idx, len(items)))
            token, activity_id, duplicate = _upload_one(token, path.name, data, ext_id)
        except RateLimited as e:
            report.rate_limited = True
            report.failed.append((path.name, str(e)))
            log.warning("strava upload: stopped for this call (rate limited): %s", e)
            break
        except StravaError as e:
            report.failed.append((path.name, str(e)))
            log.warning("strava upload of %s failed: %s", path.name, e)
            continue
        record[ext_id] = {"activity_id": activity_id, "name": path.name, "at": time.time()}
        _save_record(record)
        (report.duplicates if duplicate else report.uploaded).append(path.name)
    log.info("strava upload: %d uploaded, %d duplicates, %d failed, %d skipped%s",
             len(report.uploaded), len(report.duplicates), len(report.failed),
             len(report.skipped), ", rate limited" if report.rate_limited else "")
    return report
