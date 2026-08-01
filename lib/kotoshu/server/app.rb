# frozen_string_literal: true

require "json"
require "logger"
require "sinatra/base"
require "kotoshu"

module Kotoshu
  module Server
    class App < Sinatra::Base
      VERSION = "0.1.0".freeze

      def self.prewarm!(languages)
        logger = Logger.new($stderr)
        languages.each do |lang|
          logger.info("pre-warming #{lang}")
          begin
            Kotoshu.setup(lang.to_sym)
          rescue StandardError => e
            logger.warn("pre-warm #{lang} failed: #{e.message}")
          end
        end
      end

      configure do
        set :logging, false
        set :show_exceptions, false

        app_logger = Logger.new($stderr)
        app_logger.level = ENV.fetch("KOTOSHU_SERVER_LOG_LEVEL", Logger::INFO)
        set :app_logger, app_logger

        languages = ENV.fetch("KOTOSHU_SERVER_LANGUAGES", "en").split
        Kotoshu::Server::App.prewarm!(languages) unless ENV.fetch("KOTOSHU_SERVER_LAZY", "0") == "1"
      end

      # ---- Endpoints ----

      get "/" do
        content_type :json
        {
          name: "kotoshu-server",
          version: VERSION,
          kotoshu_version: Kotoshu::VERSION,
          docs: "/v1/health, /v1/version, /v1/languages, /v1/check, /v1/suggest, /v1/detect"
        }.to_json
      end

      get "/v1/health" do
        content_type :json
        configured = ENV.fetch("KOTOSHU_SERVER_LANGUAGES", "en").split
        ready = configured.map { |l| [l, Kotoshu.setup?(l.to_sym, :spelling)] }.to_h
        { status: "ok", ready: ready, timestamp: Time.now.utc.iso8601 }.to_json
      end

      get "/v1/version" do
        content_type :json
        { server: VERSION, kotoshu: Kotoshu::VERSION, ruby: RUBY_VERSION }.to_json
      end

      get "/v1/languages" do
        content_type :json
        cached = Kotoshu.languages_setup
        { cached: cached, supported: cached }.to_json
      end

      post "/v1/check" do
        body = parse_json_body(request.body.read)
        text = body["text"]
        language = body["language"] || ENV.fetch("KOTOSHU_SERVER_DEFAULT_LANG", "en")
        format_hint = body["format"] || "full"

        halt_with_error(400, "missing 'text'") unless text.is_a?(String)

        result = with_resource(language) do |checker|
          checker.check(text)
        end

        content_type :json
        case format_hint
        when "errors" then serialize_errors(result).to_json
        else serialize_full(result).to_json
        end
      end

      post "/v1/suggest" do
        body = parse_json_body(request.body.read)
        word = body["word"]
        language = body["language"] || ENV.fetch("KOTOSHU_SERVER_DEFAULT_LANG", "en")
        max = body["max"]&.to_i

        halt_with_error(400, "missing 'word'") unless word.is_a?(String)

        result = with_resource(language) do |checker|
          checker.suggest(word, max_suggestions: max)
        end

        content_type :json
        { word: word, suggestions: serialize_suggestions(result) }.to_json
      end

      post "/v1/detect" do
        body = parse_json_body(request.body.read)
        text = body["text"]
        halt_with_error(400, "missing 'text'") unless text.is_a?(String)

        lang, confidence = Kotoshu.detect_language_with_confidence(text)
        content_type :json
        { language: lang, confidence: confidence }.to_json
      end

      # ---- Error handling ----

      error Kotoshu::ResourceNotSetupError do
        e = env["sinatra.error"]
        status 422
        content_type :json
        { error: "resource_not_setup", message: e.message,
          hint: "POST /v1/admin/setup with {language: \"...\"} (admin only)" }.to_json
      end

      error JSON::ParserError do
        status 400
        content_type :json
        { error: "invalid_json", message: env["sinatra.error"].message }.to_json
      end

      error StandardError do
        e = env["sinatra.error"]
        settings.app_logger&.error("unhandled: #{e.class}: #{e.message}")
        status 500
        content_type :json
        { error: "internal", message: e.message }.to_json
      end

      # ---- Helpers ----

      helpers do
        def parse_json_body(body)
          return {} if body.nil? || body.empty?

          JSON.parse(body)
        end

        def halt_with_error(code, message)
          halt code, { "Content-Type" => "application/json" },
               { error: "invalid_request", message: message }.to_json
        end

        def with_resource(language)
          Kotoshu.reset_spellchecker if Kotoshu.instance_variable_get(:@spellcheckers).nil?
          bundle = Kotoshu::ResourceManager.resolve(language: language)
          checker = Kotoshu::Spellchecker.new(resource_bundle: bundle)
          yield checker
        end

        def serialize_full(result)
          {
            file: result.file,
            word_count: result.word_count,
            errors: serialize_errors(result)
          }
        end

        def serialize_errors(result)
          (result.errors || []).map do |err|
            {
              word: err.word,
              position: err.position,
              suggestions: err.suggestions.map { |s| serialize_suggestion(s) }
            }
          end
        end

        def serialize_suggestions(set)
          return [] unless set.respond_to?(:suggestions)

          set.suggestions.map { |s| serialize_suggestion(s) }
        end

        def serialize_suggestion(s)
          {
            word: s.word,
            distance: s.distance,
            confidence: s.confidence,
            source: s.source
          }
        end
      end
    end
  end
end

require "time"
