# frozen_string_literal: true

require "async"
require "async/queue"
require "async/http/endpoint"
require "async/http/protocol/response"
require "async/http/server"

module VDOM
  class Server
    class Session
      attr_reader :id

      def initialize
        @id = SecureRandom.alphanumeric(32)
        @input = Async::Queue.new
        @output = Async::Queue.new
        @stop = Async::Condition.new
      end

      def take =
        @output.dequeue

      def callback(id, payload) =
        @input.enqueue([:callback, id, payload])
      def pong(time) =
        @input.enqueue([:pong, time])

      def run(component, task: Async::Task.current)
        VDOM.run do |vroot|
          task.async { input_loop(vroot) }
          task.async { ping_loop }
          task.async { patch_loop(vroot) }

          vroot.resume(VDOM::Descriptor[component])

          @stop.wait
        ensure
          vroot&.stop
        end
      end

      private

      def input_loop(vroot)
        loop do
          handle_input(vroot, @input.dequeue)
        rescue Protocol::HTTP2::ProtocolError, EOFError => e
          Console.logger.error(self, e)
          raise
        rescue => e
          Console.logger.error(self, e)
        end
      end

      def handle_input(vroot, message)
        case message
        in :callback, callback_id, payload
          vroot.handle_callback(callback_id, payload)
        in :pong, time
          pong = current_ping_time - time
          puts format("Ping: %.2fms", pong)
        in unhandled
          puts "\e[31mUnhandled: #{unhandled.inspect}\e[0m"
        end
      rescue => e
        Console.logger.error(self, e)
      end

      def current_ping_time =
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)

      def ping_loop
        loop do
          sleep 5
          @output.enqueue(
            VDOM::Patches.serialize(VDOM::Patches::Ping[current_ping_time])
          )
        end
      end

      def patch_loop(vroot)
        while patch = vroot.take
          @output.enqueue(VDOM::Patches.serialize(patch))
        end
      rescue IOError, Errno::EPIPE, Protocol::HTTP2::ProtocolError => e
        puts "\e[31m#{e.message}\e[0m"
      ensure
        @stop.signal
      end
    end

    class App
      SESSION_ID_HEADER_NAME = "x-rdom-session-id"

      ALLOW_HEADERS = {
        "access-control-allow-methods" => "GET, POST, OPTIONS",
        "access-control-allow-headers" => [
          "content-type",
          "accept",
          SESSION_ID_HEADER_NAME,
        ].join(", ").freeze
      }.freeze

      def initialize(component:, public_path:)
        @component = component
        @public_path = public_path
        @sessions = {}
        @file_cache = {}
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
        in "/rdom.js"
          handle_script(request)
        in "/.rdom" if request.method == "OPTIONS"
          handle_options(request)
        in "/.rdom" if request.method == "GET"
          handle_rdom_get(request)
        in "/.rdom" if request.method == "POST"
          handle_rdom_post(request)
        else
          handle_404(request)
        end
      end

      def handle_index(_) =
        send_file("index.html", "text/html; charset=utf-8")
      def handle_favicon(_) =
        send_file("favicon.png", "image/png")
      def handle_script(request) =
        send_file("rdom.js", "application/javascript; charset=utf-8", origin_header(request))

      def handle_404(request)
        Protocol::HTTP::Response[
          404,
          { "content-type" => "text/plain; charset-utf-8" },
          ["404 for #{request.path}"]
        ]
      end

      def handle_options(request)
        headers = {
          **ALLOW_HEADERS,
          **origin_header(request),
        }

        Protocol::HTTP::Response[204, headers, []]
      end

      def handle_rdom_get(request, task: Async::Task.current)
        body = Async::HTTP::Body::Writable.new

        session = Session.new

        task.async do |subtask|
          @sessions.store(session.id, session)

          subtask.async do
            while msg = session.take
              body.write(JSON.generate(msg) + "\n")
            end
          end

          session.run(@component)
        ensure
          @sessions.delete(session.id)
        end

        Protocol::HTTP::Response[
          200,
          {
            "content-type" => "x-rdom/json-stream",
            SESSION_ID_HEADER_NAME => session.id,
            "access-control-expose-headers" => SESSION_ID_HEADER_NAME,
            **origin_header(request),
          },
          body
        ]
      end

      def handle_rdom_post(request)
        session_id = request.headers[SESSION_ID_HEADER_NAME].to_s

        session = @sessions.fetch(session_id) do
          Console.logger.error(self, "Could not find session #{session_id.inspect}")

          return Protocol::HTTP::Response[
            401,
            origin_header(request),
            ["Could not find session #{session_id.inspect}"]
          ]
        end

        each_message(request.body) do |message|
          case message
          in "callback", String => callback_id, payload
            session.callback(callback_id, payload)
          in "pong", Numeric => time
            session.pong(time)
          end
        rescue => e
          Console.logger.error(e)
        end

        Protocol::HTTP::Response[204, origin_header(request), []]
      end

      def each_message(body)
        buf = String.new

        body.each do |chunk|
          buf += chunk

          if idx = buf.index("\n")
            yield JSON.parse(buf[0..idx], symbolize_names: true)
            buf = buf[idx.succ..-1].to_s
          end
        end
      end


      def origin_header(request) =
        { "access-control-allow-origin" => request.headers["origin"] }

      def send_file(filename, content_type, headers = {})
        content = read_public_file(filename)

        Protocol::HTTP::Response[
          200,
          {
            "content-type" => content_type,
            "content-length" => content.bytesize,
            **headers
          },
          [content]
        ]
      end

      def read_public_file(filename)
        path =
          filename
            .then { File.expand_path(_1, "/") }
            .then { File.join(@public_path, _1) }
        @file_cache[path] ||= File.read(path)
      end
    end

    def initialize(bind:, localhost:, component:, public_path:)
      @uri = URI.parse(bind)
      @app = App.new(component:, public_path:)

      endpoint = Async::HTTP::Endpoint.new(@uri)

      if localhost
        endpoint = apply_local_certificate(endpoint)
      end

      @server = Async::HTTP::Server.new(
        @app,
        endpoint,
        scheme: @uri.scheme,
        protocol: Async::HTTP::Protocol::HTTP2,
      )
    end

    def run(task: Async::Task.current)
      task.async do
        puts "\e[3m Starting server on #{@uri} \e[0m"

        @server.run.each(&:wait)
      ensure
        puts "\n\r\e[3;31m Stopped server \e[0m"
      end
    end

    private

    def apply_local_certificate(endpoint)
      require "localhost"
      require "async/io/ssl_endpoint"

      authority = Localhost::Authority.fetch(endpoint.hostname)

      context = authority.server_context
      context.alpn_select_cb = ->(protocols) do
        protocols.include?("h2") ? "h2" : nil
      end

      context.alpn_protocols = ["h2"]
      context.session_id_context = "rdom"

      Async::IO::SSLEndpoint.new(endpoint, ssl_context: context)
    end
  end
end
