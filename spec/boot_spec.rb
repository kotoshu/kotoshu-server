# frozen_string_literal: true

require "net/http"
require "rbconfig"
require "timeout"
require "tmpdir"

RSpec.describe "kotoshu-server boot path" do
  EXE = File.expand_path("../exe/kotoshu-server", __dir__)

  def fetch_health(port)
    Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/v1/health"))
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET, IOError, SystemCallError
    nil
  end

  def stop_server(pid)
    Process.kill("TERM", pid)
    Timeout.timeout(10) { Process.wait(pid) }
  rescue Errno::ESRCH, Timeout::Error
    begin
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end
    begin
      Process.wait(pid)
    rescue Errno::ECHILD, Errno::ESRCH
      nil
    end
  end

  describe "Kotoshu::Server::App.prewarm_async!" do
    it "returns promptly with a detached thread instead of blocking the caller" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      thread = Kotoshu::Server::App.prewarm_async!(%w[en])
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(thread).to be_a(Thread)
      expect(thread).to_not eq(Thread.main)
      expect(elapsed).to be < 5.0

      thread.join(60) # do not leak the thread into other specs
      expect(Kotoshu.setup?(:en, :spelling)).to be(true)
    end
  end

  describe "spawning exe/kotoshu-server against a cold cache" do
    it "answers /v1/health while pre-warm is still running" do
      Dir.mktmpdir("kotoshu-server-boot") do |tmp|
        log_path = File.join(tmp, "boot.log")
        probe = TCPServer.new("127.0.0.1", 0)
        port = probe.addr[1]
        probe.close

        pid = Process.spawn(
          {
            "KOTOSHU_SERVER_PORT" => port.to_s,
            "KOTOSHU_SERVER_BIND" => "127.0.0.1",
            "KOTOSHU_SERVER_LANGUAGES" => "en",
            "KOTOSHU_CACHE_PATH" => File.join(tmp, "cache")
          },
          RbConfig.ruby, EXE, out: log_path, err: log_path
        )

        begin
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          deadline = started + 20
          response = nil
          until response || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            response = fetch_health(port)
            sleep 0.2 unless response
          end
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

          expect(response).to_not be_nil, "server did not answer within 20s; boot log:\n#{File.read(log_path)}"
          expect(response.code).to eq("200")
          body = JSON.parse(response.body)
          expect(body).to include("ready")
          expect(elapsed).to be < 15.0
        ensure
          stop_server(pid) if pid
        end
      end
    end
  end
end
