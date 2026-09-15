#!/usr/bin/env ruby
# frozen_string_literal: true

# The OpenAPI contract is only true if it matches the routes the app
# actually registers. Extract both sides and diff - exits nonzero on
# drift in either direction.

require "yaml"
require "set"

app = File.read(File.expand_path("../lib/kotoshu/server/app.rb", __dir__))
routes = Set.new(app.scan(/^\s*(?:get|post|put|delete|patch)\s+['"]([^'"]+)['"]/).flatten)

spec = YAML.safe_load(File.read(File.expand_path("../openapi.yaml", __dir__)))
paths = Set.new(spec.fetch("paths").keys)

missing_in_spec = routes - paths
missing_in_app = paths - routes

abort "routes missing from openapi.yaml: #{missing_in_spec.to_a.sort.join(', ')}" unless missing_in_spec.empty?
abort "openapi.yaml documents nonexistent routes: #{missing_in_app.to_a.sort.join(', ')}" unless missing_in_app.empty?

puts "contract ok: #{routes.size} routes match openapi.yaml"
