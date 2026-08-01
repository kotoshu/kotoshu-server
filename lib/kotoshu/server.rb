# frozen_string_literal: true

require_relative "server/version"
require_relative "server/app"

module Kotoshu
  module Server
    def self.run!(port: ENV.fetch("KOTOSHU_SERVER_PORT", 9292), bind: ENV.fetch("KOTOSHU_SERVER_BIND", "0.0.0.0"))
      Kotoshu::Server::App.run!(port: port.to_i, bind: bind)
    end
  end
end
