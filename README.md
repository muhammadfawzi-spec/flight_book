# LogMate — personal flight logbook

An iOS app for pilots that records flights, schedules, training progress,
medical/WINGS currency, aircraft equipment, airport data, and stats, plus
AI-assisted photo import of handwritten logbooks and schedule pages.

The repository has two parts:

- **`LogMate/`** — the Swift app (iOS 17+), split into 45 focused files.
- **`worker.mjs`** — a self-hosted Cloudflare Worker that proxies photo
  imports to an AI service. The provider key never leaves the worker;
  the app authenticates per-device with an access code stored in Keychain.

## Repository layout

```
flight_book/
├── LogMate.xcodeproj/        One app target, synchronized app folder
├── LogMate/
│   ├── MyApp.swift           App entry point
│   ├── App/                  Branding, theme, dates, formatting, root view
│   ├── DesignSystem/         Shared visual language and controls
│   ├── Models/               Pure data types and domain rules
│   ├── Stats/                Totals and stats computation
│   ├── Services/             Network, registry, catalog, photo persistence
│   ├── Import/               CSV / AI / on-device scan import pipeline
│   ├── Export/               PDF print and CSV export
│   ├── Features/             One folder per tab/screen cluster
│   └── Store/                FlightStore — the single shared state object
├── worker.mjs                AI photo-import service (Cloudflare Worker)
├── .gitignore
└── tools/                    Build-verification helpers (Python)
```

**How to build:** open `LogMate.xcodeproj` in Xcode (16 or newer), pick an
iPhone simulator (iOS 17+), and run. The project uses a *synchronized app
folder*: any file placed under `LogMate/` is automatically a member of the
target — no pbxproj editing needed when adding files.

## File map

Every Swift file begins with a one-paragraph header describing its
contents, so each file is self-describing. Summaries:

### `LogMate/MyApp.swift`
- **`MyApp.swift`** — App entry point: installs shared state and presents the root view.

### `LogMate/App/` — app shell
- **`App/Brand.swift`** — App name, prototype-only flight-reset toggle, airplane logo shape.
- **`App/Formatting.swift`** — Shared hour/number display formatting.
- **`App/FlightDates.swift`** — Date parsing/formatting (US + ISO layouts, two-digit years).
- **`App/AppTheme.swift`** — Dark/light theme, palette, animated crossfade.
- **`App/RootView.swift`** — Tab definitions, tab icons, top-level `ContentView`.

### `LogMate/DesignSystem/` — shared UI
- **`Style.swift`** — Color helper, cards, accent buttons, section headings, sheet chrome, keyboard dismissal.
- **`Controls.swift`** — `LogField` labeled input, segment button style.

### `LogMate/Models/` — data + rules (no UIKit)
- **`Flight.swift`** — `Flight` entry model + `FlightFacts` + display helpers.
- **`SavedAircraft.swift`** — Saved aircraft model.
- **`ScheduledFlight.swift`** — Future flights/bookings.
- **`Instructors.swift`** — Instructor profile, signature, milestone confirmations.
- **`Medical.swift`** — FAA medical classes, privileges, saved record, validity.
- **`WINGS.swift`** — WINGS currency records + store.
- **`Training.swift`** — Checkride/training paths, goals, credits, rule engine.
- **`TrainingCatalog.swift`** — Part 61 / Part 141 requirement catalog.

### `LogMate/Stats/` — aggregation + computation
- **`Totals.swift`** — Total-time aggregation, metric definitions, filters.
- **`StatsModels.swift`** — Stats value types + route/airport geometry.
- **`StatsEngine.swift`** — Background workers (map geometry, memory photos), stats model.

### `LogMate/Services/` — network, lookups, persistence
- **`WebData.swift`** — Shared HTTP/JSON helper + HTML/string utilities.
- **`AircraftRegistry.swift`** — N-number info, make/model lookups, evidence, reference table.
- **`AircraftFeatures.swift`** — Feature definitions, equipment state, sync, name normalizers.
- **`AircraftPhotos.swift`** — Public photo fetching/caching/persistence.
- **`Airports.swift`** — Route parsing, airport catalog + data service, map geometry, fleet grouping.
- **`ApproachCatalog.swift`** — Embedded approach-procedure rows.
- **`Procedures.swift`** — Logged-procedure model + aeronav XML parser.
- **`PhotoStore.swift`** — On-disk location + persist/load helpers for photos.

