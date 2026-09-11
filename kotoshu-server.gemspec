# frozen_string_literal: true

require_relative "lib/kotoshu/server/version"

Gem::Specification.new do |spec|
  spec.name = "kotoshu-server"
  spec.version = Kotoshu::Server::VERSION
  spec.authors = ["Ribose Inc."]
  spec.email = ["open.source@ribose.com"]

  spec.summary = "HTTP API server wrapping the Kotoshu spell checker"
  spec.description = "Self-hostable HTTP API that exposes Kotoshu's check / " \
                    "suggest / detect over JSON. Designed as the deployment " \
                    "surface for non-Ruby SDKs (Python, JS, Go)."
  spec.homepage = "https://github.com/kotoshu/kotoshu-server"
  spec.required_ruby_version = ">= 3.1.0"
  spec.license = "BSD-2-Clause"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/kotoshu/kotoshu-server/tree/main"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.glob(
    %w[exe/**/* lib/**/* openapi.yaml README.md LICENSE],
    base: __dir__
  ).select { |f| File.file?(File.expand_path(f, __dir__)) }
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "kotoshu", "~> 1.0"
  spec.add_runtime_dependency "sinatra", "~> 3.2"
  spec.add_runtime_dependency "puma", "~> 6.4"
  spec.add_runtime_dependency "logger", "~> 1.0"
end
