# frozen_string_literal: true

# Incremental daily import of NDVI history and soil snapshots.
#
# Pulled by the engine's `run every: :day` hook with the value of
# Preference('last_agro_monitoring_import'). Re-fetches a small overlap
# window before that cursor so retro-published satellite scenes are picked
# up (idempotency is enforced by Analysis#reference_number per zone).
class AgroMonitoringDailyFetchJob < ActiveJob::Base
  queue_as :default

  OVERLAP_DAYS = 1
  DEFAULT_LOOKBACK_DAYS = 7

  def perform(last_imported_at = nil)
    return if Preference.find_by(name: 'agro_monitoring_import_running')&.value

    Preference.set!('agro_monitoring_import_running', true, 'boolean')

    end_unix = Time.zone.now.to_i
    start_unix = compute_start_unix(last_imported_at)

    synced_zones.find_each do |cz|
      AgroMonitoring::NdviHistoryImportService.call(
        cultivable_zone: cz,
        start_unix: start_unix,
        end_unix: end_unix
      )
      AgroMonitoring::SoilSnapshotImportService.call(cultivable_zone: cz)
    end

    Preference.set!('last_agro_monitoring_import', end_unix, 'integer')
  rescue StandardError => e
    Rails.logger.error "[AgroMonitoring] DailyFetchJob error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    ExceptionNotifier.notify_exception(e, data: { job: 'AgroMonitoringDailyFetchJob' }) if defined?(ExceptionNotifier)
    raise
  ensure
    Preference.set!('agro_monitoring_import_running', false, 'boolean')
  end

  private

    def compute_start_unix(last_imported_at)
      cursor = last_imported_at.to_i
      cursor = (Time.zone.now - DEFAULT_LOOKBACK_DAYS.days).to_i if cursor <= 0
      cursor - (OVERLAP_DAYS * 86_400)
    end

    def synced_zones
      CultivableZone
        .where("provider ->> 'vendor' = ? AND provider ->> 'name' = ?", 'agromonitoring', 'agromonitoring_polygons')
        .order(:id)
    end
end
