# frozen_string_literal: true

require_relative "server/version"
require_relative "server/app"

module Kotoshu
  module Server
    # Boot the server.
    #
    # Pre-warm starts in a detached thread and never blocks: Puma binds
    # and serves within seconds regardless of how long resource setup
    # (cold-cache downloads) takes. KOTOSHU_SERVER_LAZY=1 skips the
    # pre-warm entirely; /v1/health reports readiness while it runs.
    def self.run!(port: ENV.fetch("KOTOSHU_SERVER_PORT", 9292), bind: ENV.fetch("KOTOSHU_SERVER_BIND", "0.0.0.0"))
      unless ENV.fetch("KOTOSHU_SERVER_LAZY", "0") == "1"
        App.prewarm_async!(App.configured_languages)
      end
      App.run!(port: port.to_i, bind: bind)
    end
  end
end
