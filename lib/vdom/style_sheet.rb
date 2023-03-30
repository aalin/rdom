# frozen_string_literal: true

require "mime-types"

module VDOM
  StyleSheet = Data.define(:asset) do
    def self.mime_type =
      MIME::Types["text/css"].first

    def self.[](content) =
      new(Assets::Asset[content, mime_type])

    def import_html =
      %{<link rel="stylesheet" href="#{asset.path}" integrity="#{asset.content.integrity}" crossorigin="anonymous">}
  end
end
