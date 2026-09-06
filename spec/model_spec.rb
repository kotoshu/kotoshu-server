# frozen_string_literal: true

require "rbconfig"
require "tmpdir"

# Semantic-model surface (plan 96): boot-time env opt-in, the
# /v1/check "model" flag, /v1/languages model reporting, and the
# kotoshu >= 0.7.0 guard.
#
# Two regimes, driven by the installed gem:
#
# - kotoshu < 0.7.0: the guard specs run (boot refuses the env
#   config, "model": true is a 503); every model-path spec skips.
# - kotoshu >= 0.7.0: the guard specs skip; the model specs run for
#   real against the setup cache, skipping when onnxruntime or the
#   English model is unavailable (the gem's own :onnx convention).
RSpec.describe "kotoshu-server semantic models" do
  SUPPORTED = Kotoshu::Server::App.semantic_models_supported?

  before(:all) do
    Kotoshu.setup(:en) unless Kotoshu.setup?(:en, :spelling)
    Kotoshu.reset_spellchecker
  end

  def post_json(path, body)
    post path, JSON.generate(body), { "CONTENT_TYPE" => "application/json" }
    begin
      parsed = JSON.parse(last_response.body)
    rescue JSON::ParserError
      parsed = nil
    end
    [last_response, parsed]
  end

  def with_env(vars)
    saved = vars.keys.to_h { |key| [key, ENV[key]] }
    vars.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    saved.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  # ---- Boot-time configuration ----

  describe "KOTOSHU_SERVER_MODEL_LANGS unset" do
    it "validates as a no-op and sets up no model languages" do
      with_env("KOTOSHU_SERVER_MODEL_LANGS" => nil) do
        expect(Kotoshu::Server::App.model_languages).to eq([])
        expect { Kotoshu::Server::App.validate_model_config! }.not_to raise_error
      end
    end
  end

  describe "KOTOSHU_SERVER_MODEL_LANGS on kotoshu < 0.7.0", if: !SUPPORTED do
    it "raises a ModelConfigError naming the requirement and the installed version" do
      with_env("KOTOSHU_SERVER_MODEL_LANGS" => "en") do
        expect { Kotoshu::Server::App.validate_model_config! }
          .to raise_error(Kotoshu::Server::ModelConfigError, a_string_including(
            "KOTOSHU_SERVER_MODEL_LANGS requires kotoshu >= 0.7.0",
            "installed: #{Kotoshu::VERSION}"
          ))
      end
    end

    it "rejects model: true requests with 503 naming the requirement" do
      res, body = post_json("/v1/check", { text: "helo", language: "en", model: true })
      expect(res.status).to eq(503)
      expect(body["error"]).to eq("model_unsupported")
      expect(body["message"]).to include("kotoshu >= 0.7.0")
      expect(body["message"]).to include(Kotoshu::VERSION)
    end

    it "boot fails fast from the exe with the guard message" do
      Dir.mktmpdir("kotoshu-server-model-guard") do |tmp|
        log_path = File.join(tmp, "boot.log")
        pid = Process.spawn(
          {
            "KOTOSHU_SERVER_PORT" => "0",
            "KOTOSHU_SERVER_BIND" => "127.0.0.1",
            "KOTOSHU_SERVER_MODEL_LANGS" => "en",
            "KOTOSHU_CACHE_PATH" => File.join(tmp, "cache")
          },
          RbConfig.ruby, File.expand_path("../exe/kotoshu-server", __dir__),
          out: log_path, err: log_path
        )
        _, status = Process.wait2(pid)
        expect(status.exitstatus).to_not eq(0)
        expect(File.read(log_path)).to include("KOTOSHU_SERVER_MODEL_LANGS requires kotoshu >= 0.7.0")
      end
    end
  end

  describe "KOTOSHU_SERVER_MODEL_TIER validation", if: SUPPORTED do
    it "accepts the known tiers and rejects an unknown tier" do
      with_env("KOTOSHU_SERVER_MODEL_LANGS" => "en") do
        expect { Kotoshu::Server::App.validate_model_config! }.not_to raise_error
        with_env("KOTOSHU_SERVER_MODEL_TIER" => "full") do
          expect { Kotoshu::Server::App.validate_model_config! }.not_to raise_error
        end
        with_env("KOTOSHU_SERVER_MODEL_TIER" => "huge") do
          expect { Kotoshu::Server::App.validate_model_config! }
            .to raise_error(Kotoshu::Server::ModelConfigError, /KOTOSHU_SERVER_MODEL_TIER/)
        end
      end
    end
  end

  # ---- Boot-time setup honored (prewarm) ----

  describe "prewarm! with KOTOSHU_SERVER_MODEL_LANGS", if: SUPPORTED do
    before(:all) do
      Kotoshu.setup(:it) unless Kotoshu.setup?(:it, :spelling)
    end

    it "sets up spelling + model for the listed languages" do
      with_env("KOTOSHU_SERVER_MODEL_LANGS" => "en") do
        Kotoshu::Server::App.prewarm!(%w[en])
      end
      expect(Kotoshu.setup?(:en, :spelling)).to be(true)
      expect(Kotoshu::Server::App.model_available?("en")).to be(true)
    end

    it "sets up spelling only when the var is unset" do
      with_env("KOTOSHU_SERVER_MODEL_LANGS" => nil) do
        Kotoshu::Server::App.prewarm!(%w[it])
      end
      expect(Kotoshu.setup?(:it, :spelling)).to be(true)
      expect(Kotoshu::Server::App.model_available?("it")).to be(false)
    end
  end

  # ---- /v1/languages model reporting ----

  describe "GET /v1/languages" do
    it "reports model availability as a boolean per cached language" do
      get "/v1/languages"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["cached"]).to include("en")
      expect(body["model"]).to be_a(Hash)
      expect(body["model"]).to have_key("en")
      expect(body["model"].values).to all(be(true).or be(false))
      expect(body["model"]["en"]).to eq(Kotoshu::Server::App.model_available?("en"))
    end

    it "reports false on kotoshu without model support", if: !SUPPORTED do
      get "/v1/languages"
      body = JSON.parse(last_response.body)
      expect(body["model"]["en"]).to be(false)
    end
  end

  # ---- /v1/check model flag (real semantic path) ----

  describe "POST /v1/check model flag", if: SUPPORTED do
    before(:all) do
      skip "onnxruntime not loaded" unless Kotoshu::Models::OnnxModel::ONNX_LOADED
      Kotoshu.setup(:en, want: %i[spelling model]) unless Kotoshu.setup?(:en, :model)
      skip "no English model cached" unless Kotoshu.setup?(:en, :model)
      Kotoshu.reset_spellchecker
    end

    it "model: false keeps the dictionary-only suggestion order" do
      res, body = post_json("/v1/check", { text: "helo wrold", language: "en", model: false })
      expect(res.status).to eq(200)
      expect(body["errors"].map { |e| e["word"] }).to contain_exactly("helo", "wrold")
      expect(body["errors"].first["suggestions"].first["word"]).to eq("hello")
      sources = body["errors"].flat_map { |e| e["suggestions"] }.map { |s| s["source"] }
      expect(sources).to_not include("semantic")
    end

    it "model: true reranks through the semantic path without losing errors" do
      res, body = post_json("/v1/check", { text: "helo wrold", language: "en", model: true })
      expect(res.status).to eq(200)
      expect(body["errors"].map { |e| e["word"] }).to contain_exactly("helo", "wrold")
      expect(body["errors"].first["suggestions"]).to_not be_empty
      expect(body["errors"].first["suggestions"].map { |s| s["word"] }).to include("hello")
    end

    it "defaults to the server-side setup state when the flag is omitted" do
      res, body = post_json("/v1/check", { text: "helo wrold", language: "en" })
      expect(res.status).to eq(200)
      expect(body["errors"].map { |e| e["word"] }).to contain_exactly("helo", "wrold")
    end

    it "returns 422 when model: true names a language without a model" do
      res, body = post_json("/v1/check", { text: "helo", language: "it", model: true })
      expect(res.status).to eq(422)
      expect(body["error"]).to eq("resource_not_setup")
      expect(body["message"]).to include("no semantic model set up for language 'it'")
    end
    it "returns 400 for a non-boolean model value" do
      res, body = post_json("/v1/check", { text: "helo", language: "en", model: "yes" })
      expect(res.status).to eq(400)
      expect(body["error"]).to eq("invalid_request")
    end
  end
end
