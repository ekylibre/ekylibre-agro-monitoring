# frozen_string_literal: true

require 'digest'

module AgroMonitoring
  # Reconciles a single CultivableZone with its Agromonitoring polygon.
  #
  # Responsibilities
  # - Validates that the zone's geometry fits the API constraints (1-3000 ha).
  # - Creates the polygon if missing, recreates it if the geometry changed,
  #   and counts each creation against the monthly free-plan quota.
  # - Persists the API polygon id and a geometry fingerprint on the zone via
  #   the Providable concern.
  #
  # Returns a Result struct describing the outcome. The service never raises
  # on integration/HTTP failures (they are captured into the result so the
  # caller can keep iterating other zones).
  class PolygonSyncService
    VENDOR = 'agromonitoring'
    PROVIDER_NAME = 'agromonitoring_polygons'

    MIN_AREA_HA = 1.0
    MAX_AREA_HA = 3000.0

    # Free plan allows 10 polygon creations per calendar month. We cap at 9
    # to keep a safety margin (race conditions, retries, manual usage of the
    # same API key outside Ekylibre).
    MONTHLY_QUOTA_LIMIT = 9

    Result = Struct.new(:status, :polygon_id, :message, keyword_init: true) do
      def success?
        %i[created updated unchanged deleted].include?(status)
      end

      def quota_exceeded?
        %i[quota_exceeded geometry_update_deferred].include?(status)
      end

      def error?
        status == :error
      end
    end

    def self.call(cultivable_zone)
      new(cultivable_zone).call
    end

    def initialize(cultivable_zone)
      @cultivable_zone = cultivable_zone
    end

    def call
      return Result.new(status: :skipped_no_shape) if @cultivable_zone.shape.blank?

      area_ha = compute_area_ha
      if area_ha < MIN_AREA_HA
        return Result.new(status: :skipped_area_too_small,
                          message: "Area #{area_ha.round(2)} ha < #{MIN_AREA_HA} ha")
      end
      if area_ha > MAX_AREA_HA
        return Result.new(status: :skipped_area_too_large,
                          message: "Area #{area_ha.round(2)} ha > #{MAX_AREA_HA} ha")
      end

      if @cultivable_zone.is_provided_by?(vendor: VENDOR, name: PROVIDER_NAME)
        sync_existing
      else
        create_new
      end
    rescue StandardError => e
      Rails.logger.error "[AgroMonitoring] PolygonSyncService error on CultivableZone##{@cultivable_zone.id}: #{e.message}"
      Result.new(status: :error, message: e.message)
    end

    # Detaches the zone from Agromonitoring: deletes the remote polygon
    # (does not consume the monthly quota) and clears the provider record.
    def remove!
      unless @cultivable_zone.is_provided_by?(vendor: VENDOR, name: PROVIDER_NAME)
        return Result.new(status: :not_synced)
      end

      polygon_id = stored_polygon_id
      result_holder = nil

      AgroMonitoringIntegration.delete_polygon(polygon_id).execute do |c|
        c.success do
          clear_provider!
          result_holder = Result.new(status: :deleted, polygon_id: polygon_id)
        end

        c.error do
          result_holder = Result.new(status: :error,
                                     polygon_id: polygon_id,
                                     message: 'delete_polygon API call failed')
        end
      end

      result_holder || Result.new(status: :error, message: 'delete_polygon returned no result')
    rescue StandardError => e
      Rails.logger.error "[AgroMonitoring] PolygonSyncService#remove! error on CultivableZone##{@cultivable_zone.id}: #{e.message}"
      Result.new(status: :error, message: e.message)
    end

    private

      def create_new
        return Result.new(status: :quota_exceeded) unless quota_available?

        geo_json = build_geo_json
        result_holder = nil

        AgroMonitoringIntegration.create_polygon(name: @cultivable_zone.name, geo_json: geo_json).execute do |c|
          c.success do |body|
            polygon_id = body[:id].to_s
            persist_provider(polygon_id)
            increment_quota_counter!
            result_holder = Result.new(status: :created, polygon_id: polygon_id)
          end

          c.error do
            result_holder = Result.new(status: :error, message: 'create_polygon API call failed')
          end
        end

        result_holder || Result.new(status: :error, message: 'create_polygon returned no result')
      end

      def sync_existing
        polygon_id = stored_polygon_id

        return Result.new(status: :unchanged, polygon_id: polygon_id) unless geometry_changed?

        unless quota_available?
          return Result.new(status: :geometry_update_deferred,
                            polygon_id: polygon_id,
                            message: 'Monthly quota exhausted; keeping previous polygon')
        end

        recreate_polygon(polygon_id)
      end

      def recreate_polygon(old_polygon_id)
        delete_result = nil
        AgroMonitoringIntegration.delete_polygon(old_polygon_id).execute do |c|
          c.success { delete_result = :ok }
          c.error { delete_result = :error }
        end
        if delete_result == :error
          return Result.new(status: :error,
                            polygon_id: old_polygon_id,
                            message: 'delete during geometry update failed')
        end

        geo_json = build_geo_json
        result_holder = nil
        AgroMonitoringIntegration.create_polygon(name: @cultivable_zone.name, geo_json: geo_json).execute do |c|
          c.success do |body|
            new_polygon_id = body[:id].to_s
            persist_provider(new_polygon_id)
            increment_quota_counter!
            result_holder = Result.new(status: :updated, polygon_id: new_polygon_id)
          end

          c.error do
            result_holder = Result.new(status: :error,
                                       message: 'recreate (create after delete) failed')
          end
        end

        result_holder || Result.new(status: :error, message: 'recreate returned no result')
      end

      def compute_area_ha
        @cultivable_zone.net_surface_area.convert(:hectare).to_f
      end

      # Agromonitoring expects a Polygon (not MultiPolygon). CultivableZone#shape
      # is a MultiPolygon — we ship the first ring, matching the legacy core client.
      def build_geo_json
        shape_json = RGeo::GeoJSON.encode(@cultivable_zone.shape.to_rgeo.first)
        { type: 'Feature', properties: {}, geometry: shape_json }
      end

      def geometry_changed?
        stored = @cultivable_zone.provider.dig(:data, 'geometry_hash') ||
                 @cultivable_zone.provider.dig(:data, :geometry_hash)
        return true if stored.blank?

        stored != current_geometry_hash
      end

      def current_geometry_hash
        @current_geometry_hash ||= Digest::SHA1.hexdigest(@cultivable_zone.shape.to_text)
      end

      def stored_polygon_id
        @cultivable_zone.provider.dig(:data, 'id') ||
          @cultivable_zone.provider.dig(:data, :id)
      end

      def persist_provider(polygon_id)
        @cultivable_zone.update!(
          provider: {
            vendor: VENDOR,
            name: PROVIDER_NAME,
            data: {
              id: polygon_id,
              geometry_hash: current_geometry_hash
            }
          }
        )
      end

      # The Providable concern's provider= setter ignores nil/blank values, so
      # we bypass it through update_column to actually clear the field.
      def clear_provider!
        @cultivable_zone.update_column(:provider, nil)
      end

      def quota_available?
        current_monthly_count < MONTHLY_QUOTA_LIMIT
      end

      def current_monthly_count
        Preference.find_by(name: quota_preference_key)&.value.to_i
      end

      def increment_quota_counter!
        Preference.set!(quota_preference_key, current_monthly_count + 1, 'integer')
      end

      def quota_preference_key
        "agro_monitoring_polygons_created_#{Time.zone.now.strftime('%Y_%m')}"
      end
  end
end
