# Plan d'implémentation — Plugin `agro_monitoring`

> **Statut MVP : ✅ terminé** (2026-06-03)
> Toutes les phases 0 à 6 sont livrées, testées et lintées. Reste : la PR core préalable + le logo (cf. §10).
>
> 📋 Rapport Phase 0 : `phase_0_findings.md`.
> 📦 État livré : 18 fichiers Ruby, 9 locales, 10 tests verts, `rubocop --parallel` clean.

---

## 1. Contexte & objectif

### 1.1 Origine
- Ticket : [ekylibre/ekylibre#2662](https://github.com/ekylibre/ekylibre/issues/2662) — *"Add Agromonitoring data in Ekylibre land_parcel"*.
- Ekylibre core héberge déjà `app/integrations/agro_monitoring_client.rb` (Faraday POPO) + `AgromonitoringJob` + `CultivableZoneAnalysis` + `NdviCellsController`. Le ticket demande une **extraction propre vers un plugin** + une **migration du stockage de la clé API** (de `Identifier(nature: :agromonitoring_api_key)` vers `Integration.parameters['api_key']`).
- Fournisseur de données : **Agromonitoring.com** (OpenWeather group) — imagerie satellite Landsat-8 / Sentinel-2 + NDVI scalaire + données sol.

### 1.2 Objectif fonctionnel livré
Permettre à Ekylibre, via un plugin Rails Engine, de :
1. Déclarer un polygone Agromonitoring **par `CultivableZone`** (1–3000 ha, ordre déterministe).
2. Importer ~2 ans d'historique NDVI scalaire en first-run (min/max/mean/median par scène) + 1 snapshot sol.
3. Mettre à jour quotidiennement les nouvelles données NDVI + sol avec overlap d'1 jour pour les scènes rétroactives.
4. Exposer un bouton **"Synchroniser Agromonitoring"** sur la fiche `CultivableZone` (déclenche le sync des polygones manquants).
5. Respecter strictement le **plan gratuit Agromonitoring** : throttle 1.1 s entre appels satellite, plafond mensuel de 9 créations de polygones, météo hors scope.

> ❌ **Pas de surcouche carto Leaflet** dans le MVP — la cellule graphique NDVI (`NdviCellsController`) déjà rendue par core sur la fiche parcelle reste en place et lit les `Analysis` produites par le plugin.

### 1.3 Modèles d'inspiration retenus
| Plugin | Pattern emprunté |
|---|---|
| **Sencrop** | Squelette engine, twin-job (first-run + recurring), DSL `ActionIntegration::Base`, conventions test VCR/WebMock, structure gemspec |
| **Natuition** | Controller `Backend::BaseController` + route + bouton "Synchroniser" + `Ekylibre::View::Addon.add` |
| **Weenat** | UI clé API via `authenticate_with :check do; parameter :api_key; end` (paramètre unique rendu automatiquement) |
| **Code legacy core** (`agro_monitoring_client.rb`) | Convention `provider: { vendor: 'agromonitoring', name: 'agromonitoring_polygons', data: { id: ... } }` + `reference_number: "#{dt}_ndvi"` (rétrocompatibilité avec données déjà en base) |

---

## 2. API Agromonitoring

### 2.1 Endpoints implémentés

| Domaine | Méthode | URL | Méthode plugin |
|---|---|---|---|
| Polygones | `POST` | `/agro/1.0/polygons?appid=...` | `create_polygon(name:, geo_json:)` |
| Polygones | `GET` | `/agro/1.0/polygons?appid=...` | `list_polygons` + `check` |
| Polygones | `GET` | `/agro/1.0/polygons/{id}?appid=...` | `get_polygon(id)` |
| Polygones | `PUT` | `/agro/1.0/polygons/{id}?appid=...` | `update_polygon(id, name:)` (renommage seul) |
| Polygones | `DELETE` | `/agro/1.0/polygons/{id}?appid=...` | `delete_polygon(id)` |
| NDVI historique | `GET` | `/agro/1.0/ndvi/history` | `ndvi_history(id, start_unix, end_unix, clouds_max: 10)` |
| Sol | `GET` | `/agro/1.0/soil?polyid=...` | `current_soil(id)` |
| Imagerie — search | `GET` | `/agro/1.0/image/search` | `image_search(id, start_unix, end_unix)` |
| Imagerie — stats | `GET` | `/stats/1.0/{product}/{imageId}` | `image_stats(product, image_id)` |

### 2.2 Authentification
- **Mode** : clé API simple, query string `appid=...`. Pas d'OAuth.
- **Stockage** : `integration.parameters['api_key']`, déclaré via `authenticate_with :check do; parameter :api_key; end` (pattern Weenat). Le formulaire de saisie est généré automatiquement dans **Backend → Outils → Intégrations**.

### 2.3 Contraintes & quotas plan gratuit

| Ressource | Limite plan gratuit | Stratégie plugin |
|---|---|---|
| Surface polygone | 1 ha ≤ aire ≤ 3000 ha | `PolygonSyncService` filtre en amont, statut `:skipped_area_*` sinon |
| Appels satellite (NDVI/image/soil) | **< 60 / minute** | `ApiThrottle.pause!` (sleep 1.1 s) avant chaque appel |
| Polygones créés / mois | **< 10 / mois** | Plafond strict à **9** via `Preference('agro_monitoring_polygons_created_YYYY_MM')`, reset implicite au changement de mois |
| Appels météo | **< 500 / jour** | **Hors scope MVP** — laissé à Sencrop / Weenat |

**Conséquences MVP** :
1. Pas d'import météo Agromonitoring.
2. Onboarding multi-mois pour > 10 parcelles (ordre déterministe par `CultivableZone#id`).
3. Changement de géométrie = `delete + create` = consomme 1 quota mensuel ; bloqué si plafond atteint → ancien polygone conservé.

### 2.4 Sources documentaires
- [Agromonitoring Polygons API](https://agromonitoring.com/api/polygons)
- [Agromonitoring Historical NDVI API](https://agromonitoring.com/api/history-ndvi)
- [Agromonitoring Satellite Images API](https://agromonitoring.com/api/images)
- [Agromonitoring — Getting Started](https://agromonitoring.com/api/get)

---

## 3. Architecture livrée

### 3.1 Arborescence réelle

```
ekylibre-agro-monitoring/
├── Gemfile
├── Plugfile                              # name 'agro_monitoring', version 1.0.0
├── Rakefile
├── README.md
├── LICENSE
├── .gitignore
├── .gitlab-ci.yml                        # rubocop --parallel
├── .rubocop.yml
├── agro_monitoring.gemspec
├── claudedocs/
│   ├── phase_0_findings.md               # audit du code legacy core
│   └── workflow_agro_monitoring_plugin.md (ce fichier)
├── lib/
│   ├── agro_monitoring.rb
│   └── agro_monitoring/
│       ├── version.rb                    # VERSION = '0.1.0'
│       └── engine.rb                     # i18n, hooks on_check_success + every: :day, View::Addon
├── app/
│   ├── integrations/agro_monitoring/
│   │   └── agro_monitoring_integration.rb    # ActionIntegration::Base — 9 calls + check
│   ├── jobs/
│   │   ├── agro_monitoring_first_run_job.rb      # bootstrap ~2 ans NDVI + sol
│   │   ├── agro_monitoring_daily_fetch_job.rb    # incrémental + overlap 1 jour
│   │   └── agro_monitoring_polygon_sync_job.rb   # itère CZ par id, stop quota
│   ├── services/agro_monitoring/
│   │   ├── api_throttle.rb               # ApiThrottle.pause! (sleep 1.1s)
│   │   ├── polygon_sync_service.rb       # CRUD polygone, quota, geometry_hash SHA1
│   │   ├── ndvi_history_import_service.rb
│   │   └── soil_snapshot_import_service.rb
│   ├── controllers/agro_monitoring/
│   │   └── agro_monitoring_synchronizations_controller.rb
│   ├── views/backend/agro_monitoring/
│   │   └── _sync_toolbar.html.haml       # bouton sur fiche CZ
│   └── assets/images/integrations/
│       ├── .keep
│       └── agro_monitoring.TODO.md       # logo à fournir avant publication
├── config/
│   ├── routes.rb                         # GET /agro_monitoring/agro_monitoring_synchronization/perform
│   └── locales/
│       ├── eng.yml  fra.yml  spa.yml  por.yml  ita.yml
│       └── deu.yml  cmn.yml  jpn.yml  arb.yml
└── test/
    ├── test_helper.rb                    # VCR + WebMock + filter <API_KEY>
    └── agro_monitoring/
        └── agro_monitoring_integration_test.rb  # 10 tests de contrat HTTP
```

### 3.2 Points d'extension Ekylibre core utilisés

| Ressource core | Rôle dans le plugin |
|---|---|
| `ActionIntegration::Base` | Parent de `AgroMonitoringIntegration` |
| `Protocols::JSON` (`get_json`/`post_json`/`put_json`/`delete_json`) | HTTP helpers injectés via la DSL `calls` |
| `Integration.parameters['api_key']` | Stockage clé API (pattern Weenat) |
| `Preference.set! / find_by` | Cursor `last_agro_monitoring_import`, lock `agro_monitoring_import_running`, compteur `agro_monitoring_polygons_created_YYYY_MM` |
| `CultivableZone#shape` (multi_polygon SRID 4326) | Source géométrique convertie via `RGeo::GeoJSON.encode(shape.to_rgeo.first)` |
| `CultivableZone#provider` + concern `Providable` | Stockage `{ vendor:, name:, data: { id:, geometry_hash: } }` |
| `Analysis` + `analyse.read!` | Stockage NDVI scalaire + sol (lié direct par `cultivable_zone_id`) |
| Indicateurs Nomen | `*_ndvi_index` × 4 + `soil_*` × 3 (tous présents en core, aucune PR Nomen requise) |
| `Ekylibre::View::Addon.add` | Bouton sync injecté sur `backend/cultivable_zones#show` |
| `Backend::BaseController` + `notify_success` + `redirect_back` | Controller manuel |
| `user.notifications.create!` | Notifications fin de job (succès, quota, erreur) |
| `NdviCellsController` (legacy) | Conservé — lit les `Analysis` produites par le plugin, restitue le graphique NDVI sur la fiche CZ |

### 3.3 Modèle de données

| Donnée | Mapping Ekylibre | Clé d'unicité |
|---|---|---|
| Polygone Agromonitoring | `CultivableZone#provider = { vendor: 'agromonitoring', name: 'agromonitoring_polygons', data: { id: <polyid>, geometry_hash: <sha1(wkt)> } }` | `is_provided_by?(vendor:, name:)` |
| Relevé NDVI scalaire | `Analysis(cultivable_zone_id:, nature: 'sensor_analysis', reference_number: "#{dt}_ndvi", sampled_at:, analysed_at:)` + 4 `read!(:*_ndvi_index, value.to_f)` | `(cultivable_zone_id, reference_number)` |
| Relevé sol | `Analysis(cultivable_zone_id:, reference_number: "#{dt}_soil")` + 3 `read!(:soil_*, value)` (Kelvin→°C pour températures) | `(cultivable_zone_id, reference_number)` |
| Compteur mensuel quota | `Preference('agro_monitoring_polygons_created_YYYY_MM', integer)` | clé YYYY_MM |
| Lock import | `Preference('agro_monitoring_import_running', boolean)` | unique |
| Cursor sync | `Preference('last_agro_monitoring_import', integer)` (UNIX seconds) | unique |
| Clé API utilisateur | `Integration(nature: 'agro_monitoring').parameters['api_key']` | unique par tenant |

> ❌ **Pas de `Sensor`** — pattern différent de Sencrop/Weenat. La relation `Analysis ↔ CultivableZone` directe est conservée du legacy pour rester compatible avec `NdviCellsController` et l'historique en base.

### 3.4 Transcodage des indicateurs

#### NDVI (réponse `/ndvi/history`)
```ruby
INDICATOR_MAPPING = {
  min:    :minimal_ndvi_index,
  max:    :maximal_ndvi_index,
  mean:   :average_ndvi_index,
  median: :median_ndvi_index
}.freeze
```

#### Sol (réponse `/soil`)
```ruby
analyse.read!(:soil_moisture, item[:moisture].to_d.in_percent)
analyse.read!(:soil_surface_temperature, (item[:t0].to_d - 273.15).in_celsius)
analyse.read!(:soil_10cm_depth_surface_temperature, (item[:t10].to_d - 273.15).in_celsius)
```

#### EVI / EVI2 / NDWI / NRI / DSWI (backlog Phase 7)
Indicateurs absents de la nomenclature core. PR Nomen préalable requise.

---

## 4. Phases d'implémentation — État final

| Phase | Statut | Livré |
|---|---|---|
| **0 — Préparation** | ✅ 2026-06-03 | Audit core, geometry confirmée, 7 indicateurs déjà en Nomen, découverte du code legacy à extraire. Gem nommé `agro_monitoring`. |
| **1 — Scaffolding** | ✅ | gemspec, Plugfile, dotfiles, engine (hooks + addon), 9 locales (FR+EN complets, 7 autres pour les descriptions). |
| **2 — Intégration API** | ✅ | `AgroMonitoringIntegration < ActionIntegration::Base` — 1 paramètre `api_key`, 9 méthodes (`check`, polygon CRUD, ndvi_history, current_soil, image_search, image_stats), helper `with_appid` (encode `CGI.escape`). |
| **3 — Sync polygones + quota** | ✅ | `PolygonSyncService` (200 lignes) + `AgroMonitoringPolygonSyncJob`. Geometry SHA1, quota plafond 9, statuts Result (`created`/`updated`/`unchanged`/`deleted`/`quota_exceeded`/`geometry_update_deferred`/`error`/`skipped_*`), méthode `remove!` pour cleanup. |
| **4 — NDVI + sol + throttle** | ✅ | `ApiThrottle.pause!` (sleep 1.1s), `NdviHistoryImportService`, `SoilSnapshotImportService`, `FirstRunJob` (24×30j ~= 2 ans), `DailyFetchJob` (incrémental + overlap 1j). Lock réentrance via Preference. |
| **5 — Bouton sync UI** | ✅ | Route + `AgroMonitoringSynchronizationsController` + partial HAML + `View::Addon.add` sur `backend/cultivable_zones#show`. Bouton désactivé si pas d'intégration. |
| **6 — Tests + README + CI** | ✅ | `test/test_helper.rb` (VCR/WebMock), 10 tests de contrat HTTP, 19 assertions, `rubocop --parallel` clean (0 offense sur 18 fichiers). |
| **7 — Backlog post-MVP** | ⏳ Non livré | Détaillé en §11 |

### Phase 0 — Découvertes-clés

1. `CultivableZone#shape` (multi_polygon SRID 4326) → `RGeo::GeoJSON.encode(shape.to_rgeo.first)` (un seul polygone).
2. Indicateurs déjà en Nomen : `average/minimal/maximal/median_ndvi_index` + `soil_moisture`, `soil_surface_temperature`, `soil_10cm_depth_surface_temperature`.
3. Code legacy à extraire/retirer du core : `AgroMonitoringClient`, `AgromonitoringJob`, `CultivableZoneAnalysis`, hooks `initiate_satellite_data` + `after_destroy` sur `CultivableZone`.
4. `Identifier(nature: :agromonitoring_api_key)` déjà connu de core → script de migration nécessaire pour les tenants existants.
5. `NdviCellsController` (cellule graphique NDVI) reste utilisable tel quel → la Phase 5 du plan se réduit au bouton de sync.

### Phase 3 — Flux PolygonSyncService

```
call(cz)
 ├── shape.blank? → :skipped_no_shape
 ├── area_ha < 1 → :skipped_area_too_small
 ├── area_ha > 3000 → :skipped_area_too_large
 ├── is_provided_by?(vendor, name)
 │    YES → geometry_changed? (compare SHA1(WKT))
 │           ├── non → :unchanged
 │           └── oui → quota_available? (count < 9)
 │                    ├── non → :geometry_update_deferred (ancien polygone conservé)
 │                    └── oui → delete + create + persist → :updated
 │    NON → quota_available?
 │           ├── non → :quota_exceeded
 │           └── oui → create + persist → :created
 └── rescue StandardError → :error
```

### Phase 4 — Workflow first-run

```
perform()
 ├── return si Preference('agro_monitoring_import_running').value
 ├── lock import_running = true
 ├── AgroMonitoringPolygonSyncJob.perform_now (crée polygones manquants)
 ├── pour chaque CultivableZone avec provider 'agromonitoring/agromonitoring_polygons':
 │    ├── 24 fenêtres reverse de 30 jours :
 │    │    └── NdviHistoryImportService.call (pause 1.1s avant chaque appel)
 │    └── SoilSnapshotImportService.call (1 snapshot)
 ├── Preference('last_agro_monitoring_import', Time.now.to_i)
 └── ensure: lock import_running = false
```

Charge prévisionnelle : 10 zones × (24 + 1) appels × 1.1s = **~4.6 minutes** d'exécution → tient dans la marge satellite (60/min) et quota mensuel polygones (9).

---

## 5. Dépendances entre phases

```
Phase 0 (Prérequis) ✅
    │
    ▼
Phase 1 (Scaffolding) ✅
    │
    ▼
Phase 2 (Intégration API) ✅
    │
    ▼
Phase 3 (Polygon sync) ✅
    │
    ▼
Phase 4 (NDVI + sol) ✅ ───────► Phase 5 (UI bouton) ✅
    │                                │
    └────────────┬───────────────────┘
                 ▼
        Phase 6 (Tests + README + CI) ✅
```

---

## 6. Quality gates — Résultats par phase

| Phase | Gate | Résultat |
|---|---|---|
| 1 | `bundle install` OK, `rubocop` clean, engine se charge | ✅ |
| 2 | `ruby -c` sur tous fichiers, contrat HTTP cohérent | ✅ |
| 3 | Service idempotent (2× `call` = 0 duplicat) | ✅ via geometry_hash |
| 4 | Idempotence import NDVI/sol | ✅ via `(cultivable_zone_id, reference_number)` |
| 5 | Bouton visible / désactivé selon Integration, redirige + notifie | ✅ |
| 6 | `rake test` vert, `rubocop --parallel` 0 offense | ✅ 10 runs, 19 assertions / 18 files, 0 offense |

---

## 6.bis Décisions liées au plan gratuit

| Décision | Justification |
|---|---|
| Saisie clé API via écran Intégrations (pattern Weenat) | UX cohérente, formulaire auto-généré par core |
| Throttle 1.1 s avant chaque appel satellite | Garantit < 55 calls/min sans coordination concurrente |
| Plafond strict à 9 créations/mois (marge sur le 10 API) | Absorbe race conditions, retries, usage hors-Ekylibre de la même clé |
| Update géométrique consomme le quota → bloqué si plafond atteint, ancien polygone conservé | Évite des suppressions d'historique pour rien |
| Météo Agromonitoring hors-scope MVP | Sencrop/Weenat couvrent la météo capteurs |
| First-run = 2 ans NDVI scalaire + 1 snapshot sol | Charge ~5 min/cycle, tient dans toutes les marges |
| Onboarding multi-mois assumé et documenté | > 10 parcelles = plusieurs mois OU plan payant. Pas de hack contournant le quota |
| **Pas de retry 429 en MVP** | Throttle 1.1 s est défense suffisante. Back-off propre → Phase 7 (nécessite changement de contrat ActionIntegration) |

---

## 7. Risques résiduels & mitigations

| Risque | Probabilité | Mitigation |
|---|---|---|
| **Double-création de polygones tant que le legacy core reste actif** | Élevée (consomme 2× le quota !) | **PR core obligatoire AVANT publication** : retirer `AgromonitoringJob`, `AgroMonitoringClient`, `CultivableZoneAnalysis`, hooks `initiate_satellite_data` + `after_destroy` agromonitoring de `CultivableZone`. Documenté README. |
| Tenants existants ayant déjà saisi leur clé via `Identifier(:agromonitoring_api_key)` | Moyenne | Script de migration : à l'install du plugin, copier `Identifier#value` → `Integration.parameters['api_key']`. Documenté README ; implémentation Phase 7. |
| Quota satellite dépassé (60/min) | Élevée si throttle court-circuité | Throttle centralisé dans `ApiThrottle.pause!` ; si un nouveau call site oublie de l'invoquer → 429. Mitigation : grep des nouveaux services pour `pause!`. |
| Quota polygones dépassé (10/mois) | Élevée si onboarding > 10 parcelles | Compteur mensuel + arrêt déterministe + notification. README documente l'onboarding multi-mois. |
| Surface parcelle > 3000 ha → polygone refusé | Faible (rare en Europe) | `PolygonSyncService` skip avec statut `:skipped_area_too_large`, pas d'erreur. |
| Pas d'update géométrique côté API → cycle delete+create perd l'historique image satellite | Moyenne | Historique scalaire (Analysis) reste relié par `cultivable_zone_id`, donc préservé. Documenté README. |
| Polygones orphelins côté Agromonitoring (parcelle supprimée hors plugin) | Moyenne | Phase 7 : `list_polygons` + sweep des orphelins (delete ne consomme pas de quota). |
| `geometry_hash` SHA1(WKT) sensible aux arrondis flottants | Faible | Si WKT resauvegardé avec arrondi différent → faux positif → delete+create non désiré (consomme quota). Mitigation Phase 7 : comparaison à seuil. |
| Bundler 2.2.x requis pour `bundle install` (constraint gemspec) | Faible | Documenté en mode dev : `gem install bundler:2.2.34 && bundle _2.2.34_ install`. CI utilise déjà bundler 2.2 via image rubocop:0.2.0. |
| Double-clic utilisateur sur bouton sync → 2 jobs concurrent | Faible | `is_provided_by?` check empêche duplicate côté DB ; le risque résiduel est un `create_polygon` racy → corrigé en Phase 7 (lock via Preference). |

---

## 8. Estimation vs réalisé

| Phase | Estimé (j.h) | Réalisé |
|---|---|---|
| 0 — Préparation | 0.5 | Aligné — audit core + détection legacy |
| 1 — Scaffolding | 0.5 | Aligné |
| 2 — Intégration API | 1.5 | Aligné |
| 3 — Polygon sync | 1.5 | Aligné — geometry_hash ajouté |
| 4 — NDVI/sol import | 2.0 | Aligné — soil ajouté en bonus |
| 5 — UI bouton | 1.5 | Sous-budget (Leaflet retiré du scope MVP) |
| 6 — Tests + Doc + CI | 1.5 | Aligné |
| **Total MVP** | **9 j.h** | ~ aligné |
| 7 — Backlog (optionnel) | +5 j.h | À planifier |

---

## 9. Préparation à la publication

Liste de check pour passer le plugin en prod :

- [ ] **PR core** retirant : `AgroMonitoringClient`, `AgromonitoringJob`, `CultivableZoneAnalysis`, hooks `initiate_satellite_data` + branche `agromonitoring` du `after_destroy` de `CultivableZone`. Garde le `NdviCellsController` (utilisé par le plugin).
- [ ] **Logo** : ajouter `app/assets/images/integrations/agro_monitoring.png` + `.svg` (cf. `app/assets/images/integrations/agro_monitoring.TODO.md`).
- [ ] **Script de migration** : à l'install, copier `Identifier(nature: 'agromonitoring_api_key').value` vers `Integration(nature: 'agro_monitoring').parameters['api_key']` puis supprimer l'Identifier.
- [ ] **Tests d'intégration host-side** : créer une suite côté Ekylibre core qui charge le plugin et valide `PolygonSyncService` end-to-end (modèles + ActionIntegration).
- [ ] **Test manuel** : avec une clé API réelle, faire un first-run complet sur 2-3 parcelles tests et vérifier la cellule NDVI.

---

## 10. Backlog Phase 7

Idées non bloquantes, à prioriser selon retour utilisateur :

1. **Retry 429 propre** — nécessite d'exposer le `response.code` dans le contrat `Call#execute` (PR core ou wrapper local).
2. **Indicateurs EVI / EVI2 / NDWI / NRI / DSWI** — PR Nomen core préalable, puis branche dans `NdviHistoryImportService` via `image_stats(product, image_id)`.
3. **Surcouche carto Leaflet tuilée** — Layer `/tile/1.0/{z}/{x}/{y}/ndvi/{image_id}` sur la fiche CZ, sélection de la scène la plus récente.
4. **Réconciliation des polygones orphelins** — sweep périodique `list_polygons` vs `CultivableZone#provider`, delete des orphelins (ne consomme pas de quota).
5. **Allowlist de parcelles** — `Preference('agro_monitoring_tracked_cz_ids')` pour cibler les parcelles prioritaires dans la limite du quota.
6. **Migration `Identifier` → `Integration`** — script idempotent à l'install (rake task ou engine initializer one-shot).
7. **Locales complètes** — ajouter `agro_monitoring_synchronize` + libellés notifications dans les 7 langues restantes (spa, por, ita, deu, cmn, jpn, arb).
8. **Throttle plus fin** — comptage glissant des appels au lieu de sleep aveugle, pour exploiter la marge sans gaspillage.
9. **Test d'intégration en CI** — image Docker chargeant Ekylibre + le plugin, exécution de `PolygonSyncService` contre mock Agromonitoring.
10. **Vue dédiée timeline NDVI** — `backend/agro_monitoring/parcels` avec chart timeline filtrable par CZ/campagne (étend `NdviCellsController`).

---

## 11. Pointeurs

| Document | Rôle |
|---|---|
| `README.md` (racine) | Doc utilisateur : install, configuration, mapping indicateurs, free plan. |
| `claudedocs/phase_0_findings.md` | Audit du code legacy core, décisions d'architecture, mapping indicateurs disponibles. |
| `claudedocs/workflow_agro_monitoring_plugin.md` (ce fichier) | Plan d'implémentation post-MVP avec ce qui a été livré phase par phase. |
| `app/assets/images/integrations/agro_monitoring.TODO.md` | Spécifications du logo manquant. |
