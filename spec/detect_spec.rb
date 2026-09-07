# frozen_string_literal: true

# /v1/detect engine selection (kotoshu 0.10.0 lid-176, plan 106).
#
# Two regimes, driven by the installed gem — mirroring
# spec/model_spec.rb:
#
# - kotoshu >= 0.10.0: /v1/detect serves lid-176 (176 languages,
#   through the native extension) once the model is set up — lazily,
#   on the first request — and the engine field reports which engine
#   answered. These specs run the real Kotoshu.detect_language; no
#   stubs.
# - kotoshu < 0.10.0: the endpoint falls back to the 7-language
#   heuristic (the 0.1.1 behavior) and says so in the engine field.
RSpec.describe "kotoshu-server language detection" do
  LID_SUPPORTED = Kotoshu::Server::App.lid_supported?

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

  # The engine the gem serves /v1/detect from right now, asked after
  # the request so a first-request lazy setup is reflected: lid-176
  # when the native model is loadable, the heuristic otherwise.
  def served_engine
    return "heuristic" unless LID_SUPPORTED && defined?(Kotoshu::Language::LidDetector)

    Kotoshu::Language::LidDetector.available? ? "lid-176" : "heuristic"
  end

  describe "POST /v1/detect" do
    it "returns language, confidence, and the engine that served" do
      res, body = post_json("/v1/detect", { text: "hello world" })
      expect(res.status).to eq(200)
      expect(body["language"]).to eq("en")
      expect(body["confidence"]).to be_a(Float)
      expect(body["engine"]).to eq(served_engine)
    end

    it "answers empty text instead of rejecting it" do
      res, body = post_json("/v1/detect", { text: "" })
      expect(res.status).to eq(200)
      expect(body["language"]).to be_nil.or be_a(String)
      expect(body["confidence"]).to be_a(Numeric)
      expect(body["engine"]).to eq(served_engine)
    end

    it "returns 400 when text is missing" do
      res, body = post_json("/v1/detect", {})
      expect(res.status).to eq(400)
      expect(body["error"]).to eq("invalid_request")
    end
  end

  describe "heuristic fallback on kotoshu < 0.10.0", if: !LID_SUPPORTED do
    it "keeps the 0.1.1 behavior and reports the heuristic engine" do
      res, body = post_json("/v1/detect", { text: "Grüße aus Köln" })
      expect(res.status).to eq(200)
      expect(body["language"]).to eq("de")
      expect(body["confidence"]).to be_a(Float)
      expect(body["engine"]).to eq("heuristic")
    end
  end

  describe "lid-176 path on kotoshu >= 0.10.0", if: LID_SUPPORTED do
    it "detects languages beyond the 7 heuristic ones" do
      res, body = post_json("/v1/detect", { text: "Γεια σου κόσμε" })
      expect(res.status).to eq(200)
      expect(body["engine"]).to eq(served_engine)
      expected_language = body["engine"] == "lid-176" ? "el" : nil
      expect(body["language"]).to eq(expected_language)
    end
  end

  describe "KOTOSHU_DETECT=heuristic" do
    it "pins the heuristic engine regardless of the gem selection" do
      with_env("KOTOSHU_DETECT" => "heuristic") do
        res, body = post_json("/v1/detect", { text: "Grüße aus Köln" })
        expect(res.status).to eq(200)
        expect(body["language"]).to eq("de")
        expect(body["engine"]).to eq("heuristic")
      end
    end
  end
end
