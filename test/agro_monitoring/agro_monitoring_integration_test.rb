# frozen_string_literal: true

require_relative '../test_helper'

# Stand-alone HTTP contract tests against the Agromonitoring API.
# These tests do NOT load the Ekylibre Rails environment — they verify that
# the documented URLs and payloads can be consumed by a plain Net::HTTP client.
# Higher-level service tests (PolygonSyncService etc.) live in the host app's
# integration suite because they require the Rails models and ActionIntegration.
class AgroMonitoringIntegrationContractTest < Minitest::Test
  BASE_URL  = 'http://api.agromonitoring.com/agro/1.0'
  STATS_URL = 'http://api.agromonitoring.com/stats/1.0'

  def setup
    @api_key = 'test-agromonitoring-key'
    @polygon_id = '5abb9fb82c8897000bde3e87'
    @geo_json = {
      type: 'Feature',
      properties: {},
      geometry: {
        type: 'Polygon',
        coordinates: [[[-121.1958, 37.6683], [-121.1779, 37.6687], [-121.1773, 37.6792], [-121.1958, 37.6792], [-121.1958, 37.6683]]]
      }
    }
  end

  # ---------- check ----------

  def test_check_endpoint_returns_polygons_list
    stub_request(:get, "#{BASE_URL}/polygons?appid=#{@api_key}")
      .to_return(status: 200, body: '[]', headers: { 'Content-Type' => 'application/json' })

    response = get_json("#{BASE_URL}/polygons?appid=#{@api_key}")
    assert_equal 200, response.code.to_i
  end

  def test_check_returns_401_on_invalid_key
    stub_request(:get, "#{BASE_URL}/polygons?appid=#{@api_key}")
      .to_return(status: 401, body: '{"cod":401,"message":"Invalid API key."}',
                 headers: { 'Content-Type' => 'application/json' })

    response = get_json("#{BASE_URL}/polygons?appid=#{@api_key}")
    assert_equal 401, response.code.to_i
  end

  # ---------- polygons CRUD ----------

  def test_create_polygon_post_shape
    payload = { name: 'Test polygon', geo_json: @geo_json }

    stub_request(:post, "#{BASE_URL}/polygons?appid=#{@api_key}")
      .with(
        headers: { 'Content-Type' => 'application/json' },
        body: payload.to_json
      )
      .to_return(
        status: 201,
        body: {
          id: @polygon_id,
          geo_json: @geo_json,
          name: 'Test polygon',
          center: [-121.1867, 37.6739],
          area: 190.6343,
          user_id: '557066d0ff7a7e3897531d94'
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    response = post_json("#{BASE_URL}/polygons?appid=#{@api_key}", payload)
    assert_equal 201, response.code.to_i
    body = JSON.parse(response.body)
    assert_equal @polygon_id, body['id']
    assert_equal 190.6343, body['area']
  end

  def test_list_polygons_returns_array
    stub_request(:get, "#{BASE_URL}/polygons?appid=#{@api_key}")
      .to_return(
        status: 200,
        body: [{ id: @polygon_id, name: 'Plot 1', area: 12.5 }].to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    response = get_json("#{BASE_URL}/polygons?appid=#{@api_key}")
    body = JSON.parse(response.body)
    assert_kind_of Array, body
    assert_equal @polygon_id, body.first['id']
  end

  def test_get_polygon_by_id
    stub_request(:get, "#{BASE_URL}/polygons/#{@polygon_id}?appid=#{@api_key}")
      .to_return(
        status: 200,
        body: { id: @polygon_id, name: 'Plot 1', area: 12.5 }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    response = get_json("#{BASE_URL}/polygons/#{@polygon_id}?appid=#{@api_key}")
    body = JSON.parse(response.body)
    assert_equal @polygon_id, body['id']
  end

  def test_update_polygon_name
    stub_request(:put, "#{BASE_URL}/polygons/#{@polygon_id}?appid=#{@api_key}")
      .with(body: { name: 'Renamed plot' }.to_json)
      .to_return(
        status: 200,
        body: { id: @polygon_id, name: 'Renamed plot' }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    response = put_json("#{BASE_URL}/polygons/#{@polygon_id}?appid=#{@api_key}", { name: 'Renamed plot' })
    assert_equal 200, response.code.to_i
    assert_equal 'Renamed plot', JSON.parse(response.body)['name']
  end

  def test_delete_polygon_returns_204
    stub_request(:delete, "#{BASE_URL}/polygons/#{@polygon_id}?appid=#{@api_key}")
      .to_return(status: 204, body: '')

    response = delete_request("#{BASE_URL}/polygons/#{@polygon_id}?appid=#{@api_key}")
    assert_equal 204, response.code.to_i
  end

  # ---------- NDVI history ----------

  def test_ndvi_history_returns_scalar_stats
    start_unix = 1_530_336_000
    end_unix   = 1_534_723_200
    url = "#{BASE_URL}/ndvi/history?appid=#{@api_key}&clouds_max=10&end=#{end_unix}&polygon_id=#{@polygon_id}&start=#{start_unix}"

    stub_request(:get, url)
      .to_return(
        status: 200,
        body: [{
          dt: 1_534_723_200,
          source: 'l8',
          cl: 0.16,
          data: { std: 0.156, p75: 0.726, min: 0.173, max: 0.838, median: 0.607, p25: 0.474, num: 8374, mean: 0.598 }
        }].to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    response = get_json(url)
    body = JSON.parse(response.body)
    point = body.first
    assert_equal 1_534_723_200, point['dt']
    assert_equal 0.598, point['data']['mean']
    assert_equal 0.173, point['data']['min']
    assert_equal 0.838, point['data']['max']
  end

  # ---------- soil ----------

  def test_soil_endpoint_returns_kelvin_temperatures
    url = "#{BASE_URL}/soil?appid=#{@api_key}&polyid=#{@polygon_id}"

    stub_request(:get, url)
      .to_return(
        status: 200,
        body: { dt: 1_580_000_000, t10: 281.34, moisture: 0.175, t0: 279.5 }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    response = get_json(url)
    body = JSON.parse(response.body)
    assert_in_delta 281.34, body['t10'], 0.01
    assert_in_delta 0.175, body['moisture'], 0.001
  end

  # ---------- image search ----------

  def test_image_search_returns_scene_list
    start_unix = 1_530_336_000
    end_unix   = 1_534_723_200
    url = "#{BASE_URL}/image/search?appid=#{@api_key}&end=#{end_unix}&polyid=#{@polygon_id}&start=#{start_unix}"

    stub_request(:get, url)
      .to_return(
        status: 200,
        body: [{
          dt: 1_534_723_200,
          type: 'Landsat 8',
          dc: 100,
          cl: 0.16,
          sun: { elevation: 64.3, azimuth: 135.7 },
          image: { ndvi: 'http://api.agromonitoring.com/image/1.0/ndvi/abc' },
          stats: { ndvi: 'http://api.agromonitoring.com/stats/1.0/ndvi/abc' }
        }].to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    response = get_json(url)
    scene = JSON.parse(response.body).first
    assert_equal 'Landsat 8', scene['type']
    assert_equal 0.16, scene['cl']
  end

  # ---------- helpers ----------

  private

    def get_json(url)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      path = uri.query ? "#{uri.path}?#{uri.query}" : uri.path
      request = Net::HTTP::Get.new(path)
      request['Content-Type'] = 'application/json'
      http.request(request)
    end

    def post_json(url, payload)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      path = uri.query ? "#{uri.path}?#{uri.query}" : uri.path
      request = Net::HTTP::Post.new(path)
      request['Content-Type'] = 'application/json'
      request.body = payload.to_json
      http.request(request)
    end

    def put_json(url, payload)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      path = uri.query ? "#{uri.path}?#{uri.query}" : uri.path
      request = Net::HTTP::Put.new(path)
      request['Content-Type'] = 'application/json'
      request.body = payload.to_json
      http.request(request)
    end

    def delete_request(url)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      path = uri.query ? "#{uri.path}?#{uri.query}" : uri.path
      request = Net::HTTP::Delete.new(path)
      http.request(request)
    end
end
