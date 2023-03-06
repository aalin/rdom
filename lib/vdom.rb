# frozen_string_literal: true

require "securerandom"
require_relative "vdom/descriptor"
require_relative "vdom/component"
require_relative "vdom/patches"
require_relative "vdom/reactively"
require_relative "vdom/nodes"

module VDOM
  def self.random_id = SecureRandom.alphanumeric(5)

  def self.run(session_id: SecureRandom.alphanumeric(32))
    Reactively.run do
      vroot = VDOM::Nodes::VRoot.start(session_id:)
      yield vroot
    ensure
      vroot&.stop
    end
  end
end
