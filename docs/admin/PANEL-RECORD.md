<!-- django-unfold 0.105.0, Django 6.0.7, Python 3.12 -->
# Panel record

The system of record for the admin panel. Read it before changing the panel; update it
on the commit that changes one. A decision that reverses an earlier one is a row in
section 10, never a silent edit.

Architecture lives in [`../architecture/DESIGN-RECORD.md`](../architecture/DESIGN-RECORD.md),
never here. The threat model is [`../../backend/SECURITY.md`](../../backend/SECURITY.md).

## 1. Pinned release

- django-unfold: **0.105.0** (`requirements/prod.txt`, pinned and hashed)
- Django: **6.0.7**
- Python: **3.12**
- Last upgrade: 2026-09-04 (first install)

The release ships Django 5.2 / 6.0 / 6.1 classifiers and depends only on
`django>=5.2`, so it adds one package and no transitive dependency. Its 1.53 MB of
static assets — Inter, Material Symbols, Tailwind's compiled stylesheet, Alpine, HTMX
and Chart.js — reference no external host, which is what lets the panel work during a
shutdown.

## 2. Entry log

| Date | Entry point | Band | Outcome |
|---|---|---|---|
| 2026-09-04 | Stock → Unfold | 1 | The stock admin's one `ModelAdmin` left. Five models registered, nine hidden, dashboard, audit log, login lockout, retention. |
| 2026-09-04 | Review | 1 | Inventory, surface check and RTL audit run; every lead confirmed by a read of the installed package. Rendered signed-in at 1440×900 and at 375×812: dashboard, four changelists and the audit log. One defect, **Unusable**: a derived app label in the breadcrumb, fixed. Two leads ruled out: a filter on Django's `SimpleListFilter` base, and a raw byte count in the size column. Panel positions otherwise as recorded. |

## 3. Positions

