# frozen_string_literal: true

module AgroMonitoring
  # Manual trigger for the polygon sync job. Reachable from the "Synchroniser"
  # button injected on every CultivableZone show page (see _sync_toolbar partial).
  class AgroMonitoringSynchronizationsController < Backend::BaseController
    def perform
      AgroMonitoringPolygonSyncJob.perform_later(user_id: current_user.id)
      notify_success(:agro_monitoring_sync_started.tl)
      redirect_back(fallback_location: backend_cultivable_zones_path)
    end
  end
end
