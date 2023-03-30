# frozen_string_literal: true

module VDOM
  CustomElement = Data.define(:name, :stylesheet, :asset) do
    def self.mime_type =
      MIME::Types["text/html"].first

    def self.[](name, html, stylesheet) =
      new(name, stylesheet, Assets::Asset["#{stylesheet&.import_html}#{html}", mime_type])
  end
end
