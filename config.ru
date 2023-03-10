# frozen_string_literal: true

require "bundler/setup"
require_relative "lib/vdom"
require_relative "lib/vdom/server"

DEFAULT_BIND = "https://localhost:8080"

server = VDOM::Server.new(
  bind: ENV.fetch("RDOM_BIND", DEFAULT_BIND),
  localhost: ENV.fetch("RDOM_LOCALHOST", "true").start_with?("t"),
  component: VDOM::Component.load_file("app/App.haml"),
  public_path: File.join(__dir__, "public"),
)

Async do
  server.run
end
