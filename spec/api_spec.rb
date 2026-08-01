# frozen_string_literal: true

RSpec.describe "kotoshu-server HTTP API" do
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

  it "GET / reports server metadata" do
    get "/"
    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["name"]).to eq("kotoshu-server")
    expect(body["kotoshu_version"]).to eq(Kotoshu::VERSION)
  end

  it "GET /v1/health returns ready status" do
    get "/v1/health"
    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["status"]).to eq("ok")
    expect(body["ready"]).to include("en" => true)
  end

  it "GET /v1/version returns server + kotoshu versions" do
    get "/v1/version"
    body = JSON.parse(last_response.body)
    expect(body["server"]).to eq(Kotoshu::Server::VERSION)
    expect(body["kotoshu"]).to eq(Kotoshu::VERSION)
  end

  it "POST /v1/check returns errors for misspelled text" do
    res, body = post_json("/v1/check", { text: "helo wrold", language: "en" })
    expect(res.status).to eq(200)
    expect(body["errors"].map { |e| e["word"] }).to contain_exactly("helo", "wrold")
    expect(body["errors"].first["suggestions"].first["word"]).to eq("hello")
  end

  it "POST /v1/suggest returns suggestions" do
    res, body = post_json("/v1/suggest", { word: "helo", language: "en", max: 3 })
    expect(res.status).to eq(200)
    words = body["suggestions"].map { |s| s["word"] }
    expect(words.first(3)).to include("hello")
    expect(body["suggestions"].length).to be <= 3
  end

  it "POST /v1/detect returns language + confidence" do
    res, body = post_json("/v1/detect", { text: "hello world" })
    expect(res.status).to eq(200)
    expect(body["language"]).to be_a(String)
    expect(body["confidence"]).to be_a(Float)
  end

  it "returns 400 on missing 'text'" do
    res, body = post_json("/v1/check", { language: "en" })
    expect(res.status).to eq(400)
    expect(body["error"]).to eq("invalid_request")
  end
end
