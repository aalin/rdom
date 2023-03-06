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

  def run(component, task: Async::Task.current)
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
        loop do
          sleep 5
          @output.enqueue(
            VDOM::Patches.serialize(VDOM::Patches::Ping[Process.clock_gettime(Process::CLOCK_MONOTONIC)])
          )
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

      vroot.resume(VDOM::Descriptor[component])

      @stop.wait
    ensure
      vroot&.stop
    end
  end
end

class App
  SESSION_ID_HEADER_NAME = "x-rdom-session-id"

  def initialize(app)
    @app = app
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
    in "/.rdom" if request.method == "POST"
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
    send_file("main.js", "application/javascript; charset=utf-8", origin_header(request))

  def handle_404(request)
    Protocol::HTTP::Response[
      404,
      { "content-type" => "text/plain; charset-utf-8" },
      ["404 for #{request.path}"]
    ]
  end

  def handle_options(request)
    headers = {
      "access-control-allow-methods" => "GET, POST, OPTIONS",
      "access-control-allow-headers" => "#{SESSION_ID_HEADER_NAME}, content-type, accept",
      **origin_header(request),
    }

    Protocol::HTTP::Response[204, headers, []]
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

      session.run(@app)
    ensure
      @sessions.delete(session.id)
    end

    Protocol::HTTP::Response[
      200,
      {
        "content-type" => "x-rdom/json-stream",
        SESSION_ID_HEADER_NAME => session.id,
        **origin_header(request),
      },
      body
    ]
  end

  def handle_callback(request)
    session_id = request.headers[SESSION_ID_HEADER_NAME].to_s

    session = @sessions.fetch(session_id) do
      Console.logger.error(self, "Could not find session #{session_id.inspect}")

      return Protocol::HTTP::Response[
        404,
        origin_header(request),
        ["Could not find session #{session_id.inspect}"]
      ]
    end

    request.body.each do |chunk|
      JSON.parse(chunk, symbolize_names: true) => [
        callback_id,
        payload,
      ]
      session.send([:callback, callback_id, payload])
    end

    Protocol::HTTP::Response[204, {}, []]
  end

  def origin_header(request) =
    { "access-control-allow-origin" => request.headers["origin"] }

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

app = VDOM::Component.load_file("app/App.rb")

server = Async::HTTP::Server.new(
  App.new(app),
  endpoint,
  scheme: url.scheme,
  protocol: Async::HTTP::Protocol::HTTP2,
)

Async do
  server.run
end