| Surface | Operator view | Band and flip signal | RTL and Persian consequence | Upgrade cost and revisit signal | Release confirmed | Evidence and currency |
|---|---|---|---|---|---|---|
| **The site** | The panel is `unfold`'s `UnfoldAdminSite`, reached at `ADMIN_PATH`; `config/urls.py` still says `admin.site.urls` | 1. Flip: a second admin site, or a site-level view the `SITE_VIEWS` key cannot express | None yet — English only | Low: no subclass to re-check. Revisit: a release changes `DefaultAppConfig.ready()` | 0.105.0 — `unfold/apps.py` `DefaultAppConfig.ready()` assigns `admin.site` and `admin.sites.site` | The auto-swap is the documented install. `unfold/sites.py:25` sets `default_site = "unfold.admin.UnfoldAdminSite"`, a dotted path that **does not exist** in the package — never copy it. Current |
| **Application order** | Nothing, when it is right. When it is wrong: an index that lists nothing, every model URL a 404, and stock styling | 1 to 3. Flip: none | None | None. Revisit: never — pinned by a test | 0.105.0 | `"unfold"` must precede `"django.contrib.admin"`: the admin's `ready()` runs `autodiscover()`, unfold's replaces the site those registrations landed on. `manage.py check` still passes when it is wrong, so `test_settings_posture` pins the order. Current |
| **Registered models** | Accounts, Devices, Attachments, and the audit log | 1. Flip: a fifth model the operator needs, which is a `secure-code-auditor` review and not a convenience | None | Each new registration is a fresh exposure review. Revisit: any `@admin.register` | 0.105.0 | The set is a security boundary ([ADR-0011](../architecture/decisions/0011-django-unfold-admin-panel.md)), pinned by `test_exactly_the_four_decided_models_are_registered`. Voice rooms left it on 2026-09-05, with the model behind them — reversal 1 below. Current |
| **Hidden models** | Nothing. They are absent from the index, the sidebar and the command palette | 1 to 3. Flip: none | None | None — unregistered is the default. Revisit: a new model | 0.105.0 | `ProfileBlob`, `UserIdentity`, `OneTimePrekey`, `PqOneTimePrekey`, `DeviceLogRecord`, `KeyBackup`, `QueuedEnvelope`, `Group`, `Permission`. `Group` is registered by `django.contrib.auth.admin` on import and is explicitly unregistered in `core/admin.py`; the rest are never registered. Current |
| **Navigation** | Four groups named for the job: Overview, People, Storage, Audit | 1. Flip: more than about a dozen items, at which point the tree needs collapsing | The sidebar's own borders and grips do not mirror; a Persian panel needs the RTL stylesheet before this tree is usable | Low. Revisit: a release renames a `SIDEBAR` item key | 0.105.0 — group keys `title`/`items`, item keys `title`/`icon`/`link`/`permission`, all read by `unfold/sites.py:_get_navigation_items` | A non-empty `SIDEBAR["navigation"]` replaces the automatic app list entirely. **Nested `item["items"]` is recursed in Python but rendered nowhere** by `app_list.html`, so the tree is one level deep by necessity. Current |
| **Navigation permissions** | A staff account that is not the owner sees an empty sidebar | 1. Flip: a second role | None | Low. Revisit: a release changes `_call_permission_callback` | 0.105.0 — `item["permission"]` takes a dotted path to `callback(request)` | Load-bearing, not decoration: the tree is a static list of links that renders whatever it holds. Without a `permission` on **every** item a non-owner sees the full navigation with a 403 behind each entry. Current |
| **App names in the breadcrumb** | "Accounts", "Devices", "Attachments" — the words the sidebar uses, on the breadcrumb of every page of each app | 1 to 3. Flip: none | The breadcrumb separator is a `›` that does not mirror; a Persian panel needs the RTL stylesheet before it reads correctly | None — one attribute for each app, and no migration. Revisit: a new app registers a model | Django 6.0.7 — `AppConfig.verbose_name`, read by the admin for the app link in the breadcrumb | Django titles the app label when an `AppConfig` declares none, which is how a run-together word reached every page of one app before phase 3. Declared on all three apps that register a model, and pinned by `test_every_registered_project_app_names_itself_in_operator_words`, which fails on a derived name rather than on a list of expected ones. Verified on screen 2026-09-04, before the voice-room page left. Current |
| **The dashboard** | The first page after login: accounts awaiting activation with a one-click activate, then active accounts, live devices and attachment storage against the disk's own free space, each a link to its list | 1. Flip: the pending list stops fitting one screen — it is uncapped, which holds while the whole population is under 50 accounts | The card grid mirrors; the numbers need Persian digits | One template override, ledgered below. Revisit: each release | 0.105.0 — `DASHBOARD_CALLBACK` is a **dotted path only**, and the callback MUST return the context | Four queries, none per-row, proven flat from 2 rows to 24 by `test_the_page_renders_and_its_query_count_does_not_grow_with_the_rows`. The callback runs for every visitor, so it reads nothing at all for a non-owner. Current |
| **What the panel never shows** | No ciphertext, no key bytes, no signature bytes, no password hash, no token, no queue row, no pairing of accounts. A device label is ciphertext and does not render | 1 to 3. Flip: none, ever | None | Each new column is a review. Revisit: any `list_display` change | 0.105.0 | Enforced by `test_no_column_or_field_names_a_blob_key_signature_or_password`, which derives the forbidden set from the models rather than from a hand-written list. Current |
| **The attachment page** | Size bucket and day. No account, no id, no row link, no change form, no per-object delete | 1. Flip: an attachment model with a non-secret addressable column | None | Medium: three separate mechanisms hold the rule. Revisit: any change to this admin | 0.105.0 | `Attachment.id` is a bearer capability, so this page is built around never letting it into visible text or a URL. The residue is AR-2 in [`ACCEPTED_RISKS.md`](../../ACCEPTED_RISKS.md). Current |
| **Actions** | Activate, deactivate, revoke every device (accounts); revoke (devices); delete with a confirmation that states the count and the bytes freed (attachments); set a password (account change form) | 1. Flip: an action that outlives one request | Action labels are copy | Medium — see the security note. Revisit: each release | 0.105.0 — `@action(permissions=…, description=…, url_path=…, dialog=…, variant=…)`; `dialog["form_class"]` is **the class**, not a dotted path | **Every list, row and detail action must carry `permissions=`.** `unfold/admin.py` wraps an action URL in `admin_site.admin_view`, which checks only `is_active and is_staff`; the sole gate on the view body is the `if permissions:` branch in `unfold/decorators.py`. Without it any staff account can run the action by URL. Current, and tested by `test_the_set_password_url_refuses_a_staff_account_that_is_not_the_owner` |
| **The audit log** | Every administrative act: when, who, what kind, what was touched, and a sentence | 1 to 3. Flip: the log outgrows one changelist, at which point retention shortens rather than the page growing | Dates need the Jalali calendar in a Persian panel | Low. Revisit: none | 0.105.0 | Django logs change-form saves and deletes itself and logs **nothing** for a bulk action, so every action in this panel writes its own rows through `core.panel.audit`. `object_id` is deliberately absent from the columns, the fields and the search. Current |
| **Roles** | One: the superuser owner. A staff account that is not the owner gets an empty index and a designed 403 | 1. Flip: a second operator | The 403 page is copy | One template, ledgered below. Revisit: each release | 0.105.0 | `PanelModelAdmin` denies add, change and delete by default and grants read to the owner alone, so a model registered later without thought is read-only rather than editable. Current |
| **Login hardening** | Five failed attempts lock the name for fifteen minutes, with one sentence that never says whether the account exists | 1. Flip: a second operator, or a lockout that hits the operator in practice | The message is copy | Low: the seam is `AuthenticationForm.clean`, which Django has kept for many releases. Revisit: a Django release changing `AuthenticationForm` | 0.105.0 — `UNFOLD["LOGIN"]["form"]` is imported in `UnfoldAdminSite.__init__`; subclass `unfold.forms.AuthenticationForm`, not Django's, to keep the input styling | The refusal is raised **before** `super().clean()`, which is what calls `authenticate()`, so a locked name costs no Argon2 verification. State is in Redis under a digest of the name, never in the database, read as bytes through the redis client and never through Django's cache framework (ADR-0018); from phase 4 the same cool-off covers the API login, with counters of its own. Fails closed — AR-3. Current |
| **Session** | Sign-in lasts at most eight hours, and ends when the browser closes | 1 to 3. Flip: none | None | None. Revisit: none | Django 6.0.7 | `SESSION_COOKIE_AGE` is the server-side ceiling the record carries; `SESSION_EXPIRE_AT_BROWSER_CLOSE` drops `Max-Age` from the cookie. They do different jobs and both apply. Current |
| **Assets** | The panel renders identically with no internet | 1 to 3. Flip: none | A Persian panel needs a project-served family through `--font-sans`; Inter carries no Persian glyph | Low. Revisit: each release re-checks the byte count | 0.105.0 — 1,533,867 B across 25 files, zero external hosts | Everything comes from the package through `collectstatic`, and nginx serves `STATIC_ROOT`. Proven by `test_no_template_or_collected_asset_fetches_from_another_host` over the staticfiles finders, which walk exactly what `collectstatic` copies. Current |
| **Retention** | Nothing directly; the audit log stops before it becomes a history of the deployment | 1 to 3. Flip: an audit requirement that needs a longer window, or one that needs the order of two acts on one day | Dates | Low: one override of `log_change`. Revisit: a release that stops routing the change-form save through `ModelAdmin.log_change` | Django 6.0.7, django-unfold 0.105.0 — `log_change`, `log_deletions` and `log_addition` all come from Django's own `ModelAdmin`, so the theme shadows none of them | `manage.py prune` deletes a `LogEntry` older than `ADMIN_AUDIT_RETENTION_DAYS`, default 30. Every row this panel writes carries midnight UTC of the day of the act rather than the second, because `action_time` belongs to a contributed application whose schema this project does not change ([ADR-0025](../architecture/decisions/0025-unlinked-attachments-erasure-and-day-granularity.md)). Named in the seizure yield of `SECURITY.md`. Current |

