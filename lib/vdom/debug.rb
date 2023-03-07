require "digest/sha2"
require "singleton"

module VDOM
  class Debug
    include Singleton

    def self.enabled? =
      Fiber[:vdom_debug_enabled?] != false

    def self.disable(enabled = false, &)
      prev = Fiber[:vdom_debug_enabled?]
      Fiber[:vdom_debug_enabled?] = enabled
      yield
    ensure
      Fiber[:vdom_debug_enabled?] = prev
    end

    def d(**kwargs)
      return unless self.class.enabled?

      kwargs.map do |key, value|
        "#{colorize(key)}: #{value.inspect}"
      end.join(", ").then { puts "{#{_1}}" }
    end

    def colorize(str)
      "\e[38;5;#{color(str)}m#{str}\e[0m"
    end

    def color(str)
      16 + Digest::SHA256.digest(str.to_s).bytes.first % 200
    end

    module Refinements
      refine Kernel do
        def d(**) = Debug.instance.d(**)
      end
    end
  end
end
