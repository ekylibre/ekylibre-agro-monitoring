# Phase 0 — Rapport de vérification

> Exécutée le 2026-06-03. Pré-requis pour les phases 1+.
> Source : repo core `/home/djoulin/projects/ekylibre`.

---

## TL;DR

🟢 **Géométrie OK** — `CultivableZone#shape` (multi_polygon SRID 4326) + helper `shape_to_geojson` disponibles.
🟢 **Indicateurs NDVI déjà présents** dans la nomenclature core (`average/minimal/maximal/median_ndvi_index`).
🟢 **Indicateurs sol déjà présents** (`soil_moisture`, `soil_surface_temperature`, `soil_10cm_depth_surface_temperature`).
🟢 **Identifier `agromonitoring_api_key` déjà défini** dans `db/nomenclatures` (libellés FR/EN).
🟡 **EVI / NDWI / NRI / DSWI absents** — pas bloquant pour le MVP (déjà repoussé en Phase 7).
🔴 **Découverte majeure** : tout le code agro-monitoring **existe déjà dans Ekylibre core** (`AgroMonitoringClient`, `AgromonitoringJob`, `NdviCellsController`, `CultivableZoneAnalysis`). Le ticket #2662 demande l'**extraction** vers un plugin, pas une réécriture.
🟢 **Nom du gem figé** : `agro_monitoring` (cohérent avec `sencrop`, `weenat`).

---

## 1. Vérification géométrie `CultivableZone`

**Fichier** : `/home/djoulin/projects/ekylibre/app/models/cultivable_zone.rb`

```ruby
#  shape                  :geometry({:srid=>4326, :type=>"multi_polygon"}) not null
# ...
has_geometry :shape, type: :multi_polygon       # ligne 65
validates :shape, presence: true                # ligne 69
validates :shape, shape: true                   # ligne 71

def shape_to_geojson                            # ligne 93
  shape.to_geojson
end
```

**Conclusion** : la géométrie est disponible et déjà sérialisable. Le pattern utilisé par le code existant est cependant légèrement différent — il passe par RGeo :

```ruby
# app/integrations/agro_monitoring_client.rb:52
shape_json = RGeo::GeoJSON.encode(@parcel.shape.to_rgeo.first)
geo_json = { type: "Feature", properties: {}, geometry: shape_json }
```

**Note** : `to_rgeo.first` parce que `shape` est un `multi_polygon` — on prend le premier polygone. Agromonitoring n'accepte que des `Polygon` (pas de `MultiPolygon`).

---

## 2. Vérification indicateurs Nomen

| Indicateur souhaité (plan initial) | Présent dans core ? | Mapping recommandé |
|---|---|---|
| `vegetation_index` | ❌ | Remplacé par les 4 `*_ndvi_index` déjà présents (séparer min/max/mean/median) |
| `enhanced_vegetation_index` (EVI) | ❌ | Phase 7 backlog |
| `water_index` (NDWI) | ❌ | Phase 7 backlog |
| `nitrogen_reflectance_index` (NRI) | ❌ | Phase 7 backlog |
| `disease_water_stress_index` (DSWI) | ❌ | Phase 7 backlog |

### 2.1 Indicateurs NDVI disponibles

Présents dans `config/locales/eng/nomenclatures.yml` et `config/locales/fra/nomenclatures.yml` :

| Clé Nomen | Libellé FR | Libellé EN |
|---|---|---|
| `average_ndvi_index` | Indice NDVI moyen | Average ndvi index |
| `minimal_ndvi_index` | Indice NDVI minimal | Minimal ndvi index |
| `maximal_ndvi_index` | Indice NDVI maximal | Maximal ndvi index |
| `median_ndvi_index` | Indice NDVI médian | Median ndvi index |

**Mapping plan recommandé** (réponse API `ndvi/history`) :

```ruby
TRANSCODE_INDICATORS = {
  min:    { indicator: :minimal_ndvi_index, unit: :unity },
  max:    { indicator: :maximal_ndvi_index, unit: :unity },
  mean:   { indicator: :average_ndvi_index, unit: :unity },
  median: { indicator: :median_ndvi_index,  unit: :unity }
}.freeze
```

> **Action plan** : modifier la table `TRANSCODE_INDICATORS` du document `workflow_agro_monitoring_plugin.md` §3.4 pour utiliser les clés réelles `*_ndvi_index` au lieu de `vegetation_index`.

### 2.2 Indicateurs sol disponibles (bonus, endpoint `/soil` Agromonitoring)

| Clé Nomen | Présent | Usage |
|---|---|---|
| `soil_moisture` | ✓ | Humidité du sol (%) |
| `soil_surface_temperature` | ✓ | Température sol (K → °C, `item[:t0] - 273.15`) |
| `soil_10cm_depth_surface_temperature` | ✓ | Température sol à 10 cm |

**Conséquence** : on peut aussi extraire `grab_current_soil` du legacy code dans le plugin pour MVP (au lieu de le repousser en Phase 7).