## 4. Override ledger

Three templates, and no CSS or JavaScript of the project's own.

| Path | Release written against | Block or class it depends on | Upgrade cost | Revisit signal |
|---|---|---|---|---|
| `backend/templates/admin/index.html` | django-unfold 0.105.0 | Extends `admin/base.html`; owns `content`, and repeats unfold's `title` and `branding` verbatim. Uses the shipped `card`, `text`, `title`, `progress` and `button` components, and the Tailwind classes `flex`, `grid`, `gap-*`, `border-b`, `last:border-b-0`, `ml-auto`, `text-font-important-light`, `text-font-subtle-light` and their dark variants. `ml-auto` is physical and is the project's one RTL debt of its own, ledgered in section 9 | Medium. A release that renames a component argument or drops a class silently changes the layout with no error | Each release: re-render the page and compare. A class the compiled stylesheet does not carry does nothing at all and reports nothing — `divide-y` is one such, which is why the pending list uses `border-b` instead |
| `backend/templates/admin/attachments/attachment/purge_confirmation.html` | django-unfold 0.105.0 | Extends `unfold/layouts/base.html`; owns `content`. Uses the `card`, `text` and `button` components | Low. Only the component arguments can move | Each release |
| `backend/templates/403.html` | django-unfold 0.105.0 | Extends `unfold/layouts/unauthenticated.html`; owns `title` and `content`. Chosen because Django's `permission_denied` view renders this template with only the request and the context processors — never `AdminSite.each_context` — so a layout that needs the sidebar or the application list would render wrong | Low | A release that makes `unauthenticated.html` depend on `each_context` |