### `LogMate/Import/` — getting data in
- **`CSV.swift`** — CSV field table, validation, review engine.
- **`CSVViews.swift`** — CSV import/review UI.
- **`AIImport.swift`** — AI endpoint config, models, importer + delegate, settings screen.
- **`Scan.swift`** — On-device scan pipeline, parsing, guided camera, review UI.

### `LogMate/Export/`
- **`LogbookExport.swift`** — `ShareFile`, PDF print layout, CSV text exporter, entry point.

### `LogMate/Features/` — one folder per tab
- **`Logbook/Logbook.swift`** — Flight list, rows, session photo, popup.
- **`Logbook/FlightEditor.swift`** — Simulator editor, full flight editor, detail, summary.
- **`Aircraft/Aircraft.swift`** — Aircraft list/add/profile + photo picker/gallery.
- **`Medical/MedicalViews.swift`** — Currency section, privilege rows, editor, WINGS editor.
- **`Medical/InstructorSigning.swift`** — Signature canvas, signing flow, signature card.
- **`Totals/TotalsViews.swift`** — Totals screen, filter, IACRA, experience, checkride.
- **`Training/TrainingViews.swift`** — Path picker, goal progress, course/ground, duty, milestones, flight review.
- **`Airports/AirportsViews.swift`** — Airport detail, flip card, fleet range sheet.
- **`Stats/StatsViews.swift`** — Stats screen, dashboard, memory photo.
- **`Schedule/Schedule.swift`** — Calendar, schedule editor, review, reminders, notification settings.
- **`More/Story.swift`** — Flight story builder, art, view, share image/saver.
- **`More/More.swift`** — More screen + share sheet.

### `LogMate/Store/`
- **`FlightStore.swift`** — The app's single shared state object (load/save/validate/delete flights, aircraft, schedules, instructors, medical, stats, backup).

## AI photo-import service (`worker.mjs`)

A small Cloudflare Worker that:

1. Validates an access token (`lm_…`) against a SHA-256 hash list in env, and rate-limits per token.
2. Accepts a base64 JPEG/PNG photo (≤ 12 MB) for a logbook or schedule page.
3. Forwards it to the AI service with a strict JSON schema, parses + validates the result, and returns normalized entries.

Key properties: **the provider API key is server-side only**; the app stores only a per-device access code (in Keychain). See the inline comments in `worker.mjs` for the exact env contract (`OPENAI_API_KEY`, `OPENAI_MODEL`, `IMPORT_TOKEN_HASHES`, `IMPORT_RATE_LIMIT`).

> This is a prototype. For production you would move the token allow-list to a database (e.g. D1/KV with hashed codes + expiry + per-code rate limits), add request logging/metrics, and put the worker behind your own domain.

## Verification discipline (how the split stayed faithful)

The original single 24,131-line file was split into these 45 files with a
strict "move, don't change" rule:

- **Move, don't change** — code was relocated verbatim. The only source
  edits were (a) splitting one expression that timed out the Swift
  type-checker inside the monolith, and (b) making five `private` helpers
  `internal` so they could be referenced across files.
- **Line-multiset check** — `tools/diffcheck.py` compares the union of all
  current lines against the original baseline and reports any difference. The
  only delta is file headers, per-file `import` lines, the one restructured
  expression, the de-privated helpers, and four imports the monolith carried
  but nothing uses.
- **Build after every move** — each of the six increments ends with a clean
  `xcodebuild` compile of the whole app, so no reference was ever left dangling.

Re-run the check any time:
```sh
python3 tools/diffcheck.py LogMate        # line-multiset vs baseline
python3 tools/declmap.py LogMate          # dump top-level decls + line numbers
```

## Git branches

The split was done in six small, independently-verifying increments on the
`ayman's-structure` branch (nothing merged to `main` yet):

1. App + design system
2. Models and stats
3. Services
4. Import pipeline and export
5. Feature screens
6. `FlightStore` + deleting the monolith

Each commit is safe to revert independently.

## Known production gaps (out of scope for this change)

- No unit tests, no CI pipeline.
- Persistence is still `UserDefaults`-backed (fine for a prototype; consider
  SwiftData/CoreData for production durability).
- The AI-import worker is a prototype (see note above).
- Some third-party data lookups (FAA registry, airport-data.com, Wikimedia)
  have no official SLA; add caching/fallbacks before relying on them.
