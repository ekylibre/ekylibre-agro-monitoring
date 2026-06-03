# Ekylibre Agromonitoring Plugin

Integrate [Agromonitoring](https://agromonitoring.com) satellite vegetation
indices (NDVI) and soil data into Ekylibre, per `CultivableZone`.

The plugin replaces and refactors the legacy `AgroMonitoringClient` code that
used to live in Ekylibre core ([ekylibre/ekylibre#2662](https://github.com/ekylibre/ekylibre/issues/2662)).
It is designed to stay strictly within the Agromonitoring **free plan** limits
(no hidden cost surprises).

- API documentation: <https://agromonitoring.com/api>
- Pricing & quotas: <https://agromonitoring.com/price>
- API key dashboard: <https://home.agromonitoring.com/users/api-keys>

---

## Table of contents

- [Overview](#overview)
- [Installation](#installation)
- [Configuration](#configuration)
- [Behavior](#behavior)
- [Architecture](#architecture)
- [Indicator mapping](#indicator-mapping)
- [Free plan limits](#free-plan-limits)
- [Migration from legacy core code](#migration-from-legacy-core-code)
- [Development](#development)
- [Troubleshooting](#troubleshooting)
- [Roadmap](#roadmap)
- [Missing assets](#missing-assets)
- [License](#license)

---

## Overview

For every `CultivableZone` whose surface is between 1 ha and 3000 ha, the plugin:

1. Registers a polygon on Agromonitoring (one polygon per zone).
2. Imports the scalar NDVI history (min / max / mean / median per acquisition
   date, Landsat-8 + Sentinel-2 sources combined) into `Analysis` records.
3. Imports a current soil snapshot (moisture, surface temperature, 10cm-depth
   temperature) into `Analysis` records.
4. Refreshes both daily.
5. Exposes a manual *"Synchroniser Agromonitoring"* button on every zone's show
   page.

The core `NdviCellsController` graph that already ships with Ekylibre keeps
working unchanged — it reads the same `Analysis` records the plugin produces.

---

## Installation

1. Add the plugin to your Ekylibre instance's `Plugfile` (or wherever your
   `Plugins.yml` lives — same convention as Sencrop / Weenat):

   ```ruby
   plugin 'agro_monitoring', git: 'https://github.com/ekylibre/ekylibre-agro-monitoring.git'
   ```

2. Install dependencies and restart the host application:

   ```sh
   bundle install
   ```

3. The engine auto-registers two scheduled hooks (no manual cron needed):
   - `on_check_success` → `AgroMonitoringFirstRunJob` (after a valid API key is
     saved for the first time)
   - `every: :day` → `AgroMonitoringDailyFetchJob` (incremental import)

Minimum Ekylibre core version: `>= 4.0.0`, `< 5.0.0` (see `Plugfile`).

> **Before going live**: a companion PR on Ekylibre core must remove the legacy
> `AgroMonitoringClient`, `AgromonitoringJob`, `CultivableZoneAnalysis` and the
> `initiate_satellite_data` / `after_destroy` hooks on `CultivableZone`. Without
> this PR, polygons will be created twice (once by core, once by the plugin)
> and the monthly quota will be exhausted in half the time.

---

## Configuration

Open **Backend → Outils → Intégrations** and configure the **Agromonitoring**
integration with a single parameter:

| Parameter | Required | Notes |
|-----------|----------|-------|
| `api_key` | yes      | Free API key from <https://home.agromonitoring.com/users/api-keys> |

The key is stored as standard `Integration.parameters['api_key']` — the exact
same UI pattern as the **Weenat** and **Sencrop** plugins. No custom view, no
extra screen.

When you click *"Vérifier la connexion"*, the plugin issues a
`GET /agro/1.0/polygons` request: a 200 (even with an empty list) validates the
key and triggers the first-run import; a 401/403 surfaces as the standard
Ekylibre integration error.

---

## Behavior

### First run

Triggered automatically once the integration check succeeds.

1. **Polygon sync**: every eligible `CultivableZone` (1–3000 ha) is registered
   as an Agromonitoring polygon, in ascending `id` order, up to the monthly
   quota of 9 creations.
2. **NDVI history**: ~2 years of scalar NDVI per polygon (24 windows of 30 days,
   reverse chronological order), stored as `Analysis` records.
3. **Soil snapshot**: one current-soil call per polygon.

Expected wall-clock at full quota (10 zones × ~25 calls × 1.1 s throttle):
**~4–5 minutes**.

### Daily incremental fetch

Triggered by the engine's `every: :day` hook.

- Resumes from `Preference('last_agro_monitoring_import')` with a 1-day overlap
  to catch retro-published satellite scenes (typical Sentinel-2 delay).
- Idempotent: an `Analysis` is keyed by `(cultivable_zone_id, reference_number)`
  so re-fetching the same `dt` is a no-op.

### Manual sync button

On every `CultivableZone` show page (`Backend → Parcellaire → Zones cultivables
→ Détail d'une parcelle`), a *"Synchroniser Agromonitoring"* button enqueues
`AgroMonitoringPolygonSyncJob`. Useful after editing a parcel shape or
adding new parcels mid-month.

The button is disabled until the integration is configured.

---

## Architecture

```
app/
├── integrations/agro_monitoring/
│   └── agro_monitoring_integration.rb    AgroMonitoring::AgroMonitoringIntegration
│                                          ├── authenticate_with :check { parameter :api_key }
│                                          └── calls :list_polygons, :create_polygon, :get_polygon,
│                                                    :update_polygon, :delete_polygon, :ndvi_history,
│                                                    :current_soil, :image_search, :image_stats
├── services/agro_monitoring/
│   ├── api_throttle.rb                   ApiThrottle.pause! → sleep 1.1s
│   ├── polygon_sync_service.rb           Per-zone polygon CRUD + monthly quota
│   ├── ndvi_history_import_service.rb    NDVI scalar → Analysis (4 indicators)
│   └── soil_snapshot_import_service.rb   Soil → Analysis (3 indicators, K→°C)
├── jobs/
│   ├── agro_monitoring_polygon_sync_job.rb     Iterates CZ by id, stops on quota
│   ├── agro_monitoring_first_run_job.rb        Polygon sync + 2y NDVI + soil
│   └── agro_monitoring_daily_fetch_job.rb      Incremental + overlap day
├── controllers/agro_monitoring/
│   └── agro_monitoring_synchronizations_controller.rb
└── views/backend/agro_monitoring/
    └── _sync_toolbar.html.haml           Button injected on CultivableZone#show
```

### Storage model

| Data | Where | Identity |
|------|-------|----------|
| Agromonitoring polygon id + geometry fingerprint | `CultivableZone#provider = { vendor: 'agromonitoring', name: 'agromonitoring_polygons', data: { id:, geometry_hash: } }` | `is_provided_by?(vendor:, name:)` |
| NDVI scalar series | `Analysis(cultivable_zone_id:, reference_number: "#{dt}_ndvi", nature: 'sensor_analysis')` + 4 `read!(:*_ndvi_index, value)` | `(cultivable_zone_id, reference_number)` |
| Soil snapshot | `Analysis(cultivable_zone_id:, reference_number: "#{dt}_soil")` + 3 `read!(:soil_*, value)` | `(cultivable_zone_id, reference_number)` |
| Monthly quota counter | `Preference('agro_monitoring_polygons_created_YYYY_MM', integer)` | one row per calendar month |
| Job reentrance lock | `Preference('agro_monitoring_import_running', boolean)` | single row |
| Last import cursor | `Preference('last_agro_monitoring_import', integer)` (UNIX seconds) | single row |
| User API key | `Integration(nature: 'agro_monitoring').parameters['api_key']` | one per tenant |

> The model intentionally does **not** create a `Sensor` per polygon — unlike
> Sencrop / Weenat. The legacy core convention links `Analysis` directly to
> `CultivableZone` and the existing `NdviCellsController` reads it that way.

---

## Indicator mapping

### NDVI history (`GET /agro/1.0/ndvi/history`)

The API returns a stats payload per acquisition date. Each scalar maps to one
existing Ekylibre Nomen indicator (no Nomen PR required):

| API field   | Ekylibre indicator    | Reference number suffix |
|-------------|-----------------------|-------------------------|
| `data.min`  | `minimal_ndvi_index`  | `"#{dt}_ndvi"`          |
| `data.max`  | `maximal_ndvi_index`  | `"#{dt}_ndvi"`          |
| `data.mean` | `average_ndvi_index`  | `"#{dt}_ndvi"`          |
| `data.median` | `median_ndvi_index` | `"#{dt}_ndvi"`          |

### Soil snapshot (`GET /agro/1.0/soil`)

| API field | Ekylibre indicator                       | Conversion           |
|-----------|------------------------------------------|----------------------|
| `moisture`| `soil_moisture`                          | ratio → percent      |
| `t0`      | `soil_surface_temperature`               | Kelvin → Celsius     |
| `t10`     | `soil_10cm_depth_surface_temperature`    | Kelvin → Celsius     |

### Other indices (EVI, NDWI, NRI, DSWI, EVI2)

Not in MVP. The Ekylibre Nomen does not contain corresponding indicator keys
yet. Adding them is on the [roadmap](#roadmap) and requires a small core PR.

---

## Free plan limits

The plugin is engineered to stay strictly within the Agromonitoring
[free plan](https://agromonitoring.com/price) hard limits.

| Resource                                          | Free-plan cap   | Plugin strategy |
|---------------------------------------------------|-----------------|-----------------|
| Satellite API calls (NDVI, image, stats, soil)    | < 60 / minute   | `ApiThrottle.pause!` = `sleep 1.1` before every call |
| Polygon creations / calendar month                | < 10 / month    | Hard cap at **9** via monthly counter `Preference('agro_monitoring_polygons_created_YYYY_MM')`; surplus zones deferred to next month, user notified |
| Current + forecast weather calls                  | < 500 / day     | **Not used** — weather is left to Sencrop / Weenat |

### Consequences for users

- **Multi-month onboarding for large farms.** If an exploitation has more than
  ~10 cultivable zones, the plugin will sync the first 9 in month 1, the next 9
  on the 1st of month 2, and so on. The iteration order is deterministic
  (ascending `CultivableZone#id`) so the result is predictable. No manual
  intervention is required; the user receives a notification when the monthly
  quota is reached.

- **Geometry changes are quota-costly.** The Agromonitoring API does **not**
  support updating a polygon's shape — only its name. When a parcel shape
  changes, the plugin must delete the old polygon and create a new one, which
  counts as a fresh creation against the monthly quota. If the quota is
  exhausted, the geometry update is deferred until next month and the old
  polygon (and its scalar NDVI history) is kept intact.

- **Weather is out of scope.** If you need weather forecasts or current
  conditions, use the Sencrop or Weenat plugins. Adding weather here would
  consume the 500-calls/day quota and complicate the implementation; it is on
  the backlog for a later release.

- **No 429 retry in MVP.** The 1.1 s pause is the primary defense and should
  keep the cadence safely below 55 calls/min. If a 429 response slips through
  (e.g. another application sharing the same API key), it is logged but not
  retried. Exponential back-off is on the [roadmap](#roadmap).

---

## Migration from legacy core code

Previous versions of Ekylibre core stored the Agromonitoring API key as:

```ruby
Identifier.find_by(nature: 'agromonitoring_api_key').value
```

This plugin reads from the standard integration parameter location:

```ruby
Integration.find_by(nature: 'agro_monitoring').parameters['api_key']
```

If you upgrade an existing tenant, copy the value across **before** activating
the plugin:

```ruby
identifier = Identifier.find_by(nature: 'agromonitoring_api_key')
if identifier&.value.present?
  Integration.find_or_initialize_by(nature: 'agro_monitoring').tap do |i|
    i.parameters = (i.parameters || {}).merge('api_key' => identifier.value.strip)
    i.save!
  end
  identifier.destroy
end
```

A scripted migration is on the [roadmap](#roadmap).

Existing `Analysis` records produced by the legacy `CultivableZoneAnalysis`
service are **forward-compatible**: the plugin uses the same
`reference_number = "#{dt}_ndvi"` convention and the same indicator keys, so
the historical data continues to display in the `NdviCellsController` chart.

---

## Development

### Setup

The gemspec pins Bundler 2.2. If your system ships a newer Bundler:

```sh
gem install bundler:2.2.34
bundle _2.2.34_ install
```

### Running tests

```sh
bundle _2.2.34_ exec rake test
```

The test suite is a thin HTTP-contract test (WebMock + VCR) against the
documented Agromonitoring endpoints. It does **not** load the Ekylibre Rails
environment; service-level tests for `PolygonSyncService`,
`NdviHistoryImportService` and `SoilSnapshotImportService` need the host
application's models (`CultivableZone`, `Analysis`, `Preference`, `Integration`,
`Charta`) and live in the core integration suite.

To record fresh cassettes against the real API, set
`AGROMONITORING_API_KEY=<your-key>` before running the tests. VCR sanitises the
key in the recorded cassettes (`<API_KEY>` placeholder).

### Linting

```sh
bundle _2.2.34_ exec rubocop --parallel
```

The CI (`.gitlab-ci.yml`) runs rubocop on every push using
`registry.gitlab.com/ekylibre/tools/rubocop/rubocop:0.2.0`.

---

## Troubleshooting

### "Quota mensuel Agromonitoring atteint" notification

The plugin reached the 9-polygon-per-month soft cap. New zones added after
this point are deferred to the next calendar month. To audit the counter:

```ruby
Preference.find_by(name: "agro_monitoring_polygons_created_#{Time.zone.now.strftime('%Y_%m')}")&.value
```

To bypass the quota for a single creation in testing, decrement the counter
manually (use with care — exceeding 10 creations will be rejected by the API):

```ruby
Preference.set!("agro_monitoring_polygons_created_#{Time.zone.now.strftime('%Y_%m')}", 0, 'integer')
```

### "Synchroniser Agromonitoring" button is disabled

The integration is not configured. Open **Backend → Outils → Intégrations** and
fill in the API key.

### NDVI chart is empty on a parcel page

Common causes:

1. The parcel's surface is outside the 1–3000 ha range (no polygon created).
2. The polygon was created but the NDVI history fetch has not yet run. Click the
   *"Synchroniser"* button or wait for the daily job.
3. Heavy cloud cover at the parcel location → no usable scenes. Check the
   Agromonitoring dashboard at <https://home.agromonitoring.com/>.

### A job is stuck (`import_running` lock won't clear)

If `Preference('agro_monitoring_import_running')` stays `true` after a job
crash, clear it manually:

```ruby
Preference.set!('agro_monitoring_import_running', false, 'boolean')
```

The lock is intentionally simple to avoid distributed-lock complexity. If you
need stronger guarantees, prefer running a single Sidekiq worker for the
`:default` queue.

### Plugin polygon count diverges from Agromonitoring dashboard

The plugin's monthly counter increments on every successful `create_polygon`
call but does **not** decrement on `delete_polygon` (deletes don't refund the
monthly quota — they are free, but the slot is gone for that month per the API
contract). If the counters appear out of sync, the source of truth is
`Integration.find_by(nature: 'agro_monitoring')` + `GET /polygons` on the API.

---

## Roadmap

Backlog items, not blocking the MVP:

1. **429 back-off** — exponential retry (10/30/60 s) on rate-limit responses.
   Requires exposing `response.code` through the `Call#execute` contract.
2. **Additional vegetation indices** — EVI, EVI2, NDWI, NRI, DSWI via
   `image_search` + `image_stats`. Needs a core Nomen PR.
3. **Leaflet tile overlay** — render the latest NDVI/EVI scene as a tiled layer
   on the parcel show page (`/tile/1.0/{z}/{x}/{y}/ndvi/{image_id}`).
4. **Orphan polygon reconciliation** — periodic sweep listing polygons on the
   API and deleting those no longer referenced by any `CultivableZone`.
5. **Per-parcel allowlist** — `Preference('agro_monitoring_tracked_cz_ids')` to
   prioritise specific zones within the monthly cap (useful for large farms
   prioritising fields under stress).
6. **Identifier → Integration migration script** — idempotent rake task or
   one-shot engine initializer.
7. **Full locale coverage** — translate the `agro_monitoring_synchronize`
   button label and the notification keys in the 7 non-FR/EN languages.
8. **Sliding-window throttle** — replace the blind `sleep 1.1` with a sliding
   60-second window counter to maximise throughput within the cap.
9. **Service-level integration tests in CI** — Docker image bundling Ekylibre
   core + the plugin, mocking the Agromonitoring API.
10. **NDVI timeline view** — dedicated `backend/agro_monitoring/parcels` index
    with a filterable chart per zone / campaign.

---

## Missing assets

The plugin ships without the Agromonitoring logo. The integration screen will
fall back to a generic icon until you add:

- `app/assets/images/integrations/agro_monitoring.png` (recommended 128×128 px,
  transparent background)
- `app/assets/images/integrations/agro_monitoring.svg`

See `app/assets/images/integrations/agro_monitoring.TODO.md`.

---

## Reference documents

- `claudedocs/phase_0_findings.md` — audit of the legacy core
  `AgroMonitoringClient` code and the discoveries that shaped the architecture.
- `claudedocs/workflow_agro_monitoring_plugin.md` — the full implementation
  workflow used to build this plugin, phase by phase, with quality gates and
  risk register.

---

## License

MIT. See `LICENSE`.