Not an override, but the same kind of debt: `LOGIN_REDIRECT_URL` is set to the admin
index because unfold 0.105.0's `admin/login.html` drops the hidden `next` field that
Django's own template carries. Without it a sign-in with no `?next=` lands on
`/accounts/profile/`, which this deployment answers with the API's `not_found`
envelope. `UNFOLD["LOGIN"]["redirect_after"]` does not fix it: the key is declared in
`unfold/settings.py` and read nowhere else in the release. Revisit when the login
template gains the field.

## 5. Assumption ledger

| Assumption | Date | Revisit trigger |
|---|---|---|
| One operator, and the panel never needs a second role | 2026-09-04 | A second person needs to sign in |
| The whole population fits one uncapped pending list and one changelist page at 25 rows | 2026-09-04 | More than 50 accounts, or a pending list that does not fit a screen |
| Every icon name in the sidebar exists in the Material Symbols font the package ships | 2026-09-04 | Verified visually on 2026-09-04 — the font decompresses to 908 KB, which is the full set, and every icon rendered. Revisit if an icon renders as its own name in text |
| The panel is usable on a phone | 2026-09-04 | Rendered at 375×812 on 2026-09-04: the sidebar collapses to its toggle, the changelist scrolls sideways inside its own container, the filter control stacks, and no page scrolls the body horizontally. Revisit: a column set that makes a changelist unreadable at that width, or a release that changes the `lg` breakpoint |
| A dead attachment capability in `LogEntry.object_id` is inert | 2026-09-04 | The attachment route stops 404-ing on a deleted row |

## 6. Role model

| Role | Sees | Can do | Hidden | Disabled |
|---|---|---|---|---|
| Owner (superuser) | Everything the panel registers | Activate, deactivate, set a password, revoke devices, change the staff flag, delete attachments, read the audit log | The nine hidden models; every blob, key, signature, password hash and token | Adding or deleting an account; adding or editing a device, an attachment or an audit row |
| Staff, not superuser | An index with nothing on it, and a designed permission-denied page on any model URL | Nothing | Everything | Everything |
| Anonymous | The login page | Nothing | Everything | Everything |

Test fixtures: one superuser (`owner`) and one staff-but-not-superuser (`staff`), both
in `backend/accounts/tests/test_admin.py`.

## 7. Localization state

- **Languages:** English only.
- **Default direction:** left to right.
- **Calendar:** Gregorian; storage is UTC.
- **Digit policy:** ASCII.
- **Catalog coverage:** none. Every operator-facing string is wrapped in
  `gettext_lazy`, so a catalog can be added without touching the code, but no `.po`
  file exists and `USE_I18N` is on only because Django's default leaves it on.
- **Open strings:** all of them.

A Persian, right-to-left panel is a deferral, not a gap — see section 9.

## 8. Upgrade debts

| Item | Cost at the next release |
|---|---|
| Three template overrides | Re-render each page and diff the block it extends. The dashboard is the one with real risk: it uses five shipped components and a set of Tailwind classes that exist only because the package's own build emitted them |
| `LOGIN_REDIRECT_URL` workaround | Check whether `admin/login.html` regained the hidden `next` field, or whether `LOGIN["redirect_after"]` became live. Remove the setting if either happened |
| `permissions=` on every action | Re-confirm that `unfold/decorators.py` still gates the view body on it and that `admin_view` still checks only `is_staff` |
| The `SIDEBAR` and `COMMAND` key names | Re-confirm against `unfold/settings.py`. Unfold registers no system check for `UNFOLD` key names, so a renamed key becomes an unknown key: it changes nothing and reports nothing |
| Asset byte count | Re-measure. The value in section 1 is what the deployment budgets for a first paint on a slow link |

## 9. Deferral list

