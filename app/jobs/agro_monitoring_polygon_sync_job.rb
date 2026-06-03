# frozen_string_literal: true

# Synchronizes every CultivableZone with its Agromonitoring polygon.
#
# Iterates zones by ascending id (deterministic order so the monthly quota
# fills predictably) and delegates per-zone work to PolygonSyncService.
# Stops the iteration as soon as the monthly quota is exhausted to avoid
# wasted API calls.
class AgroMonitoringPolygonSyncJob < ActiveJob::Base
  queue_as :default

  def perform(user_id: nil)
    user = User.find_by(id: user_id) if user_id
    counts = Hash.new(0)
    quota_blocked = false

    CultivableZone.where.not(shape: nil).order(:id).find_each do |cz|
      result = AgroMonitoring::PolygonSyncService.call(cz)
      counts[result.status] += 1

      if result.status == :quota_exceeded
        Rails.logger.warn "[AgroMonitoring] Monthly polygon quota reached at CultivableZone##{cz.id}; stopping sync."
        quota_blocked = true
        break
      end
    end

    if user
      if quota_blocked
        notify(user, :agro_monitoring_monthly_quota_reached, :warning, counts)
      else
        notify(user, :agro_monitoring_sync_succeeded, :success, counts)
      end
    end

    counts
  rescue StandardError => e
    Rails.logger.error "[AgroMonitoring] PolygonSyncJob error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    ExceptionNotifier.notify_exception(e, data: { job: 'AgroMonitoringPolygonSyncJob' }) if defined?(ExceptionNotifier)
    notify(user, :agro_monitoring_sync_failed, :error, message: e.message) if user
    raise
  end

  private

    def notify(user, message_key, level, interpolations)
      user.notifications.create!(
        message: message_key.to_s,
        level: level,
        interpolations: interpolations
      )
    end
end
