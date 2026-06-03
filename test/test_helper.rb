# frozen_string_literal: true

require 'minitest/autorun'
require 'webmock/minitest'
require 'vcr'
require 'json'

VCR.configure do |c|
  c.cassette_library_dir = File.expand_path('cassettes', __dir__)
  c.hook_into :webmock
  c.default_cassette_options = { record: :new_episodes }
  c.filter_sensitive_data('<API_KEY>') { ENV.fetch('AGROMONITORING_API_KEY', 'agromonitoring-api-key') }
end