| Component | Trigger that ends the deferral |
|---|---|
| A Persian, right-to-left panel | An operator who reads Persian. It needs, in order: a project message catalog (the package ships none, and Django covers only its own strings), a `--font-sans` family with Persian glyphs served by the project, one unlayered `[dir="rtl"]` stylesheet for the physical classes the package writes **and the one this project writes** — `ml-auto` in `templates/admin/index.html`, found by the RTL audit of 2026-09-04 — Jalali dates, and Persian digits. **Do not swap that class for the logical `ms-auto`**: the shipped stylesheet carries `.ml-auto` and no `.ms-auto`, so the swap would remove the rule and report nothing, which is the `divide-y` failure again |
| A second factor on the login | A second operator. Recorded as AR-1 in [`ACCEPTED_RISKS.md`](../../ACCEPTED_RISKS.md) |
| A role model with more than one role | A second operator |
| `ManifestStaticFilesStorage` | The panel is served from a cache or a CDN edge. Today nginx serves `STATIC_ROOT` from the same box, so hashed names buy nothing and a missing manifest would be a new way for the panel to break |
| A vocabulary pass on the breadcrumbs — **the model half only** | The sidebar says "Accounts" and the breadcrumb says "Accounts › Users", because the model is `User` and only `Meta.verbose_name` changes that. Deferred: it needs a second migration in `accounts`, which `core/tests/test_migrations.py` admits only once it is written into `HISTORY` and classified for its lock. Take it the next time that model is touched for another reason. **The app half is done** — the review of 2026-09-04 found that this row's stated reason never applied to it: an `AppConfig.verbose_name` is display metadata and enters no migration state, and one app's breadcrumb was reading a run-together word on every page it served |
| A per-session surrogate for the attachment primary key | AR-2's trigger — a second operator, or a non-secret addressable column on the model |

## 10. Reversals

| Date | Decision reversed | Reason |
|---|---|---|
| 2026-09-05 | The registered set of [ADR-0011](../architecture/decisions/0011-django-unfold-admin-panel.md) was five models. It is now four: **Voice rooms is unregistered and its model is deleted** | [ADR-0021](../architecture/decisions/0021-relayed-webrtc-mesh-and-no-server-room.md) removed the room object from the server, so there is no row for the page to show. The page was read-only plus a delete, and its one live column was a Redis set cardinality that no longer exists. Nothing replaces it: the operator has no voice surface, because the server holds no voice state. The dashboard loses its room card and one of its five queries, the sidebar group "Storage and voice" becomes "Storage", and the `voicerooms` `AppConfig` drops the `verbose_name` it needed for a breadcrumb that no page renders any more |
| 2026-09-06 | The attachment page named the account that uploaded each row, filtered on it, and the account page showed that account's stored bytes | [ADR-0025](../architecture/decisions/0025-unlinked-attachments-erasure-and-day-granularity.md) stopped the server reading and writing `Attachment.uploader`, so there is no account for either to render. The attachment page keeps the size bucket and the day, and its audit label names those two rather than an account; the `uploader` column and filter, the `list_select_related` behind them and the account page's "Attachment storage" field all leave. The dashboard's storage card stops measuring a per-account quota that no longer exists and measures the filesystem instead, which is what `ATTACH_MIN_FREE_BYTES` actually refuses uploads against. What the operator loses is the ability to answer "who uploaded this" — from the panel or from anywhere else, because nothing records it. What the page is for is unaffected: the operator sees what is on the disk and deletes it |
| 2026-09-06 | The device page showed the day a device was last seen, and offered a filter on it | [ADR-0024](../architecture/decisions/0024-peer-state-published-limits-and-no-activity-dates.md) stopped the server writing `Device.last_active_date`, so the column has no value to render. `last_active_date` leaves `list_display`, `list_filter` and `fields`; the page keeps the account, the state badge, `created_date` and `revoked_date`, and the revoke action is untouched. What the operator loses is the ability to answer "when was this device last seen" — from the panel or from anywhere else, because the column is written by nothing. What answering "I lost my phone" needs is still there: which devices the account has, which are live, and the button. The `RevokedFilter` is unaffected — it reads `revoked_date`, which stays |

## Architecture decisions

The panel depends on:

- [ADR-0011](../architecture/decisions/0011-django-unfold-admin-panel.md) — what the panel is, what it may show, and what it must never show.
- [ADR-0003](../architecture/decisions/0003-one-asgi-process.md) — the Django application is mounted behind FastAPI at `ADMIN_PATH`, which is why the panel and the API share one process and one nginx upstream.
- [ADR-0010](../architecture/decisions/0010-redis-rate-limiting-that-fails-closed.md) — the fail-closed posture the login lockout follows.
- [ADR-0014](../architecture/decisions/0014-process-hardening-at-the-edge.md) — the request deadline and body caps the panel's requests also pass through.
- [ADR-0024](../architecture/decisions/0024-peer-state-published-limits-and-no-activity-dates.md) — the server records no activity date, which is why the device page shows none.
- [ADR-0025](../architecture/decisions/0025-unlinked-attachments-erasure-and-day-granularity.md) — an attachment row names no account, which is why the attachment page shows none.
