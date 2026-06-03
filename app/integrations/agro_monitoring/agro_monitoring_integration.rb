require 'cgi'

module AgroMonitoring
  class ServiceError < StandardError; end

  class AgroMonitoringIntegration < ActionIntegration::Base
    BASE_URL  = 'http://api.agromonitoring.com/agro/1.0'.freeze
    STATS_URL = 'http://api.agromonitoring.com/stats/1.0'.freeze

    POLYGONS_URL = "#{BASE_URL}/polygons".freeze
    NDVI_HISTORY_URL = "#{BASE_URL}/ndvi/history".freeze
    SOIL_URL = "#{BASE_URL}/soil".freeze
    IMAGE_SEARCH_URL = "#{BASE_URL}/image/search".freeze

    authenticate_with :check do
      parameter :api_key
    end

    calls :list_polygons, :create_polygon, :get_polygon, :update_polygon, :delete_polygon,
          :ndvi_history, :current_soil, :image_search, :image_stats

    # GET /polygons?appid=...
    # 200 => list (possibly empty) confirms the key is valid.
    def check(integration = nil)
      integration = fetch integration
      api_key = integration.parameters['api_key']

      get_json(with_appid(POLYGONS_URL, {}, api_key)) do |r|
        r.success do
          Rails.logger.info '[Agromonitoring] API reachable'.green
        end

        r.error do
          Rails.logger.error '[Agromonitoring] check failed'.red
          r.error :api_down
        end
      end
    end

    # GET /polygons
    # response: [{ id, name, geo_json, center, area, user_id }, ...]
    def list_polygons
      get_json(with_appid(POLYGONS_URL)) do |r|
        r.success do
          JSON(r.body)
        end

        r.error do
          Rails.logger.error '[Agromonitoring] list_polygons failed'.red
        end
      end
    end

    # GET /polygons/{id}
    # response: { id, name, geo_json, center, area, user_id }
    def get_polygon(polygon_id)
      get_json(with_appid("#{POLYGONS_URL}/#{polygon_id}")) do |r|
        r.success do
          JSON(r.body).deep_symbolize_keys
        end

        r.error do
          Rails.logger.error "[Agromonitoring] get_polygon failed for #{polygon_id}".red
        end
      end
    end

    # POST /polygons
    # body: { name:, geo_json: GeoJSON Feature with Polygon geometry }
    # Quota: counts as 1 polygon against the monthly free-plan quota (<10/month).
    # response (201): { id, name, geo_json, center, area, user_id }
    def create_polygon(name:, geo_json:)
      payload = { name: name, geo_json: geo_json }

      post_json(with_appid(POLYGONS_URL), payload) do |r|
        r.success do
          JSON(r.body).deep_symbolize_keys
        end

        r.error do
          Rails.logger.error "[Agromonitoring] create_polygon failed (name=#{name})".red
          Rails.logger.error r.body
        end
      end
    end

    # PUT /polygons/{id}
    # body: { name: }
    # NOTE: the API does NOT support geometry updates — only the name can be changed.
    # To change a polygon's shape, delete it and create a new one (counts against the
    # monthly quota).
    def update_polygon(polygon_id, name:)
      put_json(with_appid("#{POLYGONS_URL}/#{polygon_id}"), { name: name }) do |r|
        r.success do
          JSON(r.body).deep_symbolize_keys
        end

        r.error do
          Rails.logger.error "[Agromonitoring] update_polygon failed for #{polygon_id}".red
        end
      end
    end

    # DELETE /polygons/{id}
    # 204 No Content on success.
    # Does NOT consume the monthly quota.
    def delete_polygon(polygon_id)
      delete_json(with_appid("#{POLYGONS_URL}/#{polygon_id}")) do |r|
        r.success do
          Rails.logger.info "[Agromonitoring] polygon #{polygon_id} deleted".green
        end

        r.error do
          Rails.logger.error "[Agromonitoring] delete_polygon failed for #{polygon_id}".red
        end
      end
    end

    # GET /ndvi/history
    # Returns scalar NDVI statistics (min/max/mean/median/...) per acquisition date.
    # start_unix, end_unix: UTC seconds.
    # response: [{ dt, source, zoom, dc, cl, data: { min, max, mean, median, std, p25, p75, num } }]
    def ndvi_history(polygon_id, start_unix, end_unix, clouds_max: 10)
      params = {
        polygon_id: polygon_id,
        start: start_unix,
        end: end_unix,
        clouds_max: clouds_max
      }
      get_json(with_appid(NDVI_HISTORY_URL, params)) do |r|
        r.success do
          JSON(r.body).map(&:deep_symbolize_keys)
        end

        r.error do
          Rails.logger.error "[Agromonitoring] ndvi_history failed for #{polygon_id}".red
        end
      end
    end

    # GET /soil?polyid=...
    # Returns the current soil snapshot for the polygon.
    # response: { dt, t10, moisture, t0 } (temperatures in Kelvin, moisture as ratio)
    def current_soil(polygon_id)
      get_json(with_appid(SOIL_URL, { polyid: polygon_id })) do |r|
        r.success do
          JSON(r.body).deep_symbolize_keys
        end

        r.error do
          Rails.logger.error "[Agromonitoring] current_soil failed for #{polygon_id}".red
        end
      end
    end

    # GET /image/search
    # Lists available satellite scenes for the polygon over the time window.
    # response: [{ dt, type, dc, cl, sun, image: { png, tile }, tile, stats, data }, ...]
    def image_search(polygon_id, start_unix, end_unix)
      params = {
        polyid: polygon_id,
        start: start_unix,
        end: end_unix
      }
      get_json(with_appid(IMAGE_SEARCH_URL, params)) do |r|
        r.success do
          JSON(r.body).map(&:deep_symbolize_keys)
        end

        r.error do
          Rails.logger.error "[Agromonitoring] image_search failed for #{polygon_id}".red
        end
      end
    end

    # GET /stats/1.0/{product}/{image_id}
    # Returns per-image statistics (mean/median/std/min/max/p25/p75/num).
    # product: one of 'ndvi', 'evi', 'evi2', 'nri', 'dswi', 'ndwi'.
    def image_stats(product, image_id)
      get_json(with_appid("#{STATS_URL}/#{product}/#{image_id}")) do |r|
        r.success do
          JSON(r.body).deep_symbolize_keys
        end

        r.error do
          Rails.logger.error "[Agromonitoring] image_stats failed for #{product}/#{image_id}".red
        end
      end
    end

    private

      def with_appid(url, extra_params = {}, api_key = nil)
        api_key ||= cached_api_key
        params = { appid: api_key }.merge(extra_params.compact)
        query = params.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }.join('&')
        separator = url.include?('?') ? '&' : '?'
        "#{url}#{separator}#{query}"
      end

      def cached_api_key
        @cached_api_key ||= fetch.parameters['api_key']
      end
  end
end