### 2.3 EVI / NDWI / NRI / DSWI (Phase 7)

Aucune entrée trouvée dans `config/locales/*/nomenclatures.yml`. À ajouter via PR core avant Phase 7. Identifiants suggérés :
- `enhanced_vegetation_index` (EVI)
- `enhanced_vegetation_index_two` (EVI2)
- `water_index` (NDWI)
- `nitrogen_reflectance_index` (NRI) — Landsat-8 only
- `disease_water_stress_index` (DSWI) — Landsat-8 only

---

## 3. Code legacy existant dans Ekylibre core

> Issue [#2662](https://github.com/ekylibre/ekylibre/issues/2662) demande le refactor de `app/integrations/agro_monitoring_client.rb`. Tout ce code existe déjà — le plugin doit l'**extraire et migrer le stockage de la clé API**.

### 3.1 `app/integrations/agro_monitoring_client.rb` (147 lignes)

Classe POPO (`AgroMonitoringClient`, **n'hérite pas de `ActionIntegration::Base`**) qui utilise Faraday. Méthodes :
- `set_polygon` — POST `/polygons` + stocke `provider: { vendor: 'agromonitoring', name: 'agromonitoring_polygons', data: { id: ... } }` sur la `CultivableZone`.
- `remove_polygon` — DELETE `/polygons/{id}`.
- `grab_ndvi_history(stopped_at = Time.now, clouds_max = 10)` — GET `/ndvi/history?polygon_id&start=stopped_at-4y&end=stopped_at&clouds_max=10`.
- `grab_current_soil` — GET `/soil?polyid=...` (renvoie `{ dt, moisture, t0, t10 }`).

Construit avec :
```ruby
Faraday.new(
  url: 'http://api.agromonitoring.com/agro/1.0',
  params: { appid: @apikey },
  headers: { 'Content-Type' => 'application/json' }
)
```

**Clé API** : récupérée via `Identifier.find_by(nature: :agromonitoring_api_key)`, **pas via `Integration.parameters`**.

### 3.2 `app/jobs/agromonitoring_job.rb`

```ruby
def perform(parcel_id:, user_id: nil)
  user       = User.find(user_id) if user_id
  parcel     = CultivableZone.find(parcel_id)
  identifier = Identifier.find_by(nature: :agromonitoring_api_key)
  service    = AgroMonitoringClient.from_identifier(identifier, parcel, user)
  cz_service = CultivableZoneAnalysis.new(parcel)
  last       = cz_service.find_last_analysis(:ndvi)
  service.set_polygon
  ndvi_items = service.grab_ndvi_history(last || nil)
  cz_service.create_agromonitoring_ndvi_analysis(ndvi_items)
  soil_item  = service.grab_current_soil
  cz_service.create_agromonitoring_soil_analysis(soil_item)
  # + notifications success/error
end
```

Déclenché par `cultivable_zone.rb#initiate_satellite_data` (hook après création/update si surface > 1 ha et identifier présent).

### 3.3 `app/services/cultivable_zone_analysis.rb`

Crée les `Analysis` directement liées à la `CultivableZone` (pas via un `Sensor`) :

```ruby
analysis = Analysis.create!(
  reference_number: "#{item[:dt]}_ndvi",
  cultivable_zone_id: @cultivable_zone.id,
  nature: 'sensor_analysis',
  sampled_at: Time.at(item[:dt].to_i),
  analysed_at: Time.at(item[:dt].to_i)
)
analysis.read!(:minimal_ndvi_index, item[:data][:min].to_f) if item[:data][:min].present?
analysis.read!(:maximal_ndvi_index, item[:data][:max].to_f) if item[:data][:max].present?
analysis.read!(:average_ndvi_index, item[:data][:mean].to_f) if item[:data][:mean].present?
analysis.read!(:median_ndvi_index,  item[:data][:median].to_f) if item[:data][:median].present?
```

### 3.4 Hooks `CultivableZone` (à neutraliser côté core une fois le plugin actif)

```ruby
# app/models/cultivable_zone.rb:241
if self.is_provided_by?(vendor: 'agromonitoring', name: 'agromonitoring_polygons')
  identifier = Identifier.find_by(nature: :agromonitoring_api_key)
  AgroMonitoringClient.from_identifier(identifier, self, updater).remove_polygon
end
```

```ruby
# app/models/cultivable_zone.rb (private)
def initiate_satellite_data
  identifier = Identifier.find_by(nature: :agromonitoring_api_key)
  if identifier.present? && net_surface_area.convert(:hectare).to_f > 1.0
    AgromonitoringJob.perform_later(parcel_id: id, user_id: updater_id)
  end
end
```

### 3.5 UI existante

- `app/controllers/backend/cells/ndvi_cells_controller.rb` — cellule qui affiche le graphique NDVI sur la fiche `CultivableZone`. Charge `Analysis.where(cultivable_zone: cz).with_indicator('minimal_ndvi_index').between(...)`.
- Route `resource :ndvi_cell, only: :show` (`config/routes.rb:251`).

**Conséquence** : la couche UI carto n'a **pas besoin** d'être ré-implémentée — elle existera toujours côté core et lira les `Analysis` créées par le plugin via le même modèle. La Phase 5 du plan se réduit donc au **bouton "Synchroniser"** (la cellule NDVI continue de fonctionner native).

---

## 4. Reframing du plan workflow

À cause des découvertes ci-dessus, le plan `workflow_agro_monitoring_plugin.md` doit être révisé sur 4 points :

| Point du plan | Avant | Après |
|---|---|---|
| Modèle de stockage | `Sensor` (pattern Sencrop) | `CultivableZone#provider` (pattern legacy core, déjà UI-compatible) |
| Indicateurs | `vegetation_index` + 4 autres | 4 × `*_ndvi_index` + 3 × soil (tous présents) |
| Source clé API | `Integration.parameters['api_key']` (à la Weenat) | **Migration** : passer de `Identifier(nature: :agromonitoring_api_key)` vers `Integration.parameters['api_key']` — c'est le **vrai contenu du refactor #2662** |
| Couche UI carto | Phase 5.5 (Leaflet tuilé) | Déjà présente (`NdviCellsController`) — Phase 5 se limite au bouton de sync |

> Le plan workflow sera mis à jour dans la foulée pour refléter ces ajustements.

---

## 5. Décision : nom du gem

| Plugin | Dossier | Gem name | Module |
|---|---|---|---|
| Sencrop | `ekylibre-sencrop` | `sencrop` | `Sencrop` |
| Weenat | `ekylibre-weenat` | `weenat` | `Weenat` |
| Natuition | `ekylibre-natuition` | `ekylibre-natuition` | `EkylibreNatuition` |
| **Agro-monitoring (décision)** | `ekylibre-agro-monitoring` | **`agro_monitoring`** | **`AgroMonitoring`** |

**Justification** :
- Pattern Sencrop/Weenat (les plus récents) → gem sans préfixe `ekylibre-`.
- `agro_monitoring` (snake_case Ruby idiomatique) ; le tiret du dossier disparaît dans le nom du gem.
- Module Ruby `AgroMonitoring` (camelcase classique).
- Plugfile : `name 'agro_monitoring'`.

### Conséquences sur les noms de fichiers

```
lib/agro_monitoring.rb
lib/agro_monitoring/version.rb
lib/agro_monitoring/engine.rb

app/integrations/agro_monitoring/agro_monitoring_integration.rb
app/jobs/agro_monitoring_first_run_job.rb        # ou app/jobs/agro_monitoring/...
app/services/agro_monitoring/polygon_sync_service.rb
app/services/agro_monitoring/ndvi_history_import_service.rb

config/locales/{fra,eng,...}.yml                 # 9 locales

agro_monitoring.gemspec
```

### Conséquences sur les Preferences

| Clé Preference | Type | Rôle |
|---|---|---|
| `last_agro_monitoring_import` | integer | timestamp UNIX du dernier import |
| `agro_monitoring_import_running` | boolean | mutex de réentrance |
| `agro_monitoring_polygons_created_YYYY_MM` | integer | compteur mensuel (quota < 10) |
| `agro_monitoring_polygons_deferred` | integer | parcelles non créées faute de quota |

---

## 6. Checkpoint Phase 0

✅ Toutes les vérifications sont concluantes : **on peut passer à la Phase 1** (scaffolding).

**Prérequis avant Phase 1** :
1. Mettre à jour `workflow_agro_monitoring_plugin.md` avec les 4 ajustements listés en §4.
2. Documenter dans le README la stratégie de migration `Identifier` → `Integration` (script de migration ?).
3. Le code legacy reste actif dans core jusqu'à publication du plugin → prévoir un commit core qui retire `AgromonitoringJob`, `AgroMonitoringClient`, `CultivableZoneAnalysis` (ou les neutralise via un feature flag `Ekylibre::Plugin.installed?('agro_monitoring')`).

---

## 7. Risques nouvellement identifiés

| Risque | Impact | Mitigation |
|---|---|---|
| Le legacy code core et le plugin créeront 2× les polygones tant que le legacy n'est pas désactivé | Élevé (consomme 2× le quota mensuel !) | PR core obligatoire AVANT mise en prod du plugin : retirer le hook `initiate_satellite_data` et l'appel `remove_polygon` dans `CultivableZone`. |
| `Identifier(nature: :agromonitoring_api_key)` existe déjà chez certains clients | Moyen | Script de migration dans le plugin : à l'install, lire l'Identifier et le copier dans `Integration.parameters['api_key']`. |
| `Analysis.cultivable_zone_id` est la clé d'idempotence, pas `Sensor#euid` | Moyen | Le plan doit refléter ce modèle réel — pas de `Sensor` à créer. |
| MultiPolygon vs Polygon (Agromonitoring n'accepte que Polygon) | Faible | Code legacy fait déjà `shape.to_rgeo.first` — à reprendre tel quel. |
