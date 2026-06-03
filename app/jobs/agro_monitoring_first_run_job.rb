# frozen_string_literal: true

# Bootstraps NDVI history and soil snapshots after a successful integration
# check. Performs ~2 years of NDVI history per zone (24 windows of 30 days,
# reverse chronological) plus one soil snapshot.
#
# Run sequentially under the agro_monitoring_import_running preference lock
# so the engine's daily hook doesn't start concurrently.
class AgroMonitoringFirstRunJob < ActiveJob::Base
  queue_as :default

  WINDOW_DAYS = 30
  WINDOW_COUNT = 24 # ~720 days, ~2 years

  def perform
    return if Preference.find_by(name: 'agro_monitoring_import_running')&.value

    Preference.set!('agro_monitoring_import_running', true, 'boolean')

    # Step 1: ensure all eligible zones have a polygon on Agromonitoring.
    AgroMonitoringPolygonSyncJob.perform_now

    # Step 2: import NDVI history + soil for every synced zone.
    synced_zones.find_each do |cz|
      import_ndvi_history(cz)
      AgroMonitoring::SoilSnapshotImportService.call(cultivable_zone: cz)
    end

    Preference.set!('last_agro_monitoring_import', Time.zone.now.to_i, 'integer')
  rescue StandardError => e
    Rails.logger.error "[AgroMonitoring] FirstRunJob error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    ExceptionNotifier.notify_exception(e, data: { job: 'AgroMonitoringFirstRunJob' }) if defined?(ExceptionNotifier)
    raise
  ensure
    Preference.set!('agro_monitoring_import_running', false, 'boolean')
  end

  private

    def synced_zones
      CultivableZone
        .where("provider ->> 'vendor' = ? AND provider ->> 'name' = ?", 'agromonitoring', 'agromonitoring_polygons')
        .order(:id)
    end

    def import_ndvi_history(cz)
      (0...WINDOW_COUNT).to_a.reverse.each do |i|
        end_unix = (Time.zone.now.utc - (i * WINDOW_DAYS).days).to_i
        start_unix = (Time.zone.now.utc - ((i + 1) * WINDOW_DAYS).days).to_i

        AgroMonitoring::NdviHistoryImportService.call(
          cultivable_zone: cz,
          start_unix: start_unix,
          end_unix: end_unix
        )
      end
    end
end
