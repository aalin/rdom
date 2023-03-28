# frozen_string_literal: true

require "securerandom"
require_relative "vdom/descriptor"
require_relative "vdom/style_sheet"
require_relative "vdom/component"
require_relative "vdom/patches"
require_relative "vdom/nodes"

module VDOM
  def self.run
    vroot = VDOM::Nodes::VRoot.start
    yield vroot
  ensure
    vroot&.stop
  end
end
