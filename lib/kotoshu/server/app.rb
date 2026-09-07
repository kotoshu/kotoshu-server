# frozen_string_literal: true

require "json"
require "logger"
require "sinatra/base"
require "kotoshu"

module Kotoshu
  module Server
    # Raised at boot when KOTOSHU_SERVER_MODEL_LANGS / _TIER are set
    # but cannot be honored (kotoshu gem too old, unknown tier).
    class ModelConfigError < StandardError; end

    class App < Sinatra::Base
      # The release version, from lib/kotoshu/server/version.rb —
      # the only source of truth (the release workflow bumps it).
      VERSION = Kotoshu::Server::VERSION

      # Semantic models (tiers, registry, confidence cascade) ship in
      # kotoshu 0.7.0. The gemspec keeps its `kotoshu ~> 0.6`
      # constraint (dependency floors are the owner's call), so the
      # server validates the *installed* gem at boot instead.
      MODEL_MIN_KOTOSHU = Gem::Version.new("0.7.0")

      # Native language identification (plan 106) ships in kotoshu
      # 0.10.0: Kotoshu.detect_language returning a
      # Language::Detection backed by the lid-176 model through the
      # native extension. Same policy as MODEL_MIN_KOTOSHU — the
      # gemspec floor stays `kotoshu ~> 0.6` (older gems keep the
      # heuristic), so the installed gem is checked per request.
      DETECT_MIN_KOTOSHU = Gem::Version.new("0.10.0")

      # Languages to set up at boot, from KOTOSHU_SERVER_LANGUAGES
      # (space separated). Single source of truth for the env var: the
      # boot pre-warm and /v1/health both read it here.
      #
      # @return [Array<String>] Language codes to pre-warm
      def self.configured_languages
        ENV.fetch("KOTOSHU_SERVER_LANGUAGES", "en").split
      end

      # Languages to set up with spelling + semantic model at boot,
      # from KOTOSHU_SERVER_MODEL_LANGS (space separated, e.g. "en de").
      # Empty when unset — boot-time opt-in only, never an implicit
      # download (the gem's two-stage promise).
      #
      # @return [Array<String>] Language codes to set up with a model
      def self.model_languages
        ENV.fetch("KOTOSHU_SERVER_MODEL_LANGS", "").split
      end

      # Model tier used for setup and resolution, from
      # KOTOSHU_SERVER_MODEL_TIER. Defaults to "fluency", the
      # ecosystem default (owner decision 2026-09-04).
      #
      # @return [String] "full", "fluency", or "mini"
      def self.model_tier
        ENV.fetch("KOTOSHU_SERVER_MODEL_TIER", "fluency")
      end

      # Whether the installed kotoshu gem carries the semantic-model
      # surface the server wires against (0.7.0+).
      #
      # @return [Boolean]
      def self.semantic_models_supported?
        Gem::Version.new(Kotoshu::VERSION) >= MODEL_MIN_KOTOSHU
      end

      # Whether a semantic model is actually set up server-side for a
      # language (cache-only lookup; false on gems without model
      # support, so the /v1/check default flag never turns models on
      # underneath an old install).
      #
      # @param language [String] Language code
      # @return [Boolean]
      def self.model_available?(language)
        return false unless semantic_models_supported?

        Kotoshu.setup?(language.to_sym, :model)
      rescue StandardError
        false
      end

      # Validate the semantic-model environment before anything is
      # set up. Raises {ModelConfigError} with an actionable message
      # when KOTOSHU_SERVER_MODEL_LANGS is set but the installed
      # kotoshu gem predates model support, or the configured tier is
      # unknown. A no-op when the vars are unset — boot behavior is
      # then exactly today's.
      #
      # @raise [ModelConfigError] on an unsatisfiable configuration
      # @return [void]
      def self.validate_model_config!
        return if model_languages.empty?

        unless semantic_models_supported?
          raise ModelConfigError,
                "KOTOSHU_SERVER_MODEL_LANGS requires kotoshu >= 0.7.0 " \
                "(installed: #{Kotoshu::VERSION}). Semantic models ship in " \
                "kotoshu 0.7.0; unset KOTOSHU_SERVER_MODEL_LANGS or upgrade " \
                "the kotoshu gem."
        end

        begin
          Kotoshu::Cache::ModelCache.normalize_tier(model_tier)
        rescue ArgumentError => e
          raise ModelConfigError, "KOTOSHU_SERVER_MODEL_TIER: #{e.message}"
        end
      end

      # Synchronously set up the given languages (downloads on a cold
      # or expired cache). Runs on the pre-warm thread; also usable
      # directly by embedders that want a blocking warm-up.
      #
      # Languages listed in KOTOSHU_SERVER_MODEL_LANGS are set up with
      # spelling + model (at KOTOSHU_SERVER_MODEL_TIER) in one setup
      # call; the rest get spelling only, as before. Both lists are
      # unioned, and setup is idempotent, so a language in both is
      # set up once with the model.
      #
      # @param languages [Array<String>] Language codes
      # @return [void]
      def self.prewarm!(languages)
        logger = Logger.new($stderr)
        model_langs = model_languages
        tier = model_tier
        (languages | model_langs).each do |lang|
          with_model = model_langs.include?(lang)
          logger.info("pre-warming #{lang}#{with_model ? " (spelling + model, #{tier} tier)" : ""}")
          begin
            if with_model
              Kotoshu.setup(lang.to_sym, want: %i[spelling model], tier: tier)
            else
              Kotoshu.setup(lang.to_sym)
            end
            logger.info("pre-warm #{lang} complete")
          rescue StandardError => e
            logger.warn("pre-warm #{lang} failed: #{e.message}")
          end
        end
      end

      # Start pre-warming in a detached background thread and return
      # immediately. The server must bind and serve within seconds of
      # boot, while resource setup can block on the network
      # (download retries, and DNS resolution that no Net::HTTP
      # timeout bounds) — so setup never runs on the boot path.
      # Progress and completion are logged; /v1/health reports
      # per-language readiness while it runs.
      #
      # @param languages [Array<String>] Language codes
      # @return [Thread] the detached pre-warm thread
      def self.prewarm_async!(languages)
        validate_model_config! # fail fast, on the caller's thread
        Thread.new do
          Thread.current.name = "kotoshu-server-prewarm"
          prewarm!(languages)
        end
      end

      # ---- Language detection (/v1/detect) ----

      @lid_setup_mutex = Mutex.new
      @lid_setup_attempted = false

      # Whether the installed kotoshu gem carries the lid-176
      # detection surface (0.10.0+): Kotoshu.detect_language returning
      # a Language::Detection, plus setup_lid / LidDetector.available?.
      #
      # @return [Boolean]
      def self.lid_supported?
        Gem::Version.new(Kotoshu::VERSION) >= DETECT_MIN_KOTOSHU
      end

      # Whether KOTOSHU_DETECT=heuristic pins /v1/detect to the
      # 7-language heuristic, bypassing the gem engine selection (the
      # 0.1.1 behavior, e.g. to reproduce earlier results).
      #
      # @return [Boolean]
      def self.heuristic_detect?
        ENV.fetch("KOTOSHU_DETECT", nil) == "heuristic"
      end

      # Detect for /v1/detect: the language code, its score, and the
      # engine that served — "lid-176" or "heuristic".
      #
      # Engine selection, in order:
      # 1. KOTOSHU_DETECT=heuristic — the heuristic, pinned.
      # 2. kotoshu < 0.10.0 — the heuristic, as in 0.1.1; the server
      #    keeps working on old gems.
      # 3. Otherwise the gem's own selection: lid-176 through the
      #    native extension when it is built, the backend is not
      #    explicitly ruby, and the artifact pair is cached; the
      #    heuristic otherwise (KOTOSHU_BACKEND=ruby, pure-Ruby
      #    install, missing model).
      #
      # The lid model is set up lazily on the first detect reaching
      # case 3 — one download, off the boot path, honoring
      # KOTOSHU_OFFLINE through the gem; a failed setup (offline with
      # no cache, no registry entry, checksum mismatch) logs once and
      # detection answers from whatever the gem can serve.
      #
      # @param text [String] the text to analyze
      # @return [Array(String, Float, String)] code (nil when the
      #   heuristic is uncertain), score in [0, 1], engine name
      def self.detect_language_with_engine(text)
        return heuristic_detection(text) if heuristic_detect? || !lid_supported?

        ensure_lid_setup!
        detection = Kotoshu.detect_language(text)
        [detection.code, detection.score, lid_engine]
      end

      # The heuristic detection (Language::Detector, the same engine
      # /v1/detect served in 0.1.1, unchanged across gem versions).
      #
      # @param text [String]
      # @return [Array(String, Float, String)]
      def self.heuristic_detection(text)
        code, confidence = Kotoshu::Language::Detector.detect_with_confidence(text)
        [code, confidence, "heuristic"]
      end

      # Which engine the gem serves detect from: lid-176 when the
      # native model is loadable, the heuristic otherwise. Asked
      # after a detect, so it always names the engine behind the
      # returned code.
      #
      # @return [String]
      def self.lid_engine
        Kotoshu::Language::LidDetector.available? ? "lid-176" : "heuristic"
      end

      # Run Kotoshu.setup_lid once per process, on the first detect.
      # Idempotent in the gem; the once-guard keeps concurrent
      # requests from racing the download. Any failure is logged and
      # swallowed — detect then falls back inside the gem to whatever
      # is cached (typically the heuristic).
      #
      # @return [void]
      def self.ensure_lid_setup!
        @lid_setup_mutex.synchronize do
          return if @lid_setup_attempted

          @lid_setup_attempted = true
          Kotoshu.setup_lid
        end
      rescue StandardError => e
        Logger.new($stderr).warn(
          "lid model setup failed, falling back to the heuristic: #{e.class}: #{e.message}"
        )
      end

      # ---- Semantic analyzers (memoized per language + model file) ----

      @semantic_analyzers = {}
      @semantic_analyzers_mutex = Mutex.new

      # A memoized {Kotoshu::Analyzers::SemanticAnalyzer} for the model
      # file the ResourceManager resolved for `language`. Loading a
      # model (vocab + ONNX session) is expensive; one analyzer per
      # language is kept for the process lifetime. A changed model
      # file (different path) loads a fresh analyzer.
      #
      # @param language [String] Language code
      # @param model_info [Hash] bundle.model from ResourceManager
      #   (needs :model_path)
      # @return [Kotoshu::Analyzers::SemanticAnalyzer]
      def self.semantic_analyzer_for(language, model_info)
        path = model_info[:model_path]
        @semantic_analyzers_mutex.synchronize do
          @semantic_analyzers[[language.to_s, path]] ||= begin
            model = Kotoshu::Models::OnnxModel.from_file(path, language_code: language.to_s)
            Kotoshu::Analyzers::SemanticAnalyzer.new(model)
          end
        end
      end

      configure do
        set :logging, false
        set :show_exceptions, false

        app_logger = Logger.new($stderr)
        app_logger.level = ENV.fetch("KOTOSHU_SERVER_LOG_LEVEL", Logger::INFO)
        set :app_logger, app_logger
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
        ready = self.class.configured_languages.map { |l| [l, Kotoshu.setup?(l.to_sym, :spelling)] }.to_h
        { status: "ok", ready: ready, timestamp: Time.now.utc.iso8601 }.to_json
      end

      get "/v1/version" do
        content_type :json
        { server: VERSION, kotoshu: Kotoshu::VERSION, ruby: RUBY_VERSION }.to_json
      end

      get "/v1/languages" do
        content_type :json
        cached = Kotoshu.languages_setup
        model = cached.to_h { |lang| [lang, self.class.model_available?(lang)] }
        { cached: cached, supported: cached, model: model }.to_json
      end

      post "/v1/check" do
        body = parse_json_body(request.body.read)
        text = body["text"]
        language = body["language"] || ENV.fetch("KOTOSHU_SERVER_DEFAULT_LANG", "en")
        format_hint = body["format"] || "full"
        want_model = model_request_flag(body["model"], language)

        halt_with_error(400, "missing 'text'") unless text.is_a?(String)

        want = want_model ? %i[spelling model] : %i[spelling]
        result = with_resource(language, want: want) do |checker, bundle|
          if want_model && bundle.model.nil?
            # The gem resolves a nil model for languages that cannot
            # have one; an explicit request must not silently degrade.
            halt 422, { "Content-Type" => "application/json" },
                 {
                   error: "resource_not_setup",
                   message: "no semantic model set up for language '#{language}'",
                   hint: "list it in KOTOSHU_SERVER_MODEL_LANGS and restart"
                 }.to_json
          end
          check_result = checker.check(text)
          want_model ? rerank_semantic(language, check_result, text, bundle.model) : check_result
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

        language, confidence, engine = self.class.detect_language_with_engine(text)
        content_type :json
        { language: language, confidence: confidence, engine: engine }.to_json
      end

      # ---- Error handling ----

      error Kotoshu::Server::ModelConfigError do
        status 500
        content_type :json
        { error: "model_config", message: env["sinatra.error"].message }.to_json
      end

      error Kotoshu::Models::OnnxModel::OnnxUnavailable do
        status 503
        content_type :json
        { error: "onnx_unavailable", message: env["sinatra.error"].message,
          hint: "install the onnxruntime gem, or stop setting model langs" }.to_json
      end

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

        def with_resource(language, want: %i[spelling])
          Kotoshu.reset_spellchecker if Kotoshu.instance_variable_get(:@spellcheckers).nil?
          bundle = Kotoshu::ResourceManager.resolve(language: language, want: want)
          checker = Kotoshu::Spellchecker.new(resource_bundle: bundle)
          yield checker, bundle
        end

        # Resolve the effective "model" flag for /v1/check: an explicit
        # request value wins; otherwise the default is whether the
        # language has a model set up server-side (cache-only). An
        # explicit true on a kotoshu install without model support is
        # a 503 naming the requirement, not a silent dictionary-only
        # answer.
        #
        # @param value [Boolean, nil] the request's "model" field
        # @param language [String] resolved request language
        # @return [Boolean]
        def model_request_flag(value, language)
          case value
          when nil then self.class.model_available?(language)
          when true
            unless self.class.semantic_models_supported?
              halt 503, { "Content-Type" => "application/json" },
                   {
                     error: "model_unsupported",
                     message: "semantic models require kotoshu >= 0.7.0 " \
                              "(installed: #{Kotoshu::VERSION})"
                   }.to_json
            end
            true
          when false then false
          else halt_with_error(400, "'model' must be true or false")
          end
        end

        # Rerank a traditional check result with the gem's semantic
        # analyzer (dictionary verdict first, neural rerank for
        # uncertain candidates — the gem's confidence cascade decides
        # per word whether the ONNX rerank runs at all). Semantic
        # candidates lead the merged suggestion list; traditional
        # candidates follow, deduplicated by word. Any per-word
        # analyzer failure keeps the traditional suggestions for that
        # word — one bad word never fails the request.
        #
        # @param language [String] Language code
        # @param result [Kotoshu::Models::Result::DocumentResult]
        # @param text [String] the checked text (context source)
        # @param model_info [Hash, nil] bundle.model from the resolve
        # @return [Kotoshu::Models::Result::DocumentResult]
        def rerank_semantic(language, result, text, model_info)
          return result if model_info.nil? || model_info[:model_path].nil?
          errors = Array(result.errors)
          return result if errors.empty?

          analyzer = self.class.semantic_analyzer_for(language, model_info)
          cascade = Kotoshu::Suggestions::SemanticCascade.from_configuration(Kotoshu.configuration)

          reranked = errors.map { |error| rerank_error(analyzer, cascade, text, error) }

          Kotoshu::Models::Result::DocumentResult.new(
            file: result.file,
            errors: reranked,
            suppressed_errors: result.suppressed_errors,
            word_count: result.word_count
          )
        end

        # Rerank one error's suggestions, or return the error unchanged
        # when the cascade skips it or the analyzer has nothing better
        # (including an analyzer failure on this word — traditional
        # suggestions survive).
        #
        # @param analyzer [Kotoshu::Analyzers::SemanticAnalyzer]
        # @param cascade [Kotoshu::Suggestions::SemanticCascade]
        # @param text [String] the checked text
        # @param error [Kotoshu::Models::Result::WordResult]
        # @return [Kotoshu::Models::Result::WordResult]
        def rerank_error(analyzer, cascade, text, error)
          traditional = error.suggestions.to_a
          return error if traditional.empty? || cascade.skip?(traditional)

          semantic = begin
            analyzer.suggest_corrections(error.word, context: semantic_context(text, error))
          rescue StandardError
            []
          end
          return error if semantic.empty?

          Kotoshu::Models::Result::WordResult.new(
            word: error.word,
            correct: false,
            position: error.position,
            suggestions: merge_suggestions(semantic, traditional),
            suppressed: error.suppressed,
            suppressed_by: error.suppressed_by
          )
        end

        # Merge analyzer suggestions (semantic, context-ranked) ahead
        # of the traditional ones, deduplicated by word, mapped to the
        # wire Suggestion shape /v1/check already serializes.
        #
        # @param semantic [Array<Kotoshu::Models::Suggestion>]
        # @param traditional [Array<Kotoshu::Suggestions::Suggestion>]
        # @return [Array<Kotoshu::Suggestions::Suggestion>]
        def merge_suggestions(semantic, traditional)
          merged = []
          seen = {}
          semantic.each do |s|
            next if seen[s.word]

            seen[s.word] = true
            merged << Kotoshu::Suggestions::Suggestion.new(
              word: s.word,
              distance: s.metadata[:distance].to_i,
              confidence: s.confidence,
              source: :semantic
            )
          end
          traditional.each do |s|
            next if seen[s.word]

            seen[s.word] = true
            merged << s
          end
          merged
        end

        # The text window around an error, in the shape the analyzer's
        # own context ranking expects ({Models::Context} before /
        # current / after slices; nil when the error has no position).
        #
        # @param text [String] the checked text
        # @param error [Kotoshu::Models::Result::WordResult]
        # @return [Kotoshu::Models::Context, nil]
        def semantic_context(text, error)
          pos = error.position
          return nil unless pos.is_a?(Integer)

          window = 32
          word_end = pos + error.word.length
          Kotoshu::Models::Context.new(
            before: text[[pos - window, 0].max...pos] || "",
            current: text[pos...word_end] || "",
            after: text[word_end...(word_end + window)] || "",
            location: nil
          )
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
