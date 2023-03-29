# frozen_string_literal: true

require "mime-types"

module VDOM
  StyleSheet = Data.define(:asset) do
    def self.mime_type =
      MIME::Types["text/css"].first

    def self.[](content) =
      new(Assets::Asset[content, mime_type])

    def import_html =
      "<style>@import url(#{asset.path});</style>"
  end
end
