# frozen_string_literal: true

require "securerandom"
require_relative "vdom/descriptor"
require_relative "vdom/component"
require_relative "vdom/patches"
require_relative "vdom/reactively"
require_relative "vdom/nodes"

module VDOM
  def self.run
    Reactively.run do
      vroot = VDOM::Nodes::VRoot.start
      yield vroot
    ensure
      vroot&.stop
    end
  end
end
