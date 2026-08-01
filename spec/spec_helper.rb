# frozen_string_literal: true

require "rspec"
require "rack/test"
require "kotoshu"
require_relative "../lib/kotoshu/server"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.include Rack::Test::Methods
end

def app
  Kotoshu::Server::App
end
