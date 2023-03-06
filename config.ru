# frozen_string_literal: true

require "bundler/setup"
require "async"
require "async/http/endpoint"
require "async/http/protocol/response"
require "async/http/server"
require "async/io/host_endpoint"
require "async/io/ssl_endpoint"
require "localhost"

require_relative "lib/vdom"

MyComponent = VDOM::Component.load_file("app/MyComponent.rb")

class Session
  attr_reader :id

  def initialize
    @id = SecureRandom.alphanumeric(32)
    @input = Async::Queue.new
    @output = Async::Queue.new
    @stop = Async::Condition.new
  end

  def send(msg) =
    @input.enqueue(msg)
  def take =
    @output.dequeue

  def run(task: Async::Task.current)
    VDOM.run(session_id: self.id) do |vroot|
      task.async do
        loop do
          case @input.dequeue
          in [:callback, callback_id, payload]
            vroot.handle_callback(callback_id, payload)
          in unhandled
            puts "\e[31mUnhandled: #{unhandled}\e[0m"
          end
        rescue Protocol::HTTP2::ProtocolError
          puts "Got ProtocolError"
          break
        rescue EOFError
          puts "Got EOF"
          break
        rescue => e
          Console.logger.error(self, e)
        end
      end

      task.async do
        while patch = vroot.take
          @output.enqueue(VDOM::Patches.serialize(patch))
        end
      rescue IOError, Errno::EPIPE, Protocol::HTTP2::ProtocolError => e
        puts "\e[31m#{e.message}\e[0m"
      ensure
        @stop.signal
      end

      vroot.resume(VDOM::Descriptor[MyComponent])

      @stop.wait
    ensure
      vroot&.stop
    end
  end
end

class App
  def initialize
    @sessions = {}
  end

  def call(request, task: Async::Task.current)
    Console.logger.info(
      "#{request.method} #{request.path}",
    )

    case request.path
    in "/"
      handle_index(request)
    in "/favicon.ico"
      handle_favicon(request)
    in "/.rdom.js"
      handle_script(request)
    in "/.rdom" if request.method == "OPTIONS"
      handle_options(request)
    in "/.rdom" if request.method == "GET"
      handle_stream(request)
    in "/.rdom" if request.method == "PUT"
      handle_callback(request)
    else
      handle_404(request)
    end
  end

  def handle_index(_) =
    send_file("index.html", "text/html; charset=utf-8")
  def handle_favicon(_) =
    send_file("favicon.png", "image/png")
  def handle_script(request) =
    send_file("main.js", "application/javascript; charset=utf-8", {
      "access-control-allow-origin" => request.headers["origin"],
    })

  def handle_404(request)
    Protocol::HTTP::Response[
      404,
      { "content-type" => "text/plain; charset-utf-8" },
      ["404 for #{request.path}"]
    ]
  end

  def handle_options(request)
    Protocol::HTTP::Response[
      204,
      {
        "access-control-allow-methods" => "GET, PUT, OPTIONS",
        "access-control-allow-origin" => request.headers["origin"],
        "access-control-allow-headers" => "x-rdom-session-id, content-type, accept",
      },
      [""]
    ]
  end

  def handle_callback(request)
    JSON.parse(request.body.read, symbolize_names: true) => [
      session_id,
      callback_id,
      payload,
    ]

    @sessions
      .fetch(session_id)
      .send([:callback, callback_id, payload])

    Protocol::HTTP::Response[
      204,
      {
        "access-control-allow-origin" => request.headers["origin"],
      },
      [""]
    ]
  end

  def handle_stream(request, task: Async::Task.current)
    body = Async::HTTP::Body::Writable.new

    session = Session.new

    task.async do |subtask|
      @sessions.store(session.id, session)

      subtask.async do
        while msg = session.take
          body.write(JSON.generate(msg) + "\n")
        end
      end

      session.run
    ensure
      @sessions.delete(session.id)
    end

    Protocol::HTTP::Response[
      200,
      {
        "content-type" => "x-rdom/json-stream",
        "x-rdom-session-id" => session.id,
        "access-control-allow-origin" => request.headers["origin"],
      },
      body
    ]
  end

  def send_file(filename, content_type, headers = {})
    path = File.join(
      __dir__,
      "public",
      File.expand_path(filename, "/")
    )

    Protocol::HTTP::Response[
      200,
      { "content-type" => content_type, **headers },
      [File.read(path)]
    ]
  end
end

def setup_local_certificate(endpoint)
  authority = Localhost::Authority.fetch(endpoint.hostname)

  context = authority.server_context
  context.alpn_select_cb = ->(protocols) { protocols.include?("h2") ? "h2" : nil }

  context.alpn_protocols = ["h2"]
  context.session_id_context = "rdom"

  Async::IO::SSLEndpoint.new(endpoint, ssl_context: context)
end


endpoint = Async::HTTP::Endpoint.parse(
  ENV.fetch("ENDPOINT", "https://localhost:8080")
)
url = endpoint.url

if url.scheme == "https" && url.hostname == "localhost"
  endpoint = setup_local_certificate(endpoint)
end

puts "Starting server on #{url}"

server = Async::HTTP::Server.new(
  App.new,
  endpoint,
  scheme: url.scheme,
  protocol: Async::HTTP::Protocol::HTTP2,
)

Async do
  server.run
end
